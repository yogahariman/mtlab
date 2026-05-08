from __future__ import annotations

from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd
import pytz
import ta

from mt5linux import MetaTrader5
from sklearn.ensemble import RandomForestRegressor
from sklearn.metrics import mean_absolute_error, r2_score
from sklearn.neural_network import MLPRegressor
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler


# ===== Edit configuration here, then run: python create_model_multi.py =====
MODEL_NAME = "random_forest"  # random_forest, lightgbm, xgboost, neural_network
SYMBOL = "XAUUSD.vx"
TIMEFRAME = "M15"  # M5, M15, M30, H1
FROM_YEAR = 2010
TARGET_BARS = 3

TRAIN_RATIO = 0.70
VALID_RATIO = 0.15

# Cost is subtracted per opened position in the threshold backtest prototype.
# Use price units, e.g. 0.21 for XAU if 21 points equals 0.21 in your broker quotes.
TRADE_COST = 0.0

MT5_PATH = "/home/rfi212/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe"
EXPORT_ONNX = True
ONNX_PATH = "model_random_forest.onnx"


TIMEFRAMES = {
    "M5": "TIMEFRAME_M5",
    "M15": "TIMEFRAME_M15",
    "M30": "TIMEFRAME_M30",
    "H1": "TIMEFRAME_H1",
}


def initialize_mt5(mt5_path: str) -> MetaTrader5:
    mt5 = MetaTrader5()
    if not mt5.initialize(path=mt5_path):
        raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")

    info = mt5.terminal_info()
    if info is not None:
        print(f"MetaTrader 5 Build: {info.build}")
        print(f"Broker: {info.company}")
    return mt5


def load_rates(symbol: str, timeframe_name: str, from_year: int, mt5_path: str) -> pd.DataFrame:
    mt5 = initialize_mt5(mt5_path)
    timezone = pytz.timezone("Etc/UTC")
    utc_from = datetime(from_year, 1, 1, tzinfo=timezone)
    utc_to = datetime.now(timezone)

    timeframe = getattr(mt5, TIMEFRAMES[timeframe_name])
    rates = mt5.copy_rates_range(symbol, timeframe, utc_from, utc_to)
    mt5.shutdown()

    if rates is None or len(rates) == 0:
        raise RuntimeError("No data retrieved. Check symbol, timeframe, or MT5 connection.")

    rates_frame = pd.DataFrame(rates)
    rates_frame["time"] = pd.to_datetime(rates_frame["time"], unit="s", utc=True)
    rates_frame.set_index("time", inplace=True)
    return rates_frame


def add_macd_features(data_matrix: pd.DataFrame, close: pd.Series, features: list[str]) -> None:
    macd_settings = [(8, 16, 6), (12, 24, 9), (36, 72, 27), (48, 96, 36)]

    for fast, slow, sign in macd_settings:
        macd = ta.trend.MACD(
            close,
            window_slow=slow,
            window_fast=fast,
            window_sign=sign,
            fillna=True,
        )
        macd_main = macd.macd()
        macd_signal = macd.macd_signal()
        macd_sig_main = macd_signal - macd_main
        suffix = f"{fast:02d},{slow:02d},{sign:02d}"

        cols = {
            f"MACD_MAIN_{suffix}": macd_main,
            f"DMACD_MAIN_{suffix}": macd_main.diff(),
            f"MACD_SIGNAL_{suffix}": macd_signal,
            f"DMACD_SIGNAL_{suffix}": macd_signal.diff(),
            f"MACD_Sig_Main_{suffix}": macd_sig_main,
            f"DMACD_Sig_Main_{suffix}": macd_sig_main.diff(),
        }
        for col, values in cols.items():
            data_matrix[col] = values
            features.append(col)


