"""Train the XAUUSD single-shot classifier and export it to ONNX.

The target is trade outcome, not simply the next candle direction:
0 = SELL wins (SL is hit first), 1 = no trade/timeout, 2 = BUY wins.
"""

from __future__ import annotations

from pathlib import Path
import json

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import classification_report, confusion_matrix
from sklearn.neural_network import MLPClassifier
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from skl2onnx import convert_sklearn
from skl2onnx.common.data_types import FloatTensorType
from onnxmltools import convert_xgboost
from onnxmltools.convert.common.data_types import FloatTensorType as XGBFloatTensorType
from xgboost import XGBClassifier


ROOT = Path(__file__).resolve().parent
# Rentang candle M5 yang dipakai sebagai dataset entry/training.
# Ubah kedua nilai ini untuk menentukan periode data secara hardcode.
DATA_START = "2025-01-01 00:00:00+00:00"
DATA_END = "2026-08-31 23:59:59+00:00"
DATA_DIR = ROOT / "data"
MODEL_PATH = ROOT / "model_xau_single_shot.onnx"
FEATURE_ORDER_PATH = ROOT / "feature_order.txt"
METRICS_PATH = ROOT / "training_metrics.json"

# Downloader menghasilkan nama berdasarkan simbol broker. vx adalah contoh
# suffix broker; pencarian glob membuat training tetap bekerja untuk XAUUSDm,
# XAUUSD.v, dan variasi nama lainnya.
M1_PATTERNS = ("XAUUSD*_M1.csv", "*_M1.csv")
M5_PATTERNS = ("XAUUSD*_M5.csv", "*_M5.csv")
H1_PATTERNS = ("XAUUSD*_H1.csv", "*_H1.csv")

ATR_PERIOD = 14
EMA_FAST = 50
EMA_SLOW = 200
EMA_SLOPE_PERIOD = 20
RSI_PERIOD = 14
ADX_PERIOD = 14
BB_PERIOD = 20
HORIZON_BARS = 12
SL_ATR_MULTIPLIER = 0.8
RR = 0.8
MIN_PROBABILITY = 0.80
RANDOM_STATE = 42
MODEL_NAMES = (
    "logistic_regression", "random_forest", "hist_gradient_boosting", "xgboost", "mlp",
)
# Pilih model di sini. Tidak perlu parameter command line.
MODEL_NAME = "xgboost"
# Converter XGBoost/onnxmltools pada environment ini mendukung maksimal opset 15.
ONNX_TARGET_OPSET = 15
EARLY_STOPPING_ROUNDS = 50
TRAIN_RATIO = 0.70
TEST_RATIO = 0.15
VALIDATION_RATIO = 0.15

M5_FEATURES = [
    "norm_atr_14", "bb_width", "body_to_range", "dist_ema_50",
    "dist_ema_200", "ema_slope_20", "rsi_scaled", "adx_scaled",
    "log_return_1", "upper_shadow_ratio", "lower_shadow_ratio",
    "hour_sin", "hour_cos", "norm_spread",
]
H1_FEATURES = ["h1_dist_ema_50", "h1_dist_ema_200", "h1_ema_slope_20", "h1_adx_scaled"]
FEATURES = M5_FEATURES + H1_FEATURES


def find_data(patterns: tuple[str, ...]) -> Path:
    for pattern in patterns:
        matches = sorted(DATA_DIR.glob(pattern))
        if matches:
            return matches[0]
    raise FileNotFoundError(f"No data found in {DATA_DIR} for {patterns}")


def load_ohlc(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, parse_dates=["time"])
    required = {"time", "open", "high", "low", "close"}
    missing = required.difference(df.columns)
    if missing:
        raise ValueError(f"{path.name} is missing columns: {sorted(missing)}")
    df = df.sort_values("time").drop_duplicates("time").reset_index(drop=True)
    df = df.set_index("time")
    for col in ["open", "high", "low", "close"]:
        df[col] = pd.to_numeric(df[col], errors="coerce")
    df = df.dropna(subset=["open", "high", "low", "close"])
    return df


