# XAU ML EA

## File

- `01_download_data.py` - download data OHLCV dari MT5 ke `data/`
- `02_train_model_onnx.py` - bangun fitur, train model, export `model_xau_stoch_ml.onnx`
- `03_XAU_ML_ONNX_EA.mq5` - EA MT5 untuk inference ONNX
- `EA_ML.md` - dokumen konsep

## Urutan Jalan

```bash
python xau_ml_ea/01_download_data.py
python xau_ml_ea/02_train_model_onnx.py
```

## Menjalankan Downloader dengan Wine

Downloader dijalankan menggunakan Python Windows di dalam Wine dan package
native `MetaTrader5`. Docker dan `mt5linux` tidak diperlukan.

### 1. Install dependency

```bash
wine python.exe -m pip install MetaTrader5 pandas pytz
```

### 2. Jalankan MetaTrader 5

```bash
wine "/home/rfi212/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe"
```

Login ke akun demo dan pastikan simbol `XAUUSD` tersedia di Market Watch.
Di `01_download_data.py`, gunakan:

```python
MT5_PATH = None
```

### 3. Jalankan downloader

Buka Wine CMD:

```bash
wine cmd
```

Lalu jalankan:

```cmd
cd Z:\Drive\D\mtlab\xau_ml_ea
python 01_download_data.py
```

Script secara default mengunduh timeframe `M5` dan `H1`, membuang candle yang
masih berjalan, lalu menyimpan hasilnya ke folder `data/`:

```text
data/XAUUSD_M5.csv
data/XAUUSD_H1.csv
```

Jika muncul `IPC initialize failed`, pastikan terminal MT5 sudah berjalan dan
`MT5_PATH = None`. Jika ingin menjalankan terminal secara otomatis, isi path
`terminal64.exe` sesuai lokasi instalasi MT5 di Wine.

Pastikan environment Python Anda punya minimal:

```bash
pip install pandas numpy ta scikit-learn skl2onnx onnx
```

Kalau memilih `MODEL_NAME = "xgboost"`, tambahkan juga:

```bash
pip install xgboost
```

Lalu:

1. copy `model_xau_stoch_ml.onnx` ke resource folder EA jika diperlukan oleh build MT5 Anda
2. compile `03_XAU_ML_ONNX_EA.mq5`
3. attach EA ke chart XAUUSD M1

## Data Sementara

Untuk sementara pipeline hanya download:

1. `M1`
2. `M5`

## Ringkas Logika

- Jika `%K < 20`, EA mencari BUY candidate
- Jika `%K > 80`, EA mencari SELL candidate
- Kandidat itu hanya dieksekusi jika probability ML melewati threshold
