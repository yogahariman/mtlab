from datetime import datetime
# import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import pytz
import ta
import seaborn as sns
import matplotlib.pyplot as plt

from sklearn.ensemble import RandomForestRegressor
from sklearn.metrics import mean_absolute_error, r2_score


from mt5linux import MetaTrader5
import os

# Gunakan path lengkap ke terminal64.exe kamu
mt5_path = "/home/rfi212/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe"

mt5 = MetaTrader5()

# Coba inisialisasi dengan path manual
if not mt5.initialize(path=mt5_path):
    print("Inisialisasi Gagal!")
    print("Error code:", mt5.last_error())
else:
    print("Koneksi Berhasil!")
    print(mt5.terminal_info())


# Display data on the MetaTrader 5 package
# print("MetaTrader5 package author: ", mt5.__author__)
# print("MetaTrader5 package version: ", mt5.__version__)
# Cek informasi versi Terminal MT5 yang sedang berjalan (di Wine)
terminal_info = mt5.terminal_info()
if terminal_info is not None:
    print("MetaTrader 5 Build: ", terminal_info.build)
    print("Broker: ", terminal_info.company)
else:
    print("Gagal mengambil info terminal. Pastikan mt5.initialize() sudah dipanggil.")

# Connection to MetaTrader 5 terminal
if not mt5.initialize():
    print("initialize() failed, error code =", mt5.last_error())
    quit()

# Set time zone to UTC
timezone = pytz.timezone("Etc/UTC")
# Create datetime objects in UTC to ensure consistent timezone handling
utc_from = datetime(2025, 1, 1, tzinfo=timezone)
utc_to = datetime.now(timezone)  # Current date and time in UTC

# Get bars from XAUUSD H1 (hourly timeframe) within the specified interval
rates = mt5.copy_rates_range("XAUUSD.vx", mt5.TIMEFRAME_H1, utc_from, utc_to)

# Shut down connection to the MetaTrader 5 terminal
mt5.shutdown()

# Check if data was retrieved
if rates is None or len(rates) == 0:
    print("No data retrieved. Please check the symbol or date range.")
    quit()

# Create a DataFrame from the obtained tick data
rates_frame = pd.DataFrame(rates)
# Convert the timestamp column from seconds to datetime
rates_frame['time'] = pd.to_datetime(rates_frame['time'], unit='s')

# Use the datetime column as the DataFrame index for easier slicing and plotting
rates_frame.set_index('time', inplace=True)

macd_settings = [(8,16,6),(12,24,9),(36,72,27),(48,96,36)]
features = []

# Build the base feature matrix from close price changes
close = pd.DataFrame(rates_frame['close'][:-1].to_numpy(dtype=float), columns=['close'])
diff = rates_frame['close'].diff().to_numpy(dtype=float)
# Pair consecutive differences into 'last' and 'next' columns
diff = np.column_stack((diff[:-1], diff[1:]))
data_matrix = pd.DataFrame(diff, columns=['last', 'next'])
features.append('last') # Add to features list for later use
# Add a 11-period rolling mean of the previous bar move
data_matrix['last_11'] = data_matrix['last'].rolling(window=11).mean()
features.append('last_11') # Add to features list for later use 
# Add the difference between the rolling mean and current bar move
data_matrix['last_last_11'] = data_matrix['last_11'] - data_matrix['last']
features.append('last_last_11') # Add to features list for later use
# Add a 9-period future return target for the next bars
data_matrix['next_9'] = data_matrix['next'].rolling(window=9).sum().shift(-8)
# Add a 12-period simple moving average as a technical feature
data_matrix['SMA_12'] = ta.trend.sma_indicator(close['close'], window=12, fillna=True)
features.append('SMA_12') # Add to features list for later use

