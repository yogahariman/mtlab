# 02_02 — Next Candle Direction

Pipeline ini memakai informasi candle `t` untuk memprediksi candle `t+1`.
Posisi dibuka pada `Open[t+1]` dan ditutup pada `Close[t+1]`. Harga absolut tidak
masuk ke model; semua candle diubah menjadi rasio terhadap open dan ATR.

## Instalasi dan training

```bash
pip install pandas numpy scikit-learn xgboost skl2onnx onnxmltools onnx
python 02_02_train_next_candle.py \
  --csv data/XAUUSD_H4.csv --lookback 10 --threshold 0.60
```

Output berada di folder CSV:

- `*_next_candle_*.onnx`: model binary ONNX, input `features` float32.
- `*_feature_order.txt`: urutan fitur yang wajib sama saat dibangun EA.
- `*.meta`: jumlah fitur, threshold, mapping kelas, dan aturan entry/exit.
- `*_metrics.json`: accuracy, precision BUY, ROC-AUC, CV ROC-AUC, dan simulasi return.

`lookback=10` menghasilkan 100 input fitur (10 candle x 10 fitur). Jika
probabilitas BUY berada di atas threshold, BUY; jika probabilitas BUY di bawah
`1-threshold`, SELL; selain itu no-trade. Return backtest belum mengurangi
spread, komisi, swap, dan slippage, sehingga tambahkan biaya broker sebelum
menilai kelayakan strategi.

## Catatan MQL5

EA harus membangun candle tertutup terakhir sampai `lookback` candle dalam
urutan yang sama seperti `*_feature_order.txt`, mengirim array `float` ke
`OnnxRun`, lalu membaca probabilitas kelas 1 sebagai BUY. Jalankan inference
hanya sekali saat bar baru terdeteksi. Karena model hanya memakai candle yang
sudah close, jangan memasukkan candle berjalan. Copy `.onnx` dan `.meta` ke
Common\Files atau folder resource EA sesuai cara EA memanggil `OnnxCreate`.
