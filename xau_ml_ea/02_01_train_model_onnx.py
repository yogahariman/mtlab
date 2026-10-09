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
CONFIG_PATH = ROOT / "02_01_train_model_onnx_config.json"
TRAINING_CONFIG = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
# Rentang candle M5 yang dipakai sebagai dataset entry/training.
# Ubah kedua nilai ini untuk menentukan periode data secara hardcode.
DATA_START = "2025-01-01 00:00:00+00:00"
DATA_END = "2026-08-31 23:59:59+00:00"
DATA_DIR = ROOT / "data"
MODEL_PATH = ROOT / "model_xau_single_shot.onnx"
FEATURE_ORDER_PATH = ROOT / "feature_order.txt"
METRICS_PATH = ROOT / "training_metrics.json"
MODEL_METADATA_PATH = ROOT / "model_xau_single_shot.meta"

# Downloader menghasilkan nama berdasarkan simbol broker. vx adalah contoh
# suffix broker; pencarian glob membuat training tetap bekerja untuk XAUUSDm,
# XAUUSD.v, dan variasi nama lainnya.
OUTCOME_TIMEFRAME = TRAINING_CONFIG["outcome_timeframe"]
CONTEXT_TIMEFRAME = TRAINING_CONFIG["context_timeframe"]
DATA_PATTERNS = {
    "M1": ("XAUUSD*_M1.csv", "*_M1.csv"),
    "M5": ("XAUUSD*_M5.csv", "*_M5.csv"),
    "M15": ("XAUUSD*_M15.csv", "*_M15.csv"),
    "H1": ("XAUUSD*_H1.csv", "*_H1.csv"),
    "H4": ("XAUUSD*_H4.csv", "*_H4.csv"),
    "D1": ("XAUUSD*_D1.csv", "*_D1.csv"),
}

ATR_PERIOD = TRAINING_CONFIG["risk"]["atr_period"]
EMA_FAST = TRAINING_CONFIG["indicators"]["ema_fast"]
EMA_SLOW = TRAINING_CONFIG["indicators"]["ema_slow"]
EMA_SLOPE_PERIOD = TRAINING_CONFIG["indicators"]["ema_slope_period"]
RSI_PERIOD = TRAINING_CONFIG["indicators"]["rsi_period"]
ADX_PERIOD = TRAINING_CONFIG["indicators"]["adx_period"]
BB_PERIOD = TRAINING_CONFIG["indicators"]["bb_period"]
SL_ATR_MULTIPLIER = TRAINING_CONFIG["risk"]["sl_atr_multiplier"]
RR = TRAINING_CONFIG["risk"]["rr"]
MIN_PROBABILITY = TRAINING_CONFIG["risk"]["min_probability"]
RANDOM_STATE = 42
MODEL_NAMES = (
    "logistic_regression", "random_forest", "hist_gradient_boosting", "xgboost", "mlp",
)
# Pilih model di sini. Tidak perlu parameter command line.
MODEL_NAME = TRAINING_CONFIG["model"]["name"]
# Converter XGBoost/onnxmltools pada environment ini mendukung maksimal opset 15.
ONNX_TARGET_OPSET = 15
EARLY_STOPPING_ROUNDS = 50
TRAIN_RATIO = TRAINING_CONFIG["split"]["train_ratio"]
TEST_RATIO = TRAINING_CONFIG["split"]["test_ratio"]
VALIDATION_RATIO = TRAINING_CONFIG["split"]["validation_ratio"]

ENTRY_FEATURES = [
    "norm_atr_14", "bb_width", "body_to_range", "dist_ema_50",
    "dist_ema_200", "ema_slope_20", "rsi_scaled", "adx_scaled",
    "log_return_1", "upper_shadow_ratio", "lower_shadow_ratio",
    "hour_sin", "hour_cos", "norm_spread",
]
CONTEXT_FEATURES = ["context_dist_ema_50", "context_dist_ema_200", "context_ema_slope_20", "context_adx_scaled"]
FEATURES = ENTRY_FEATURES + CONTEXT_FEATURES


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


