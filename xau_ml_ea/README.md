# XAU Stoch ML EA

Pipeline ini memisahkan peran seperti berikut:

1. `Stochastic` menjadi gate kandidat entry.
2. `ML` memutuskan apakah first entry valid lewat `predict_proba`.
3. EA menjalankan model ONNX untuk eksekusi trading.

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
