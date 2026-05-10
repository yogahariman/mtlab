from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd
import ta

from sklearn.ensemble import RandomForestRegressor
from sklearn.metrics import mean_absolute_error, r2_score
from sklearn.neural_network import MLPRegressor
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler


BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
SYMBOL_FILE = "XAUUSD"
ENTRY_TIMEFRAME = "M5"
CONTEXT_TIMEFRAMES = ["M15", "H1", "H4", "D1"]
MODEL_NAME = "random_forest"  # random_forest, xgboost, neural_network
ONNX_PATH = BASE_DIR / "model_xau_ml.onnx"
FEATURES_PATH = BASE_DIR / "feature_order.txt"

# EA evaluasi tiap candle M5 close. Target 6 bar M5 = kira-kira 30 menit ke depan.
TARGET_BARS = 6
TRAIN_RATIO = 0.70
VALID_RATIO = 0.15
TRADE_COST = 0.0
RANDOM_STATE = 42


TIMEFRAME_MINUTES = {
    "M5": 5,
    "M15": 15,
    "H1": 60,
    "H4": 240,
    "D1": 1440,
}


def data_path(timeframe: str) -> Path:
    return DATA_DIR / f"{SYMBOL_FILE}_{timeframe}.csv"


def load_cached_rates(timeframe: str) -> pd.DataFrame:
    path = data_path(timeframe)
    if not path.exists():
        raise FileNotFoundError(f"Data cache not found: {path}. Run 01_download_data.py first.")

    df = pd.read_csv(path)
    df["time"] = pd.to_datetime(df["time"], utc=True)
    return df.drop_duplicates(subset="time").sort_values("time").set_index("time")


def build_timeframe_features(rates: pd.DataFrame, timeframe: str) -> tuple[pd.DataFrame, pd.Series | None, pd.Series | None]:
    data = pd.DataFrame(index=rates.index)
    open_ = rates["open"].astype(float)
    high = rates["high"].astype(float)
    low = rates["low"].astype(float)
    close = rates["close"].astype(float)
    tick_volume = rates["tick_volume"].astype(float)
    prefix = timeframe.lower()

    data[f"{prefix}_last"] = close.diff()
    data[f"{prefix}_last_3"] = data[f"{prefix}_last"].rolling(3).mean()
    data[f"{prefix}_last_11"] = data[f"{prefix}_last"].rolling(11).mean()
    data[f"{prefix}_range"] = high - low
    data[f"{prefix}_body"] = close - open_
    data[f"{prefix}_atr_14"] = ta.volatility.average_true_range(high, low, close, window=14, fillna=True)
    data[f"{prefix}_volume_ratio_20"] = tick_volume / tick_volume.rolling(20).mean()

    sma_12 = ta.trend.sma_indicator(close, window=12, fillna=True)
    sma_48 = ta.trend.sma_indicator(close, window=48, fillna=True)
    data[f"{prefix}_close_sma_12"] = close - sma_12
    data[f"{prefix}_close_sma_48"] = close - sma_48
    data[f"{prefix}_sma_12_slope"] = sma_12.diff()
    data[f"{prefix}_rsi_14"] = ta.momentum.rsi(close, window=14, fillna=True)

    macd = ta.trend.MACD(close, window_fast=12, window_slow=24, window_sign=9, fillna=True)
    macd_main = macd.macd()
    macd_signal = macd.macd_signal()
    data[f"{prefix}_macd_main"] = macd_main
    data[f"{prefix}_macd_signal"] = macd_signal
    data[f"{prefix}_macd_sig_main"] = macd_signal - macd_main

    next_move = None
    target = None
    if timeframe == ENTRY_TIMEFRAME:
        next_move = close.shift(-1) - close
        target = next_move.rolling(TARGET_BARS).sum().shift(-(TARGET_BARS - 1))
        data[f"{prefix}_target_{TARGET_BARS}"] = target
        data[f"{prefix}_next"] = next_move

    # A bar is only known after it closes. Shift index from open time to close/availability time.
    data.index = data.index + pd.to_timedelta(TIMEFRAME_MINUTES[timeframe], unit="m")
    if target is not None:
        target.index = target.index + pd.to_timedelta(TIMEFRAME_MINUTES[timeframe], unit="m")
    if next_move is not None:
        next_move.index = next_move.index + pd.to_timedelta(TIMEFRAME_MINUTES[timeframe], unit="m")

    features = data.drop(columns=[c for c in data.columns if c.endswith(f"target_{TARGET_BARS}") or c.endswith("_next")])
    return features, target, next_move


