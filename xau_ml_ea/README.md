# XAU ML EA

Project ini adalah pipeline awal untuk membuat EA MetaTrader 5 berbasis machine learning/ONNX untuk XAUUSD.

Tujuan utamanya:

1. Ambil dan cache data market dari broker/MT5 supaya eksperimen model tidak perlu download ulang terus.
2. Training model dari data multi-timeframe, lalu export ke ONNX.
3. Jalankan model ONNX di EA MT5 untuk mengambil keputusan trading.

## Konsep Trading

EA mengevaluasi peluang setiap candle M5 close. M5 dipakai sebagai entry timeframe, sedangkan timeframe yang lebih besar dipakai sebagai konteks supaya keputusan tidak hanya melihat noise timeframe kecil.

Timeframe yang dipakai:

```text
M5  = entry/evaluasi utama
M15 = konteks mikro
H1  = konteks intraday
H4  = konteks trend besar
D1  = konteks regime harian
```

Target model saat ini:

```text
next 6 candle M5
```

Artinya model belajar memprediksi total pergerakan harga kira-kira 30 menit ke depan.

## File

### 01_download_data.py

Mengambil data XAUUSD dari MT5 untuk timeframe:

```text
M5, M15, H1, H4, D1
```

Hasilnya disimpan ke folder lokal:

```text
xau_ml_ea/data/
```

Contoh file hasil download:

```text
data/XAUUSD_M5.csv
data/XAUUSD_M15.csv
data/XAUUSD_H1.csv
data/XAUUSD_H4.csv
data/XAUUSD_D1.csv
```

Folder `data/` masuk `.gitignore` karena isinya cache hasil download dan bisa besar/berubah setiap run.

### 02_train_model_onnx.py

Membaca CSV dari `data/`, membangun feature multi-timeframe, melakukan train/validation/test split berbasis urutan waktu, lalu export model ke:

```text
model_xau_ml.onnx
```

Model default:

```text
random_forest
```

Pilihan lain yang sudah disiapkan:

```text
xgboost
neural_network
```

File ini juga membuat `feature_order.txt` untuk mencatat urutan input model. File tersebut di-ignore karena merupakan artifact hasil training.

### 03_XAU_ML_ONNX_EA.mq5

EA MT5 yang menjalankan model ONNX.

EA melakukan:

1. Menunggu candle M5 baru.
2. Menghitung feature dari M5, M15, H1, H4, D1.
3. Menjalankan `model_xau_ml.onnx`.
4. Entry BUY/SELL hanya kalau prediksi melewati threshold.
5. Filter spread dengan `InpMaxSpreadPoints`.
6. Menggunakan magic number `InpMagic`.

## Feature Model

Ada 14 feature untuk setiap timeframe:

```text
last
last_3
last_11
range
body
atr_14
volume_ratio_20
close_sma_12
close_sma_48
sma_12_slope
rsi_14
macd_main
macd_signal
macd_sig_main
```

Karena ada 5 timeframe:

```text
14 x 5 = 70 feature
```

Ditambah 4 feature waktu:

```text
time_hour_sin
time_hour_cos
time_dow_sin
time_dow_cos
```

Total input model:

```text
74 feature
```

## Cara Pakai

Pastikan MT5 sudah terbuka dan login ke akun broker/demo. Untuk MetaQuotes demo, symbol default yang dipakai adalah:

```text
XAUUSD
```

Di MT5, sebaiknya lakukan:

1. Buka Market Watch.
2. Klik kanan, pilih Show All.
3. Pastikan `XAUUSD` tersedia.
4. Buka chart XAUUSD M5 agar terminal memuat history.

Lalu jalankan:

```powershell
python xau_ml_ea/01_download_data.py
python xau_ml_ea/02_train_model_onnx.py
```

Setelah training berhasil, gunakan file berikut di MT5:

```text
03_XAU_ML_ONNX_EA.mq5
model_xau_ml.onnx
```

## Artifact Yang Tidak Masuk Git

Yang sengaja di-ignore:

```text
xau_ml_ea/data/
xau_ml_ea/*.onnx
xau_ml_ea/feature_order.txt
```

Alasannya:

1. Data broker bisa besar dan berubah.
2. Model ONNX adalah hasil training lokal.
3. Cache dan artifact lebih baik dibuat ulang dari script.

## Catatan Penting

Training higher-timeframe dibuat memakai candle yang sudah close saja. Ini penting supaya backtest/training tidak bocor data masa depan.

Sebelum live trading, model harus diuji minimal dengan:

```text
backtest
forward test di demo
spread/slippage realistis
filter news
risk management
```

Project ini masih pondasi awal, bukan sistem trading final.
