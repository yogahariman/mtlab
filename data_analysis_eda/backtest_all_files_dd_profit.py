#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable


# =========================
# Konfigurasi utama
# =========================
# Pilih salah satu:
# 1) Isi INPUT_FILES manual, atau
# 2) Kosongkan INPUT_FILES dan pakai INPUT_FOLDER + INPUT_PATTERN.
#
# Contoh Windows:
# INPUT_FOLDER = Path(r"C:\Users\user\Downloads\EA MT5\BackTest2025")
#
# Contoh WSL/Linux:
INPUT_FOLDER = Path(r"/Drive/E/mt5")
# INPUT_FOLDER = Path(r"C:\Users\user\Downloads\EA MT5\BackTest2025")
INPUT_PATTERN = "t1_*.csv"
INPUT_FILES: list[Path] = []

WEEKDAYS_ONLY = True
DEDUP_BY_MAX_DD = True
OUTPUT_CSV: Path | None = None

INPUT_HEADER_TOKENS = {"<DATE>", "DATE", "<BALANCE>", "BALANCE", "<EQUITY>", "EQUITY"}
DATETIME_FORMATS = [
    "%Y.%m.%d %H:%M:%S",
    "%Y-%m-%d %H:%M:%S",
    "%d.%m.%Y %H:%M:%S",
    "%Y.%m.%d %H:%M",
    "%Y-%m-%d %H:%M",
]


@dataclass
class ParsedRow:
    datetime: datetime
    balance: float
    equity: float

    @property
    def dd(self) -> float:
        return self.balance - self.equity


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Hitung max DD dan total profit dari semua file CSV backtest MT5."
    )
    parser.add_argument(
        "--folder",
        type=Path,
        default=INPUT_FOLDER,
        help="Folder input CSV. Dipakai jika --files tidak diisi.",
    )
    parser.add_argument(
        "--pattern",
        default=INPUT_PATTERN,
        help='Pattern file di folder input, contoh: "*.csv" atau "t1_*.csv".',
    )
    parser.add_argument(
        "--files",
        nargs="*",
        type=Path,
        default=INPUT_FILES,
        help="Daftar file spesifik. Jika diisi, --folder/--pattern diabaikan.",
    )
    parser.add_argument(
        "--include-weekend",
        action="store_true",
        help="Ikutkan Sabtu/Minggu. Default hanya Senin-Jumat.",
    )
    parser.add_argument(
        "--output-csv",
        type=Path,
        default=OUTPUT_CSV,
        help="Simpan ringkasan ke CSV.",
    )
    return parser.parse_args()


def is_header_row(row: list[str]) -> bool:
    joined_upper = " ".join(str(cell).strip().upper() for cell in row)
    return any(token in joined_upper for token in INPUT_HEADER_TOKENS)


def detect_delimiter(sample: str) -> str:
    try:
        return csv.Sniffer().sniff(sample, delimiters="\t,;").delimiter
    except csv.Error:
        return "\t"


def to_float(value: str):
    value = str(value).strip().replace(" ", "")
    if not value:
        return None
    try:
        return float(value)
    except ValueError:
        try:
            return float(value.replace(",", "."))
        except ValueError:
            return None


def parse_datetime(date_str: str, time_str: str):
    raw = f"{date_str.strip()} {time_str.strip()}"
    for fmt in DATETIME_FORMATS:
        try:
            return datetime.strptime(raw, fmt)
        except ValueError:
            continue
    return None


def parse_row(row: list[str]):
    if not row:
        return None

    cleaned = [str(c).strip() for c in row if c is not None]
    if not cleaned or is_header_row(cleaned):
        return None

    if len(cleaned) >= 5:
        date_str, time_str = cleaned[0], cleaned[1]
        balance_str, equity_str = cleaned[2], cleaned[3]
    elif len(cleaned) >= 4:
        parts = cleaned[0].split()
        if len(parts) < 2:
            return None
        date_str, time_str = parts[0], parts[1]
        balance_str, equity_str = cleaned[1], cleaned[2]
    else:
        return None

    balance = to_float(balance_str)
    equity = to_float(equity_str)
    if balance is None or equity is None:
        return None

    dt = parse_datetime(date_str, time_str)
    if dt is None:
        return None

    return ParsedRow(datetime=dt, balance=balance, equity=equity)


def read_rows(path: Path) -> Iterable[ParsedRow]:
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


def get_input_paths(files: list[Path], folder: Path, pattern: str) -> tuple[list[Path], list[Path]]:
    candidates = files if files else sorted(folder.glob(pattern))

    existing: list[Path] = []
    missing: list[Path] = []
    for path in candidates:
        if path.is_file():
            existing.append(path)
        else:
            missing.append(path)
    return existing, missing


