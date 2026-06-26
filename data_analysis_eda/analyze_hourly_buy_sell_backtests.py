#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from statistics import mean
from typing import Iterable, Optional


# def _bootstrap_site_packages() -> None:
#     candidates = []
#     home_env = Path("/home/rfi212/my_env")
#     if home_env.exists():
#         candidates.extend(home_env.glob("lib/python*/site-packages"))
#     for candidate in candidates:
#         if candidate.exists() and str(candidate) not in sys.path:
#             sys.path.insert(0, str(candidate))


os.environ.setdefault("MPLCONFIGDIR", "/tmp/matplotlib-config")

import matplotlib.pyplot as plt


INPUT_FOLDER = Path("/home/rfi212/Documents/mt5")
INPUT_FILES: list[Path] = []
INPUT_PATTERN = "cross_ema120_*.csv"
TIME_OFFSET_HOURS = 4
PLOT_Y_MIN = -7000 #None
PLOT_Y_MAX = 4000 #None

INPUT_HEADER_TOKENS = {"<DATE>", "DATE", "<BALANCE>", "BALANCE", "<EQUITY>", "EQUITY"}
DATETIME_FORMATS = [
    "%Y.%m.%d %H:%M:%S",
    "%Y-%m-%d %H:%M:%S",
    "%Y.%m.%d %H:%M",
    "%Y-%m-%d %H:%M",
]
FILENAME_RE = re.compile(r"(\d{2})$")


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
        description="Analisis performa backtest MT5 untuk file CSV dengan jam di nama file."
    )
    parser.add_argument("--folder", type=Path, default=INPUT_FOLDER)
    parser.add_argument(
        "--pattern",
        default=INPUT_PATTERN,
        help='Pattern file di folder input, contoh: "*.csv" atau "ema_*.csv".',
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
        "--save-png",
        type=Path,
        default=None,
        help="Simpan plot ke PNG sebelum ditampilkan.",
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


def to_float(value: str) -> Optional[float]:
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


def parse_datetime(date_str: str, time_str: str) -> Optional[datetime]:
    raw = f"{date_str.strip()} {time_str.strip()}"
    for fmt in DATETIME_FORMATS:
        try:
            return datetime.strptime(raw, fmt)
        except ValueError:
            continue
    return None


def parse_row(row: list[str]) -> Optional[ParsedRow]:
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


def parse_file_meta(path: Path) -> int:
    match = FILENAME_RE.search(path.stem)
    if not match:
        raise ValueError(f"Nama file harus diakhiri jam 2 digit, contoh 01.csv atau ema_01.csv: {path.name}")
    hour = int(match.group(1))
    if not 0 <= hour <= 23:
        raise ValueError(f"Jam di luar range 00-23: {path.name}")
    return hour


def broker_hour_to_wib(hour: int) -> int:
    return (hour + TIME_OFFSET_HOURS) % 24


def load_file(path: Path, weekdays_only: bool) -> list[ParsedRow]:
    rows = list(read_rows(path))
    if not rows:
        raise ValueError(f"Tidak ada row valid di file: {path}")

    by_datetime: dict[datetime, ParsedRow] = {}
    for row in rows:
        previous = by_datetime.get(row.datetime)
        if previous is None or row.dd > previous.dd:
            by_datetime[row.datetime] = row

    rows = sorted(by_datetime.values(), key=lambda item: item.datetime)
    if weekdays_only:
        rows = [row for row in rows if row.datetime.weekday() <= 4]

    if not rows:
        raise ValueError(f"Data kosong setelah filter hari kerja: {path}")
    return rows


def analyze_file(path: Path, weekdays_only: bool) -> dict:
    hour = parse_file_meta(path)
    rows = load_file(path, weekdays_only)
    hour_wib = broker_hour_to_wib(hour)

    start_balance = float(rows[0].balance)
    end_balance = float(rows[-1].balance)
    total_profit = end_balance - start_balance
    max_dd_row = max(rows, key=lambda item: item.dd)

    return {
        "file": path.name,
        "path": str(path),
        "hour_broker": hour,
        "hour_wib": hour_wib,
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


def build_hour_summary(records: list[dict]) -> list[dict]:
    grouped: dict[int, list[dict]] = {hour: [] for hour in range(24)}
    for row in records:
        grouped[int(row["hour_wib"])].append(row)

    summary: list[dict] = []
    for hour in range(24):
        items = grouped[hour]
        if items:
            profits = [float(item["total_profit"]) for item in items]
            dds = [float(item["max_dd"]) for item in items]
            row_counts = [float(item["rows"]) for item in items]
            total_profit = sum(profits)
            avg_profit = mean(profits)
            best_profit = max(profits)
            worst_profit = min(profits)
            avg_max_dd = mean(dds)
            worst_max_dd = max(dds)
            avg_rows = mean(row_counts)
            positive_files = sum(1 for profit in profits if profit > 0)
            negative_files = sum(1 for profit in profits if profit < 0)
            win_rate_pct = round(positive_files / len(items) * 100.0, 2)
            profit_to_avg_dd = total_profit / avg_max_dd if avg_max_dd else 0.0
            profit_to_worst_dd = total_profit / worst_max_dd if worst_max_dd else 0.0
        else:
            total_profit = 0.0
            avg_profit = 0.0
            best_profit = 0.0
            worst_profit = 0.0
            avg_max_dd = 0.0
            worst_max_dd = 0.0
            avg_rows = 0.0
            positive_files = 0
            negative_files = 0
            win_rate_pct = 0.0
            profit_to_avg_dd = 0.0
            profit_to_worst_dd = 0.0

        summary.append(
            {
                "hour": hour,
                "file_count": len(items),
                "positive_files": positive_files,
                "negative_files": negative_files,
                "total_profit": total_profit,
                "avg_profit": avg_profit,
                "best_profit": best_profit,
                "worst_profit": worst_profit,
                "avg_max_dd": avg_max_dd,
                "worst_max_dd": worst_max_dd,
                "avg_rows": avg_rows,
                "win_rate_pct": win_rate_pct,
                "profit_to_avg_dd": profit_to_avg_dd,
                "profit_to_worst_dd": profit_to_worst_dd,
            }
        )

    summary.sort(key=lambda item: (-float(item["total_profit"]), int(item["hour"])))
    return summary


def format_value(value) -> str:
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(value, float):
        return f"{value:,.2f}"
    return str(value)


def print_table(rows: list[dict], columns: list[str]) -> None:
    if not rows:
        print("(kosong)")
        return

    text_rows = [[format_value(row.get(col, "-")) for col in columns] for row in rows]
    widths = [
        max(len(column), *(len(row[idx]) for row in text_rows))
        for idx, column in enumerate(columns)
    ]

    header = "  ".join(column.ljust(widths[idx]) for idx, column in enumerate(columns))
    print(header)
    print("  ".join("-" * width for width in widths))
    for row in text_rows:
        print("  ".join(value.rjust(widths[idx]) for idx, value in enumerate(row)))


def create_hour_figure(
    hour_summary: list[dict],
    y_min: float | None = None,
    y_max: float | None = None,
) -> plt.Figure:
    plot_rows = sorted(hour_summary, key=lambda row: int(row["hour"]))
    fig, ax = plt.subplots(figsize=(15, 8.5), dpi=120)
    fig.patch.set_facecolor("white")
    ax.set_facecolor("white")

    if not plot_rows:
        ax.text(0.5, 0.5, "No data", transform=ax.transAxes, ha="center", va="center")
        ax.set_axis_off()
        fig.tight_layout()
        return fig

    hours = [int(row["hour"]) for row in plot_rows]
    profits = [float(row["total_profit"]) for row in plot_rows]
    file_counts = [int(row["file_count"]) for row in plot_rows]
    colors = ["#2ca02c" if p >= 0 else "#d62728" for p in profits]

    max_profit = max(profits)
    min_profit = min(profits)
    top_pad = 0.1 * max(abs(max_profit), abs(min_profit), 1.0)

    if y_min is None and y_max is None:
        y_top = max_profit + top_pad
        y_bottom = min_profit - top_pad
    else:
        y_bottom = min_profit - top_pad if y_min is None else y_min
        y_top = max_profit + top_pad if y_max is None else y_max
        if y_top <= y_bottom:
            raise ValueError("y-max harus lebih besar dari y-min")

    bars = ax.bar(hours, profits, color=colors, width=0.72, edgecolor="none")
    ax.axhline(0, color="black", linewidth=1.0)
    ax.grid(axis="y", alpha=0.2)
    ax.set_axisbelow(True)
    ax.set_xlim(-0.6, 23.6)
    ax.set_ylim(y_bottom, y_top)
    ax.set_xticks(range(24))
    ax.set_xticklabels([f"{h:02d}" for h in range(24)])
    ax.set_xlabel("WIB Hour")
    ax.set_ylabel("Profit")
    ax.set_title("Hourly Backtest Profit by WIB Hour", pad=18)
    ax.text(
        0.01,
        1.02,
        f"Broker hour converted to WIB (+{TIME_OFFSET_HOURS})",
        transform=ax.transAxes,
        fontsize=10,
        va="bottom",
    )

    y_range = max(abs(y_top), abs(y_bottom), 1.0)
    label_offset = y_range * 0.03
    count_y = y_bottom + (y_top - y_bottom) * 0.02

    for bar, profit, count in zip(bars, profits, file_counts):
        x = bar.get_x() + bar.get_width() / 2
        if profit >= 0:
            ax.text(x, profit + label_offset, f"{profit:,.0f}", ha="center", va="bottom", fontsize=8)
        else:
            ax.text(x, profit - label_offset, f"{profit:,.0f}", ha="center", va="top", fontsize=8)
        ax.text(x, count_y, str(count), ha="center", va="bottom", fontsize=8)

    ax.text(
        0.99,
        0.02,
        "file_count below each hour",
        transform=ax.transAxes,
        ha="right",
        va="bottom",
        fontsize=8,
    )

    fig.tight_layout()
    return fig


def save_plot_png(fig: plt.Figure, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, format="png", bbox_inches="tight", dpi=200)


def show_hour_plot(
    hour_summary: list[dict],
    save_png: Path | None = None,
    y_min: float | None = None,
    y_max: float | None = None,
) -> None:
    fig = create_hour_figure(hour_summary, y_min=y_min, y_max=y_max)
    if save_png is not None:
        save_plot_png(fig, save_png)
        print(f"Plot disimpan: {save_png}")
    plt.show()


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

    summaries: list[dict] = []
    failed: list[tuple[Path, Exception]] = []

    for path in files:
        try:
            summary = analyze_file(path, weekdays_only)
            summaries.append(summary)
            print(
                f"[OK] {path.name}: profit={summary['total_profit']:,.2f}, "
                f"max_dd={summary['max_dd']:,.2f}"
            )
        except Exception as exc:
            failed.append((path, exc))
            print(f"[SKIP] {path.name}: {exc}")

    if not summaries:
        print("Tidak ada file yang berhasil dianalisis.")
        return 1

    hour_summary = build_hour_summary(summaries)

    print("\n=== Ringkasan Per Jam ===")
    print(f"(semua jam sudah dikonversi ke WIB, broker +{TIME_OFFSET_HOURS})")
    print_table(
        hour_summary,
        [
            "hour",
            "file_count",
            "positive_files",
            "negative_files",
            "win_rate_pct",
            "total_profit",
            "avg_profit",
            "best_profit",
            "worst_profit",
            "worst_max_dd",
        ],
    )

    print("\n=== Total / Terbaik / Terburuk ===")
    total_profit_all = sum(float(row["total_profit"]) for row in hour_summary)
    best_hour = max(hour_summary, key=lambda row: float(row["total_profit"]))
    worst_hour = min(hour_summary, key=lambda row: float(row["total_profit"]))

    print(f"Total profit semua jam : {total_profit_all:,.2f}")
    print(
        f"Jam paling profit      : {int(best_hour['hour']):02d} "
        f"({best_hour['total_profit']:,.2f}, {int(best_hour['file_count'])} file)"
    )
    print(
        f"Jam paling minus       : {int(worst_hour['hour']):02d} "
        f"({worst_hour['total_profit']:,.2f}, {int(worst_hour['file_count'])} file)"
    )

    try:
        show_hour_plot(hour_summary, args.save_png, PLOT_Y_MIN, PLOT_Y_MAX)
    except Exception as exc:
        print(f"\nPlot tidak bisa ditampilkan: {exc}")

    if failed:
        print(f"\nFile gagal dianalisis: {len(failed)}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