def build_dataset() -> tuple[pd.DataFrame, pd.Series, pd.Series, list[str]]:
    entry_rates = load_cached_rates(ENTRY_TIMEFRAME)
    X, y, y_next = build_timeframe_features(entry_rates, ENTRY_TIMEFRAME)
    assert y is not None and y_next is not None

    X = X.sort_index()
    for timeframe in CONTEXT_TIMEFRAMES:
        context_rates = load_cached_rates(timeframe)
        context_features, _, _ = build_timeframe_features(context_rates, timeframe)
        X = pd.merge_asof(
            X.sort_index(),
            context_features.sort_index(),
            left_index=True,
            right_index=True,
            direction="backward",
        )

    hours = pd.Series(X.index.hour, index=X.index, dtype=float)
    # MQL5 MqlDateTime.day_of_week uses Sunday=0, while pandas dayofweek uses Monday=0.
    days = pd.Series((X.index.dayofweek + 1) % 7, index=X.index, dtype=float)
    X["time_hour_sin"] = np.sin(2 * np.pi * hours / 24)
    X["time_hour_cos"] = np.cos(2 * np.pi * hours / 24)
    X["time_dow_sin"] = np.sin(2 * np.pi * days / 7)
    X["time_dow_cos"] = np.cos(2 * np.pi * days / 7)

    dataset = X.join(y.rename("target")).join(y_next.rename("next"))
    dataset = dataset.replace([np.inf, -np.inf], np.nan).dropna()

    features = [c for c in dataset.columns if c not in {"target", "next"}]
    return dataset[features], dataset["target"], dataset["next"], features


def split_time_series(X: pd.DataFrame, y: pd.Series):
    train_end = int(len(X) * TRAIN_RATIO)
    valid_end = int(len(X) * (TRAIN_RATIO + VALID_RATIO))
    return (
        X.iloc[:train_end],
        X.iloc[train_end:valid_end],
        X.iloc[valid_end:],
        y.iloc[:train_end],
        y.iloc[train_end:valid_end],
        y.iloc[valid_end:],
    )


def create_model(name: str):
    if name == "random_forest":
        return RandomForestRegressor(
            n_estimators=300,
            max_depth=10,
            max_leaf_nodes=180,
            min_samples_split=6,
            min_samples_leaf=3,
            bootstrap=True,
            random_state=RANDOM_STATE,
            n_jobs=-1,
        )

    if name == "xgboost":
        from xgboost import XGBRegressor

        return XGBRegressor(
            n_estimators=800,
            learning_rate=0.02,
            max_depth=5,
            min_child_weight=20,
            subsample=0.8,
            colsample_bytree=0.8,
            objective="reg:squarederror",
            random_state=RANDOM_STATE,
            n_jobs=-1,
            tree_method="hist",
        )

    if name == "neural_network":
        return Pipeline(
            [
                ("scaler", StandardScaler()),
                (
                    "mlp",
                    MLPRegressor(
                        hidden_layer_sizes=(96, 48),
                        alpha=0.001,
                        learning_rate_init=0.001,
                        max_iter=300,
                        early_stopping=True,
                        random_state=RANDOM_STATE,
                    ),
                ),
            ]
        )

    raise ValueError(f"Unsupported model: {name}")


def evaluate(label: str, model, X: pd.DataFrame, y: pd.Series) -> np.ndarray:
    pred = np.nan_to_num(model.predict(X), nan=0.0, posinf=0.0, neginf=0.0)
    corr = np.corrcoef(pred, y)[0, 1] if np.std(pred) > 0 and np.std(y) > 0 else np.nan
    print(f"\n{label}")
    print("Rows:", len(X))
    print("R2:", round(r2_score(y, pred), 6))
    print("MAE:", round(mean_absolute_error(y, pred), 8))
    print("Pred/Target corr:", round(float(corr), 6) if np.isfinite(corr) else corr)
    return pred


