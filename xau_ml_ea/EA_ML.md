# XAU Stoch ML EA

Konsep ini adalah pengembangan dari `XAU_StochTrend`, tetapi keputusan entry pertama tidak lagi diambil langsung oleh stochastic.

Di versi ini:

1. `Stochastic` hanya berfungsi sebagai **gate** atau pemicu area kandidat entry.
2. `ML` berfungsi sebagai **validator** untuk memutuskan apakah first entry layak diambil.
3. Setelah first entry valid, pengelolaan posisi lanjut mengikuti struktur EA yang sudah ada, misalnya grid/martingale bila memang dipakai.

## Inti Konsep

Saat `%K` stochastic berada di:

```text
> 80  -> area overbought, kandidat SELL
< 20  -> area oversold, kandidat BUY
```

EA tidak langsung entry hanya karena stochastic sudah masuk area ekstrem.

Yang terjadi adalah:

1. EA membaca bahwa market sudah masuk area perhatian.
2. EA mengumpulkan fitur market saat itu.
3. Model ML menilai apakah kondisi tersebut valid untuk first entry.
4. Jika valid, EA open posisi pertama.
5. Jika tidak valid, EA menunggu kesempatan berikutnya selama stochastic masih berada di area ekstrem.

Jadi alurnya bukan:

```text
stochastic -> open posisi
```

melainkan:

```text
stochastic -> kandidat setup -> ML validation -> first entry
```

## Peran Masing-masing Komponen

### Stochastic

Fungsi stochastic di sini sederhana:

1. Menentukan apakah market sedang berada dalam area overbought atau oversold.
2. Mengurangi jumlah momen yang perlu dianalisis ML.
3. Menjaga agar ML tidak bekerja di semua kondisi market.

Dengan cara ini, ML tidak dipakai untuk “mencari entry dari nol”, tetapi hanya saat market sudah masuk zona yang relevan.

### ML

Fungsi ML adalah menentukan apakah momen stochastic tersebut benar-benar layak untuk open posisi pertama.

ML bisa belajar membedakan kondisi seperti:

1. Overbought yang hanya retracement kecil dan tidak layak sell.
2. Overbought yang memang berpotensi jadi reversal atau continuation sell.
3. Oversold yang masih lemah dan sebaiknya belum buy.
4. Oversold yang sudah cukup kuat untuk first entry buy.

## Pipeline Yang Diinginkan

Langkah awal yang Anda sebutkan sangat cocok untuk dibuat sebagai pipeline terpisah:

1. **Script Python untuk download data**
2. **Training ML dan simpan ke ONNX**
3. **Script EA untuk menjalankan ONNX**

## Rencana File

### 1. Script Download Data

Tugas script ini:

1. Mengambil data OHLCV dari MT5.
2. Menyimpan data ke CSV lokal.
3. Menjadi cache agar training tidak perlu download ulang terus.

Untuk konsep stochastic + ML, data yang disimpan sebaiknya minimal mencakup:

```text
time, open, high, low, close, tick_volume, spread, real_volume
```

Kalau memungkinkan, data multi-timeframe juga tetap bagus supaya model punya konteks yang lebih kaya.

### 2. Script Training ML

Tugas script ini:

1. Membaca data historis dari CSV.
2. Membangun fitur.
3. Membuat label target first entry.
4. Melatih model.
5. Mengekspor model ke format ONNX.

Untuk konsep ini, model sebaiknya tidak memprediksi harga mentah.
Lebih cocok jika model memprediksi:

```text
layak entry / tidak layak entry
```

atau:

```text
probabilitas BUY
probabilitas SELL
```

### 3. Script EA

Tugas EA:

1. Membaca stochastic pada candle/tick yang dipilih.
2. Jika `%K` berada di atas 80 atau di bawah 20, masuk mode candidate search.
3. Menghitung fitur yang sama seperti saat training.
4. Menjalankan model ONNX.
5. Jika hasil valid, open posisi pertama.

## Alur Logika First Entry

### Skenario BUY

1. `%K < 20`
2. EA menandai bahwa market berada di zona oversold.
3. EA mengumpulkan fitur kondisi market.
4. ML memberi hasil `valid buy`.
5. EA membuka BUY pertama.

### Skenario SELL

1. `%K > 80`
2. EA menandai bahwa market berada di zona overbought.
3. EA mengumpulkan fitur kondisi market.
4. ML memberi hasil `valid sell`.
5. EA membuka SELL pertama.

## Definisi Valid Entry

Bagian paling penting dari sistem ini adalah definisi kata **valid**.

Secara praktis, valid entry bisa didefinisikan dengan beberapa cara:

1. Harga bergerak sesuai arah posisi minimal sekian pip/point setelah entry.
2. TP tercapai sebelum SL.
3. Return setelah N candle ke depan bernilai positif dan melewati ambang tertentu.
4. Entry mempunyai expected value yang cukup baik.

Untuk tahap awal, definisi yang paling mudah biasanya:

```text
BUY valid jika setelah entry harga naik lebih dulu dan mencapai target tertentu sebelum stop loss.
SELL valid jika setelah entry harga turun lebih dulu dan mencapai target tertentu sebelum stop loss.
```

## Saran Struktur Model

Untuk versi awal, model paling sederhana dan mudah dijalankan di ONNX adalah:

1. **Binary classification**
   - output: `0 = tidak valid`, `1 = valid`

2. **Dual class direction**
   - output: `BUY score`
   - output: `SELL score`

3. **Threshold-based decision**
   - model mengeluarkan score/probabilitas
   - EA hanya entry jika score melewati ambang tertentu

Kalau tujuan utama Anda adalah first entry yang rapi, saya cenderung menyarankan:

```text
1 model klasifikasi dengan output valid / tidak valid
```

lalu arah BUY/SELL tetap ditentukan oleh zona stochastic:

```text
< 20 = BUY candidate
> 80 = SELL candidate
```

## Catatan Tentang Fitur

Karena stochastic hanya gate, fitur ML sebaiknya fokus pada konteks market saat kandidat entry muncul.

Contoh kelompok fitur yang bisa dipakai:

1. Struktur candle terakhir
2. Volatilitas
3. Tren pendek dan menengah
4. Posisi harga terhadap MA
5. Momentum
6. Nilai stochastic saat itu
7. Jarak stochastic terhadap batas ekstrem

Contoh fitur stochastic:

```text
stoch_k
stoch_d
stoch_k_minus_d
stoch_distance_from_20
stoch_distance_from_80
```

## Tahap Implementasi Yang Masuk Akal

Urutan kerja yang paling aman:

1. Buat dulu aturan label valid entry.
2. Siapkan script download data.
3. Bangun script training.
4. Export ONNX.
5. Baru buat EA yang membaca stochastic + model.

Dengan urutan ini, kita tidak membangun EA terlalu cepat sebelum tahu modelnya benar-benar belajar apa.

## Ringkasan

Konsep Anda saya pahami sebagai:

```text
Stochastic = pemicu kandidat first entry
ML = penentu valid atau tidaknya first entry
```

Jadi stochastic tidak menggantikan ML, dan ML juga tidak menggantikan stochastic.
Keduanya dibagi peran:

1. stochastic menyaring kapan market layak diperiksa
2. ML memutuskan apakah momen itu layak diambil
