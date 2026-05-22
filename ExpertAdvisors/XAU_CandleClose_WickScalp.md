# XAU Candle Close Wick Scalp

## Tujuan

EA ini memakai candle yang baru close sebagai setup arah, lalu menunggu harga pada candle berikutnya menembus level trigger sebelum entry market. Konsep OCO tidak dipakai. Referensi konversi pip/point mengikuti `XAU_GridMarti_Table.mq5`.

## Definisi Pip, Point, dan Dollar XAUUSD

EA memakai fungsi `PipPoint()` yang sama konsepnya dengan `XAU_GridMarti_Table.mq5`.

```text
Untuk XAUUSD:
1 pip EA = 0.01 harga gold
100 pips EA = 1.00 harga gold
100 pips EA = pergerakan $1 pada chart XAUUSD
```

Broker 2 digit:

```text
Harga contoh: 2400.12
SYMBOL_POINT = 0.01
1 pip EA = 1 broker point
$1 movement = 100 pips EA = 100 broker points
```

Broker 3 digit:

```text
Harga contoh: 2400.123
SYMBOL_POINT = 0.001
1 pip EA = 10 broker points
$1 movement = 100 pips EA = 1000 broker points
```

Contoh input:

```text
TP $1.50       -> InpTakeProfitPips = 150
SL $1.50       -> InpStopLossPips = 150
Spread $0.40   -> InpMaxSpreadPips = 40
Range $0.50    -> InpMinCandleRangePips = 50
Buffer $0.10   -> InpCandleStopBufferPips = 10
```

## Alur Entry

EA membuat setup pada first tick candle baru, tetapi entry market tidak wajib langsung terjadi. Jika `InpUseTriggerConfirmation=true`, EA menunggu harga menembus high/low candle setup plus buffer.

```text
1. Candle baru terdeteksi.
2. Baca candle sebelumnya, yaitu candle index 1.
3. Hitung body, upper wick, lower wick, dan range.
4. Jika candle sebelumnya valid, simpan sebagai setup BUY atau SELL.
5. Pada tick berikutnya, tunggu trigger:
   BUY  -> Ask menembus high candle setup + buffer.
   SELL -> Bid menembus low candle setup - buffer.
6. Jika trigger kena, spread aman, dan tidak ada posisi aktif, open market.
7. Pasang TP dan SL saat order dikirim.
8. Jika harga bergerak melawan setup lebih dulu, setup dibatalkan.
9. Jika setup tidak trigger dalam `InpSetupExpiryBars`, setup expired.
10. Jika profit mencapai `InpBreakevenStartPips`, SL dipindah ke breakeven plus lock.
11. Tunggu posisi close, lalu cooldown sebelum entry berikutnya.
```

## Sinyal BUY

BUY valid jika:

```text
lower_wick >= body * InpWickBodyRatio
close_position >= InpCloseZonePercent
range candle >= InpMinCandleRangePips
range candle <= InpMaxCandleRangePips, jika max diaktifkan
spread <= InpMaxSpreadPips
jika InpRequireCandleColor=true, candle harus bullish
jika InpUseLiquiditySweep=true, low candle harus sweep low beberapa candle sebelumnya lalu close balik di atas low tersebut
jika InpUseEmaTrendFilter=true, close candle harus di atas EMA
```

`close_position` dihitung dari posisi close di dalam range candle:

```text
close_position = ((close - low) / (high - low)) * 100
```

Contoh BUY:

```text
Open  = 2400.50
High  = 2401.00
Low   = 2398.80
Close = 2400.90
```

Harga sempat turun, membentuk lower wick panjang, lalu close dekat high. EA menyimpan candle ini sebagai setup BUY pada awal candle berikutnya.

Dengan trigger confirmation aktif, EA belum langsung BUY. EA menunggu:

```text
Ask >= high setup + InpTriggerBufferPips * PipPoint()
```

## Sinyal SELL

SELL valid jika:

```text
upper_wick >= body * InpWickBodyRatio
close_position <= 100 - InpCloseZonePercent
range candle >= InpMinCandleRangePips
range candle <= InpMaxCandleRangePips, jika max diaktifkan
spread <= InpMaxSpreadPips
jika InpRequireCandleColor=true, candle harus bearish
jika InpUseLiquiditySweep=true, high candle harus sweep high beberapa candle sebelumnya lalu close balik di bawah high tersebut
jika InpUseEmaTrendFilter=true, close candle harus di bawah EMA
```

Contoh SELL:

```text
Open  = 2400.50
High  = 2402.00
Low   = 2400.20
Close = 2400.30
```

Harga sempat naik, membentuk upper wick panjang, lalu close dekat low. EA menyimpan candle ini sebagai setup SELL pada awal candle berikutnya.

