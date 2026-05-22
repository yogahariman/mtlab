# XAU_EMA_SNR_ATR

EA MT5 single-shot untuk XAUUSD. Strateginya memakai EMA untuk filter trend, SNR untuk lokasi entry, dan ATR untuk menentukan jarak SL/TP.

Versi default saat ini memakai EMA `20/50`, SNR lookback `20`, toleransi SNR `100` atau sekitar `$1`, dan validasi SNR aktif.

## Standar Jarak XAU

EA ini mengikuti standar project XAU yang sudah dipakai:

```text
100 = $1 pergerakan harga XAU
500 = $5
1000 = $10
```

Secara internal, XAUUSD selalu dihitung dengan `1 pip = 0.01`, jadi aman untuk broker 2 digit maupun 3 digit.

## Cara Kerja

EA hanya mengecek sinyal saat candle baru terbentuk. Candle yang dinilai adalah candle sebelumnya yang sudah close.

BUY:

1. EMA fast berada di atas EMA slow.
2. Jika aktif, close candle harus berada di atas EMA fast.
3. Candle menyentuh area support dari swing low lookback.
4. Jika aktif, candle harus bullish.
5. Tidak ada posisi aktif dengan symbol dan magic number yang sama.

SELL:

1. EMA fast berada di bawah EMA slow.
2. Jika aktif, close candle harus berada di bawah EMA fast.
3. Candle menyentuh area resistance dari swing high lookback.
4. Jika aktif, candle harus bearish.
5. Tidak ada posisi aktif dengan symbol dan magic number yang sama.

## SNR

Support diambil dari low terendah dalam `InpSnrLookbackBars`, mulai dari candle ke-2 ke belakang. Resistance diambil dari high tertinggi pada area yang sama.

Candle sinyal tidak ikut dihitung sebagai pembentuk SNR. Ini membuat area support/resistance berasal dari struktur sebelum candle sinyal.

`InpSnrTouchTolerancePips` menentukan toleransi jarak dari area SNR. Contoh:

```text
InpSnrTouchTolerancePips = 50
Artinya toleransi $0.50 dari support/resistance.
```

## SNR Validation

Validasi SNR aktif secara default:

```text
InpUseSnrValidation = true
InpMinSnrTouches = 2
InpSnrValidationZonePips = 100
InpMinBarsBetweenTouches = 3
InpRequireSnrRejection = true
InpMinRejectWickRatio = 1.2
```

Artinya support/resistance harus punya minimal 2 touch historis dalam zona sekitar `$1`. Touch yang terlalu rapat tidak dihitung berkali-kali, karena sering hanya noise dari candle berdekatan.

Jika `InpRequireSnrRejection = true`, candle sinyal juga harus menunjukkan rejection:

```text
BUY: lower wick cukup panjang dari area support
SELL: upper wick cukup panjang dari area resistance
```

`InpMinRejectWickRatio = 1.2` berarti wick rejection minimal 1.2x body candle.

## ATR Risk

Stop loss dihitung dari ATR:

```text
SL distance = ATR * InpAtrStopMultiplier
```

Kalau hasil ATR terlalu kecil, EA memakai `InpMinStopPips` sebagai jarak minimum.

Take profit dihitung dari reward:risk:

```text
TP distance = SL distance * InpRewardRiskRatio
```

Contoh:

```text
ATR = $1.20
InpAtrStopMultiplier = 1.5
SL = $1.80 = 180
InpRewardRiskRatio = 1.5
TP = $2.70 = 270
```

## Breakeven dan Trailing

EA punya proteksi posisi bawaan:

```text
InpUseBreakeven = true
InpBreakevenStartPips = 100
InpBreakevenLockPips = 10
```

Artinya setelah posisi profit sekitar `$1`, SL dipindahkan ke sekitar entry plus `$0.10` untuk BUY, atau entry minus `$0.10` untuk SELL.

Trailing juga aktif secara default:

```text
InpUseTrail = true
InpTrailStartPips = 150
InpTrailDistancePips = 100
```

Artinya setelah posisi profit sekitar `$1.50`, SL akan mengikuti harga dengan jarak sekitar `$1`.

## Input Penting

`InpLots`: ukuran lot tetap.

`InpMaxSpreadPips`: batas spread. Dengan standar XAU, `40` berarti $0.40.

`InpFastEmaPeriod` dan `InpSlowEmaPeriod`: filter arah trend.

`InpSnrLookbackBars`: jumlah candle untuk mencari support/resistance.

`InpSnrTouchTolerancePips`: toleransi sentuh SNR.

`InpUseSnrValidation`: aktifkan validasi kualitas support/resistance.

`InpMinSnrTouches`: jumlah touch minimum pada area SNR.

`InpSnrValidationZonePips`: lebar zona validasi touch.

`InpRequireSnrRejection`: wajibkan wick rejection pada candle sinyal.

`InpAtrStopMultiplier`: pengali ATR untuk SL.

`InpMinStopPips`: SL minimum.

`InpRewardRiskRatio`: rasio TP terhadap SL.

`InpUseBreakeven`: aktifkan pengamanan SL ke area entry setelah posisi profit.

`InpUseTrail`: aktifkan trailing stop setelah posisi bergerak cukup jauh.

## Catatan Penggunaan

EA ini bukan grid dan bukan martingale. Ia hanya membuka satu posisi per symbol+magic number. Setelah posisi terbuka, EA menunggu posisi itu selesai sebelum mencari sinyal baru.

Timeframe awal yang layak diuji: M15, M30, dan H1. Untuk XAU, lakukan backtest dengan spread realistis karena sinyal dekat SNR bisa sensitif terhadap biaya trading.

Jika posisi masih terlalu jarang, coba naikkan `InpSnrTouchTolerancePips` ke `150`, turunkan `InpMinSnrTouches` ke `1`, matikan `InpRequireSnrRejection`, atau matikan `InpRequireCloseBeyondFastEma`.

Jika posisi terlalu sering loss, coba naikkan `InpAtrStopMultiplier` ke `2.0`, turunkan `InpRewardRiskRatio` ke `1.0`, atau pakai timeframe yang lebih besar.
