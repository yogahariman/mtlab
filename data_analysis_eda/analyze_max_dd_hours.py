#!/usr/bin/env python3
"""Analisis jam ketika backtest menyentuh MAX_DD.

Skrip ini membaca satu atau banyak CSV backtest MT5, menghitung drawdown
sebagai balance - equity, lalu merangkum:
- jam berapa event DD >= MAX_DD paling sering muncul
- tanggal mana saja yang terkena MAX_DD
- ringkasan event per jam dan per file

Format CSV yang didukung mengikuti pola yang sudah dipakai skrip EDA lain
di folder ini.
"""

from __future__ import annotations

import argparse
import csv
from datetime import datetime
from pathlib import Path
from typing import Iterable, List, Optional, Tuple

import numpy as np
import pandas as pd


INPUT_HEADER_TOKENS = {"<DATE>", "DATE", "<BALANCE>", "BALANCE", "<EQUITY>", "EQUITY"}

# Ubah sesuai kebutuhan:
INPUT_FOLDER = Path(r"C:\Users\user\Downloads\EA MT5\BackTest")
INPUT_PATTERN = "2020-2026_ema120_933_dd3000*.csv"
INPUT_FILES: List[Path] = []

# Threshold DD yang ingin dianalisis.
MAX_DD = 2300

# Konversi broker -> WIB. Contoh: 00.00 broker = 04.00 WIB.
TIME_OFFSET_HOURS = 4

# Jika True, tampilkan plot ringkasan jam dengan matplotlib.
PLOT_HOURLY_VIEW = True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analisis jam ketika backtest menyentuh MAX_DD."
    )
    parser.add_argument(
        "--input-folder",
        type=Path,
        default=INPUT_FOLDER,
        help="Folder input jika INPUT_FILES kosong.",
    )
    parser.add_argument(
        "--input-pattern",
        type=str,
        default=INPUT_PATTERN,
        help="Pattern glob untuk file CSV dalam folder input.",
    )
    parser.add_argument(
        "--max-dd",
        type=float,
        default=MAX_DD,
        help="Threshold DD yang dianggap terkena MAX_DD.",
    )
    parser.add_argument(
        "--no-plot",
        action="store_true",
        help="Matikan plot histogram jam.",
    )
    return parser.parse_args()


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


def parse_row(row: List[str]) -> Optional[Tuple[str, str, float, float]]:
    if not row:
        return None

    cleaned = [c.strip() for c in row if c is not None]
    if not cleaned or is_header_row(cleaned):
        return None

    if len(cleaned) >= 5:
        date_str, time_str = cleaned[0], cleaned[1]
        balance_str, equity_str = cleaned[2], cleaned[3]
    elif len(cleaned) >= 4:
        dt_raw = cleaned[0]
        parts = dt_raw.split()
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

    return date_str, time_str, balance, equity


def read_rows(path: Path) -> Iterable[Tuple[str, str, float, float]]:
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


def sort_date_key(date_str: str):
    try:
        return datetime.strptime(date_str, "%Y.%m.%d")
    except ValueError:
        return datetime.max


def build_hour_summary(all_df: pd.DataFrame, event_df: pd.DataFrame) -> pd.DataFrame:
    total_counts = all_df["hour"].value_counts().reindex(range(24), fill_value=0)
    event_counts = event_df["hour"].value_counts().reindex(range(24), fill_value=0)

    summary = pd.DataFrame(
        {
            "hour": range(24),
            "total_count": total_counts.values,
            "event_count": event_counts.values,
        }
    )
    summary["hit_rate_pct"] = np.where(
        summary["total_count"] > 0,
        summary["event_count"] / summary["total_count"] * 100.0,
        0.0,
    )
    summary["hit_rate_pct"] = summary["hit_rate_pct"].round(4)
    return summary


def build_severity_summary(event_df: pd.DataFrame) -> pd.DataFrame:
    severity = (
        event_df.groupby("hour", as_index=False)
        .agg(
            event_count=("dd", "size"),
            avg_dd=("dd", "mean"),
            median_dd=("dd", "median"),
            max_dd=("dd", "max"),
        )
        .set_index("hour")
        .reindex(range(24))
        .reset_index()
    )
    return severity


def build_day_hour_counts(event_df: pd.DataFrame) -> pd.DataFrame:
    day_order = range(7)
    hour_order = range(24)

    hits = (
        event_df.pivot_table(index="dow", columns="hour", values="dd", aggfunc="size", fill_value=0)
        .reindex(index=day_order, columns=hour_order, fill_value=0)
    )
    return hits


