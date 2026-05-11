# README - XAU_GridMarti_Table

Dokumentasi ringkas EA versi tabel berdasarkan implementasi saat ini.  
File utama: `ExpertAdvisors/XAU_GridMarti_Table.mq5`

## 1) Tujuan EA
- EA grid-martingale untuk `XAUUSD` pada akun `Hedging`.
- Mendukung 2 mode arah via `InpTradeMode`:
- `TRADE_BUY_ONLY`
- `TRADE_SELL_ONLY`
- Entry/lot/spacing/TP level diambil dari CSV tabel (`lot,gridPoints,tpMoney`); versi ini dipertahankan sebagai basis EA berbasis tabel.
- Exit pakai kombinasi `level TP`, `basket TP`, `trailing`, dan `floating DD stop`.

## 2) Validasi Penting Saat Init
- Simbol harus mengandung `XAUUSD`.
- Akun wajib `ACCOUNT_MARGIN_MODE_RETAIL_HEDGING`.
- Jika `InpUseTimeFilter=true`, jam start/pause harus valid (`0..23`) dan `start < pause`.

## 3) Input Inti
- `InpMagic`: ID unik strategi untuk filter posisi/deal.
- `InpTradeMode`: arah trading (buy-only / sell-only).
- `InpTableFile`: nama file CSV level.
- `InpUseCommonFiles`: `true` untuk baca CSV dari `Terminal/Common/Files`.
- `InpUseLastLevelIfExceeded`: gunakan level terakhir jika posisi melebihi baris tabel.
- `InpUseCloseLock`: mode paksa close sampai semua posisi habis.
- `InpFloatingDDStopMoney`: jika tercapai, close-all dan stop trading sampai restart EA.
- `InpTrailGridFrom`, `InpTrailStartMoney`, `InpTrailDistancePercent`: kontrol trailing basket.

## 4) Format dan Lokasi CSV Level
Format wajib:
```csv
lot,gridPoints,tpMoney
0.01,20,1.0
0.01,25,2.5
0.02,30,4.0
```

Catatan:
- Separator `,` atau `;` didukung.
- Semua nilai harus `> 0`.
- Jika `InpUseCommonFiles=true`: simpan di `Terminal/Common/Files`.
- Jika `InpUseCommonFiles=false`: simpan di `MQL5/Files` terminal aktif.

## 5) Alur Trading Ringkas
1. Hitung posisi aktif untuk kombinasi `symbol + magic + side`.
2. Jika `close-lock` aktif, EA fokus close all.
3. Terapkan proteksi: session, spread, max positions, delay order.
4. Jika ada posisi, evaluasi exit berurutan:
- floating DD stop
- forced TP (grid di bawah `InpTrailGridFrom`)
- level TP
- basket TP default
- basket trailing
5. Jika tidak ada posisi, evaluasi first-entry filter lalu buka posisi pertama.
6. Jika ada posisi, evaluasi trigger grid berikutnya sesuai jarak `gridPoints`.

## 6) Daily Stats
- Diaktifkan oleh `InpEnableDailyStats`.
- File dibentuk otomatis:
- `<account_login>_<table_name>_daily_stats.csv`
- Isi kolom:
- `date,symbol,magic,daily_profit,max_dd`
- `daily_profit` dihitung dari deal close (`profit + swap + commission`) untuk `symbol+magic`.
- `max_dd` adalah drawdown basket EA (berdasarkan floating profit EA), bukan DD total akun.

## 7) Time Filter
- `InpUseTimeFilter=true` membatasi first entry ke window:
- dari `InpStartHourBroker` sampai sebelum `InpPauseHourBroker`
- referensi waktu mengikuti `InpSessionTimeMode` (`BROKER`, `UTC`, `WIB`).
- Setelah jam pause dan basket sudah flat, EA pause sampai masuk window start berikutnya.

## 8) Telegram
- Dipakai untuk notifikasi `floating DD stop` dan heartbeat EA aktif.
- Wajib allow WebRequest:
- `https://api.telegram.org`
- Token/chat ID saat ini disimpan hardcoded di source.

## 9) Catatan Operasional
- Pakai `InpMagic` berbeda untuk setiap instance strategi agar data posisi/statistik tidak tercampur.
- Jika mengganti skema logging lama, hapus file daily stats lama agar file baru bersih.
- Lakukan backtest dan forward test sebelum live.
