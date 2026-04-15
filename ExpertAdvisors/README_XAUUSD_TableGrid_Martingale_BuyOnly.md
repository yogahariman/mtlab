# README - XAUUSD_TableGrid_Martingale_BuyOnly

Ringkasan algoritma EA supaya cepat diingat.
File utama: `ExpertAdvisors/XAUUSD_TableGrid_Martingale_BuyOnly.mq5`

## 1) Konsep Inti
- EA khusus `BUY` untuk `XAUUSD` pada akun `Hedging`.
- Lot dan jarak grid normal diambil dari CSV (`InpTableFile`).
- Saat posisi mencapai `InpMaxPositions`, EA pause dan kirim warning.
- Lanjut entry hanya lewat `Manual Resume` (batch tambahan).

## 2) Alur OnTick
1. Hitung `posCount` (jumlah buy aktif untuk kombinasi `symbol + magic`).
2. Proses `Manual Resume`.
3. Proses exit basket (`Basket TP` lalu `Basket Trailing`).
4. Jika kena batas max posisi (dan bukan mode manual batch), kirim warning lalu pause.
5. Jika boleh entry:
- `posCount == 0` -> first entry.
- `posCount > 0` -> grid entry dari posisi buy terakhir.

## 3) First Entry
- Dieksekusi per tick (bukan menunggu candle close), tetapi data RSI pakai candle close.
- Filter RSI opsional (`InpUseFirstEntryRsiFilter`).
- Syarat RSI:
- `RSI_now < InpRsiThreshold`
- `(RSI_now - RSI_prev) >= InpRsiMinRise`
- `RSI_now` = shift 1, `RSI_prev` = shift 2.
- Saat `Manual Resume` aktif, filter RSI first-entry di-bypass.

## 4) Filter Spread
- `InpMaxSpreadFirstEntryPips` untuk first entry.
- `InpMaxSpreadGridEntryPips` untuk grid entry.
- Nilai `0` = filter nonaktif.

## 5) Manual Resume Batch
Input:
- `InpManualResumeCycleId`
- `InpManualResumeLot`
- `InpManualResumeGridPips`
- `InpManualResumeCount`

Aturan:
- Resume baru hanya jalan jika `InpManualResumeCycleId` naik.
- Contoh naik valid: `0 -> 1 -> 2 -> 3`.
- Saat aktif, lot+grid memakai parameter manual resume.
- Jika jumlah tambahan sudah mencapai `InpManualResumeCount`, EA pause lagi dan kirim warning.

## 6) Telegram Warning
Trigger warning:
- Menyentuh `InpMaxPositions`.
- `Manual Resume` batch selesai.

Isi pesan (dipersingkat):
- reason, account name, symbol, posisi `current/max`.

Catatan:
- Token/chat Telegram hardcoded di source (`TG_BOT_TOKEN`, `TG_CHAT_ID`).
- Tidak muncul di EA Properties/.set.
- Tetap wajib aktifkan WebRequest: `https://api.telegram.org`.

## 7) CSV Level
Format:
```csv
lot,gridPips
0.01,20
0.01,25
0.02,30
```

Lokasi file:
- `InpUseCommonFiles=false` -> `MQL5/Files/...` (live), `MQL5/Tester/Files/...` (tester).
- `InpUseCommonFiles=true` -> `Terminal/Common/Files/...`.

## 8) Checklist Operasional
1. Pastikan CSV kebaca saat init.
2. Pastikan WebRequest Telegram aktif.
3. Saat pause karena max posisi:
- isi parameter manual resume,
- lalu naikkan `InpManualResumeCycleId`.
4. Pantau panel chart `Manual Cycle Ref`.

## 9) Contoh Parameter Awal
- `InpUseFirstEntryRsiFilter=true`
- `InpRsiPeriod=14`
- `InpRsiThreshold=50`
- `InpRsiMinRise=1.0`
- `InpMaxSpreadFirstEntryPips=3`
- `InpMaxSpreadGridEntryPips=5`
- `InpUseBasketTrail=true`

## 10) Risiko
- Strategi ini tetap termasuk grid/martingale buy-only.
- Gunakan lot konservatif, batas posisi yang masuk akal, dan wajib validasi di backtest + forward test.
