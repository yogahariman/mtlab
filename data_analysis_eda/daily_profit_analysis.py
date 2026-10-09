#!/usr/bin/env python3
# File analisa profit harian MT5.
"""Analisa net profit dan frekuensi win/loss per hari dari CSV backtest MT5."""

from __future__ import annotations

import csv
from collections import defaultdict
from datetime import datetime
from pathlib import Path


INPUT_FILE = Path(r"/home/rfi212/Documents/mt5/05-00.csv")
DAY_NAMES = ["Senin", "Selasa", "Rabu", "Kamis", "Jumat"]
DATE_FORMATS = (
    "%Y.%m.%d %H:%M:%S", "%Y-%m-%d %H:%M:%S",
    "%d.%m.%Y %H:%M:%S", "%Y.%m.%d %H:%M", "%Y-%m-%d %H:%M",
)


def parse_datetime(value: str) -> datetime | None:
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(value.strip(), fmt)
        except ValueError:
            continue
    return None


def parse_number(value: str) -> float | None:
    try:
        return float(value.strip().replace(" ", "").replace(",", "."))
    except (AttributeError, ValueError):
        return None


def read_rows(path: Path) -> list[tuple[datetime, float]]:
    raw = path.read_bytes()
    encoding = "utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    text = raw.decode(encoding, errors="replace")
    try:
        delimiter = csv.Sniffer().sniff(text[:4096], delimiters="\t,;").delimiter
    except csv.Error:
        delimiter = "\t"

    result = []
    for values in csv.reader(text.splitlines(), delimiter=delimiter):
        cleaned = [str(value).strip() for value in values if value is not None]
        if len(cleaned) >= 5:
            # DATE, TIME, BALANCE, EQUITY, ...
            date_text = f"{cleaned[0]} {cleaned[1]}"
            balance_text = cleaned[2]
        elif len(cleaned) >= 4:
            # "DATE TIME", BALANCE, EQUITY, ...
            date_parts = cleaned[0].split()
            if len(date_parts) < 2:
                continue
            date_text = f"{date_parts[0]} {date_parts[1]}"
            balance_text = cleaned[1]
        else:
            continue

        timestamp = parse_datetime(date_text)
        balance = parse_number(balance_text)
        if timestamp is not None and balance is not None:
            result.append((timestamp, balance))
    return sorted(result, key=lambda item: item[0])


def calculate_daily(rows: list[tuple[datetime, float]]):
    profits = defaultdict(float)
    wins = defaultdict(int)
    losses = defaultdict(int)
    previous_balance = None

    for timestamp, balance in rows:
        if previous_balance is not None and timestamp.weekday() < 5:
            change = balance - previous_balance
            day = timestamp.weekday()
            profits[day] += change
            if change > 0:
                wins[day] += 1
            elif change < 0:
                losses[day] += 1
        previous_balance = balance

    return (
        [profits[i] for i in range(5)],
        [wins[i] for i in range(5)],
        [losses[i] for i in range(5)],
    )


def main() -> int:
    if not INPUT_FILE.is_file():
        print(f"File input tidak ditemukan: {INPUT_FILE}")
        print("Ubah nilai INPUT_FILE di bagian atas script.")
        return 1

    rows = read_rows(INPUT_FILE)
    if not rows:
        print("Tidak menemukan data tanggal dan balance yang valid.")
        return 1

    profits, wins, losses = calculate_daily(rows)
    print("Hari          Net Profit     Win   Loss")
    print("----------------------------------------")
    for day, profit, win, loss in zip(DAY_NAMES, profits, wins, losses):
        print(f"{day:<10} {profit:>14,.2f} {win:>7} {loss:>6}")

    try:
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib belum terpasang: pip install matplotlib")
        return 1

    colors = ["seagreen" if value >= 0 else "firebrick" for value in profits]
    fig, (profit_ax, frequency_ax) = plt.subplots(2, 1, figsize=(11, 8), sharex=True)
    bars = profit_ax.bar(DAY_NAMES, profits, color=colors)
    profit_ax.axhline(0, color="black", linewidth=0.8)
    profit_ax.set_title(f"Net Profit per Hari - {INPUT_FILE.name}")
    profit_ax.set_ylabel("Net profit")
    profit_ax.grid(axis="y", alpha=0.25)
    for bar, value in zip(bars, profits):
        profit_ax.text(bar.get_x() + bar.get_width() / 2, value, f"{value:,.2f}",
                       ha="center", va="bottom" if value >= 0 else "top")

    positions = list(range(5))
    width = 0.36
    frequency_ax.bar([p - width / 2 for p in positions], wins, width,
                     label="Win", color="seagreen")
    frequency_ax.bar([p + width / 2 for p in positions], losses, width,
                     label="Loss", color="firebrick")
    frequency_ax.set_title("Frekuensi Win/Loss")
    frequency_ax.set_ylabel("Frekuensi")
    frequency_ax.set_xlabel("Hari")
    frequency_ax.set_xticks(positions, DAY_NAMES)
    frequency_ax.legend()
    frequency_ax.grid(axis="y", alpha=0.25)
    fig.tight_layout()
    plt.show()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