Dengan trigger confirmation aktif, EA belum langsung SELL. EA menunggu:

```text
Bid <= low setup - InpTriggerBufferPips * PipPoint()
```

## State Algoritma

EA sekarang memakai tiga state sederhana:

```text
WAIT_SETUP:
Tidak ada setup aktif dan tidak ada posisi.
Saat candle baru mulai, EA membaca candle sebelumnya.

WAIT_TRIGGER:
Setup aktif, tetapi posisi belum dibuka.
EA menunggu harga menembus trigger sesuai arah setup.

IN_POSITION:
Ada posisi aktif untuk symbol+magic.
Setup dihapus, lalu EA hanya mengelola posisi, TP/SL, dan trailing.
```

Setup akan expired saat jumlah candle berjalan setelah setup mencapai `InpSetupExpiryBars`.

Setup juga bisa dibatalkan sebelum trigger jika `InpCancelSetupOnInvalidation=true`.

```text
INVALIDATE_SETUP_MIDPOINT:
BUY batal jika Bid turun ke bawah midpoint candle setup.
SELL batal jika Ask naik ke atas midpoint candle setup.

INVALIDATE_SETUP_EXTREME:
BUY batal jika Bid turun ke bawah low candle setup.
SELL batal jika Ask naik ke atas high candle setup.
```

## Stop Loss dan Take Profit

TP selalu berdasarkan `InpTakeProfitPips`.

```text
BUY TP  = entry + InpTakeProfitPips * PipPoint()
SELL TP = entry - InpTakeProfitPips * PipPoint()
```

SL punya dua mode:

```text
SL_FIXED_PIPS:
BUY SL  = entry - InpStopLossPips * PipPoint()
SELL SL = entry + InpStopLossPips * PipPoint()

SL_CANDLE_EXTREME:
BUY SL  = previous candle low - buffer
SELL SL = previous candle high + buffer
```

EA juga menyesuaikan SL/TP agar tidak melanggar minimum stop distance broker.

## Liquidity Sweep Filter

Filter ini membuat wick rejection lebih selektif.

BUY setup butuh:

```text
low candle setup < lowest low dari InpSweepLookbackBars candle sebelumnya
close candle setup > lowest low tersebut
```

SELL setup butuh:

```text
high candle setup > highest high dari InpSweepLookbackBars candle sebelumnya
close candle setup < highest high tersebut
```

Tujuannya agar EA tidak mengambil semua wick biasa, tetapi hanya wick yang terlihat seperti sweep liquidity lalu rejection.

## Spread 33 Pips

Jika broker rata-rata spread sekitar 33 pips EA, `InpMaxSpreadPips=40` masih bisa dipakai. Tetapi target 100 pips terlalu sempit karena spread memakan sekitar sepertiga target. Default TP dan SL dinaikkan ke 150 pips agar biaya transaksi tidak terlalu dominan.

```text
Spread 33 pips = sekitar $0.33 pada XAUUSD
TP 100 pips    = sekitar $1.00, spread makan 33%
TP 150 pips    = sekitar $1.50, spread makan 22%
```

## Breakeven

Jika `InpUseBreakeven=true`, EA akan memindahkan SL setelah profit berjalan cukup jauh.

```text
BUY:
profit >= InpBreakevenStartPips -> SL ke entry + InpBreakevenLockPips

SELL:
profit >= InpBreakevenStartPips -> SL ke entry - InpBreakevenLockPips
```

## Setting Awal untuk Backtest

```text
InpLots = 0.01
InpMaxSpreadPips = 40
InpUseTriggerConfirmation = true
InpTriggerBufferPips = 5
InpSetupExpiryBars = 1
InpCancelSetupOnInvalidation = true
InpInvalidationMode = INVALIDATE_SETUP_EXTREME
InpWickBodyRatio = 2.0
InpCloseZonePercent = 60
InpMinCandleRangePips = 50
InpMaxCandleRangePips = 0
InpUseLiquiditySweep = true
InpSweepLookbackBars = 5
InpUseEmaTrendFilter = false
InpTakeProfitPips = 150
InpStopLossPips = 150
InpStopLossMode = SL_FIXED_PIPS
InpUseBreakeven = true
InpBreakevenStartPips = 75
InpBreakevenLockPips = 5
InpCooldownSecondsAfterClose = 60
InpUseTrail = false
```

## Catatan Risiko

Target $1 pada XAUUSD kecil, jadi spread, slippage, dan komisi sangat berpengaruh. Strategi ini wajib diuji di Strategy Tester dengan spread realistis, terutama pada timeframe M1 atau M5.
