from datetime import datetime

import requests

try:
    from risk_engine.keeper.config import KeeperConfig
except ModuleNotFoundError:
    from config import KeeperConfig

FRED_OBSERVATIONS_URL = "https://api.stlouisfed.org/fred/series/observations"


def fetch_latest_yield_percent(api_key: str, series_id: str) -> tuple[float, str]:
    params = {
        "series_id": series_id,
        "api_key": api_key,
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


def price_8dp_to_implied_yield_percent(
    price_8dp: int,
    face_value_usd: float,
    term_days: int,
) -> float:
    if price_8dp <= 0:
        raise ValueError("Invalid price_8dp for implied yield conversion")

    price_usd = price_8dp / 1e8
    if face_value_usd <= 0 or term_days <= 0:
        raise ValueError("face_value_usd and term_days must be positive")

    # Inverse of bank-discount conversion used in yield_to_price_8dp.
    implied = (1.0 - (price_usd / face_value_usd)) * (360.0 / term_days) * 100.0
    return max(implied, 0.0)


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
    primary_yld, primary_as_of = fetch_latest_yield_percent(
        api_key=config.fred_api_key,
        series_id=config.fred_series_id,
    )

    target_yield = primary_yld
    as_of_date = primary_as_of
    if config.fred_secondary_series_id:
        try:
            secondary_yld, secondary_as_of = fetch_latest_yield_percent(
                api_key=config.fred_api_key,
                series_id=config.fred_secondary_series_id,
            )
            w = min(max(config.secondary_series_weight, 0.0), 1.0)
            target_yield = (1.0 - w) * primary_yld + w * secondary_yld
            as_of_date = max(primary_as_of, secondary_as_of)
        except Exception:
            # Keep primary series as fallback when optional secondary feed is unavailable.
            target_yield = primary_yld

    yld = target_yield
    price_8dp = yield_to_price_8dp(
        annual_yield_percent=yld,
        face_value_usd=config.tbill_face_value_usd,
        term_days=config.tbill_term_days,
    )
    fetched_at = datetime.utcnow().isoformat(timespec="seconds") + "Z"
    return price_8dp, yld, as_of_date, fetched_at


def get_latest_tbill_price_8dp_smoothed(
    config: KeeperConfig,
    current_onchain_price_8dp: int | None,
) -> tuple[int, float, str, str]:
    price_8dp, target_yield, as_of_date, fetched_at = get_latest_tbill_price_8dp(config)

    if current_onchain_price_8dp is None or current_onchain_price_8dp <= 0:
        return price_8dp, target_yield, as_of_date, fetched_at

    try:
        current_yield = price_8dp_to_implied_yield_percent(
            current_onchain_price_8dp,
            face_value_usd=config.tbill_face_value_usd,
            term_days=config.tbill_term_days,
        )
    except Exception:
        return price_8dp, target_yield, as_of_date, fetched_at

    alpha = min(max(config.yield_smoothing_alpha, 0.0), 1.0)
    smoothed_yield = alpha * target_yield + (1.0 - alpha) * current_yield
    smoothed_price_8dp = yield_to_price_8dp(
        annual_yield_percent=smoothed_yield,
        face_value_usd=config.tbill_face_value_usd,
        term_days=config.tbill_term_days,
    )
    return smoothed_price_8dp, smoothed_yield, as_of_date, fetched_at
