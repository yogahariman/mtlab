from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import csv
from datetime import datetime
from typing import Iterable

import pandas as pd

# =========================
# Konfigurasi utama
# =========================
# Ubah daftar file sesuai lokasi data Anda.
INPUT_FILES = [
    # Path(r"/Drive/E/mt5/t1.csv"),
    # Path(r"/Drive/E/mt5/t2.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_0-4.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_1-5.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_2-6.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_3-7.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_4-8.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_5-9.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_6-10.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_7-11.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_8-12.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_9-13.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_10-14.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_11-15.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_12-16.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_13-17.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_14-18.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_15-19.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_16-20.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_17-21.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_18-22.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_19-23.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_0-8.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_1-9.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_2-10.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_3-11.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_4-12.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_5-13.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_6-14.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_7-15.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_8-16.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_9-17.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_10-18.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_11-19.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_12-20.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_13-21.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_14-22.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_90_15-23.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_400.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_420.csv"),
    # Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_440.csv"),
    Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_460.csv"),
    Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_480.csv"),
    Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_500.csv"),
    Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_520.csv"),
    Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_540.csv"),
    Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_560.csv"),
    Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_580.csv"),
    Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_600.csv"),
    Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_620.csv"),
    Path(r"C:\Users\user\Downloads\EA MT5\BackTest2020\t1_640.csv"),
    ]

INITIAL_CAPITAL = 10_000.0
WEEKDAYS_ONLY = True
USE_BALANCE_FOR_DAILY_PNL = True

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
    date_only: datetime
    balance: float
    equity: float


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
    dt = pd.to_datetime(raw, errors="coerce")
    if pd.isna(dt):
        return None
    return dt.to_pydatetime()


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

    return ParsedRow(
        datetime=dt,
        date_only=datetime(dt.year, dt.month, dt.day),
        balance=balance,
        equity=equity,
    )


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


def simulate_daily_reset(df_intraday: pd.DataFrame, label: str) -> tuple[pd.DataFrame, dict]:
    if WEEKDAYS_ONLY:
        df_intraday = df_intraday[df_intraday["datetime"].dt.dayofweek <= 4].copy()

    if df_intraday.empty:
        return pd.DataFrame(), {
            "setup": label,
            "days": 0,
            "mc_count": 0,
            "mc_rate_pct": 0.0,
            "total_profit": 0.0,
            "total_loss_non_mc": 0.0,
            "total_loss_mc": 0.0,
            "total_loss": 0.0,
            "net_result": 0.0,
            "avg_daily_pnl_non_mc": 0.0,
        }

    daily_rows = []

    for day, grp in df_intraday.groupby("date_only", sort=True):
        g = grp.sort_values("datetime").reset_index(drop=True)

        start_balance = float(g.loc[0, "balance"])
        end_balance = float(g.loc[len(g) - 1, "balance"])
        end_equity = float(g.loc[len(g) - 1, "equity"])

        # Normalisasi ke modal simulasi harian (reset modal setiap hari)
        sim_equity_series = INITIAL_CAPITAL + (g["equity"].astype(float) - start_balance)
        day_min_sim_equity = float(sim_equity_series.min())
        is_mc = day_min_sim_equity <= 0.0

        if USE_BALANCE_FOR_DAILY_PNL:
            daily_pnl = end_balance - start_balance
        else:
            daily_pnl = end_equity - start_balance

        if is_mc:
            day_profit = 0.0
            day_loss = INITIAL_CAPITAL
            day_pnl_effective = -INITIAL_CAPITAL
        else:
            day_profit = max(daily_pnl, 0.0)
            day_loss = max(-daily_pnl, 0.0)
            day_pnl_effective = daily_pnl

        daily_rows.append(
            {
                "setup": label,
                "date": day.date().isoformat(),
                "rows": int(len(g)),
                "start_balance": start_balance,
                "end_balance": end_balance,
                "end_equity": end_equity,
                "daily_pnl_raw": float(daily_pnl),
                "min_sim_equity": day_min_sim_equity,
                "mc": bool(is_mc),
                "profit": float(day_profit),
                "loss": float(day_loss),
                "pnl_effective": float(day_pnl_effective),
            }
        )

    daily_df = pd.DataFrame(daily_rows)

    mc_count = int(daily_df["mc"].sum())
    days = int(len(daily_df))
    total_profit = float(daily_df["profit"].sum())
    total_loss_mc = float(daily_df.loc[daily_df["mc"], "loss"].sum())
    total_loss_non_mc = float(daily_df.loc[~daily_df["mc"], "loss"].sum())
    # Total loss utama dihitung hanya dari modal awal yang habis saat MC.
    total_loss = total_loss_mc
    net_result = total_profit - total_loss

    non_mc = daily_df.loc[~daily_df["mc"], "daily_pnl_raw"]
    avg_daily_pnl_non_mc = float(non_mc.mean()) if not non_mc.empty else 0.0

    summary = {
        "setup": label,
        "days": days,
        "mc_count": mc_count,
        "mc_rate_pct": (mc_count / days * 100.0) if days > 0 else 0.0,
        "total_profit": total_profit,
        "total_loss_non_mc": total_loss_non_mc,
        "total_loss_mc": total_loss_mc,
        "total_loss": total_loss,
        "net_result": net_result,
        "avg_daily_pnl_non_mc": avg_daily_pnl_non_mc,
    }
    return daily_df, summary