def plot_analysis(
    hour_summary: pd.DataFrame,
    severity_summary: pd.DataFrame,
    day_hour_counts: pd.DataFrame,
    max_dd: float,
    input_folder: Path,
    input_pattern: str,
    time_label: str,
) -> None:
    try:
        import matplotlib.pyplot as plt
        from matplotlib import colors
    except Exception as exc:  # pragma: no cover
        print(f"\nPlot dilewati karena matplotlib tidak tersedia: {exc}")
        return

    event_counts = hour_summary["event_count"].to_numpy(dtype=float)
    total_counts = hour_summary["total_count"].to_numpy(dtype=float)
    hours = hour_summary["hour"].to_numpy(dtype=int)

    safe_hours = hour_summary.sort_values(
        ["event_count", "total_count", "hour"], ascending=[True, False, True]
    ).head(5)
    risky_hours = hour_summary.sort_values(
        ["event_count", "total_count", "hour"], ascending=[False, False, True]
    ).head(5)

    cmap = plt.cm.get_cmap("RdYlGn_r")
    norm = colors.Normalize(vmin=0.0, vmax=max(float(event_counts.max()), 1.0))
    heat_norm = colors.Normalize(vmin=0.0, vmax=max(float(day_hour_counts.to_numpy(dtype=float).max()), 1.0))

    fig = plt.figure(figsize=(18, 14))
    gs = fig.add_gridspec(3, 1, height_ratios=[1.2, 1.0, 1.7], hspace=0.34)

    ax1 = fig.add_subplot(gs[0, 0])
    bar_colors = cmap(norm(event_counts))
    bars = ax1.bar(hours, event_counts, color=bar_colors, edgecolor="#263238", linewidth=0.4)

    for bar, hits, total in zip(bars, event_counts, total_counts):
        if total > 0:
            ax1.text(
                bar.get_x() + bar.get_width() / 2.0,
                bar.get_height() + max(event_counts.max() * 0.015, 0.1),
                f"{int(hits)}",
                ha="center",
                va="bottom",
                fontsize=8,
            )

    count_q25 = float(np.quantile(event_counts, 0.25))
    count_q75 = float(np.quantile(event_counts, 0.75))
    ax1.axhline(count_q25, color="#2E7D32", linestyle="--", linewidth=1.2, label=f"Q25 count = {count_q25:.0f}")
    ax1.axhline(count_q75, color="#C62828", linestyle="--", linewidth=1.2, label=f"Q75 count = {count_q75:.0f}")
    ax1.set_xticks(range(24))
    ax1.set_xlim(-0.5, 23.5)
    ax1.set_xlabel(f"Jam {time_label}")
    ax1.set_ylabel("Jumlah event DD >= MAX_DD")
    ax1.set_title(f"1) Frekuensi per Jam ({time_label})")
    ax1.grid(axis="y", alpha=0.25)
    ax1.legend(loc="upper right")
    ax1.text(
        0.01,
        0.98,
        "Hijau = jarang, merah = sering",
        transform=ax1.transAxes,
        ha="left",
        va="top",
        fontsize=9,
        color="#C62828",
    )

    ax2 = fig.add_subplot(gs[1, 0])
    ax2.plot(severity_summary["hour"], severity_summary["avg_dd"], marker="o", linewidth=2, label="Average DD")
    ax2.plot(severity_summary["hour"], severity_summary["median_dd"], marker="o", linewidth=2, label="Median DD")
    ax2.plot(severity_summary["hour"], severity_summary["max_dd"], marker="o", linewidth=2, label="Max DD")
    ax2.set_xticks(range(24))
    ax2.set_xlim(-0.5, 23.5)
    ax2.set_xlabel(f"Jam {time_label}")
    ax2.set_ylabel("DD saat event")
    ax2.set_title("2) Severity DD per Jam")
    ax2.grid(alpha=0.25)
    ax2.legend(loc="upper right")
    ax2.text(
        0.01,
        0.98,
        "Hanya jam yang terkena MAX_DD yang dihitung di sini",
        transform=ax2.transAxes,
        ha="left",
        va="top",
        fontsize=9,
        color="#455A64",
    )

    ax3 = fig.add_subplot(gs[2, 0])
    heat = day_hour_counts.to_numpy(dtype=float)
    im = ax3.imshow(heat, aspect="auto", cmap="RdYlGn_r", norm=heat_norm)
    day_labels = ["Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu", "Minggu"]
    ax3.set_yticks(range(7))
    ax3.set_yticklabels(day_labels)
    ax3.set_xticks(range(24))
    ax3.set_xlabel(f"Jam {time_label}")
    ax3.set_ylabel("Hari")
    ax3.set_title("3) Heatmap Hari x Jam WIB (Jumlah event)")

    for day_idx in range(day_hour_counts.shape[0]):
        for hour_idx in range(day_hour_counts.shape[1]):
            val = float(day_hour_counts.iat[day_idx, hour_idx])
            if val > 0:
                ax3.text(hour_idx, day_idx, f"{int(val)}", ha="center", va="center", fontsize=6, color="black")

    cbar = fig.colorbar(im, ax=ax3, orientation="horizontal", pad=0.13, fraction=0.06)
    cbar.set_label("Jumlah event DD >= MAX_DD")

    fig.suptitle(
        f"Analisis MAX_DD ({time_label}) | threshold = {max_dd:,.2f} | file/folder: {input_folder} | pattern: {input_pattern}",
        fontsize=12,
        y=0.985,
    )

    risky_text = "\n".join(
        f"{int(row.hour):02d}:00 -> {int(row.event_count)} event"
        for row in risky_hours.itertuples(index=False)
    )
    safe_text = "\n".join(
        f"{int(row.hour):02d}:00 -> {int(row.event_count)} event"
        for row in safe_hours.itertuples(index=False)
    )

    fig.text(
        0.01,
        0.01,
        f"Top jam rawan:\n{risky_text}",
        ha="left",
        va="bottom",
        fontsize=9,
        bbox={"boxstyle": "round,pad=0.35", "facecolor": "white", "alpha": 0.9, "edgecolor": "#B0BEC5"},
    )
    fig.text(
        0.99,
        0.01,
        f"Top jam aman:\n{safe_text}",
        ha="right",
        va="bottom",
        fontsize=9,
        bbox={"boxstyle": "round,pad=0.35", "facecolor": "white", "alpha": 0.9, "edgecolor": "#B0BEC5"},
    )

    plt.tight_layout(rect=[0, 0.05, 1, 0.965])
    plt.show()


