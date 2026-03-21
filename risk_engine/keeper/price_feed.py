from datetime import datetime

import requests

try:
    from risk_engine.keeper.config import KeeperConfig
except ModuleNotFoundError:
    from config import KeeperConfig

FRED_OBSERVATIONS_URL = "https://api.stlouisfed.org/fred/series/observations"


def fetch_latest_yield_percent(config: KeeperConfig) -> tuple[float, str]:
    params = {
        "series_id": config.fred_series_id,
        "api_key": config.fred_api_key,
        "file_type": "json",
        "sort_order": "desc",
        "limit": 10,
    }

    response = requests.get(FRED_OBSERVATIONS_URL, params=params, timeout=20)
    response.raise_for_status()
    payload = response.json()

    observations = payload.get("observations", [])
    for row in observations:
        value = row.get("value", ".")
        if value == ".":
            continue
        return float(value), row.get("date", "")

    raise RuntimeError("FRED returned no usable observations")


def yield_to_price_8dp(
    annual_yield_percent: float,
    face_value_usd: float,
    term_days: int,
) -> int:
    # Bank-discount yield conversion used by T-bill discount-rate series.
    annual_yield = annual_yield_percent / 100.0
    price_usd = face_value_usd * (1.0 - annual_yield * (term_days / 360.0))
    if price_usd <= 0:
        raise ValueError("Computed non-positive T-bill price from yield input")
    return int(round(price_usd * 1e8))


def get_latest_tbill_price_8dp(config: KeeperConfig) -> tuple[int, float, str, str]:
    yld, as_of_date = fetch_latest_yield_percent(config)
    price_8dp = yield_to_price_8dp(
        annual_yield_percent=yld,
        face_value_usd=config.tbill_face_value_usd,
        term_days=config.tbill_term_days,
    )
    fetched_at = datetime.utcnow().isoformat(timespec="seconds") + "Z"
    return price_8dp, yld, as_of_date, fetched_at
