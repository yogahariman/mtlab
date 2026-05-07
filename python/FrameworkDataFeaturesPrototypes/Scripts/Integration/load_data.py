# wine python -m pip install MetaTrader5 rpyc mt5linux
# pip install mt5linux rpyc

from datetime import datetime
# import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import pytz
import seaborn as sns
import matplotlib.pyplot as plt
import ta

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
# Create 'datetime' objects in UTC time zone to avoid the implementation of a local time zone offset
utc_from = datetime(2020, 1, 1, tzinfo=timezone)
utc_to = datetime.now(timezone)  # Set to the current date and time

# Get bars from XAUUSD H1 (hourly timeframe) within the specified interval
rates = mt5.copy_rates_range("XAUUSD.vx", mt5.TIMEFRAME_H1, utc_from, utc_to)

# Shut down connection to the MetaTrader 5 terminal
mt5.shutdown()

# Check if data was retrieved
if rates is None or len(rates) == 0:
    print("No data retrieved. Please check the symbol or date range.")
    quit()
# Print the first 10 raw records for a quick data sanity check
print("Display obtained data 'as is'")
for rate in rates[:10]:
    print(rate)

# Create a DataFrame from the retrieved tick data
rates_frame = pd.DataFrame(rates)
# Convert the timestamp column from seconds since epoch to datetime
rates_frame['time'] = pd.to_datetime(rates_frame['time'], unit='s')

# Use datetime as the DataFrame index for time series plotting and analysis
rates_frame.set_index('time', inplace=True)

# Plot closing price and tick volume
fig, ax1 = plt.subplots(figsize=(12, 6))

# Close price on primary y-axis
ax1.set_xlabel('Date')
ax1.set_ylabel('Close Price', color='tab:blue')
ax1.plot(rates_frame.index, rates_frame['close'], color='tab:blue', label='Close Price')
ax1.tick_params(axis='y', labelcolor='tab:blue')

# Tick volume on secondary y-axis
ax2 = ax1.twinx()  
ax2.set_ylabel('Tick Volume', color='tab:green')
max_tick = rates_frame['tick_volume'].max()
ax2.set_ylim(0, max_tick * 5)
ax2.plot(rates_frame.index, rates_frame['tick_volume'], color='tab:green', label='Tick Volume')
ax2.tick_params(axis='y', labelcolor='tab:green')

# Show the plot
plt.title('Close Price and Tick Volume Over Time')
fig.tight_layout()
plt.show()
fig.savefig('close_price.png')

# Correlation analysis between adjacent bar moves
close = rates_frame['close'].to_numpy(dtype=float)
# last and next price move differences
diff = close[1:] - close[:-1]
diff = np.column_stack((diff[:-1], diff[1:]))
data_matrix = pd.DataFrame(diff, columns=['last', 'next'])
correlation_matrix = data_matrix.corr('pearson')
plt.subplots(figsize=(3, 2))
sns.heatmap(correlation_matrix, annot=True, cmap='coolwarm')
plt.title('Correlation Bar to Bar') 
plt.savefig('bar_to_bar.png')
plt.show()

# Add rolling mean features for the previous and future moves
for period in range(2, 24, 1):
    data_matrix[f'last_mean_{period:02d}'] = data_matrix['last'].rolling(window=period).mean()
for period in range(2, 10, 1):
    data_matrix[f'next_mean_{period}'] = data_matrix['next'].rolling(window=period).mean().shift(-(period-1))

# Remove rows with missing values created by rolling calculations
data_matrix.dropna(inplace=True)
correlation_matrix = data_matrix.corr('pearson')
# Match columns that begin with "next"
reg = r'^next.*$'
selected_cols = correlation_matrix.filter(regex=reg).columns
remaining_rows = correlation_matrix.index.difference(selected_cols)
correlation_matrix = correlation_matrix.loc[remaining_rows, selected_cols]
plt.figure(figsize=(12, 7))
plt.subplots_adjust(left=0.15, right=1, bottom=0.16, top=0.95)
sns.heatmap(correlation_matrix, annot=True, cmap='coolwarm')
plt.title('Correlation Means Last to Next Bars') 
plt.savefig('mean_to_bar.png')
plt.show()

# Recreate the base matrix for indicator engineering
data_matrix = pd.DataFrame(diff, columns=['last', 'next'])
# Add 11-period previous move averages and derived momentum features
data_matrix[f'last_mean_11'] = data_matrix['last'].rolling(window=11).mean()
data_matrix[f'Dlast_mean_11'] = data_matrix[f'last_mean_11'].diff()
data_matrix[f'DDlast_mean_11'] = data_matrix[f'Dlast_mean_11'].diff()
# Feature representing the gap between the rolling mean and the current move
data_matrix[f'last_last_11'] = data_matrix[f'last_mean_11'] - data_matrix['last']
data_matrix[f'Dlast_last_11'] = data_matrix[f'last_last_11'].diff()
data_matrix[f'DDlast_last_11'] = data_matrix[f'Dlast_last_11'].diff()
# Add short-term future sum targets for the next bars
for period in range(2, 10, 1):
    data_matrix[f'next_{period}'] = data_matrix['next'].rolling(window=period).sum().shift(-(period-1))

