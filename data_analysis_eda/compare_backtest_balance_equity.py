from pathlib import Path
import csv

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

# =========================
# Konfigurasi utama
# =========================
FILE_A = Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\T1_300.csv")
FILE_B = Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\T2_300.csv")
LABEL_A = "T1_300"
LABEL_B = "T2_300"

# Jika True: saat timestamp sama, pertahankan baris dengan DD tertinggi
DEDUP_BY_MAX_DD = True

# Threshold gap equity vs balance (untuk hitung % hari floating loss besar)
BIG_GAP_PCT = 5.0

PLOT_OPTIONS = {
    "balance_overlay": True,
    "equity_overlay": True,
    "drawdown_overlay": True,
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


def load_intraday(path: Path) -> pd.DataFrame:
    if not path.exists():
        raise FileNotFoundError(f"File tidak ditemukan: {path}")

    rows = list(read_rows(path))
    if not rows:
        raise ValueError(f"Tidak ada row valid di file: {path}")

    df = pd.DataFrame(rows, columns=["date", "time", "balance", "equity"])
    df["datetime"] = pd.to_datetime(df["date"] + " " + df["time"], errors="coerce")
    df = df[df["datetime"].notna()].copy()
    df["dd"] = df["balance"] - df["equity"]

    df = df.sort_values("datetime").reset_index(drop=True)

    if DEDUP_BY_MAX_DD:
        df = (
            df.sort_values(["datetime", "dd"], ascending=[True, False])
            .drop_duplicates(subset=["datetime"], keep="first")
            .sort_values("datetime")
            .reset_index(drop=True)
        )
    else:
        df = (
            df.drop_duplicates(subset=["datetime"], keep="last")
            .sort_values("datetime")
            .reset_index(drop=True)
        )

    # Hanya hari kerja
    df = df[df["datetime"].dt.dayofweek <= 4].copy()
    return df


def build_daily(df_intraday: pd.DataFrame) -> pd.DataFrame:
    temp = df_intraday.copy()
    temp["date_only"] = temp["datetime"].dt.normalize()

    daily_last = (
        temp.sort_values("datetime")
        .groupby("date_only", as_index=False)
        .agg(balance=("balance", "last"), equity=("equity", "last"))
    )

    daily_risk = temp.groupby("date_only", as_index=False).agg(
        daily_max_dd=("dd", "max"),
        daily_min_equity=("equity", "min"),
    )

    daily = daily_last.merge(daily_risk, on="date_only", how="left")
    daily = daily.sort_values("date_only").reset_index(drop=True)
    return daily


def max_drawdown_abs_and_pct(series: pd.Series):
    running_peak = series.cummax()
    dd_abs = running_peak - series
    dd_pct = dd_abs / running_peak.replace(0, np.nan) * 100.0
    return float(dd_abs.max()), float(dd_pct.max()), dd_pct.fillna(0.0)


def compute_metrics(daily: pd.DataFrame) -> dict:
    if daily.empty:
        raise ValueError("Data harian kosong.")

    bal = daily["balance"].astype(float)
    eq = daily["equity"].astype(float)

    start_balance = float(bal.iloc[0])
    end_balance = float(bal.iloc[-1])
    net_profit = end_balance - start_balance
    return_pct = (net_profit / start_balance * 100.0) if start_balance != 0 else np.nan

    max_dd_bal_abs, max_dd_bal_pct, _ = max_drawdown_abs_and_pct(bal)
    max_dd_eq_abs, max_dd_eq_pct, dd_eq_pct_series = max_drawdown_abs_and_pct(eq)

    recovery_factor = (net_profit / max_dd_eq_abs) if max_dd_eq_abs > 0 else np.nan

    ulcer_index = float(np.sqrt(np.mean(np.square(dd_eq_pct_series))))
    time_in_dd_pct = float((dd_eq_pct_series > 0).mean() * 100.0)

    gap = bal - eq
    avg_gap = float(gap.mean())
    max_gap = float(gap.max())
    big_gap_days_pct = float((gap > (bal * (BIG_GAP_PCT / 100.0))).mean() * 100.0)

    eq_ret = eq.pct_change().dropna()
    worst_day_eq_ret_pct = float(eq_ret.min() * 100.0) if len(eq_ret) > 0 else np.nan
    eq_vol_daily_pct = float(eq_ret.std() * 100.0) if len(eq_ret) > 1 else np.nan

    return {
        "days": int(len(daily)),
        "start_balance": start_balance,
        "end_balance": end_balance,
        "net_profit": net_profit,
        "return_pct": return_pct,
        "max_dd_balance_abs": max_dd_bal_abs,
        "max_dd_balance_pct": max_dd_bal_pct,
        "max_dd_equity_abs": max_dd_eq_abs,
        "max_dd_equity_pct": max_dd_eq_pct,
        "recovery_factor": recovery_factor,
        "ulcer_index": ulcer_index,
        "time_in_drawdown_pct": time_in_dd_pct,
        "avg_balance_equity_gap": avg_gap,
        "max_balance_equity_gap": max_gap,
        "big_gap_days_pct": big_gap_days_pct,
        "worst_day_equity_return_pct": worst_day_eq_ret_pct,
        "equity_vol_daily_pct": eq_vol_daily_pct,
    }


def print_comparison_table(metrics_a: dict, metrics_b: dict):
    rows = []
    for k in metrics_a.keys():
        rows.append({"metric": k, LABEL_A: metrics_a[k], LABEL_B: metrics_b[k]})

    out = pd.DataFrame(rows)

    numeric_cols = [LABEL_A, LABEL_B]
    out[numeric_cols] = out[numeric_cols].apply(pd.to_numeric, errors="coerce")
    out[numeric_cols] = out[numeric_cols].round(4)

    print("\n=== Tabel Perbandingan Metrics ===")
    print(out.to_string(index=False))


def plot_overlay(aligned: pd.DataFrame):
    if aligned.empty:
        return

    base_a = aligned[f"balance_{LABEL_A}"].iloc[0]
    base_b = aligned[f"balance_{LABEL_B}"].iloc[0]
    eq_base_a = aligned[f"equity_{LABEL_A}"].iloc[0]
    eq_base_b = aligned[f"equity_{LABEL_B}"].iloc[0]

    bal_a_idx = aligned[f"balance_{LABEL_A}"] / base_a * 100.0 if base_a != 0 else np.nan
    bal_b_idx = aligned[f"balance_{LABEL_B}"] / base_b * 100.0 if base_b != 0 else np.nan
    eq_a_idx = aligned[f"equity_{LABEL_A}"] / eq_base_a * 100.0 if eq_base_a != 0 else np.nan
    eq_b_idx = aligned[f"equity_{LABEL_B}"] / eq_base_b * 100.0 if eq_base_b != 0 else np.nan

    if PLOT_OPTIONS.get("balance_overlay", True):
        plt.figure(figsize=(11, 5))
        plt.plot(aligned["date_only"], bal_a_idx, label=f"Balance {LABEL_A} (idx)", linewidth=2)
        plt.plot(aligned["date_only"], bal_b_idx, label=f"Balance {LABEL_B} (idx)", linewidth=2)
        plt.axhline(100, color="gray", linestyle=":", linewidth=1)
        plt.title("Perbandingan Kurva Balance (Index=100)")
        plt.xlabel("Tanggal")
        plt.ylabel("Index")
        plt.grid(alpha=0.25)
        plt.legend()
        plt.tight_layout()
        plt.show()

    if PLOT_OPTIONS.get("equity_overlay", True):
        plt.figure(figsize=(11, 5))
        plt.plot(aligned["date_only"], eq_a_idx, label=f"Equity {LABEL_A} (idx)", linewidth=2)
        plt.plot(aligned["date_only"], eq_b_idx, label=f"Equity {LABEL_B} (idx)", linewidth=2)
        plt.axhline(100, color="gray", linestyle=":", linewidth=1)
        plt.title("Perbandingan Kurva Equity (Index=100)")
        plt.xlabel("Tanggal")
        plt.ylabel("Index")
        plt.grid(alpha=0.25)
        plt.legend()
        plt.tight_layout()
        plt.show()

    if PLOT_OPTIONS.get("drawdown_overlay", True):
        _, _, dd_a = max_drawdown_abs_and_pct(aligned[f"equity_{LABEL_A}"])
        _, _, dd_b = max_drawdown_abs_and_pct(aligned[f"equity_{LABEL_B}"])

        plt.figure(figsize=(11, 4.5))
        plt.plot(aligned["date_only"], dd_a, label=f"Equity DD% {LABEL_A}", linewidth=2)
        plt.plot(aligned["date_only"], dd_b, label=f"Equity DD% {LABEL_B}", linewidth=2)
        plt.title("Perbandingan Equity Drawdown (%)")
        plt.xlabel("Tanggal")
        plt.ylabel("Drawdown %")
        plt.grid(alpha=0.25)
        plt.legend()
        plt.tight_layout()
        plt.show()


def main():
    print(f"File A: {FILE_A}")
    print(f"File B: {FILE_B}")

    df_a_intraday = load_intraday(FILE_A)
    df_b_intraday = load_intraday(FILE_B)

    daily_a = build_daily(df_a_intraday)
    daily_b = build_daily(df_b_intraday)

    aligned = daily_a.merge(
        daily_b,
        on="date_only",
        how="inner",
        suffixes=(f"_{LABEL_A}", f"_{LABEL_B}"),
    )

    if aligned.empty:
        raise ValueError("Tidak ada overlap tanggal antara dua file.")

    a_for_metrics = aligned[["date_only", f"balance_{LABEL_A}", f"equity_{LABEL_A}", f"daily_max_dd_{LABEL_A}"]].rename(
        columns={
            f"balance_{LABEL_A}": "balance",
            f"equity_{LABEL_A}": "equity",
            f"daily_max_dd_{LABEL_A}": "daily_max_dd",
        }
    )
    b_for_metrics = aligned[["date_only", f"balance_{LABEL_B}", f"equity_{LABEL_B}", f"daily_max_dd_{LABEL_B}"]].rename(
        columns={
            f"balance_{LABEL_B}": "balance",
            f"equity_{LABEL_B}": "equity",
            f"daily_max_dd_{LABEL_B}": "daily_max_dd",
        }
    )

    print("\n=== Ringkasan Data ===")
    print(f"Rows intraday {LABEL_A}: {len(df_a_intraday):,}")
    print(f"Rows intraday {LABEL_B}: {len(df_b_intraday):,}")
    print(f"Hari overlap            : {len(aligned):,}")
    print(
        f"Periode overlap         : {aligned['date_only'].min().date()} s/d {aligned['date_only'].max().date()}"
    )

    metrics_a = compute_metrics(a_for_metrics)
    metrics_b = compute_metrics(b_for_metrics)

    print_comparison_table(metrics_a, metrics_b)

    # Highlight cepat pemenang utama
    winner_return = LABEL_A if metrics_a["return_pct"] > metrics_b["return_pct"] else LABEL_B
    winner_dd = LABEL_A if metrics_a["max_dd_equity_pct"] < metrics_b["max_dd_equity_pct"] else LABEL_B
    winner_recovery = LABEL_A if metrics_a["recovery_factor"] > metrics_b["recovery_factor"] else LABEL_B

    print("\n=== Highlight Cepat ===")
    print(f"Return lebih tinggi      : {winner_return}")
    print(f"Max equity DD lebih kecil: {winner_dd}")
    print(f"Recovery factor lebih baik: {winner_recovery}")

    plot_overlay(aligned)


if __name__ == "__main__":
    main()