def main() -> int:
    args = parse_args()

    input_folder = args.input_folder
    input_pattern = args.input_pattern
    max_dd = float(args.max_dd)
    plot_hourly_view = PLOT_HOURLY_VIEW and not args.no_plot
    time_label = "WIB"

    files, missing_files = get_input_paths(INPUT_FILES, input_folder, input_pattern)

    if missing_files:
        print(f"File dilewati (tidak ada): {len(missing_files)}")
        for mf in missing_files:
            print(f" - {mf}")

    if not files:
        print("Tidak ada file input yang ditemukan.")
        print(f"Folder : {input_folder}")
        print(f"Pattern: {input_pattern}")
        return 0

    rows: list[dict] = []
    total_rows = 0

    for path in files:
        for date_str, time_str, balance, equity in read_rows(path):
            dd = balance - equity
            total_rows += 1
            dt = pd.to_datetime(f"{date_str} {time_str}", errors="coerce")
            rows.append(
                {
                    "file": path.name,
                    "date": date_str,
                    "time": time_str,
                    "datetime": dt,
                    "datetime_wib": dt + pd.Timedelta(hours=TIME_OFFSET_HOURS)
                    if pd.notna(dt)
                    else pd.NaT,
                    "balance": balance,
                    "equity": equity,
                    "dd": dd,
                }
            )

    if not rows:
        print("Tidak ada baris valid yang bisa dianalisis.")
        print(f"File dibaca      : {len(files)}")
        print(f"Total baris valid: {total_rows}")
        return 0

    all_df = pd.DataFrame(rows)
    all_df = all_df[all_df["datetime"].notna() & all_df["datetime_wib"].notna()].copy()
    all_df["hour"] = all_df["datetime_wib"].dt.hour
    all_df["dow"] = all_df["datetime_wib"].dt.dayofweek
    all_df["date_only"] = all_df["datetime_wib"].dt.normalize()
    all_df["date_wib"] = all_df["datetime_wib"].dt.strftime("%Y.%m.%d")

    # Dedup timestamp agar satu titik waktu tidak dihitung dobel antar file.
    all_df = (
        all_df.sort_values(["datetime_wib", "dd"], ascending=[True, False])
        .drop_duplicates(subset=["datetime_wib"], keep="first")
        .reset_index(drop=True)
    )

    event_df = all_df[all_df["dd"] >= max_dd].copy()
    if event_df.empty:
        print(f"Tidak ada event DD >= {max_dd:,.2f}.")
        print(f"File dibaca      : {len(files)}")
        print(f"Total baris valid: {total_rows:,}")
        print(f"Timezone tampilan: WIB (broker +{TIME_OFFSET_HOURS} jam)")
        return 0

    event_df["hour"] = event_df["datetime_wib"].dt.hour
    event_df["dow"] = event_df["datetime_wib"].dt.dayofweek

    file_counts = event_df["file"].value_counts()
    hour_summary = build_hour_summary(all_df, event_df)
    severity_summary = build_severity_summary(event_df)
    day_hour_counts = build_day_hour_counts(event_df)

    hour_summary["hit_rate_pct"] = hour_summary["hit_rate_pct"].round(4)
    severity_summary[["avg_dd", "median_dd", "max_dd"]] = severity_summary[
        ["avg_dd", "median_dd", "max_dd"]
    ].round(2)

    total_hits = len(event_df)
    overall_rate = total_hits / len(all_df) * 100.0 if len(all_df) > 0 else 0.0
    top_risky_hours = hour_summary.sort_values(
        ["event_count", "total_count", "hour"], ascending=[False, False, True]
    ).head(5)
    top_safe_hours = hour_summary.sort_values(
        ["event_count", "total_count", "hour"], ascending=[True, False, True]
    ).head(5)
    top_severity = severity_summary.dropna(subset=["avg_dd"]).sort_values(
        ["avg_dd", "event_count", "hour"], ascending=[False, False, True]
    ).head(5)
    top_day_hour = (
        day_hour_counts.stack()
        .rename("event_count")
        .reset_index()
        .rename(columns={"level_0": "dow", "level_1": "hour"})
    )
    top_day_hour = top_day_hour.sort_values(
        ["event_count", "dow", "hour"], ascending=[False, True, True]
    ).head(10)

    day_names = {
        0: "Senin",
        1: "Selasa",
        2: "Rabu",
        3: "Kamis",
        4: "Jumat",
        5: "Sabtu",
        6: "Minggu",
    }

    print(f"Folder input        : {input_folder}")
    print(f"Pattern input       : {input_pattern}")
    print(f"File dibaca         : {len(files)}")
    print(f"Total baris valid   : {total_rows:,}")
    print(f"Event DD >= {max_dd:,.2f}: {total_hits:,}")
    print(f"Timezone tampilan   : {time_label} (broker +{TIME_OFFSET_HOURS} jam)")
    print(f"Jumlah tanggal unik : {all_df['date_only'].nunique():,}")
    print(f"Overall hit rate    : {overall_rate:.2f}% ({total_hits:,}/{len(all_df):,})")
    peak_row = hour_summary.sort_values(
        ["event_count", "hit_rate_pct", "hour"], ascending=[False, False, True]
    ).iloc[0]
    print(
        f"Jam paling sering   : {int(peak_row['hour']):02d}:00 {time_label} "
        f"({int(peak_row['event_count']):,} event)"
    )

    print("\n=== Frekuensi per Jam ===")
    display_hour = hour_summary.copy()
    display_hour = display_hour.rename(columns={"event_count": "maxdd_count", "total_count": "total_obs"})
    print(display_hour[["hour", "maxdd_count", "total_obs"]].to_string(index=False))

    print("\n=== Top Jam Rawan (jumlah event tertinggi) ===")
    print(top_risky_hours.rename(columns={"event_count": "maxdd_count", "total_count": "total_obs"})[["hour", "maxdd_count", "total_obs"]].to_string(index=False))

    print("\n=== Top Jam Aman (jumlah event terendah) ===")
    print(top_safe_hours.rename(columns={"event_count": "maxdd_count", "total_count": "total_obs"})[["hour", "maxdd_count", "total_obs"]].to_string(index=False))

    print("\n=== Severity DD per Jam (top by average DD) ===")
    print(top_severity.to_string(index=False))

    print("\n=== Top file sumber event ===")
    print(file_counts.head(10).to_string())

    print("\n=== Top tanggal yang terkena MAX_DD ===")
    date_summary = (
        event_df.groupby("date_wib", as_index=False)
        .agg(event_count=("dd", "size"), max_dd=("dd", "max"))
        .sort_values(["event_count", "max_dd"], ascending=[False, False])
    )
    print(date_summary.head(15).to_string(index=False))

    print("\n=== Top kombinasi Hari x Jam (jumlah event tertinggi) ===")
    top_day_hour["day_name"] = top_day_hour["dow"].map(day_names)
    top_day_hour["hour_label"] = top_day_hour["hour"].map(lambda x: f"{int(x):02d}:00")
    print(
        top_day_hour[
            ["day_name", "hour_label", "event_count"]
        ].to_string(index=False)
    )

    if plot_hourly_view:
        plot_analysis(hour_summary, severity_summary, day_hour_counts, max_dd, input_folder, input_pattern, time_label)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
