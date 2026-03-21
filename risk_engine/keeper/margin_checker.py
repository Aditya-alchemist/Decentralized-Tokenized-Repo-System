from web3 import Web3

try:
    from risk_engine.keeper.config import KeeperConfig
except ModuleNotFoundError:
    from config import KeeperConfig

MARGIN_ENGINE_ABI = [
    {
        "inputs": [{"internalType": "uint256[]", "name": "repoIds", "type": "uint256[]"}],
        "name": "checkRepos",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "anonymous": False,
        "inputs": [
            {"indexed": True, "internalType": "uint256", "name": "repoId", "type": "uint256"},
            {"indexed": False, "internalType": "uint256", "name": "currentLTV", "type": "uint256"},
            {"indexed": False, "internalType": "uint256", "name": "deadline", "type": "uint256"},
        ],
        "name": "MarginCallTriggered",
        "type": "event",
    },
    {
        "anonymous": False,
        "inputs": [
            {"indexed": True, "internalType": "uint256", "name": "repoId", "type": "uint256"},
            {"indexed": False, "internalType": "uint256", "name": "currentLTV", "type": "uint256"},
        ],
        "name": "LiquidationTriggered",
        "type": "event",
    },
    {
        "anonymous": False,
        "inputs": [
            {"indexed": True, "internalType": "uint256", "name": "repoId", "type": "uint256"},
            {"indexed": False, "internalType": "uint256", "name": "currentLTV", "type": "uint256"},
        ],
        "name": "RepoHealthy",
        "type": "event",
    }
]

REPO_VAULT_ABI = [
    {
        "inputs": [],
        "name": "nextRepoId",
        "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [{"internalType": "uint256", "name": "repoId", "type": "uint256"}],
        "name": "getRepo",
        "outputs": [
            {
                "components": [
                    {"internalType": "address", "name": "borrower", "type": "address"},
                    {"internalType": "uint256", "name": "collateralAmount", "type": "uint256"},
                    {"internalType": "uint256", "name": "loanAmount", "type": "uint256"},
                    {"internalType": "uint256", "name": "repoRateBps", "type": "uint256"},
                    {"internalType": "uint256", "name": "haircutBps", "type": "uint256"},
                    {"internalType": "uint256", "name": "openedAt", "type": "uint256"},
                    {"internalType": "uint256", "name": "maturityDate", "type": "uint256"},
                    {"internalType": "uint256", "name": "termDays", "type": "uint256"},
                    {"internalType": "bool", "name": "isActive", "type": "bool"},
                    {"internalType": "bool", "name": "marginCallActive", "type": "bool"},
                    {"internalType": "uint256", "name": "marginCallDeadline", "type": "uint256"},
                ],
                "internalType": "struct RepoVault.RepoPosition",
                "name": "",
                "type": "tuple",
            }
        ],
        "stateMutability": "view",
        "type": "function",
    },
]


class MarginChecker:
    def __init__(self, config: KeeperConfig) -> None:
        self.config = config
        self.w3 = Web3(Web3.HTTPProvider(config.rpc_url))

        if not self.w3.is_connected():
            raise ConnectionError("Failed to connect to RPC endpoint")

        self.account = self.w3.eth.account.from_key(config.private_key)
        self.margin_engine = self.w3.eth.contract(
            address=Web3.to_checksum_address(config.margin_engine_address),
            abi=MARGIN_ENGINE_ABI,
        )
        self.repo_vault = self.w3.eth.contract(
            address=Web3.to_checksum_address(config.repo_vault_address),
            abi=REPO_VAULT_ABI,
        )

    def get_active_repo_ids(self) -> list[int]:
        next_repo_id = int(self.repo_vault.functions.nextRepoId().call())
        active: list[int] = []

        for repo_id in range(next_repo_id):
            repo = self.repo_vault.functions.getRepo(repo_id).call()
            if bool(repo[8]):
                active.append(repo_id)

        return active

    def check_active_repos(self) -> dict | None:
        repo_ids = self.get_active_repo_ids()
        if not repo_ids:
            return None

        nonce = self.w3.eth.get_transaction_count(self.account.address)
        tx = self.margin_engine.functions.checkRepos(repo_ids).build_transaction(
            {
                "from": self.account.address,
                "chainId": self.config.chain_id,
                "nonce": nonce,
            }
        )

        if "gas" not in tx:
            tx["gas"] = self.margin_engine.functions.checkRepos(repo_ids).estimate_gas(
                {"from": self.account.address}
            )
        if "maxFeePerGas" not in tx and "maxPriorityFeePerGas" not in tx:
            tx["gasPrice"] = self.w3.eth.gas_price

        signed = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = self.w3.eth.wait_for_transaction_receipt(
            tx_hash,
            timeout=self.config.tx_timeout_seconds,
        )

        margin_engine_logs = [
            log
            for log in receipt.logs
            if log.get("address", "").lower() == self.margin_engine.address.lower()
        ]

        def _decode_event(event) -> list:
            decoded = []
            for log in margin_engine_logs:
                try:
                    decoded.append(event.process_log(log))
                except Exception:
                    # Ignore logs that belong to different events.
                    pass
            return decoded

        margin_calls = _decode_event(self.margin_engine.events.MarginCallTriggered())
        liquidations = _decode_event(self.margin_engine.events.LiquidationTriggered())
        healthy = _decode_event(self.margin_engine.events.RepoHealthy())

        return {
            "tx_hash": tx_hash.hex(),
            "active_repo_ids": repo_ids,
            "margin_calls": [
                {
                    "repo_id": int(evt["args"]["repoId"]),
                    "ltv_bps": int(evt["args"]["currentLTV"]),
                    "deadline": int(evt["args"]["deadline"]),
                }
                for evt in margin_calls
            ],
            "liquidations": [
                {
                    "repo_id": int(evt["args"]["repoId"]),
                    "ltv_bps": int(evt["args"]["currentLTV"]),
                }
                for evt in liquidations
            ],
            "healthy": [
                {
                    "repo_id": int(evt["args"]["repoId"]),
                    "ltv_bps": int(evt["args"]["currentLTV"]),
                }
                for evt in healthy
            ],
        }
