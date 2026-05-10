#!/usr/bin/env python3
import argparse
import csv
from datetime import datetime
from pathlib import Path
from typing import List, Optional, Tuple


INPUT_HEADER_TOKENS = {"<DATE>", "DATE", "<BALANCE>", "BALANCE", "<EQUITY>", "EQUITY"}

# Hardcode file input di sini.
# Ubah sesuai kebutuhan: tambah/hapus nama file.
INPUT_FILES = [
    Path(r"C:\Users\user\Downloads\EA MT5\BackTest2024\740.csv"),
    # Path(r"/Drive/E/mt5/t1200.csv"),
]
# INPUT_FOLDER = Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020")
# INPUT_START = 400
# INPUT_END = 660
# INPUT_STEP = 20
# INPUT_FILES = [
#     INPUT_FOLDER / f"{grid}.csv"
#     for grid in range(INPUT_START, INPUT_END + 1, INPUT_STEP)
# ]

# Hardcode max DD di sini.
MAX_DD = 11_000

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Gabungkan banyak CSV backtest MT5, hitung DD = balance - equity, "
            "filter DD >= maxDD, lalu keluarkan tanggal unik."
        )
    )
    return parser.parse_args()


def get_hardcoded_input_paths() -> Tuple[List[Path], List[str]]:
    existing: List[Path] = []
    missing: List[str] = []

    for name in INPUT_FILES:
        p = Path(name)
        if p.is_file():
            existing.append(p)
        else:
            missing.append(str(p))

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


def sort_date_key(date_str: str):
    try:
        return datetime.strptime(date_str, "%Y.%m.%d")
    except ValueError:
        return datetime.max


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
    files, missing_files = get_hardcoded_input_paths()

    if missing_files:
        print(f"File dilewati (tidak ada): {len(missing_files)}")
        for mf in missing_files:
            print(f" - {mf}")

    if not files:
        print("Tidak ada file input hardcode yang ditemukan. Semua file dilewati.")
        print(f"Daftar hardcode saat ini: {', '.join(INPUT_FILES)}")
        return 0

    total_rows = 0
    filtered_dates = set()
    date_to_max_dd = {}

    for path in files:
        for date_str, time_str, balance, equity, dep_load in read_rows(path):
            dd = balance - equity
            total_rows += 1
            if dd >= MAX_DD:
                filtered_dates.add(date_str)
                prev_max = date_to_max_dd.get(date_str)
                if prev_max is None or dd > prev_max:
                    date_to_max_dd[date_str] = dd

    sorted_dates = sorted(filtered_dates, key=sort_date_key)

    print(f"File dibaca      : {len(files)}")
    print(f"Total baris valid: {total_rows}")
    print(f"Tanggal unik DD>={MAX_DD}: {len(sorted_dates)}")

    if sorted_dates:
        print("\n=== Daftar tanggal terfilter (date, max_dd) ===")
        for d in sorted_dates:
            print(f"{d}, {date_to_max_dd[d]:.2f}")
    else:
        print("\nTidak ada tanggal yang memenuhi filter DD.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
