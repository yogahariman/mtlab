"""Train a next-candle direction model and export it to ONNX.

Example:
    python 02_02_train_next_candle.py --csv data/XAUUSD_H4.csv --lookback 10

The model sees only information available at the close of candle t and predicts
the direction of candle t+1.  The ONNX input is one flat float vector in the
feature order written to ``*_feature_order.txt``.
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.base import clone
from sklearn.metrics import accuracy_score, confusion_matrix, precision_score, roc_auc_score
from sklearn.model_selection import ParameterGrid
from xgboost import XGBClassifier
from onnxmltools import convert_xgboost
from onnxmltools.convert.common.data_types import FloatTensorType as XGBFloatTensorType

RANDOM_STATE = 42
# ===== EDIT THIS BLOCK ONLY =====
CSV_PATH = "xau_ml_ea/data/XAUUSD_H1.csv"
OUTPUT_DIR = Path(__file__).resolve().parent / "models"
DATA_START = "2025-01-01 00:00:00+00:00"
DATA_END = "2026-08-31 23:59:59+00:00"
LOOKBACK = 4                 # number of closed candles used as input
PROBABILITY_THRESHOLD = 0.35  # BUY >= this, SELL <= 1-this, otherwise no trade
MIN_CANDLE_MOVE = 3.0        # USD: minimum next-candle close-open movement
FILTER_START_HOUR = 5        # inclusive broker-CSV hour of candle t
FILTER_END_HOUR = 20         # inclusive broker-CSV hour of candle t
TEST_RATIO = 0.20
# ================================
BASE_FEATURES = [
    "return_body",
    "upper_shadow",
    "lower_shadow",
    "candle_range",
    "relative_volume",
    "normalized_atr",
    "day_sin",
    "day_cos",
    "hour_sin",
    "hour_cos",
]


def load_ohlcv(path: str | Path) -> pd.DataFrame:
    df = pd.read_csv(path)
    aliases = {c.lower().strip(): c for c in df.columns}
    required = {"time", "open", "high", "low", "close"}
    missing = required - set(aliases)
    if missing:
        raise ValueError(f"CSV missing columns: {sorted(missing)}")
    rename = {aliases[k]: k for k in aliases if k in {"time", "open", "high", "low", "close", "volume"}}
    df = df.rename(columns=rename)
    if "volume" not in df:
        # MT5 exports commonly use tick_volume or real_volume.
        for volume_name in ("tick_volume", "real_volume"):
            if volume_name in df:
                df["volume"] = df[volume_name]
                break
        else:
            df["volume"] = 0.0
    # Preserve the hour exactly as written by the broker CSV for session
    # filtering. The normalized UTC timestamp is still used for date filtering.
    broker_time = pd.to_datetime(df["time"])
    df["_broker_hour"] = broker_time.dt.hour
    df["time"] = pd.to_datetime(df["time"], utc=True)
    for col in ["open", "high", "low", "close", "volume"]:
        df[col] = pd.to_numeric(df[col], errors="coerce")
    return df.sort_values("time").drop_duplicates("time").dropna(
        subset=["open", "high", "low", "close"]
    ).reset_index(drop=True)


def atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    prev = df.close.shift(1)
    tr = pd.concat([df.high - df.low, (df.high - prev).abs(),
                    (df.low - prev).abs()], axis=1).max(axis=1)
    return tr.ewm(alpha=1 / period, adjust=False, min_periods=period).mean()


def make_features(df: pd.DataFrame, lookback: int = 10) -> tuple[pd.DataFrame, list[str]]:
    o, h, l, c = df.open, df.high, df.low, df.close
    safe_open = o.replace(0, np.nan)
    rng = (h - l).clip(lower=0)
    body_hi, body_lo = pd.concat([o, c], axis=1).max(axis=1), pd.concat([o, c], axis=1).min(axis=1)
    vol_ma = df.volume.rolling(20, min_periods=20).mean().replace(0, np.nan)
    raw = pd.DataFrame({
        "return_body": (c - o) / safe_open,
        "upper_shadow": (h - body_hi) / safe_open,
        "lower_shadow": (body_lo - l) / safe_open,
        "candle_range": rng / safe_open,
        "relative_volume": df.volume / vol_ma,
        "normalized_atr": atr(df) / c.replace(0, np.nan),
        "day_sin": np.sin(2 * np.pi * df.time.dt.dayofweek / 7),
        "day_cos": np.cos(2 * np.pi * df.time.dt.dayofweek / 7),
        "hour_sin": np.sin(2 * np.pi * df.time.dt.hour / 24),
        "hour_cos": np.cos(2 * np.pi * df.time.dt.hour / 24),
    })
    unknown_features = sorted(set(BASE_FEATURES) - set(raw.columns))
    if unknown_features:
        raise ValueError(
            f"Unknown feature(s) in BASE_FEATURES: {unknown_features}. "
            f"Available features: {list(raw.columns)}"
        )
    if not BASE_FEATURES:
        raise ValueError("BASE_FEATURES must contain at least one feature")
    # The feature order here is also the order exported for the EA/ONNX model.
    raw = raw.loc[:, BASE_FEATURES]
    parts, names = [], []
    for lag in range(lookback - 1, -1, -1):
        shifted = raw.shift(lag).add_prefix(f"t-{lag}_")
        parts.append(shifted)
        names.extend(shifted.columns.tolist())
    return pd.concat(parts, axis=1), names


def make_dataset(df: pd.DataFrame, lookback: int) -> tuple[pd.DataFrame, pd.Series, list[str]]:
    x, names = make_features(df, lookback)
    move = df.close.shift(-1) - df.open.shift(-1)
    y = pd.Series(np.select(
        [move <= -MIN_CANDLE_MOVE, move >= MIN_CANDLE_MOVE],
        [0.0, 2.0], default=1.0,
    ), index=df.index, dtype="float32", name="target")
    y.iloc[-1] = np.nan  # no candle t+1 exists for the final row
    valid = x.replace([np.inf, -np.inf], np.nan).notna().all(axis=1) & y.notna()
    return x.loc[valid].astype("float32"), y.loc[valid], names


def purged_splits(n: int, n_splits: int = 4, purge: int = 1):
    """Expanding time split; removes observations adjacent to validation."""
    edges = np.linspace(0, n, n_splits + 2, dtype=int)
    for i in range(1, n_splits + 1):
        train_end, val_start, val_end = edges[i], edges[i], edges[i + 1]
        train = np.arange(0, max(0, train_end - purge))
        val = np.arange(val_start, val_end)
        if len(train) and len(val):
            yield train, val


def backtest(y: np.ndarray, probabilities: np.ndarray, threshold: float, returns: np.ndarray) -> dict:
    confidence = probabilities.max(axis=1)
    predicted_class = probabilities.argmax(axis=1)
    signal = np.where((predicted_class == 2) & (confidence >= threshold), 1,
                      np.where((predicted_class == 0) & (confidence >= threshold), -1, 0))
    pnl = signal * returns
    traded = signal != 0
    return {"trades": int(traded.sum()), "coverage": float(traded.mean()),
            "total_return": float(pnl.sum()), "avg_return_per_trade": float(pnl[traded].mean()) if traded.any() else 0.0,
            "win_rate": float((pnl[traded] > 0).mean()) if traded.any() else 0.0}


def main() -> None:
    # For three classes, the largest class probability is at least 1/3.
    # A threshold below 0.5 is valid here; it is useful for testing trade
    # coverage, although the final value should still be selected by backtest.
    if not 1 / 3 <= PROBABILITY_THRESHOLD < 1 or LOOKBACK < 1:
        raise ValueError("threshold must be in [1/3, 1), lookback must be >= 1")
    if not 0 <= FILTER_START_HOUR <= 23 or not 0 <= FILTER_END_HOUR <= 23:
        raise ValueError("FILTER_START_HOUR and FILTER_END_HOUR must be between 0 and 23")
    source = Path(CSV_PATH)
    out = Path(OUTPUT_DIR) if OUTPUT_DIR else source.parent
    out.mkdir(parents=True, exist_ok=True)
    df = load_ohlcv(source)
    data_start = pd.Timestamp(DATA_START, tz="UTC")
    data_end = pd.Timestamp(DATA_END, tz="UTC")
    if data_start >= data_end:
        raise ValueError("DATA_START must be earlier than DATA_END")
    df = df[df["time"].between(data_start, data_end)].reset_index(drop=True)
    if df.empty:
        raise ValueError(f"No OHLCV data found between {DATA_START} and {DATA_END}")
    x, y, feature_names = make_dataset(df, LOOKBACK)
    # Filter the reference candle t after creating lookback features. This keeps
    # the preceding candles available while restricting training samples to the
    # broker-hour window selected above.
    sample_hours = df.loc[x.index, "_broker_hour"]
    if FILTER_START_HOUR <= FILTER_END_HOUR:
        hour_mask = sample_hours.between(FILTER_START_HOUR, FILTER_END_HOUR)
    else:
        # Supports windows crossing midnight, e.g. 22 -> 3.
        hour_mask = (sample_hours >= FILTER_START_HOUR) | (sample_hours <= FILTER_END_HOUR)
    x, y = x.loc[hour_mask], y.loc[hour_mask]
    if len(x) < 20:
        raise ValueError(
            f"Dataset terlalu kecil setelah feature engineering: {len(x)} baris. "
            "Periksa kolom volume/tanggal dan pastikan data cukup."
        )
    # XGBoost's ONNX converter requires feature names f0, f1, ... .
    # Keep the descriptive names separately for MQL5 feature-order metadata.
    x.columns = [f"f{i}" for i in range(len(feature_names))]
    raw_returns = (df.close.shift(-1) / df.open.shift(-1) - 1).reindex(x.index).to_numpy()
    split = int(len(x) * (1 - TEST_RATIO))
    x_train, x_test, y_train, y_test = x.iloc[:split], x.iloc[split:], y.iloc[:split], y.iloc[split:]

    # Keep the search reasonably small because this is a time-series CV search.
    # The added regularization helps reduce overfitting on noisy candle data.
    base = XGBClassifier(
        objective="multi:softprob",
        num_class=3,
        eval_metric="mlogloss",
        tree_method="hist",
        random_state=RANDOM_STATE,
        n_jobs=2,
        verbosity=0,
    )
    grid = ParameterGrid({
        "max_depth": [2, 3, 4],
        "learning_rate": [0.03, 0.06],
        "n_estimators": [200, 400],
        "min_child_weight": [3, 8],
        "subsample": [0.8],
        "colsample_bytree": [0.8],
        "reg_lambda": [1.0, 5.0],
    })
    best, best_score = None, -np.inf
    for params in grid:
        scores = []
        for tr, va in purged_splits(len(x_train), purge=1):
            model = clone(base).set_params(**params)
            model.fit(x_train.iloc[tr], y_train.iloc[tr])
            scores.append(roc_auc_score(y_train.iloc[va], model.predict_proba(x_train.iloc[va]),
                                         multi_class="ovr", labels=[0, 1, 2]))
        if scores and np.mean(scores) > best_score:
            best_score, best = float(np.mean(scores)), params
    model = clone(base).set_params(**(best or {})).fit(x_train, y_train)
    train_probabilities = model.predict_proba(x_train)
    probabilities = model.predict_proba(x_test)
    if train_probabilities.shape[1] != 3 or probabilities.shape[1] != 3:
        raise ValueError(
            "Training hanya menghasilkan satu kelas label. "
            f"Distribusi label train: {y_train.value_counts().to_dict()}"
        )
    train_pred = train_probabilities.argmax(axis=1).astype("int8")
    pred = probabilities.argmax(axis=1).astype("int8")
    train_matrix = confusion_matrix(y_train, train_pred, labels=[0, 1, 2])
    matrix = confusion_matrix(y_test, pred, labels=[0, 1, 2])
    def matrix_dict(values):
        return {
            "labels": ["SELL (0)", "HOLD (1)", "BUY (2)"],
            "rows_actual": ["SELL (0)", "HOLD (1)", "BUY (2)"],
            "columns_predicted": ["SELL (0)", "HOLD (1)", "BUY (2)"],
            "values": values.tolist(),
        }
    metrics = {"cv_auc": best_score, "best_params": best, "lookback": LOOKBACK,
               "threshold": PROBABILITY_THRESHOLD, "min_candle_move": MIN_CANDLE_MOVE,
               "filter_start_hour": FILTER_START_HOUR, "filter_end_hour": FILTER_END_HOUR,
               "test_rows": len(y_test),
               "train_rows": len(y_train),
               "train_accuracy": accuracy_score(y_train, train_pred),
               "accuracy": accuracy_score(y_test, pred),
               "precision_buy": precision_score(y_test, pred, labels=[2], average="macro", zero_division=0),
               "roc_auc": roc_auc_score(y_test, probabilities, multi_class="ovr", labels=[0, 1, 2]),
               "confusion_matrix_train": matrix_dict(train_matrix),
               "confusion_matrix_test": matrix_dict(matrix),
               "backtest": backtest(y_test.to_numpy(), probabilities, PROBABILITY_THRESHOLD, raw_returns[split:])}
    stem = source.stem + f"_next_candle_lb{LOOKBACK}"
    onnx = convert_xgboost(model, initial_types=[("features", XGBFloatTensorType([None, len(feature_names)]))], target_opset=15)
    (out / f"{stem}.onnx").write_bytes(onnx.SerializeToString())
    (out / f"{stem}_feature_order.txt").write_text("\n".join(feature_names) + "\n", encoding="utf-8")
    (out / f"{stem}.meta").write_text(json.dumps({"feature_count": len(feature_names), "lookback": LOOKBACK,
        "threshold": PROBABILITY_THRESHOLD, "min_candle_move": MIN_CANDLE_MOVE,
        "filter_start_hour": FILTER_START_HOUR, "filter_end_hour": FILTER_END_HOUR,
        "target": "SELL if move <= -min, HOLD if abs(move) < min, BUY if move >= min",
        "class_0": "SELL", "class_1": "HOLD", "class_2": "BUY",
        "entry": "next candle open", "exit": "next candle close", "features": feature_names}, indent=2), encoding="utf-8")
    (out / f"{stem}_metrics.json").write_text(json.dumps(metrics, indent=2), encoding="utf-8")
    print(json.dumps(metrics, indent=2))
    for title, values in (("TRAIN", train_matrix), ("TEST", matrix)):
        print(f"\nConfusion Matrix {title} [actual rows x predicted columns]")
        print("              SELL(0)  HOLD(1)  BUY(2)")
        for row, label in enumerate(("SELL (0)", "HOLD (1)", "BUY  (2)")):
            print(f"{label:<14}{values[row, 0]:7d}  {values[row, 1]:7d}  {values[row, 2]:6d}")
    print(f"Exported: {out / (stem + '.onnx')}")


if __name__ == "__main__":
    main()