# Build additional technical indicators using the close price series
close = pd.DataFrame(close[:-1], columns=['close'])
indicator_cols = {}
for period in [4, 8, 12, 24, 36, 48]:
    sma = ta.trend.sma_indicator(close['close'], window=period, fillna=True)
    dsma = sma.diff()
    ddsma = dsma.diff()
    rsi = ta.momentum.rsi(close['close'], window=period, fillna=True)
    drsi = rsi.diff()
    ddrsi = drsi.diff()
    macd = ta.trend.MACD(
        close['close'],
        window_slow=2 * period,
        window_fast=period,
        window_sign=period * 3 // 4,
        fillna=True,
    )
    macd_main = macd.macd()
    dmacd = macd_main.diff()
    ddmacd = dmacd.diff()
    macd_diff = macd.macd_diff()
    dmacd_diff = macd_diff.diff()
    ddmacd_diff = dmacd_diff.diff()
    macd_signal = macd.macd_signal()
    dmacd_signal = macd_signal.diff()
    ddmacd_signal = dmacd_signal.diff()
    macd_sig_main = macd_signal - macd_main
    dmacd_sig_main = macd_sig_main.diff()
    ddmacd_sig_main = dmacd_sig_main.diff()

    indicator_cols[f'SMA_{period:02d}'] = sma
    indicator_cols[f'DSMA_{period:02d}'] = dsma
    indicator_cols[f'DDSMA_{period:02d}'] = ddsma
    indicator_cols[f'RSI_{period:02d}'] = rsi
    indicator_cols[f'DRSI_{period:02d}'] = drsi
    indicator_cols[f'DDRSI_{period:02d}'] = ddrsi
    indicator_cols[f'MACD_{period:02d},{2*period:02d},{period*3//4:02d}'] = macd_main
    indicator_cols[f'DMACD_{period:02d},{2*period:02d},{period*3//4:02d}'] = dmacd
    indicator_cols[f'DDMACD_{period:02d},{2*period:02d},{period*3//4:02d}'] = ddmacd
    indicator_cols[f'MACD_DIFF_{period:02d},{2*period:02d},{period*3//4:02d}'] = macd_diff
    indicator_cols[f'DMACD_DIFF_{period:02d},{2*period:02d},{period*3//4:02d}'] = dmacd_diff
    indicator_cols[f'DDMACD_DIFF_{period:02d},{2*period:02d},{period*3//4:02d}'] = ddmacd_diff
    indicator_cols[f'MACD_SIGNAL_{period:02d},{2*period:02d},{period*3//4:02d}'] = macd_signal
    indicator_cols[f'DMACD_SIGNAL_{period:02d},{2*period:02d},{period*3//4:02d}'] = dmacd_signal
    indicator_cols[f'DDMACD_SIGNAL_{period:02d},{2*period:02d},{period*3//4:02d}'] = ddmacd_signal
    indicator_cols[f'MACD_Sig_Main{period:02d},{2*period:02d},{period*3//4:02d}'] = macd_sig_main
    indicator_cols[f'DMACD_Sig_Main{period:02d},{2*period:02d},{period*3//4:02d}'] = dmacd_sig_main
    indicator_cols[f'DDMACD_Sig_Main{period:02d},{2*period:02d},{period*3//4:02d}'] = ddmacd_sig_main

# Append all indicator columns to the feature matrix in one operation
# This avoids repeated DataFrame assignment and keeps the DataFrame compact
data_matrix = pd.concat([data_matrix, pd.DataFrame(indicator_cols)], axis=1)
# Remove any rows with NaN values created by indicator calculations
data_matrix.dropna(inplace=True)
correlation_matrix = data_matrix.corr('pearson')
selected_cols = correlation_matrix.filter(regex=reg).columns
remaining_rows = correlation_matrix.index.difference(selected_cols)
correlation_matrix = correlation_matrix.loc[remaining_rows, selected_cols]
# Delete rows with low correlations
correlation_matrix = correlation_matrix[correlation_matrix.abs().max(axis=1) >= 0.02]
plt.figure(figsize=(12, 7))
plt.subplots_adjust(left=0.2, right=1, bottom=0.05, top=0.95)
sns.heatmap(correlation_matrix, annot=True, cmap='coolwarm')
plt.title('Correlation Indicators to Next Bars') 
plt.savefig('trend_to_bar.png')
plt.show()