def rsi(close: pd.Series, period: int) -> pd.Series:
    delta = close.diff()
    gain = delta.clip(lower=0).ewm(alpha=1 / period, adjust=False).mean()
    loss = (-delta.clip(upper=0)).ewm(alpha=1 / period, adjust=False).mean()
    rs = gain / loss.replace(0, np.nan)
    return (100 - 100 / (1 + rs)).fillna(50)


def atr(df: pd.DataFrame, period: int) -> pd.Series:
    prev_close = df["close"].shift(1)
    tr = pd.concat([
        df["high"] - df["low"],
        (df["high"] - prev_close).abs(),
        (df["low"] - prev_close).abs(),
    ], axis=1).max(axis=1)
    return tr.ewm(alpha=1 / period, adjust=False).mean()


def adx(df: pd.DataFrame, period: int) -> pd.Series:
    up = df["high"].diff()
    down = -df["low"].diff()
    plus_dm = up.where((up > down) & (up > 0), 0.0)
    minus_dm = down.where((down > up) & (down > 0), 0.0)
    tr = atr(df, period)
    plus_di = 100 * plus_dm.ewm(alpha=1 / period, adjust=False).mean() / tr
    minus_di = 100 * minus_dm.ewm(alpha=1 / period, adjust=False).mean() / tr
    dx = 100 * (plus_di - minus_di).abs() / (plus_di + minus_di).replace(0, np.nan)
    return dx.ewm(alpha=1 / period, adjust=False).mean().fillna(0)


def make_features(df: pd.DataFrame, prefix: str = "") -> pd.DataFrame:
    close = df["close"]
    candle_range = (df["high"] - df["low"]).replace(0, np.nan)
    ema20 = close.ewm(span=20, adjust=False).mean()
    ema50 = close.ewm(span=EMA_FAST, adjust=False).mean()
    ema200 = close.ewm(span=EMA_SLOW, adjust=False).mean()
    atr14 = atr(df, ATR_PERIOD)
    middle = close.rolling(BB_PERIOD).mean()
    std = close.rolling(BB_PERIOD).std()
    rsi14 = rsi(close, RSI_PERIOD)
    adx14 = adx(df, ADX_PERIOD)
    body_high = df[["open", "close"]].max(axis=1)
    body_low = df[["open", "close"]].min(axis=1)

    if prefix:
        return pd.DataFrame({
            f"{prefix}dist_ema_50": (close - ema50) / close,
            f"{prefix}dist_ema_200": (close - ema200) / close,
            f"{prefix}ema_slope_20": ema20 / ema20.shift(EMA_SLOPE_PERIOD) - 1,
            f"{prefix}adx_scaled": adx14 / 100,
        }, index=df.index)

    spread = pd.to_numeric(df.get("spread", pd.Series(0, index=df.index)), errors="coerce")
    spread = spread.fillna(0)
    return pd.DataFrame({
        "norm_atr_14": atr14 / close,
        "bb_width": (4 * std / middle).replace([np.inf, -np.inf], np.nan),
        "body_to_range": (body_high - body_low) / candle_range,
        "dist_ema_50": (close - ema50) / close,
        "dist_ema_200": (close - ema200) / close,
        "ema_slope_20": ema20 / ema20.shift(EMA_SLOPE_PERIOD) - 1,
        "rsi_scaled": rsi14 / 100,
        "adx_scaled": adx14 / 100,
        "log_return_1": np.log(close / close.shift(1)),
        "upper_shadow_ratio": (df["high"] - body_high) / candle_range,
        "lower_shadow_ratio": (body_low - df["low"]) / candle_range,
        "hour_sin": np.sin(2 * np.pi * df.index.hour / 24),
        "hour_cos": np.cos(2 * np.pi * df.index.hour / 24),
        "norm_spread": spread / close,
    }, index=df.index)


