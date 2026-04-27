from pathlib import Path
import csv

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

# =========================
# Konfigurasi utama
# =========================
INPUT_FILE = Path(r"/Drive/D/mt5/BackTest_T1_2020/t1_100.csv")  # Ubah sesuai lokasi data Anda
# INPUT_FILE = Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\T2_300.csv")
BUFFER_PCT = 0.20  # buffer modal, contoh 0.20 = 20%
TARGET_BREACH_PCT = 5.0
DETAIL_QUANTILE = 0.995
# Opsi quantile:
# - "range"  : generate otomatis dari start-end
# - "manual" : pakai daftar manual
QUANTILE_MODE = "range"
QUANTILE_RANGE_START = 0.980
QUANTILE_RANGE_END = 0.999
QUANTILE_RANGE_STEPS = 20
QUANTILES_MANUAL = [0.990, 0.992, 0.995, 0.997, 0.999]
# Opsi on/off plot:
# - True  = tampilkan plot
# - False = skip plot
PLOT_OPTIONS = {
    "quantile_tradeoff": True,
    "day_hour_bars": False,
    "day_hour_heatmap": False,
}

INPUT_HEADER_TOKENS = {"<DATE>", "DATE", "<BALANCE>", "BALANCE", "<EQUITY>", "EQUITY"}


def is_header_row(row):
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


def parse_row(row):
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

    return date_str, time_str, balance, equity


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


def build_quantiles():
    if QUANTILE_MODE == "manual":
        quantiles = [float(q) for q in QUANTILES_MANUAL]
    else:
        quantiles = np.linspace(
            QUANTILE_RANGE_START, QUANTILE_RANGE_END, QUANTILE_RANGE_STEPS
        ).tolist()

    quantiles = sorted(set(quantiles))
    invalid = [q for q in quantiles if q <= 0.0 or q >= 1.0]
    if invalid:
        raise ValueError(f"Quantile harus di rentang (0,1). Invalid: {invalid}")
    if not quantiles:
        raise ValueError("Daftar quantile kosong. Cek konfigurasi quantile.")
    return quantiles


