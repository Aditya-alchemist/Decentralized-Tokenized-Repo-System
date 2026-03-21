from web3 import Web3

try:
    from risk_engine.keeper.config import KeeperConfig
except ModuleNotFoundError:
    from config import KeeperConfig

ORACLE_ABI = [
    {
        "inputs": [{"internalType": "uint256", "name": "_price", "type": "uint256"}],
        "name": "updatePrice",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "getLatestPrice",
        "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "getLastUpdated",
        "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    }
]


class OracleUpdater:
    def __init__(self, config: KeeperConfig) -> None:
        self.config = config
        self.w3 = Web3(Web3.HTTPProvider(config.rpc_url))

        if not self.w3.is_connected():
            raise ConnectionError("Failed to connect to RPC endpoint")

        self.account = self.w3.eth.account.from_key(config.private_key)
        self.oracle = self.w3.eth.contract(
            address=Web3.to_checksum_address(config.oracle_address),
            abi=ORACLE_ABI,
        )

    def get_latest_price(self) -> int | None:
        try:
            return int(self.oracle.functions.getLatestPrice().call())
        except Exception:
            # Reverts before first oracle write or when stale threshold is breached.
            return None

    def get_last_updated(self) -> int | None:
        try:
            ts = int(self.oracle.functions.getLastUpdated().call())
            if ts == 0:
                return None
            return ts
        except Exception:
            return None

    def push_price(self, price_8dp: int) -> str:
        nonce = self.w3.eth.get_transaction_count(self.account.address)

        tx = self.oracle.functions.updatePrice(int(price_8dp)).build_transaction(
            {
                "from": self.account.address,
                "chainId": self.config.chain_id,
                "nonce": nonce,
            }
        )

        if "gas" not in tx:
            tx["gas"] = self.oracle.functions.updatePrice(int(price_8dp)).estimate_gas(
                {"from": self.account.address}
            )
        if "maxFeePerGas" not in tx and "maxPriorityFeePerGas" not in tx:
            tx["gasPrice"] = self.w3.eth.gas_price

        signed = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        self.w3.eth.wait_for_transaction_receipt(
            tx_hash,
            timeout=self.config.tx_timeout_seconds,
        )
        return tx_hash.hex()