def load_file(path: Path, weekdays_only: bool) -> list[ParsedRow]:
    rows = list(read_rows(path))
    if not rows:
        raise ValueError(f"Tidak ada row valid di file: {path}")

    if DEDUP_BY_MAX_DD:
        by_datetime: dict[datetime, ParsedRow] = {}
        for row in rows:
            previous = by_datetime.get(row.datetime)
            if previous is None or row.dd > previous.dd:
                by_datetime[row.datetime] = row
        rows = sorted(by_datetime.values(), key=lambda item: item.datetime)
    else:
        by_datetime = {}
        for row in sorted(rows, key=lambda item: item.datetime):
            by_datetime[row.datetime] = row
        rows = sorted(by_datetime.values(), key=lambda item: item.datetime)

    if weekdays_only:
        rows = [row for row in rows if row.datetime.weekday() <= 4]

    return rows


def analyze_file(path: Path, weekdays_only: bool) -> dict:
    rows = load_file(path, weekdays_only)
    if not rows:
        raise ValueError(f"Data kosong setelah filter hari kerja: {path}")

    start_balance = float(rows[0].balance)
    end_balance = float(rows[-1].balance)
    total_profit = end_balance - start_balance

    max_dd_row = max(rows, key=lambda item: item.dd)

    return {
        "file": path.name,
        "path": str(path),
        "rows": int(len(rows)),
        "start_datetime": rows[0].datetime,
        "end_datetime": rows[-1].datetime,
        "start_balance": start_balance,
        "end_balance": end_balance,
        "total_profit": float(total_profit),
        "max_dd": float(max_dd_row.dd),
        "max_dd_datetime": max_dd_row.datetime,
        "balance_at_max_dd": float(max_dd_row.balance),
        "equity_at_max_dd": float(max_dd_row.equity),
    }


def format_value(value) -> str:
    if isinstance(value, float):
        return f"{value:,.2f}"
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%d %H:%M:%S")
    return str(value)


def print_table(rows: list[dict], columns: list[str]) -> None:
    text_rows = [[format_value(row[col]) for col in columns] for row in rows]
    widths = [
        max(len(column), *(len(row[idx]) for row in text_rows))
        for idx, column in enumerate(columns)
    ]

    header = "  ".join(column.ljust(widths[idx]) for idx, column in enumerate(columns))
    print(header)
    print("  ".join("-" * width for width in widths))
    for row in text_rows:
        print("  ".join(value.rjust(widths[idx]) for idx, value in enumerate(row)))


def write_summary_csv(path: Path, summaries: list[dict]) -> None:
    columns = [
        "file",
        "path",
        "rows",
        "start_datetime",
        "end_datetime",
        "start_balance",
        "end_balance",
        "total_profit",
        "max_dd",
        "max_dd_datetime",
        "balance_at_max_dd",
        "equity_at_max_dd",
    ]
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=columns)
        writer.writeheader()
        for summary in summaries:
            writer.writerow(
                {
                    key: (
                        value.strftime("%Y-%m-%d %H:%M:%S")
                        if isinstance(value, datetime)
                        else value
                    )
                    for key, value in summary.items()
                }
            )


def main() -> int:
    args = parse_args()
    weekdays_only = not args.include_weekend

    files, missing = get_input_paths(args.files, args.folder, args.pattern)

    if missing:
        print(f"File dilewati (tidak ada): {len(missing)}")
        for path in missing:
            print(f" - {path}")

    if not files:
        print("Tidak ada file input yang ditemukan.")
        print(f"Folder : {args.folder}")
        print(f"Pattern: {args.pattern}")
        return 0

    print(f"File ditemukan : {len(files)}")
    print(f"Weekdays only  : {weekdays_only}")

    summaries = []
    failed = []
    for path in files:
        try:
            summary = analyze_file(path, weekdays_only)
            summaries.append(summary)
            print(
                f"[OK] {path.name}: max_dd={summary['max_dd']:,.2f}, "
                f"profit={summary['total_profit']:,.2f}"
            )
        except Exception as exc:
            failed.append((path, exc))
            print(f"[SKIP] {path.name}: {exc}")

    if not summaries:
        print("Tidak ada file yang berhasil dianalisis.")
        return 1

    summaries = sorted(
        summaries,
        key=lambda item: (-float(item["total_profit"]), float(item["max_dd"])),
    )

    print("\n=== Ringkasan Semua File ===")
    print_table(
        summaries,
        [
            "file",
            "rows",
            "start_datetime",
            "end_datetime",
            "total_profit",
            "max_dd",
            "max_dd_datetime",
        ],
    )

    total_profit_all = sum(float(item["total_profit"]) for item in summaries)
    worst_dd = max(summaries, key=lambda item: float(item["max_dd"]))
    best_profit = max(summaries, key=lambda item: float(item["total_profit"]))

    print("\n=== Total / Terbaik / Terburuk ===")
    print(f"Total profit semua file : {total_profit_all:,.2f}")
    print(
        f"Profit terbesar         : {best_profit['file']} "
        f"({best_profit['total_profit']:,.2f})"
    )
    print(
        f"Max DD terbesar         : {worst_dd['file']} "
        f"({worst_dd['max_dd']:,.2f} @ {worst_dd['max_dd_datetime']})"
    )

    if args.output_csv:
        write_summary_csv(args.output_csv, summaries)
        print(f"\nOutput CSV disimpan: {args.output_csv}")

    if failed:
        print(f"\nFile gagal dianalisis: {len(failed)}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