def make_labels(entry_df: pd.DataFrame, features: pd.DataFrame, outcome_df: pd.DataFrame, horizon_minutes: int) -> pd.Series:
    """Triple-barrier labels for M5 entries, evaluated using M1 candles."""
    atr_values = (features["norm_atr_14"] * entry_df["close"]).to_numpy()
    outcome_times = outcome_df.index.to_numpy()
    highs = outcome_df["high"].to_numpy()
    lows = outcome_df["low"].to_numpy()
    labels = np.full(len(entry_df), 1, dtype=np.int64)
    horizon = pd.Timedelta(minutes=horizon_minutes)
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



# Model arah dikonfigurasi berdasarkan peran. Target setiap model: horizon 1 hari.
# Samakan ketiga nilai ini dengan input timeframe pada EA.
PRIMARY_TIMEFRAME = TRAINING_CONFIG["roles"]["primary"]
CONFIRM_TIMEFRAME1 = TRAINING_CONFIG["roles"]["confirm1"]
HORIZON_MINUTES = TRAINING_CONFIG["horizon_minutes"]

TIMEFRAME_DATA = {
    "M5": (DATA_PATTERNS["M5"], 5),
    "M15": (DATA_PATTERNS["M15"], 15),
    "H1": (DATA_PATTERNS["H1"], 60),
    "H4": (DATA_PATTERNS["H4"], 240),
}


def timeframe_config(timeframe: str) -> dict:
    if timeframe not in TIMEFRAME_DATA:
        raise ValueError(f"Unsupported timeframe: {timeframe}")
    patterns, minutes = TIMEFRAME_DATA[timeframe]
    bars = HORIZON_MINUTES // minutes
    if HORIZON_MINUTES % minutes != 0:
        raise ValueError(f"Horizon {HORIZON_MINUTES} is not divisible by {timeframe}")
    return {"name": timeframe, "patterns": patterns, "bars": bars, "horizon_minutes": HORIZON_MINUTES}


TIMEFRAME_CONFIG = {
    "primary": timeframe_config(PRIMARY_TIMEFRAME),
    "confirm1": timeframe_config(CONFIRM_TIMEFRAME1),
}


def export_probabilities(model, model_name: str):
    """Export one output only: probabilities with shape [batch, 3]."""
    if model_name == "xgboost":
        onnx_model = convert_xgboost(
            model,
            initial_types=[("float_input", XGBFloatTensorType([None, len(FEATURES)]))],
            target_opset=ONNX_TARGET_OPSET,
        )
    else:
        onnx_model = convert_sklearn(
            model,
            initial_types=[("float_input", FloatTensorType([None, len(FEATURES)]))],
            options={id(model): {"zipmap": False}},
            target_opset=ONNX_TARGET_OPSET,
        )
    if len(onnx_model.graph.output) > 1:
        del onnx_model.graph.output[0]
    return onnx_model