# Add MACD-based technical indicators for the selected parameter sets
for fast, slow, sign in macd_settings:
    macd = ta.trend.MACD(
        close['close'],
        window_slow=slow,
        window_fast=fast,
        window_sign=sign,
        fillna=True,
    )
    macd_main = macd.macd()
    dmacd = macd_main.diff()
    macd_signal = macd.macd_signal()
    dmacd_signal = macd_signal.diff()
    macd_sig_main = macd_signal - macd_main

    sufix = f"{fast:02d},{slow:02d},{sign:02d}"
    data_matrix[f'MACD_MAIN_{sufix}'] = macd_main
    features.append(f'MACD_MAIN_{sufix}') # Add to features list for later use
    data_matrix[f'DMACD_MAIN_{sufix}'] = dmacd
    features.append(f'DMACD_MAIN_{sufix}') # Add to features list for later use     
    data_matrix[f'MACD_SIGNAL_{sufix}'] = macd_signal
    features.append(f'MACD_SIGNAL_{sufix}') # Add to features list for later use
    data_matrix[f'DMACD_SIGNAL_{sufix}'] = dmacd_signal
    features.append(f'DMACD_SIGNAL_{sufix}') # Add to features list for later use
    data_matrix[f'MACD_Sig_Main_{sufix}'] = macd_sig_main
    features.append(f'MACD_Sig_Main_{sufix}') # Add to features list for later use
    data_matrix[f'DMACD_Sig_Main_{sufix}'] = macd_sig_main.diff()
    features.append(f'DMACD_Sig_Main_{sufix}') # Add to features list for later use

data_matrix.dropna(inplace=True)

# ===== 1) Data preparation =====
# Copy the raw feature matrix (preserves original data for later reference)
df = data_matrix.copy()

# Keep only features that are actually present in the DataFrame
features = [c for c in features if c in data_matrix.columns]

df = df[features + ["next_9"]]
X = df[features]
y = df["next_9"]

# ===== 2) Time-based split =====
split_idx = int(len(X) * 0.9)

X_train = X.iloc[:split_idx]
X_test = X.iloc[split_idx:]
y_train = y.iloc[:split_idx]
y_test = y.iloc[split_idx:]

# ===== 3) Model =====
results = []
for est in range(90,111,1):
    for nodes in range(160,181,1):
        print(f"\n=== Estimators: {est}, Max Nodes: {nodes} ===")
        model = RandomForestRegressor(
            n_estimators=est,
            max_depth=10,
            max_leaf_nodes=nodes,
            min_samples_split=6,
            min_samples_leaf=3,
            bootstrap=True,
            random_state=42,
            n_jobs=-1
            )

        model.fit(X_train, y_train)

        # ===== 4) Evaluation =====
        pred_train=np.nan_to_num(model.predict(X_train), nan=0.0, posinf=0.0, neginf=0.0)
        pred_test = np.nan_to_num(model.predict(X_test), nan=0.0, posinf=0.0, neginf=0.0)
        
        pt_corr = np.corrcoef(pred_test, y_test)[0, 1]
        results.append((est, nodes, pt_corr))
        print("Train R2:", round(r2_score(y_train, pred_train), 6))
        print("Test  R2:", round(r2_score(y_test, pred_test), 6))
        print("Test MAE:", round(mean_absolute_error(y_test, pred_test), 8))
        print("Pred/Target corr:", round(pt_corr, 6))


# --- results -> DataFrame ---
df_results = pd.DataFrame(
    results,
    columns=["Estimators", "Max Nodes", "Test Correlation"]
)

# --- pivot table ---
heatmap_data = df_results.pivot(
    index="Estimators",
    columns="Max Nodes",
    values="Test Correlation"
).sort_index()

# --- heatmap ---
plt.figure(figsize=(14, 10))
sns.heatmap(
    heatmap_data,
    annot=True,
    fmt=".4f",
    cmap="coolwarm",
    linewidths=0.5,
    cbar_kws={"label": "Test Correlation"}
)

plt.title("Heatmap of Test Correlation by n_estimators and max_leaf_nodes")
plt.xlabel("Max Nodes")
plt.ylabel("Estimators")
plt.tight_layout()
plt.show()

# --- optional: print table ---
print(heatmap_data.to_string())