def make_labels(entry_df: pd.DataFrame, features: pd.DataFrame, outcome_df: pd.DataFrame) -> pd.Series:
    """Triple-barrier labels for M5 entries, evaluated using M1 candles."""
    atr_values = (features["norm_atr_14"] * entry_df["close"]).to_numpy()
    outcome_times = outcome_df.index.to_numpy()
    highs = outcome_df["high"].to_numpy()
    lows = outcome_df["low"].to_numpy()
    labels = np.full(len(entry_df), 1, dtype=np.int64)
    horizon = pd.Timedelta(minutes=HORIZON_BARS * 5)
    for i, entry_time in enumerate(entry_df.index):
        distance = atr_values[i] * SL_ATR_MULTIPLIER
        if not np.isfinite(distance) or distance <= 0:
            continue
        start = outcome_df.index.searchsorted(entry_time, side="right")
        end = outcome_df.index.searchsorted(entry_time + horizon, side="right")
        entry = entry_df["close"].iloc[i]
        buy_sl, buy_tp = entry - distance, entry + distance * RR
        sell_sl, sell_tp = entry + distance, entry - distance * RR
        for j in range(start, min(end, len(outcome_df))):
            buy_sl_hit, buy_tp_hit = lows[j] <= buy_sl, highs[j] >= buy_tp
            sell_sl_hit, sell_tp_hit = highs[j] >= sell_sl, lows[j] <= sell_tp
            if buy_sl_hit and buy_tp_hit:
                labels[i] = 0
                break
            if sell_sl_hit and sell_tp_hit:
                labels[i] = 2
                break
            if buy_tp_hit:
                labels[i] = 2
                break
            if sell_tp_hit:
                labels[i] = 0
                break
            if buy_sl_hit or sell_sl_hit:
                labels[i] = 0 if buy_sl_hit else 2
                break
    return pd.Series(labels, index=entry_df.index, name="target")


def build_model(name: str):
    if name == "logistic_regression":
        return Pipeline([
            ("scaler", StandardScaler()),
            ("model", LogisticRegression(
                max_iter=1000, class_weight="balanced", C=0.5,
                random_state=RANDOM_STATE,
            )),
        ])
    if name == "random_forest":
        return RandomForestClassifier(
            n_estimators=300, max_depth=12, min_samples_leaf=20,
            class_weight="balanced_subsample", n_jobs=-1,
            random_state=RANDOM_STATE,
        )
    if name == "hist_gradient_boosting":
        return HistGradientBoostingClassifier(
            max_iter=250, learning_rate=0.05, max_leaf_nodes=31,
            l2_regularization=1.0, random_state=RANDOM_STATE,
        )
    if name == "xgboost":
        return XGBClassifier(
                n_estimators=25000,         # Dinaikkan tinggi, namun WAJIB menggunakan early_stopping_rounds
                max_depth=4,                # Dibuat dangkal (rentang 3-5 sangat ideal untuk data trading agar tidak overfit ke noise)
                learning_rate=0.015,        # Diturunkan sedikit agar pencarian pola lebih stabil dan presisi
                subsample=0.7,              # Dikurangi agar model lebih tangguh terhadap noise pasar
                colsample_bytree=0.7,       # Dikurangi agar model tidak terlalu bergantung pada kombinasi fitur tertentu
                min_child_weight=20,        # Dinaikkan signifikan (min 20-50) agar model tidak membuat daun berdasarkan sedikit bar / outlier
                gamma=0.2,                  # Regularisasi konservatif untuk memotong cabang yang tidak krusial
                reg_alpha=0.5,              # Ditambah untuk penalitas L1 (mematikan fitur noise secara implisit)
                reg_lambda=2.0,             # Ditambah untuk penalitas L2 (menjaga bobot prediksi tetap stabil)
                objective="multi:softprob",
                num_class=3,
                eval_metric="mlogloss",
                early_stopping_rounds=EARLY_STOPPING_ROUNDS,
                # tree_method="hist",
                n_jobs=-1,
                random_state=RANDOM_STATE
            )

            
        # XGBClassifier(
        #     n_estimators=300, max_depth=21, learning_rate=0.01,
        #     subsample=0.85, colsample_bytree=0.85,
        #     min_child_weight=10, objective="multi:softprob",
        #     num_class=3, eval_metric="mlogloss", early_stopping_rounds=EARLY_STOPPING_ROUNDS,
                # tree_method="hist",
        #     n_jobs=-1, random_state=RANDOM_STATE,
        # )
    if name == "mlp":
        return Pipeline([
            ("scaler", StandardScaler()),
            ("model", MLPClassifier(
                hidden_layer_sizes=(99, 99, 99, 99, 99), activation="relu", solver="adam",
                alpha=1e-4, batch_size=512, learning_rate_init=1e-3,
                max_iter=100, early_stopping=False,
                n_iter_no_change=12, random_state=RANDOM_STATE,
            )),
        ])
    raise ValueError(f"Unknown model {name!r}. Choose one of: {', '.join(MODEL_NAMES)}")


