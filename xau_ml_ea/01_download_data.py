from __future__ import annotations

from datetime import datetime
from pathlib import Path

import pandas as pd
import pytz


SYMBOL = "XAUUSD"
TIMEFRAMES_TO_DOWNLOAD = ["M5", "M15", "H1", "H4", "D1"]
FROM_YEAR = 2015
FALLBACK_BARS = 100_000
DATA_DIR = Path(__file__).resolve().parent / "data"

# Isi kalau pakai mt5linux/Wine. Biarkan None kalau pakai package MetaTrader5 native.
MT5_PATH = None
# MT5_PATH = "/home/rfi212/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe"


TIMEFRAMES = {
    "M1": "TIMEFRAME_M1",
    "M5": "TIMEFRAME_M5",
    "M15": "TIMEFRAME_M15",
    "M30": "TIMEFRAME_M30",
    "H1": "TIMEFRAME_H1",
    "H4": "TIMEFRAME_H4",
    "D1": "TIMEFRAME_D1",
}


def import_mt5():
    try:
        import MetaTrader5 as mt5

        return mt5
    except ImportError:
        from mt5linux import MetaTrader5

        return MetaTrader5()


def output_path(symbol: str, timeframe: str) -> Path:
    safe_symbol = symbol.replace("/", "_").replace("\\", "_").replace(".", "_")
    return DATA_DIR / f"{safe_symbol}_{timeframe}.csv"


def initialize_mt5(mt5) -> None:
    ok = mt5.initialize(path=MT5_PATH) if MT5_PATH else mt5.initialize()
    if not ok:
        raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")

    info = mt5.terminal_info()
    if info is not None:
        print(f"MetaTrader 5 Build: {info.build}")
        print(f"Broker: {info.company}")


def find_matching_symbols(mt5, symbol: str) -> list[str]:
    patterns = [symbol, f"{symbol}*", "*XAU*", "*GOLD*"]
    matches: list[str] = []
    for pattern in patterns:
        try:
            symbols = mt5.symbols_get(pattern)
        except Exception:
            symbols = None
        if symbols:
            for item in symbols:
                name = getattr(item, "name", "")
                if name and name not in matches:
                    matches.append(name)
    return matches


def ensure_symbol_selected(mt5, symbol: str) -> None:
    try:
        selected = mt5.symbol_select(symbol, True)
    except Exception:
        selected = False

    if selected:
        return

    matches = find_matching_symbols(mt5, symbol)
    hint = ", ".join(matches[:20]) if matches else "no XAU/GOLD-like symbols found"
    raise RuntimeError(
        f"Symbol {symbol} cannot be selected in MT5 Market Watch. "
        f"Available candidates: {hint}"
    )


def download_timeframe(mt5, symbol: str, timeframe_name: str, utc_from: datetime, utc_to: datetime) -> None:
    if timeframe_name not in TIMEFRAMES:
        raise ValueError(f"Unsupported timeframe: {timeframe_name}")

    ensure_symbol_selected(mt5, symbol)
    timeframe = getattr(mt5, TIMEFRAMES[timeframe_name])
    print(f"\nDownloading {symbol} {timeframe_name} from {utc_from.date()} to {utc_to.date()}...")
    rates = mt5.copy_rates_range(symbol, timeframe, utc_from, utc_to)

    if rates is None or len(rates) == 0:
        print(
            f"No range data returned for {symbol} {timeframe_name}. "
            f"Trying latest {FALLBACK_BARS} bars from terminal history..."
        )
        rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, FALLBACK_BARS)

    if rates is None or len(rates) == 0:
        matches = find_matching_symbols(mt5, symbol)
        hint = ", ".join(matches[:20]) if matches else "no XAU/GOLD-like symbols found"
        raise RuntimeError(
            f"No data retrieved for {symbol} {timeframe_name}. "
            f"MT5 last_error={mt5.last_error()}. "
            f"Check broker history, timeframe availability, or symbol name. "
            f"Available candidates: {hint}"
        )

    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    df = df.drop_duplicates(subset="time").sort_values("time")

    path = output_path(symbol, timeframe_name)
    df.to_csv(path, index=False)
    print(f"Saved {len(df)} bars to {path}")
    print(df.tail(2).to_string(index=False))


def main() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    timezone = pytz.timezone("Etc/UTC")
    utc_from = datetime(FROM_YEAR, 1, 1, tzinfo=timezone)
    utc_to = datetime.now(timezone)

    mt5 = import_mt5()
    initialize_mt5(mt5)
    try:
        for timeframe in TIMEFRAMES_TO_DOWNLOAD:
            download_timeframe(mt5, SYMBOL, timeframe, utc_from, utc_to)
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