def train_one_timeframe(role: str, config: dict) -> None:
    timeframe = config["name"]
    entry_path = find_data(config["patterns"])
    outcome_path = find_data(DATA_PATTERNS[OUTCOME_TIMEFRAME])
    context_path = find_data(DATA_PATTERNS[CONTEXT_TIMEFRAME])
    entry = load_ohlc(entry_path)
    outcome = load_ohlc(outcome_path)
    context = load_ohlc(context_path)

    # Feature utama mengikuti timeframe model.
    x_entry = make_features(entry)
    # ATR risiko berasal dari timeframe pertama/model entry.
    # M15 model memakai ATR M15, H1 memakai ATR H1, H4 memakai ATR H4.
    # M1 tetap hanya dipakai untuk mengevaluasi urutan hit TP/SL.

    # H1 context hanya memakai candle yang sudah closed.
    x_context = make_features(context, prefix="context_").shift(1)
    x_context = x_context.reindex(entry.index, method="ffill")
    x = pd.concat([x_entry, x_context], axis=1)[FEATURES]

    y = make_labels(
        entry,
        x_entry,
        outcome,
        horizon_minutes=config["horizon_minutes"],
    )
    data = (
        pd.concat([x, y], axis=1)
        .replace([np.inf, -np.inf], np.nan)
        .dropna()
        .loc[DATA_START:DATA_END]
    )
    data = data.iloc[:-config["bars"]]
    if len(data) < 1000:
        raise RuntimeError(f"Too little usable {timeframe} data: {len(data)} rows")

    train_end = int(len(data) * TRAIN_RATIO)
    validation_end = int(len(data) * (TRAIN_RATIO + VALIDATION_RATIO))
    train = data.iloc[:train_end]
    validation = data.iloc[train_end:validation_end]
    test = data.iloc[validation_end:]

    x_train = train[FEATURES].to_numpy(dtype=np.float32)
    x_validation = validation[FEATURES].to_numpy(dtype=np.float32)
    x_test = test[FEATURES].to_numpy(dtype=np.float32)
    y_train = train["target"].to_numpy(dtype=np.int64)
    y_validation = validation["target"].to_numpy(dtype=np.int64)
    y_test = test["target"].to_numpy(dtype=np.int64)

    model = build_model(MODEL_NAME)
    if MODEL_NAME == "xgboost":
        model.fit(x_train, y_train, eval_set=[(x_validation, y_validation)], verbose=False)
        pred_train = model.predict(x_train)
        pred_validation = model.predict(x_validation)
        pred_test = model.predict(x_test)
    else:
        model.fit(train[FEATURES].astype(np.float32), y_train)
        pred_train = model.predict(train[FEATURES].astype(np.float32))
        pred_validation = model.predict(validation[FEATURES].astype(np.float32))
        pred_test = model.predict(test[FEATURES].astype(np.float32))

    print(f"\n===== {timeframe} =====")
    print(f"Rows: {len(data)} | horizon: {config['horizon_minutes']} minutes")
    print("TEST classification report:")
    print(classification_report(
        y_test, pred_test, labels=[0, 1, 2],
        target_names=["SELL", "NO_TRADE", "BUY"], zero_division=0,
    ))
    print("TEST confusion matrix [SELL, NO_TRADE, BUY]:")
    print(confusion_matrix(y_test, pred_test, labels=[0, 1, 2]))

    onnx_model = export_probabilities(model, MODEL_NAME)
    model_path = ROOT / f"model_xau_{role}.onnx"
    metadata_path = ROOT / f"model_xau_{role}.meta"
    feature_path = ROOT / f"feature_order_xau_{role}.txt"
    model_path.write_bytes(onnx_model.SerializeToString())
    feature_path.write_text("\n".join(FEATURES) + "\n", encoding="utf-8")
    metadata = {
        "model": MODEL_NAME,
        "role": role,
        "timeframe": timeframe,
        "feature_count": len(FEATURES),
        "horizon_bars": config["bars"],
        "horizon_minutes": config["horizon_minutes"],
        "risk_atr_timeframe": timeframe,
        "outcome_timeframe": OUTCOME_TIMEFRAME,
        "context_timeframe": CONTEXT_TIMEFRAME,
        "atr_period": ATR_PERIOD,
        "ema_fast": EMA_FAST,
        "ema_slow": EMA_SLOW,
        "ema_slope_period": EMA_SLOPE_PERIOD,
        "rsi_period": RSI_PERIOD,
        "adx_period": ADX_PERIOD,
        "bb_period": BB_PERIOD,
        "sl_atr_multiplier": SL_ATR_MULTIPLIER,
        "rr": RR,
        "min_probability": MIN_PROBABILITY,
        "test_accuracy": float((pred_test == y_test).mean()),
    }
    metadata_path.write_text(
        "\n".join(f"{key}={value}" for key, value in metadata.items()) + "\n",
        encoding="utf-8",
    )
    print(f"Saved: {model_path.name}, {metadata_path.name}")


if __name__ == "__main__":
    if MODEL_NAME not in MODEL_NAMES:
        raise ValueError(f"Unknown MODEL_NAME={MODEL_NAME!r}")
    for role, config in TIMEFRAME_CONFIG.items():
        train_one_timeframe(role, config)
