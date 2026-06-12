#!/usr/bin/env python3
import argparse
import csv
from datetime import datetime, timedelta
from pathlib import Path
from typing import List, Optional, Tuple


INPUT_HEADER_TOKENS = {"<DATE>", "DATE", "<BALANCE>", "BALANCE", "<EQUITY>", "EQUITY"}

# Pilih salah satu:
# 1) Isi INPUT_FILES manual, atau
# 2) Kosongkan INPUT_FILES dan pakai INPUT_FOLDER + INPUT_PATTERN.
# INPUT_FOLDER = Path(r"C:\Users\user\Downloads\EA MT5\BackTest")
INPUT_FOLDER = Path(r"/home/rfi212/Documents/mt5")
INPUT_PATTERN = "all.csv"
INPUT_FILES: List[Path] = []

# Hardcode max DD di sini.
MAX_DD = 1500.0

# Konversi broker -> WIB. Contoh: 00.00 broker = 04.00 WIB.
TIME_OFFSET_HOURS = 4

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Gabungkan banyak CSV backtest MT5, hitung DD = balance - equity, "
            "filter DD >= maxDD, lalu keluarkan tanggal unik."
        )
    )
    return parser.parse_args()


def get_input_paths(files: List[Path], folder: Path, pattern: str) -> Tuple[List[Path], List[Path]]:
    candidates = files if files else sorted(folder.glob(pattern))

    existing: List[Path] = []
    missing: List[Path] = []

    for path in candidates:
        if path.is_file():
            existing.append(path)
        else:
            missing.append(path)

    return existing, missing


def is_header_row(row: List[str]) -> bool:
    joined_upper = " ".join(cell.strip().upper() for cell in row)
    return any(token in joined_upper for token in INPUT_HEADER_TOKENS)


def detect_delimiter(sample: str) -> str:
    try:
        return csv.Sniffer().sniff(sample, delimiters="\t,;").delimiter
    except csv.Error:
        return "\t"


def to_float(value: str) -> Optional[float]:
    value = value.strip().replace(" ", "")
    if not value:
        return None
    try:
        return float(value)
    except ValueError:
        try:
            return float(value.replace(",", "."))
        except ValueError:
            return None


def parse_broker_datetime(date_str: str, time_str: str) -> Optional[datetime]:
    raw = f"{date_str} {time_str}"
    for fmt in (
        "%Y.%m.%d %H:%M:%S",
        "%Y.%m.%d %H:%M",
        "%Y.%m.%d %H.%M.%S",
        "%Y.%m.%d %H.%M",
    ):
        try:
            return datetime.strptime(raw, fmt)
        except ValueError:
            continue
    return None


def parse_row(row: List[str]) -> Optional[Tuple[str, str, float, float, float]]:
    if not row:
        return None

    cleaned = [c.strip() for c in row if c is not None]
    if not cleaned or is_header_row(cleaned):
        return None

    if len(cleaned) >= 5:
        date_str, time_str = cleaned[0], cleaned[1]
        balance_str, equity_str, dep_load_str = cleaned[2], cleaned[3], cleaned[4]
    elif len(cleaned) >= 4:
        dt_raw = cleaned[0]
        parts = dt_raw.split()
        if len(parts) < 2:
            return None
        date_str, time_str = parts[0], parts[1]
        balance_str, equity_str, dep_load_str = cleaned[1], cleaned[2], cleaned[3]
    else:
        return None

    balance = to_float(balance_str)
    equity = to_float(equity_str)
    dep_load = to_float(dep_load_str)
    if balance is None or equity is None or dep_load is None:
        return None

    return date_str, time_str, balance, equity, dep_load


def read_rows(path: Path):
    raw = path.read_bytes()
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        text = raw.decode("utf-16", errors="replace")
    else:
        text = raw.decode("utf-8-sig", errors="replace")

    delimiter = detect_delimiter(text[:4096])

    reader = csv.reader(text.splitlines(), delimiter=delimiter)
    for row in reader:
        parsed = parse_row(row)
        if parsed is not None:
            yield parsed


def main() -> int:
    parse_args()
    files, missing_files = get_input_paths(INPUT_FILES, INPUT_FOLDER, INPUT_PATTERN)

    if missing_files:
        print(f"File dilewati (tidak ada): {len(missing_files)}")
        for mf in missing_files:
            print(f" - {mf}")

    if not files:
        print("Tidak ada file input yang ditemukan.")
        print(f"Folder : {INPUT_FOLDER}")
        print(f"Pattern: {INPUT_PATTERN}")
        return 0

    total_rows = 0
    event_rows = {}

    for path in files:
        for date_str, time_str, balance, equity, dep_load in read_rows(path):
            dd = balance - equity
            total_rows += 1
            dt = parse_broker_datetime(date_str, time_str)
            if dt is None:
                continue
            dt_wib = dt + timedelta(hours=TIME_OFFSET_HOURS)

            if dd >= MAX_DD:
                prev_max = event_rows.get(dt_wib)
                if prev_max is None or dd > prev_max:
                    event_rows[dt_wib] = dd

    sorted_events = sorted(event_rows.items(), key=lambda item: item[0])

    print(f"Folder input     : {INPUT_FOLDER}")
    print(f"Pattern input    : {INPUT_PATTERN}")
    print(f"File dibaca      : {len(files)}")
    print(f"Total baris valid: {total_rows}")
    print(f"Event DD>={MAX_DD}: {len(sorted_events)}")

    if sorted_events:
        print("\n=== Daftar event terfilter (date_wib, hour_wib, max_dd) ===")
        for dt_wib, max_dd in sorted_events:
            print(f"{dt_wib.strftime('%Y.%m.%d')}, {dt_wib.strftime('%H:%M:%S')}, {max_dd:.2f}")
    else:
        print("\nTidak ada event yang memenuhi filter DD.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
