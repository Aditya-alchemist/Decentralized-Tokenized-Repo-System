import argparse
import logging
import time
from pathlib import Path

try:
    from risk_engine.keeper.config import load_config
    from risk_engine.keeper.margin_checker import MarginChecker
    from risk_engine.keeper.oracle_updater import OracleUpdater
    from risk_engine.keeper.price_feed import (
        get_latest_tbill_price_8dp,
        get_latest_tbill_price_8dp_smoothed,
    )
except ModuleNotFoundError:
    import sys

    # Allow `python bot.py` from risk_engine/keeper by adding repo root to sys.path.
    sys.path.append(str(Path(__file__).resolve().parents[2]))
    try:
        from risk_engine.keeper.config import load_config
        from risk_engine.keeper.margin_checker import MarginChecker
        from risk_engine.keeper.oracle_updater import OracleUpdater
        from risk_engine.keeper.price_feed import (
            get_latest_tbill_price_8dp,
            get_latest_tbill_price_8dp_smoothed,
        )
    except ModuleNotFoundError:
        from config import load_config
        from margin_checker import MarginChecker
        from oracle_updater import OracleUpdater
        from price_feed import get_latest_tbill_price_8dp, get_latest_tbill_price_8dp_smoothed


def _setup_logging(log_file_path: str) -> None:
    handlers: list[logging.Handler] = [logging.StreamHandler()]

    log_path = Path(log_file_path)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    handlers.append(logging.FileHandler(log_path, encoding="utf-8"))

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)s | %(message)s",
        handlers=handlers,
    )


def _relative_change_bps(new_value: int, old_value: int) -> float:
    if old_value <= 0:
        return float("inf")
    return (abs(new_value - old_value) * 10000.0) / old_value


def run_once() -> None:
    config = load_config()

    # Always fetch market data first; RPC is only required for on-chain reads/writes.
    base_price_8dp, base_yld, as_of_date, fetched_at = get_latest_tbill_price_8dp(config)
    logging.info(
        "Fetched FRED %s (secondary=%s) yield=%.4f%% as_of=%s fetched_at=%s -> base_price_8dp=%d",
        config.fred_series_id,
        config.fred_secondary_series_id or "none",
        base_yld,
        as_of_date,
        fetched_at,
        base_price_8dp,
    )

    try:
        oracle = OracleUpdater(config)
    except Exception as exc:
        logging.warning(
            "RPC unavailable; skipped on-chain oracle push and margin checks this cycle: %s",
            exc,
        )
        return

    checker = MarginChecker(config)

    current_onchain_price = oracle.get_latest_price()
    price_8dp, yld, as_of_date, fetched_at = get_latest_tbill_price_8dp_smoothed(
        config,
        current_onchain_price_8dp=current_onchain_price,
    )
    logging.info("Smoothed target oracle price_8dp=%d (yield=%.4f%%)", price_8dp, yld)

    last_updated = oracle.get_last_updated()
    now_ts = int(time.time())

    should_push = True
    reason = "first write or stale/unknown oracle state"
    if current_onchain_price is not None:
        change_bps = _relative_change_bps(price_8dp, current_onchain_price)
        is_stale_floor_hit = (
            last_updated is None
            or (now_ts - last_updated) >= config.stale_update_floor_seconds
        )
        should_push = (
            change_bps >= config.price_change_threshold_bps or is_stale_floor_hit
        )
        reason = (
            f"change_bps={change_bps:.4f}, threshold={config.price_change_threshold_bps}, "
            f"stale_floor_hit={is_stale_floor_hit}"
        )

    if should_push:
        price_tx = oracle.push_price(price_8dp)
        logging.info("Oracle updated. tx_hash=%s (%s)", price_tx, reason)
    else:
        logging.info("Oracle update skipped (%s)", reason)

    margin_result = checker.check_active_repos()
    if margin_result is None:
        logging.info("No active repos found. Margin check skipped.")
    else:
        logging.info(
            "Margin check executed. tx_hash=%s active_repos=%s healthy=%d margin_calls=%d liquidations=%d",
            margin_result["tx_hash"],
            margin_result["active_repo_ids"],
            len(margin_result["healthy"]),
            len(margin_result["margin_calls"]),
            len(margin_result["liquidations"]),
        )
        for margin_call in margin_result["margin_calls"]:
            logging.warning(
                "Margin call issued: repo_id=%d ltv_bps=%d deadline=%d",
                margin_call["repo_id"],
                margin_call["ltv_bps"],
                margin_call["deadline"],
            )
        for liquidation in margin_result["liquidations"]:
            logging.error(
                "Liquidation triggered: repo_id=%d ltv_bps=%d",
                liquidation["repo_id"],
                liquidation["ltv_bps"],
            )


def main() -> None:
    parser = argparse.ArgumentParser(description="Tokenized repo keeper bot")
    parser.add_argument(
        "--once",
        action="store_true",
        help="Run one keeper cycle and exit",
    )
    args = parser.parse_args()

    config = load_config()
    _setup_logging(config.log_file_path)
    interval = config.poll_interval_seconds

    if args.once:
        run_once()
        return

    logging.info("Keeper bot started. interval=%ss", interval)
    while True:
        sleep_seconds = interval
        try:
            run_once()
        except Exception as exc:
            logging.exception("Keeper cycle failed: %s", exc)
            sleep_seconds = max(1, int(config.failure_retry_seconds))
            logging.info("Retrying keeper cycle in %ss", sleep_seconds)

        time.sleep(sleep_seconds)


if __name__ == "__main__":
    main()
