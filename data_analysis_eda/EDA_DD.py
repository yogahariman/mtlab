from pathlib import Path
import csv

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

# =========================
# Konfigurasi utama
# =========================
INPUT_FILE = Path(r"/Drive/D/mt5/BackTest_TableGrid_2020/400.csv")
BUFFER_PCT = 0.20  # buffer modal, contoh 0.20 = 20%
TARGET_BREACH_PCT = 5.0
DETAIL_PROFILE = "Balanced"  # opsi: Aggressive, Balanced, Conservative

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


def main():
    print("Input file:", INPUT_FILE)

    if not INPUT_FILE.exists():
        raise FileNotFoundError(f"File tidak ditemukan: {INPUT_FILE}")

    rows = list(read_rows(INPUT_FILE))
    df = pd.DataFrame(rows, columns=["date", "time", "balance", "equity"])
    df["datetime"] = pd.to_datetime(df["date"] + " " + df["time"], errors="coerce")
    df["dd"] = df["balance"] - df["equity"]
    df = df[df["dd"].notna() & df["datetime"].notna()].reset_index(drop=True)

    # Senin=0 ... Minggu=6, ambil hari kerja saja
    df = df[df["datetime"].dt.dayofweek <= 4].copy()

    # Key minggu dimulai dari Senin
    df["week_start"] = (
        df["datetime"] - pd.to_timedelta(df["datetime"].dt.dayofweek, unit="D")
    ).dt.normalize()

    # Dalam 1 minggu (Senin-Jumat), ambil DD maksimum
    analysis_df = (
        df.groupby("week_start", as_index=False)["dd"]
        .max()
        .rename(columns={"dd": "weekly_max_dd"})
    )

    print(f"Rows valid (harian/intraday): {len(df):,}")
    print(f"Jumlah minggu kerja         : {len(analysis_df):,}")
    print(f"Max weekly DD               : {analysis_df['weekly_max_dd'].max():,.2f}")

    # =========================
    # Rekomendasi modal efisien (berbasis weekly max DD)
    # =========================
    quantile_profiles = [
        ("Aggressive", 0.90),
        ("Balanced", 0.95),
        ("Conservative", 0.99),
    ]
    rec_rows = []
    for profile, q in quantile_profiles:
        modal_raw = float(analysis_df["weekly_max_dd"].quantile(q))
        modal_with_buffer = modal_raw * (1.0 + BUFFER_PCT)
        breach_rate = float((analysis_df["weekly_max_dd"] > modal_raw).mean() * 100.0)
        rec_rows.append(
            {
                "profile": profile,
                "quantile": q,
                "modal_raw": modal_raw,
                "modal_with_buffer": modal_with_buffer,
                "expected_breach_pct": breach_rate,
            }
        )

    rec_df = pd.DataFrame(rec_rows)
    rec_df["quantile"] = rec_df["quantile"].map(lambda x: f"{x:.0%}")
    for col in ["modal_raw", "modal_with_buffer", "expected_breach_pct"]:
        rec_df[col] = rec_df[col].round(2)

    print("\n=== Rekomendasi Modal (Weekly Max DD) ===")
    print(f"Buffer modal: {BUFFER_PCT:.0%}")
    print(rec_df.to_string(index=False))

    balanced_modal = float(analysis_df["weekly_max_dd"].quantile(0.95))
    balanced_modal_with_buffer = balanced_modal * (1.0 + BUFFER_PCT)
    print(
        f"\nSaran awal modal efisien (balanced, target breach ~5%): "
        f"{balanced_modal_with_buffer:,.2f}"
    )

    threshold_by_profile = {row["profile"]: float(row["modal_raw"]) for row in rec_rows}
    print("\nThreshold dari quantile profile:")
    for profile in ["Aggressive", "Balanced", "Conservative"]:
        print(f"- {profile:<12}: {threshold_by_profile[profile]:,.2f}")

    # Kurva quantile: modal vs breach% untuk analisa trade-off
    q_grid = np.linspace(0.80, 0.999, 200)
    modal_curve = analysis_df["weekly_max_dd"].quantile(q_grid).to_numpy()
    breach_curve_pct = (1.0 - q_grid) * 100.0
    modal_curve_buffer = modal_curve * (1.0 + BUFFER_PCT)

    marker_quantiles = [0.90, 0.95, 0.99]
    marker_labels = ["P90", "P95", "P99"]
    marker_modal = analysis_df["weekly_max_dd"].quantile(marker_quantiles).to_numpy()
    marker_breach = (1.0 - np.array(marker_quantiles)) * 100.0

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
    plt.title("Trade-off Quantile: Modal vs Breach% (Weekly Max DD)")
    plt.grid(alpha=0.25)
    plt.legend()
    plt.tight_layout()
    plt.show()

    print("\n=== Breach Summary per Profile ===")
    total_weeks = len(analysis_df)
    for profile in ["Aggressive", "Balanced", "Conservative"]:
        threshold = threshold_by_profile[profile]
        breach = analysis_df["weekly_max_dd"] > threshold
        breach_df = analysis_df[breach].copy()
        weeks_above = int(breach.sum())

        print(f"\n[{profile}]")
        print(f"Threshold modal : {threshold:,.2f}")
        print(f"Total weeks     : {total_weeks:,}")
        print(f"Breach count    : {weeks_above:,}")
        print(f"Breach %        : {breach.mean() * 100:.2f}%")

        if len(breach_df) > 0:
            print(f"Avg excess DD   : {(breach_df['weekly_max_dd'] - threshold).mean():,.2f}")
            print(f"Worst excess DD : {(breach_df['weekly_max_dd'] - threshold).max():,.2f}")
        else:
            print("Tidak ada DD yang melewati threshold.")

    # =========================
    # Analisis breach terhadap hari dan jam
    # =========================
    detail_profile = DETAIL_PROFILE if DETAIL_PROFILE in threshold_by_profile else "Balanced"
    detail_threshold = threshold_by_profile[detail_profile]
    breach_events = df[df["dd"] > detail_threshold].copy()
    if breach_events.empty:
        print(
            f"\nAnalisis hari/jam [{detail_profile}]: tidak ada event DD > threshold."
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

    print(f"\n=== Pola DD > Threshold (Intraday, {detail_profile}) ===")
    print(f"Threshold detail            : {detail_threshold:,.2f}")
    print(f"Total event DD > threshold: {len(breach_events):,}")
    print(f"Hari paling sering         : {day_names[top_day_idx]} ({int(day_counts.max()):,} event)")
    print(f"Jam paling sering          : {top_hour_idx:02d}:00 ({int(hour_counts.max()):,} event)")

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