def evaluate_thresholds(pred_train: np.ndarray, pred_test: np.ndarray, y_test_next: pd.Series) -> None:
    corr = np.corrcoef(pred_test, y_test_next)[0, 1] if np.std(pred_test) > 0 and np.std(y_test_next) > 0 else 0.0
    direction_factor = np.sign(corr) if corr != 0 else 1.0
    percentiles = np.arange(50, 100, 5)
    thresholds = np.percentile(np.abs(pred_train), percentiles)

    pred_matrix = np.tile(pred_test[:, None], (1, thresholds.size))
    position = np.sign(pred_matrix) * direction_factor * (np.abs(pred_matrix) >= thresholds[None, :])
    target_matrix = np.tile(y_test_next.values[:, None], (1, thresholds.size))
    strategy_ret = position * target_matrix - np.abs(position) * TRADE_COST

    trades = np.sum(position != 0, axis=0)
    wins = np.sum(strategy_ret > 0, axis=0)
    losses = np.abs(np.sum(np.minimum(strategy_ret, 0), axis=0))
    gains = np.sum(np.maximum(strategy_ret, 0), axis=0)

    results = pd.DataFrame(
        {
            "percentile": percentiles,
            "threshold": thresholds,
            "trades": trades,
            "final_equity": np.sum(strategy_ret, axis=0),
            "mean_return": np.sum(strategy_ret, axis=0) / (trades + 1e-9),
            "win_rate": wins / (trades + 1e-9),
            "profit_factor": gains / (losses + 1e-9),
        }
    )
    print("\nThreshold backtest prototype")
    print(results.to_string(index=False, float_format="%.6f"))


def export_onnx(model_name: str, model, n_features: int, output_path: Path) -> None:
    from skl2onnx.common.data_types import FloatTensorType

    initial_types = [("float_input", FloatTensorType([None, n_features]))]

    if model_name in {"random_forest", "neural_network"}:
        from skl2onnx import convert_sklearn

        onnx_model = convert_sklearn(model, initial_types=initial_types)
    elif model_name == "xgboost":
        from onnxmltools import convert_xgboost

        onnx_model = convert_xgboost(model, initial_types=initial_types)
    else:
        raise ValueError(f"Unsupported ONNX model: {model_name}")

    output_path.write_bytes(onnx_model.SerializeToString())
    print(f"\nSaved ONNX model: {output_path}")


def main() -> None:
    X, y, y_next, features = build_dataset()
    FEATURES_PATH.write_text("\n".join(features) + "\n", encoding="utf-8")

    print(f"Entry timeframe: {ENTRY_TIMEFRAME}")
    print(f"Context timeframes: {', '.join(CONTEXT_TIMEFRAMES)}")
    print(f"Target: next {TARGET_BARS} {ENTRY_TIMEFRAME} bars")
    print(f"Dataset rows: {len(X)}")
    print(f"Features: {len(features)}")
    for idx, feature in enumerate(features):
        print(f"f{idx}: {feature}")

    X_model = X.copy()
    X_model.columns = [f"f{i}" for i in range(X_model.shape[1])]

    X_train, X_valid, X_test, y_train, y_valid, y_test = split_time_series(X_model, y)
    model = create_model(MODEL_NAME)
    print(f"\nTraining {MODEL_NAME}...")
    model.fit(X_train, y_train)

    pred_train = evaluate("Train", model, X_train, y_train)
    evaluate("Validation", model, X_valid, y_valid)
    pred_test = evaluate("Test", model, X_test, y_test)
    evaluate_thresholds(pred_train, pred_test, y_next.iloc[-len(pred_test):])
    export_onnx(MODEL_NAME, model, X_train.shape[1], ONNX_PATH)


if __name__ == "__main__":
    main()
