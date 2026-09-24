from __future__ import annotations

import sys
from datetime import datetime
from pathlib import Path

import pandas as pd
import pytz


SYMBOL = "XAUUSD.vx"
# M1, M5, dan H1 digunakan untuk entry dan konteks/filter trend.
TIMEFRAMES_TO_DOWNLOAD = ["M1", "M5", "M15", "H1", "H4", "D1"]
FROM_YEAR = 2024
FALLBACK_BARS = 1_000_000_000
DATA_DIR = Path(__file__).resolve().parent / "data"

REQUIRED_COLUMNS = {
    "time",
    "open",
    "high",
    "low",
    "close",
    "tick_volume",
}

# Isi kalau pakai mt5linux/Wine. Biarkan None kalau pakai package MetaTrader5 native.
MT5_PATH = None
# MT5_PATH = "/home/rfi212/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe"

# Kredensial akun demo. Ganti tiga nilai berikut sesuai akun MT5 Anda.
MT5_LOGIN = 372028191
MT5_PASSWORD = "hariman@H22"
MT5_SERVER = "ValetaxIntl_Live-2"

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
    # Di Linux, prioritaskan mt5linux agar tidak mencoba IPC native ke
    # terminal64.exe. Backend native MetaTrader5 ditujukan terutama untuk Windows.
    if sys.platform != "win32":
        try:
            from mt5linux import MetaTrader5

            if (
                not MT5_LOGIN
                or MT5_PASSWORD == "GANTI_DENGAN_PASSWORD_DEMO"
                or MT5_SERVER == "GANTI_DENGAN_SERVER_BROKER"
            ):
                raise RuntimeError(
                    "Isi MT5_LOGIN, MT5_PASSWORD, dan MT5_SERVER pada "
                    "bagian konfigurasi 01_download_data.py."
                )

            return MetaTrader5(
                mt5_login=MT5_LOGIN,
                mt5_password=MT5_PASSWORD,
                mt5_server=MT5_SERVER,
            )
        except ImportError:
            pass

    try:
        import MetaTrader5 as mt5

        return mt5
    except ImportError as native_error:
        try:
            from mt5linux import MetaTrader5
        except ImportError as linux_error:
            raise RuntimeError(
                "MetaTrader5 tidak tersedia. Install package native "
                "MetaTrader5 atau mt5linux pada environment Python ini."
            ) from linux_error

        try:
            return MetaTrader5()
        except ConnectionRefusedError as connection_error:
            raise RuntimeError(
                "Tidak dapat terhubung ke bridge mt5linux (Connection refused). "
                "Pastikan terminal MetaTrader 5 berjalan di Wine dan bridge "
                "mt5linux sudah dijalankan sebelum script ini. Jika memakai "
                "package MetaTrader5 native, install package tersebut dan "
                "gunakan Python environment yang sesuai dengan instalasinya."
            ) from connection_error
        except OSError as connection_error:
            raise RuntimeError(
                "Koneksi ke MetaTrader 5/mt5linux gagal. Pastikan MT5 dan "
                "bridge aktif, lalu periksa MT5_PATH serta konfigurasi koneksi."
            ) from connection_error


def output_path(symbol: str, timeframe: str) -> Path:
    safe_symbol = symbol.replace("/", "_").replace("\\", "_").replace(".", "_")
    return DATA_DIR / f"{safe_symbol}_{timeframe}.csv"


def initialize_mt5(mt5) -> None:
    # mt5linux mengelola terminal di dalam container; MT5_PATH hanya relevan
    # untuk package MetaTrader5 native.
    is_mt5linux = hasattr(mt5, "container")
    ok = mt5.initialize() if is_mt5linux or not MT5_PATH else mt5.initialize(path=MT5_PATH)
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
    missing_columns = REQUIRED_COLUMNS.difference(df.columns)
    if missing_columns:
        missing = ", ".join(sorted(missing_columns))
        raise RuntimeError(
            f"MT5 returned incomplete {symbol} {timeframe_name} data. "
            f"Missing columns: {missing}"
        )

    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    df = (
        df.drop_duplicates(subset="time")
        .sort_values("time")
        .reset_index(drop=True)
    )

    # Bar terakhir masih berjalan dan nilainya dapat berubah saat training.
    if len(df) > 1:
        df = df.iloc[:-1].copy()

    numeric_columns = ["open", "high", "low", "close", "tick_volume"]
    if "spread" in df.columns:
        numeric_columns.append("spread")
    if "real_volume" in df.columns:
        numeric_columns.append("real_volume")

    for column in numeric_columns:
        df[column] = pd.to_numeric(df[column], errors="coerce")

    df = df.dropna(subset=["open", "high", "low", "close"])
    if df.empty:
        raise RuntimeError(f"No valid OHLC rows remain for {symbol} {timeframe_name}")

    if (df[["open", "high", "low", "close"]] <= 0).any().any():
        raise RuntimeError(f"Non-positive OHLC value found for {symbol} {timeframe_name}")

    if not df["time"].is_monotonic_increasing:
        raise RuntimeError(f"Timestamp order is invalid for {symbol} {timeframe_name}")

    path = output_path(symbol, timeframe_name)
    df.to_csv(path, index=False)
    print(f"Saved {len(df)} closed bars to {path}")
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