def main():
    print("Input file:", INPUT_FILE)

    if not INPUT_FILE.exists():
        raise FileNotFoundError(f"File tidak ditemukan: {INPUT_FILE}")

    rows = list(read_rows(INPUT_FILE))
    df = pd.DataFrame(rows, columns=["date", "time", "balance", "equity"])
    df["datetime"] = pd.to_datetime(df["date"] + " " + df["time"], errors="coerce")
    df["dd"] = df["balance"] - df["equity"]
    df = df[df["dd"].notna() & df["datetime"].notna()].reset_index(drop=True)
    valid_rows_before_dedup = len(df)

    # Jika timestamp sama, pertahankan baris dengan DD tertinggi
    df = (
        df.sort_values(["datetime", "dd"], ascending=[True, False])
        .drop_duplicates(subset=["datetime"], keep="first")
        .reset_index(drop=True)
    )
    duplicate_timestamp_removed = valid_rows_before_dedup - len(df)

    # Senin=0 ... Minggu=6, ambil hari kerja saja
    df = df[df["datetime"].dt.dayofweek <= 4].copy()

    # Agregasi harian: dalam 1 hari, ambil DD maksimum
    df["date_only"] = df["datetime"].dt.normalize()
    analysis_df = (
        df.groupby("date_only", as_index=False)["dd"]
        .max()
        .rename(columns={"dd": "daily_max_dd"})
    )

    print(f"Rows valid awal             : {valid_rows_before_dedup:,}")
    print(f"Duplikat timestamp dihapus  : {duplicate_timestamp_removed:,}")
    print(f"Rows valid (harian/intraday): {len(df):,}")
    print(f"Jumlah hari kerja           : {len(analysis_df):,}")
    print(f"Max daily DD                : {analysis_df['daily_max_dd'].max():,.2f}")

    # =========================
    # Rekomendasi modal efisien (berbasis daily max DD)
    # =========================
    quantiles = build_quantiles()
    print(
        f"Quantile mode               : {QUANTILE_MODE} "
        f"({len(quantiles)} level, {quantiles[0]:.3f} - {quantiles[-1]:.3f})"
    )

    total_days = len(analysis_df)
    rec_rows = []
    for q in quantiles:
        modal_raw = float(analysis_df["daily_max_dd"].quantile(q))
        modal_with_buffer = modal_raw * (1.0 + BUFFER_PCT)
        breach_rate = float((analysis_df["daily_max_dd"] > modal_raw).mean() * 100.0)
        breach_count = int((analysis_df["daily_max_dd"] > modal_raw).sum())
        total_loss = breach_count * modal_raw
        rec_rows.append(
            {
                "label": f"Q{q:.3f}",
                "quantile": q,
                "modal_raw": modal_raw,
                "modal_with_buffer": modal_with_buffer,
                "breach_count": breach_count,
                "expected_breach_pct": breach_rate,
                "total_kerugian": total_loss,
            }
        )

    rec_df = pd.DataFrame(rec_rows)
    rec_df["quantile_pct"] = rec_df["quantile"].map(lambda x: f"{x * 100:.3f}%")
    rec_df["breach_total_hari_pct"] = (
        rec_df["breach_count"] / total_days * 100.0
    )
    for col in ["modal_raw", "modal_with_buffer", "expected_breach_pct", "total_kerugian"]:
        rec_df[col] = rec_df[col].round(2)
    rec_df["breach_total_hari_pct"] = rec_df["breach_total_hari_pct"].round(2)

    print("\n=== Perbandingan Quantile (Daily Max DD) ===")
    print(f"Buffer modal: {BUFFER_PCT:.0%}")
    display_cols = [
        "label",
        "quantile_pct",
        "modal_raw",
        "modal_with_buffer",
        "breach_count",
        "breach_total_hari_pct",
        "expected_breach_pct",
        "total_kerugian",
    ]
    print(rec_df[display_cols].to_string(index=False))

    best_loss_row = rec_df.sort_values("total_kerugian", ascending=True).iloc[0]
    print(
        f"\nKandidat kerugian minimum: {best_loss_row['label']} "
        f"(total kerugian {best_loss_row['total_kerugian']:,.2f}, "
        f"threshold {best_loss_row['modal_raw']:,.2f})"
    )

    # Kurva quantile: modal vs breach% untuk analisa trade-off
    q_grid = np.linspace(0.80, 0.999, 200)
    modal_curve = analysis_df["daily_max_dd"].quantile(q_grid).to_numpy()
    breach_curve_pct = (1.0 - q_grid) * 100.0
    modal_curve_buffer = modal_curve * (1.0 + BUFFER_PCT)

    marker_quantiles = quantiles
    marker_labels = [f"Q{q:.3f}" for q in quantiles]
    marker_modal = analysis_df["daily_max_dd"].quantile(marker_quantiles).to_numpy()
    marker_breach = (1.0 - np.array(marker_quantiles)) * 100.0

    if PLOT_OPTIONS.get("quantile_tradeoff", True):
        plt.figure(figsize=(10, 5))
        plt.plot(modal_curve, breach_curve_pct, linewidth=2, label="Modal raw vs Breach%")
        plt.plot(
            modal_curve_buffer,
            breach_curve_pct,
            linewidth=2,
            linestyle="--",
            label=f"Modal + buffer ({BUFFER_PCT:.0%}) vs Breach%",
        )
        plt.axhline(
            TARGET_BREACH_PCT,
            color="gray",
            linestyle=":",
            linewidth=1.5,
            label=f"Target breach {TARGET_BREACH_PCT:.1f}%",
        )

        for x, y, lbl in zip(marker_modal, marker_breach, marker_labels):
            plt.scatter([x], [y], s=50)
            plt.text(
                x,
                y,
                f" {lbl} (${x:,.0f})",
                va="bottom",
                fontsize=9,
                bbox={"facecolor": "white", "alpha": 0.7, "edgecolor": "none"},
            )

        plt.xlabel("Modal")
        plt.ylabel("Breach (%)")
        plt.title("Trade-off Quantile: Modal vs Breach% (Daily Max DD)")
        plt.grid(alpha=0.25)
        plt.legend()
        plt.tight_layout()
        plt.show()

    print("\n=== Ranking Quantile Berdasarkan Total Kerugian (kecil ke besar) ===")
    ranking_cols = [
        "label",
        "quantile_pct",
        "total_kerugian",
        "modal_raw",
        "breach_count",
        "breach_total_hari_pct",
    ]
    print(rec_df.sort_values("total_kerugian")[ranking_cols].to_string(index=False))

    # =========================
    # Analisis breach terhadap hari dan jam
    # =========================
    detail_threshold = float(analysis_df["daily_max_dd"].quantile(DETAIL_QUANTILE))
    breach_events = df[df["dd"] > detail_threshold].copy()
    if breach_events.empty:
        print(
            f"\nAnalisis hari/jam [Q{DETAIL_QUANTILE:.3f}]: tidak ada event DD > threshold."
        )
        return

    day_names = {
        0: "Senin",
        1: "Selasa",
        2: "Rabu",
        3: "Kamis",
        4: "Jumat",
    }
    day_order = [0, 1, 2, 3, 4]

    breach_events["dow"] = breach_events["datetime"].dt.dayofweek
    breach_events["hour"] = breach_events["datetime"].dt.hour

    day_counts = breach_events["dow"].value_counts().reindex(day_order, fill_value=0)
    hour_counts = breach_events["hour"].value_counts().reindex(range(24), fill_value=0)

    top_day_idx = int(day_counts.idxmax())
    top_hour_idx = int(hour_counts.idxmax())

    print(f"\n=== Pola DD > Threshold (Intraday, Q{DETAIL_QUANTILE:.3f}) ===")
    print(f"Threshold detail            : {detail_threshold:,.2f}")
    print(f"Total event DD > threshold: {len(breach_events):,}")
    print(f"Hari paling sering         : {day_names[top_day_idx]} ({int(day_counts.max()):,} event)")
    print(f"Jam paling sering          : {top_hour_idx:02d}:00 ({int(hour_counts.max()):,} event)")

    if PLOT_OPTIONS.get("day_hour_bars", True):
        fig, axes = plt.subplots(1, 2, figsize=(14, 4))

        axes[0].bar([day_names[d] for d in day_order], day_counts.values, color="#E45756")
        axes[0].set_title("Event DD > Threshold per Hari")
        axes[0].set_xlabel("Hari")
        axes[0].set_ylabel("Jumlah Event")
        axes[0].grid(alpha=0.25)

        axes[1].bar(hour_counts.index, hour_counts.values, color="#4C78A8")
        axes[1].set_title("Event DD > Threshold per Jam")
        axes[1].set_xlabel("Jam")
        axes[1].set_ylabel("Jumlah Event")
        axes[1].set_xticks(range(0, 24, 2))
        axes[1].grid(alpha=0.25)

        plt.tight_layout()
        plt.show()

    # Heatmap hari-jam untuk pola lebih detail
    heatmap = breach_events.pivot_table(
        index="dow", columns="hour", values="dd", aggfunc="count", fill_value=0
    ).reindex(index=day_order, columns=range(24), fill_value=0)

    if PLOT_OPTIONS.get("day_hour_heatmap", True):
        plt.figure(figsize=(14, 4))
        plt.imshow(heatmap.values, aspect="auto", cmap="YlOrRd")
        plt.colorbar(label="Jumlah Event DD > Threshold")
        plt.yticks(range(len(day_order)), [day_names[d] for d in day_order])
        plt.xticks(range(0, 24, 1))
        plt.xlabel("Jam")
        plt.ylabel("Hari")
        plt.title("Heatmap Event DD > Threshold (Hari x Jam)")
        plt.tight_layout()
        plt.show()


if __name__ == "__main__":
    main()