def analyze_file(path: Path):
    rows = list(read_rows(path))
    if not rows:
        raise ValueError(f"Tidak ada row valid di file: {path}")

    df = pd.DataFrame(
        {
            "datetime": [r.datetime for r in rows],
            "date_only": [r.date_only for r in rows],
            "balance": [r.balance for r in rows],
            "equity": [r.equity for r in rows],
        }
    )

    df = (
        df.sort_values(["datetime", "balance", "equity"], ascending=[True, False, False])
        .drop_duplicates(subset=["datetime"], keep="first")
        .reset_index(drop=True)
    )

    label = path.stem
    return simulate_daily_reset(df, label)


def main():
    print(f"Initial capital (daily reset): {INITIAL_CAPITAL:,.2f}")
    print(f"Weekdays only                : {WEEKDAYS_ONLY}")
    print(f"Use balance for daily pnl    : {USE_BALANCE_FOR_DAILY_PNL}")

    all_daily = []
    summaries = []

    for file_path in INPUT_FILES:
        if not file_path.exists():
            print(f"[SKIP] File tidak ditemukan: {file_path}")
            continue

        daily_df, summary = analyze_file(file_path)
        all_daily.append(daily_df)
        summaries.append(summary)
        print(
            f"[OK] {summary['setup']}: days={summary['days']}, "
            f"MC={summary['mc_count']} ({summary['mc_rate_pct']:.2f}%), "
            f"net={summary['net_result']:,.2f}"
        )

    if not summaries:
        print("Tidak ada file yang berhasil dianalisis.")
        return

    summary_df = pd.DataFrame(summaries)
    summary_df = summary_df.sort_values(["net_result", "mc_count"], ascending=[False, True]).reset_index(drop=True)

    daily_df = pd.concat(all_daily, ignore_index=True)

    money_cols = [
        "total_profit",
        "total_loss_non_mc",
        "total_loss_mc",
        "total_loss",
        "net_result",
        "avg_daily_pnl_non_mc",
    ]
    for col in money_cols:
        summary_df[col] = summary_df[col].round(2)

    print("\n=== Ringkasan Setup (rank terbaik di atas) ===")
    print(
        summary_df[
            [
                "setup",
                "days",
                "mc_count",
                "mc_rate_pct",
                "total_profit",
                "total_loss",
                "net_result",
            ]
        ].to_string(index=False)
    )

    best = summary_df.iloc[0]
    print(
        f"\nSetup terbaik (by net_result): {best['setup']} | "
        f"net={best['net_result']:,.2f}, MC={int(best['mc_count'])}/{int(best['days'])}"
    )

    print("\nDetail harian tersedia di memori (daily_df), output file CSV dinonaktifkan.")


if __name__ == "__main__":
    main()
