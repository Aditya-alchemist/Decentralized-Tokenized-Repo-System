"""Backward-compatible entrypoint for older scripts.

Use `python -m risk_engine.keeper.bot --once` for one-shot runs.
"""

from risk_engine.keeper.bot import main


if __name__ == "__main__":
	main()