def main() -> None:
    if MODEL_NAME not in MODEL_NAMES:
        raise ValueError(
            f"Unknown MODEL_NAME={MODEL_NAME!r}. Choose one of: {', '.join(MODEL_NAMES)}"
        )
    m5_path, h1_path = find_data(M5_PATTERNS), find_data(H1_PATTERNS)
    m1_path = find_data(M1_PATTERNS)
    print(f"M5: {m5_path.name}\nM1: {m1_path.name}\nH1: {h1_path.name}")
    m5, m1, h1 = load_ohlc(m5_path), load_ohlc(m1_path), load_ohlc(h1_path)
    x_m5 = make_features(m5)
    x_h1 = make_features(h1, prefix="h1_")
    # H1 candle must already be closed at the M5 timestamp: no look-ahead.
    x_h1 = x_h1.shift(1)
    x_h1 = x_h1.reindex(m5.index, method="ffill")
    x = pd.concat([x_m5, x_h1], axis=1)[FEATURES]
    # Features are M5; SL/TP outcome is evaluated from subsequent M1 candles.
    y = make_labels(m5, x_m5, m1)
    data = pd.concat([x, y], axis=1).replace([np.inf, -np.inf], np.nan).dropna()
    # Batasi candle entry/training sesuai rentang hardcode; feature tetap
    # dihitung dari seluruh history agar EMA/ATR tidak kehilangan warm-up.
    data = data.loc[DATA_START:DATA_END]
    data = data.iloc[:-HORIZON_BARS]
    print(f"Selected data period: {data.index.min()} -> {data.index.max()}")
    if len(data) < 1000:
        raise RuntimeError(f"Too little usable data for training: {len(data)} rows")

    if not np.isclose(TRAIN_RATIO + VALIDATION_RATIO + TEST_RATIO, 1.0):
        raise ValueError("TRAIN_RATIO + VALIDATION_RATIO + TEST_RATIO harus sama dengan 1.0")
    train_end = int(len(data) * TRAIN_RATIO)
    validation_end = int(len(data) * (TRAIN_RATIO + VALIDATION_RATIO))
    train = data.iloc[:train_end]
    validation = data.iloc[train_end:validation_end]
    test = data.iloc[validation_end:]
    print(f"Training period: {train.index.min()} -> {train.index.max()}")
    print(f"Validation period: {validation.index.min()} -> {validation.index.max()}")
    print(f"Testing period:    {test.index.min()} -> {test.index.max()}")
    model = build_model(MODEL_NAME)
    x_train = train[FEATURES].to_numpy(dtype=np.float32)
    x_validation = validation[FEATURES].to_numpy(dtype=np.float32)
    x_test = test[FEATURES].to_numpy(dtype=np.float32)
    y_train = train["target"].to_numpy(dtype=np.int64)
    y_validation = validation["target"].to_numpy(dtype=np.int64)
    y_test = test["target"].to_numpy(dtype=np.int64)
    # onnxmltools converter untuk XGBoost versi ini hanya menerima feature
    # names otomatis f0, f1, ...; mapping nama feature tetap disimpan terpisah.
    if MODEL_NAME == "xgboost":
        model.fit(x_train, y_train, eval_set=[(x_validation, y_validation)], verbose=False)
    else:
        model.fit(train[FEATURES].astype(np.float32), y_train)
    pred_train = model.predict(x_train if MODEL_NAME == "xgboost" else train[FEATURES].astype(np.float32))
    pred_validation = model.predict(x_validation if MODEL_NAME == "xgboost" else validation[FEATURES].astype(np.float32))
    pred_test = model.predict(x_test if MODEL_NAME == "xgboost" else test[FEATURES].astype(np.float32))
    print(f"Model: {MODEL_NAME}")
    print("\nClassification report - TRAIN:")
    print(classification_report(y_train, pred_train, labels=[0, 1, 2],
                                target_names=["SELL", "NO_TRADE", "BUY"], zero_division=0))
    print("Confusion matrix TRAIN [SELL, NO_TRADE, BUY]:")
    print(confusion_matrix(y_train, pred_train, labels=[0, 1, 2]))
    print("\nClassification report - VALIDATION:")
    print(classification_report(y_validation, pred_validation, labels=[0, 1, 2],
                                target_names=["SELL", "NO_TRADE", "BUY"], zero_division=0))
    print("Confusion matrix VALIDATION [SELL, NO_TRADE, BUY]:")
    print(confusion_matrix(y_validation, pred_validation, labels=[0, 1, 2]))
    print("\nClassification report - TEST:")
    print(classification_report(y_test, pred_test, labels=[0, 1, 2],
                                target_names=["SELL", "NO_TRADE", "BUY"], zero_division=0))
    print("Confusion matrix TEST [SELL, NO_TRADE, BUY]:")
    print(confusion_matrix(y_test, pred_test, labels=[0, 1, 2]))

    if MODEL_NAME == "xgboost":
        onnx_model = convert_xgboost(
            model, initial_types=[("float_input", XGBFloatTensorType([None, len(FEATURES)]))],
            target_opset=ONNX_TARGET_OPSET,
        )
    else:
        onnx_model = convert_sklearn(
            model, initial_types=[("float_input", FloatTensorType([None, len(FEATURES)]))],
            options={id(model): {"zipmap": False}}, target_opset=ONNX_TARGET_OPSET,
        )
    MODEL_PATH.write_bytes(onnx_model.SerializeToString())
    FEATURE_ORDER_PATH.write_text("\n".join(FEATURES) + "\n", encoding="utf-8")
    metrics = {
        "model": MODEL_NAME,
        "features": FEATURES, "classes": {"0": "SELL", "1": "NO_TRADE", "2": "BUY"},
        "rows": len(data), "train_rows": len(train), "validation_rows": len(validation), "test_rows": len(test),
        "train_start": train.index.min().isoformat(),
        "train_end": train.index.max().isoformat(),
        "validation_start": validation.index.min().isoformat(),
        "validation_end": validation.index.max().isoformat(),
        "test_start": test.index.min().isoformat(),
        "test_end": test.index.max().isoformat(),
        "horizon_bars": HORIZON_BARS, "sl_atr_multiplier": SL_ATR_MULTIPLIER,
        "rr": RR, "min_probability": MIN_PROBABILITY,
        "validation_accuracy": float((pred_validation == y_validation).mean()),
        "test_accuracy": float((pred_test == y_test).mean()),
    }
    METRICS_PATH.write_text(json.dumps(metrics, indent=2), encoding="utf-8")
    print(f"Saved ONNX model: {MODEL_PATH}")
    print(f"Saved feature order: {FEATURE_ORDER_PATH}")


if __name__ == "__main__":
    main()
