import json
import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

# repo_root/risk_engine/keeper/config.py -> parents[2] is repo root
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ADDRESSES_PATH = REPO_ROOT / "contracts" / "deployments" / "addresses.json"
DEFAULT_ROOT_ENV_PATH = REPO_ROOT / ".env"
DEFAULT_CONTRACTS_ENV_PATH = REPO_ROOT / "contracts" / ".env"
DEFAULT_BOT_LOG_PATH = Path(__file__).resolve().with_name("bot.log")

# Loads risk_engine/keeper/.env when present.
load_dotenv(Path(__file__).resolve().with_name(".env"))
# Loads repo-level .env so one shared secrets file can be used.
load_dotenv(DEFAULT_ROOT_ENV_PATH)
# Also load contracts/.env so existing deployment secrets work out of the box.
load_dotenv(DEFAULT_CONTRACTS_ENV_PATH)
load_dotenv()


@dataclass(frozen=True)
class KeeperConfig:
    rpc_url: str
    private_key: str
    fred_api_key: str
    oracle_address: str
    margin_engine_address: str
    repo_vault_address: str
    chain_id: int = 11155111
    poll_interval_seconds: int = 1800
    fred_series_id: str = "DTB4WK"
    tbill_face_value_usd: float = 1000.0
    tbill_term_days: int = 28
    tx_timeout_seconds: int = 180
    price_change_threshold_bps: int = 10
    stale_update_floor_seconds: int = 5400
    log_file_path: str = str(DEFAULT_BOT_LOG_PATH)


def _read_addresses(path: Path) -> dict:
    if not path.exists():
        raise FileNotFoundError(f"addresses.json not found at: {path}")

    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)

    required = ["BondPriceOracle", "MarginEngine", "RepoVault"]
    missing = [k for k in required if k not in data]
    if missing:
        raise ValueError(f"Missing contract addresses in {path}: {missing}")

    return data


def load_config() -> KeeperConfig:
    addresses_path = Path(
        os.getenv("ADDRESSES_PATH", str(DEFAULT_ADDRESSES_PATH))
    ).resolve()
    addresses = _read_addresses(addresses_path)

    rpc_url = os.getenv("RPC_URL", "").strip()
    private_key = os.getenv("PRIVATE_KEY", "").strip()
    fred_api_key = os.getenv("FRED_API_KEY", "").strip()

    if not rpc_url:
        raise ValueError("RPC_URL is required")
    if not private_key:
        raise ValueError("PRIVATE_KEY is required")
    if not fred_api_key:
        raise ValueError("FRED_API_KEY is required")

    return KeeperConfig(
        rpc_url=rpc_url,
        private_key=private_key,
        fred_api_key=fred_api_key,
        oracle_address=addresses["BondPriceOracle"],
        margin_engine_address=addresses["MarginEngine"],
        repo_vault_address=addresses["RepoVault"],
        chain_id=int(os.getenv("CHAIN_ID", "11155111")),
        poll_interval_seconds=int(os.getenv("BOT_INTERVAL_SECONDS", "1800")),
        fred_series_id=os.getenv("FRED_SERIES_ID", "DTB4WK"),
        tbill_face_value_usd=float(os.getenv("TBILL_FACE_VALUE_USD", "1000")),
        tbill_term_days=int(os.getenv("TBILL_TERM_DAYS", "28")),
        tx_timeout_seconds=int(os.getenv("TX_TIMEOUT_SECONDS", "180")),
        price_change_threshold_bps=int(
            os.getenv("PRICE_CHANGE_THRESHOLD_BPS", "10")
        ),
        stale_update_floor_seconds=int(
            os.getenv("STALE_UPDATE_FLOOR_SECONDS", "5400")
        ),
        log_file_path=os.getenv("KEEPER_LOG_PATH", str(DEFAULT_BOT_LOG_PATH)),
    )
