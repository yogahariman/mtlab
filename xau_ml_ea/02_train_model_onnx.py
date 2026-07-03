from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd
import ta

from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import (
    accuracy_score,
    average_precision_score,
    brier_score_loss,
    f1_score,
    log_loss,
    precision_score,
    recall_score,
    roc_auc_score,
)
from sklearn.neural_network import MLPClassifier
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler


BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
SYMBOL_FILE = "XAUUSD"
ENTRY_TIMEFRAME = "M1"
CONTEXT_TIMEFRAMES = ["M5"]
MODEL_NAME = "xgboost"  # random_forest, xgboost, neural_network
ONNX_PATH = BASE_DIR / "model_xau_stoch_ml.onnx"
FEATURES_PATH = BASE_DIR / "feature_order.txt"

TARGET_BARS = 6
TP_ATR_MULT = 1.25
SL_ATR_MULT = 0.90
OVERSOLD = 20.0
OVERBOUGHT = 80.0
TRAIN_RATIO = 0.70
VALID_RATIO = 0.15
TRADE_COST = 0.0
RANDOM_STATE = 42

TIMEFRAME_MINUTES = {
    "M1": 1,
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


def shift_to_close_time(df: pd.DataFrame, timeframe: str) -> pd.DataFrame:
    shifted = df.copy()
    shifted.index = shifted.index + pd.to_timedelta(TIMEFRAME_MINUTES[timeframe], unit="m")
    return shifted


def build_common_features(rates: pd.DataFrame, timeframe: str) -> pd.DataFrame:
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
    data[f"{prefix}_atr_14"] = ta.volatility.average_true_range(high, low, close, window=14, fillna=False)
    data[f"{prefix}_volume_ratio_20"] = tick_volume / tick_volume.rolling(20).mean()

    sma_12 = ta.trend.sma_indicator(close, window=12, fillna=False)
    sma_48 = ta.trend.sma_indicator(close, window=48, fillna=False)
    data[f"{prefix}_close_sma_12"] = close - sma_12
    data[f"{prefix}_close_sma_48"] = close - sma_48
    data[f"{prefix}_sma_12_slope"] = sma_12.diff()
    data[f"{prefix}_rsi_14"] = ta.momentum.rsi(close, window=14, fillna=False)

    macd = ta.trend.MACD(close, window_fast=12, window_slow=24, window_sign=9, fillna=False)
    macd_main = macd.macd()
    macd_signal = macd.macd_signal()
    data[f"{prefix}_macd_main"] = macd_main
    data[f"{prefix}_macd_signal"] = macd_signal
    data[f"{prefix}_macd_sig_main"] = macd_signal - macd_main

    return shift_to_close_time(data, timeframe)


def simulate_candidate_success(
    rates: pd.DataFrame,
    signal_index: int,
    direction: float,
    entry_price: float,
    tp_distance: float,
    sl_distance: float,
    target_bars: int,
) -> float:
    last_index = min(signal_index + target_bars, len(rates) - 1)
    for idx in range(signal_index + 1, last_index + 1):
        bar_open = float(rates["open"].iloc[idx])
        bar_high = float(rates["high"].iloc[idx])
        bar_low = float(rates["low"].iloc[idx])

        if direction > 0:
            tp_hit = bar_open >= entry_price + tp_distance or bar_high >= entry_price + tp_distance
            sl_hit = bar_open <= entry_price - sl_distance or bar_low <= entry_price - sl_distance
        else:
            tp_hit = bar_open <= entry_price - tp_distance or bar_low <= entry_price - tp_distance
            sl_hit = bar_open >= entry_price + sl_distance or bar_high >= entry_price + sl_distance

        if tp_hit and sl_hit:
            return 0.0
        if sl_hit:
            return 0.0
        if tp_hit:
            return 1.0

    return 0.0


def build_entry_dataset(entry_rates: pd.DataFrame) -> pd.DataFrame:
    base = build_common_features(entry_rates, ENTRY_TIMEFRAME)
    delta = pd.to_timedelta(TIMEFRAME_MINUTES[ENTRY_TIMEFRAME], unit="m")

    high = entry_rates["high"].astype(float)
    low = entry_rates["low"].astype(float)
    close = entry_rates["close"].astype(float)

    stoch = ta.momentum.StochasticOscillator(
        high=high,
        low=low,
        close=close,
        window=14,
        smooth_window=3,
        fillna=False,
    )
    stoch_k = stoch.stoch()
    stoch_d = stoch.stoch_signal()
    prefix = ENTRY_TIMEFRAME.lower()
    stoch_df = pd.DataFrame(
        {
            f"{prefix}_stoch_k": stoch_k,
            f"{prefix}_stoch_d": stoch_d,
            f"{prefix}_stoch_k_minus_d": stoch_k - stoch_d,
            f"{prefix}_stoch_distance_from_20": stoch_k - OVERSOLD,
            f"{prefix}_stoch_distance_from_80": stoch_k - OVERBOUGHT,
        },
        index=entry_rates.index,
    )
    stoch_df.index = stoch_df.index + delta

    direction = pd.Series(np.nan, index=entry_rates.index, dtype=float)
    direction[stoch_k < OVERSOLD] = 1.0
    direction[stoch_k > OVERBOUGHT] = -1.0
    direction.index = direction.index + delta
    direction.name = f"{prefix}_candidate_direction"

    target = pd.Series(np.nan, index=entry_rates.index, dtype=float)
    target.index = target.index + delta
    atr = base[f"{prefix}_atr_14"].reset_index(drop=True)

    for i in range(len(entry_rates) - TARGET_BARS):
        direction_i = direction.iloc[i]
        if not np.isfinite(direction_i) or direction_i == 0:
            continue

        atr_i = float(atr.iloc[i])
        if not np.isfinite(atr_i) or atr_i <= 0:
            continue

        entry_price = float(close.iloc[i])
        tp_distance = atr_i * TP_ATR_MULT
        sl_distance = atr_i * SL_ATR_MULT
        target.iloc[i] = simulate_candidate_success(
            entry_rates,
            i,
            direction_i,
            entry_price,
            tp_distance,
            sl_distance,
            TARGET_BARS,
        )

    entry = base.join(stoch_df)
    entry[f"{prefix}_candidate_direction"] = direction
    entry["target"] = target
    return entry


def build_dataset() -> tuple[pd.DataFrame, pd.Series, list[str]]:
    entry_rates = load_cached_rates(ENTRY_TIMEFRAME)
    entry = build_entry_dataset(entry_rates)

    X = entry.drop(columns=["target"]).sort_index()
    y = entry["target"].sort_index()

    for timeframe in CONTEXT_TIMEFRAMES:
        context_rates = load_cached_rates(timeframe)
        context_features = build_common_features(context_rates, timeframe)
        X = pd.merge_asof(
            X.sort_index(),
            context_features.sort_index(),
            left_index=True,
            right_index=True,
            direction="backward",
        )

    hours = pd.Series(X.index.hour, index=X.index, dtype=float)
    days = pd.Series((X.index.dayofweek + 1) % 7, index=X.index, dtype=float)
    X["time_hour_sin"] = np.sin(2 * np.pi * hours / 24)
    X["time_hour_cos"] = np.cos(2 * np.pi * hours / 24)
    X["time_dow_sin"] = np.sin(2 * np.pi * days / 7)
    X["time_dow_cos"] = np.cos(2 * np.pi * days / 7)

    dataset = X.join(y.rename("target"))
    dataset = dataset.replace([np.inf, -np.inf], np.nan).dropna()

    features = [c for c in dataset.columns if c != "target"]
    return dataset[features], dataset["target"], features


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
        return RandomForestClassifier(
            n_estimators=400,
            max_depth=12,
            max_leaf_nodes=220,
            min_samples_split=6,
            min_samples_leaf=3,
            bootstrap=True,
            class_weight="balanced_subsample",
            random_state=RANDOM_STATE,
            n_jobs=-1,
        )

    if name == "xgboost":
        from xgboost import XGBClassifier

        return XGBClassifier(
            n_estimators=800,
            learning_rate=0.02,
            max_depth=5,
            min_child_weight=20,
            subsample=0.8,
            colsample_bytree=0.8,
            objective="binary:logistic",
            random_state=RANDOM_STATE,
            n_jobs=-1,
            tree_method="hist",
            eval_metric="logloss",
        )

    if name == "neural_network":
        return Pipeline(
            [
                ("scaler", StandardScaler()),
                (
                    "mlp",
                    MLPClassifier(
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
    proba = np.nan_to_num(model.predict_proba(X)[:, 1], nan=0.0, posinf=0.0, neginf=0.0)
    pred = (proba >= 0.5).astype(int)
    print(f"\n{label}")
    print("Rows:", len(X))
    print("Accuracy:", round(accuracy_score(y, pred), 6))
    print("Precision:", round(precision_score(y, pred, zero_division=0), 6))
    print("Recall:", round(recall_score(y, pred, zero_division=0), 6))
    print("F1:", round(f1_score(y, pred, zero_division=0), 6))
    print("ROC AUC:", round(roc_auc_score(y, proba), 6) if len(np.unique(y)) > 1 else "nan")
    print("PR AUC:", round(average_precision_score(y, proba), 6) if len(np.unique(y)) > 1 else "nan")
    print("Brier:", round(brier_score_loss(y, proba), 6))
    if len(np.unique(y)) > 1:
        print("LogLoss:", round(log_loss(y, np.vstack([1 - proba, proba]).T, labels=[0, 1]), 6))
    else:
        print("LogLoss: nan")
    return proba


def evaluate_thresholds(pred_train: np.ndarray, pred_test: np.ndarray, y_test: pd.Series) -> None:
    percentiles = np.arange(50, 100, 5)
    thresholds = np.percentile(pred_train, percentiles)

    pred_matrix = np.tile(pred_test[:, None], (1, thresholds.size))
    position = (pred_matrix >= thresholds[None, :]).astype(float)
    target_matrix = np.tile(y_test.values[:, None], (1, thresholds.size))
    trade_outcome = np.where(target_matrix > 0, 1.0, -1.0)
    strategy_ret = position * trade_outcome - np.abs(position) * TRADE_COST

    trades = np.sum(position != 0, axis=0)
    wins = np.sum((position != 0) & (target_matrix > 0), axis=0)
    losses = np.sum((position != 0) & (target_matrix <= 0), axis=0)
    gains = wins

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
    from skl2onnx import convert_sklearn

    initial_types = [("float_input", FloatTensorType([None, n_features]))]
    onnx_model = convert_sklearn(
        model,
        initial_types=initial_types,
        options={id(model): {"zipmap": False}},
    )

    try:
        import onnx
        from onnx import TensorProto, helper, numpy_helper
    except ImportError as exc:
        raise RuntimeError(
            "Package onnx is required to rewrite classifier output into a single probability tensor."
        ) from exc

    graph = onnx_model.graph
    probability_output = None
    for output in graph.output:
        if "label" not in output.name.lower():
            probability_output = output.name
            break
    if probability_output is None:
        raise RuntimeError("Unable to locate classifier probability output in ONNX graph.")

    positive_probability_name = "positive_class_probability"
    class_index_name = "positive_class_index"
    class_index_tensor = numpy_helper.from_array(np.array([1], dtype=np.int64), name=class_index_name)
    graph.initializer.append(class_index_tensor)
    graph.node.append(
        helper.make_node(
            "Gather",
            inputs=[probability_output, class_index_name],
            outputs=[positive_probability_name],
            axis=1,
        )
    )

    del graph.output[:]
    graph.output.extend(
        [helper.make_tensor_value_info(positive_probability_name, TensorProto.FLOAT, [None, 1])]
    )

    output_path.write_bytes(onnx_model.SerializeToString())
    print(f"\nSaved ONNX model: {output_path}")


def save_feature_order(features: list[str]) -> None:
    FEATURES_PATH.write_text("\n".join(features) + "\n", encoding="utf-8")
    print(f"Saved feature order: {FEATURES_PATH}")


def main() -> None:
    if MODEL_NAME not in {"random_forest", "xgboost", "neural_network"}:
        raise ValueError(f"Unsupported MODEL_NAME: {MODEL_NAME}")

    print(f"Loading data for {SYMBOL_FILE}...")
    X, y, features = build_dataset()
    print(f"Dataset rows: {len(X)}")
    print(f"Feature count: {len(features)}")
    print(f"Positive label rate: {y.mean():.6f}")
    print("Feature order for EA input:")
    for idx, col in enumerate(features):
        print(f"  f{idx}: {col}")

    save_feature_order(features)

    X_train, X_valid, X_test, y_train, y_valid, y_test = split_time_series(X, y)

    model = create_model(MODEL_NAME)
    print(f"\nTraining model: {MODEL_NAME}")
    model.fit(X_train, y_train)

    pred_train = evaluate("Train", model, X_train, y_train)
    evaluate("Validation", model, X_valid, y_valid)
    pred_test = evaluate("Test", model, X_test, y_test)
    evaluate_thresholds(pred_train, pred_test, y_test)

    try:
        export_onnx(MODEL_NAME, model, X_train.shape[1], ONNX_PATH)
    except Exception as exc:
        print(f"\nONNX export skipped/failed: {exc}")


if __name__ == "__main__":
    main()