def build_features(rates_frame: pd.DataFrame, target_bars: int) -> tuple[pd.DataFrame, pd.Series, list[str]]:
    data_matrix = pd.DataFrame(index=rates_frame.index)
    close = rates_frame["close"].astype(float)
    high = rates_frame["high"].astype(float)
    low = rates_frame["low"].astype(float)
    open_ = rates_frame["open"].astype(float)

    features: list[str] = []

    data_matrix["last"] = close.diff()
    data_matrix["next"] = close.shift(-1) - close
    data_matrix["last_3"] = data_matrix["last"].rolling(window=3).mean()
    data_matrix["last_11"] = data_matrix["last"].rolling(window=11).mean()
    data_matrix["last_last_11"] = data_matrix["last_11"] - data_matrix["last"]
    data_matrix[f"next_{target_bars}"] = (
        data_matrix["next"].rolling(window=target_bars).sum().shift(-(target_bars - 1))
    )
    features.extend(["last", "last_3", "last_11", "last_last_11"])

    data_matrix["range"] = high - low
    data_matrix["body"] = close - open_
    data_matrix["upper_wick"] = high - np.maximum(open_, close)
    data_matrix["lower_wick"] = np.minimum(open_, close) - low
    data_matrix["atr_14"] = ta.volatility.average_true_range(high, low, close, window=14, fillna=True)
    features.extend(["range", "body", "upper_wick", "lower_wick", "atr_14"])

    sma_12 = ta.trend.sma_indicator(close, window=12, fillna=True)
    sma_48 = ta.trend.sma_indicator(close, window=48, fillna=True)
    data_matrix["close_sma_12"] = close - sma_12
    data_matrix["close_sma_48"] = close - sma_48
    data_matrix["sma_12_slope"] = sma_12.diff()
    data_matrix["rsi_14"] = ta.momentum.rsi(close, window=14, fillna=True)
    features.extend(["close_sma_12", "close_sma_48", "sma_12_slope", "rsi_14"])

    add_macd_features(data_matrix, close, features)

    hours = pd.Series(data_matrix.index.hour, index=data_matrix.index, dtype=float)
    day_of_week = pd.Series(data_matrix.index.dayofweek, index=data_matrix.index, dtype=float)
    data_matrix["hour_sin"] = np.sin(2 * np.pi * hours / 24)
    data_matrix["hour_cos"] = np.cos(2 * np.pi * hours / 24)
    data_matrix["dow_sin"] = np.sin(2 * np.pi * day_of_week / 7)
    data_matrix["dow_cos"] = np.cos(2 * np.pi * day_of_week / 7)
    features.extend(["hour_sin", "hour_cos", "dow_sin", "dow_cos"])

    target_col = f"next_{target_bars}"
    data_matrix = data_matrix[features + [target_col, "next"]].replace([np.inf, -np.inf], np.nan)
    data_matrix.dropna(inplace=True)

    X = data_matrix[features]
    y = data_matrix[target_col]
    return X, y, features


def split_time_series(
    X: pd.DataFrame,
    y: pd.Series,
    train_ratio: float,
    valid_ratio: float,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, pd.Series, pd.Series, pd.Series]:
    if train_ratio <= 0 or valid_ratio < 0 or train_ratio + valid_ratio >= 1:
        raise ValueError("train_ratio and valid_ratio must leave a non-empty test set.")

    train_end = int(len(X) * train_ratio)
    valid_end = int(len(X) * (train_ratio + valid_ratio))

    return (
        X.iloc[:train_end],
        X.iloc[train_end:valid_end],
        X.iloc[valid_end:],
        y.iloc[:train_end],
        y.iloc[train_end:valid_end],
        y.iloc[valid_end:],
    )


def rename_features_for_onnx(X: pd.DataFrame) -> pd.DataFrame:
    X_model = X.copy()
    X_model.columns = [f"f{i}" for i in range(X_model.shape[1])]
    return X_model


def create_model(model_name: str, random_state: int = 42):
    if model_name == "random_forest":
        return RandomForestRegressor(
            n_estimators=300,
            max_depth=10,
            max_leaf_nodes=180,
            min_samples_split=6,
            min_samples_leaf=3,
            bootstrap=True,
            random_state=random_state,
            n_jobs=-1,
        )

    if model_name == "lightgbm":
        try:
            from lightgbm import LGBMRegressor
        except ImportError as exc:
            raise RuntimeError("Install lightgbm first: pip install lightgbm") from exc

        return LGBMRegressor(
            n_estimators=800,
            learning_rate=0.02,
            num_leaves=31,
            max_depth=8,
            min_child_samples=100,
            subsample=0.8,
            colsample_bytree=0.8,
            objective="regression",
            random_state=random_state,
            n_jobs=-1,
            verbosity=-1,
        )

    if model_name == "xgboost":
        try:
            from xgboost import XGBRegressor
        except ImportError as exc:
            raise RuntimeError("Install xgboost first: pip install xgboost") from exc

        return XGBRegressor(
            n_estimators=800,
            learning_rate=0.02,
            max_depth=5,
            min_child_weight=20,
            subsample=0.8,
            colsample_bytree=0.8,
            objective="reg:squarederror",
            random_state=random_state,
            n_jobs=-1,
            tree_method="hist",
        )

    if model_name == "neural_network":
        return Pipeline(
            steps=[
                ("scaler", StandardScaler()),
                (
                    "mlp",
                    MLPRegressor(
                        hidden_layer_sizes=(64, 32),
                        activation="relu",
                        alpha=0.001,
                        learning_rate_init=0.001,
                        max_iter=300,
                        early_stopping=True,
                        random_state=random_state,
                    ),
                ),
            ]
        )

    raise ValueError(f"Unsupported model: {model_name}")


def evaluate(name: str, model, X: pd.DataFrame, y: pd.Series) -> np.ndarray:
    pred = np.nan_to_num(model.predict(X), nan=0.0, posinf=0.0, neginf=0.0)
    corr = np.corrcoef(pred, y)[0, 1] if np.std(pred) > 0 and np.std(y) > 0 else np.nan

    print(f"\n{name}")
    print("Rows:", len(X))
    print("R2:", round(r2_score(y, pred), 6))
    print("MAE:", round(mean_absolute_error(y, pred), 8))
    print("Pred/Target corr:", round(float(corr), 6) if np.isfinite(corr) else corr)
    return pred


def evaluate_thresholds(pred_train: np.ndarray, pred_test: np.ndarray, y_test: pd.Series, cost: float) -> None:
    corr = np.corrcoef(pred_test, y_test)[0, 1] if np.std(pred_test) > 0 and np.std(y_test) > 0 else 0.0
    direction_factor = np.sign(corr) if corr != 0 else 1.0
    percentiles = np.arange(50, 100, 5)
    thresholds = np.percentile(np.abs(pred_train), percentiles)

    pred_matrix = np.tile(pred_test[:, None], (1, thresholds.size))
    threshold_matrix = thresholds[None, :]
    position = np.sign(pred_matrix) * direction_factor * (np.abs(pred_matrix) >= threshold_matrix)

    target_matrix = np.tile(y_test.values[:, None], (1, thresholds.size))
    strategy_ret = position * target_matrix - np.abs(position) * cost
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
    print(results.to_string(index=False, float_format="%.8f"))


def export_onnx(model_name: str, model, n_features: int, output_path: str) -> None:
    from skl2onnx.common.data_types import FloatTensorType

    initial_types = [("float_input", FloatTensorType([None, n_features]))]
    path = Path(output_path)

    if model_name in {"random_forest", "neural_network"}:
        from skl2onnx import convert_sklearn

        onnx_model = convert_sklearn(model, initial_types=initial_types)
    elif model_name == "lightgbm":
        try:
            from onnxmltools import convert_lightgbm
        except ImportError as exc:
            raise RuntimeError("Install onnxmltools first: pip install onnxmltools") from exc
        onnx_model = convert_lightgbm(model, initial_types=initial_types)
    elif model_name == "xgboost":
        try:
            from onnxmltools import convert_xgboost
        except ImportError as exc:
            raise RuntimeError("Install onnxmltools first: pip install onnxmltools") from exc
        onnx_model = convert_xgboost(model, initial_types=initial_types)
    else:
        raise ValueError(f"Unsupported model for ONNX export: {model_name}")

    path.write_bytes(onnx_model.SerializeToString())
    print(f"\nSaved ONNX model: {path.resolve()}")


def main() -> None:
    if MODEL_NAME not in {"random_forest", "lightgbm", "xgboost", "neural_network"}:
        raise ValueError(f"Unsupported MODEL_NAME: {MODEL_NAME}")
    if TIMEFRAME not in TIMEFRAMES:
        raise ValueError(f"Unsupported TIMEFRAME: {TIMEFRAME}")

    print(f"Loading {SYMBOL} {TIMEFRAME} from {FROM_YEAR}...")
    rates_frame = load_rates(SYMBOL, TIMEFRAME, FROM_YEAR, MT5_PATH)
    print(f"Loaded bars: {len(rates_frame)}")

    X, y, features = build_features(rates_frame, TARGET_BARS)
    print(f"Feature rows: {len(X)}")
    print(f"Features: {len(features)}")
    print("Feature order for EA input:")
    for idx, col in enumerate(features):
        print(f"  f{idx}: {col}")

    X_model = rename_features_for_onnx(X)

    X_train, X_valid, X_test, y_train, y_valid, y_test = split_time_series(
        X_model, y, TRAIN_RATIO, VALID_RATIO
    )

    model = create_model(MODEL_NAME)
    print(f"\nTraining model: {MODEL_NAME}")
    model.fit(X_train, y_train)

    pred_train = evaluate("Train", model, X_train, y_train)
    evaluate("Validation", model, X_valid, y_valid)
    pred_test = evaluate("Test", model, X_test, y_test)
    evaluate_thresholds(pred_train, pred_test, y_test, TRADE_COST)

    if EXPORT_ONNX:
        try:
            export_onnx(MODEL_NAME, model, X_train.shape[1], ONNX_PATH)
        except Exception as exc:
            print(f"\nONNX export skipped/failed: {exc}")


if __name__ == "__main__":
    main()
