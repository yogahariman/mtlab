# README - XAUUSD_TableGrid_Martingale_BuyOnly

Ringkasan algoritma EA (versi terbaru).
File utama: `ExpertAdvisors/XAUUSD_TableGrid_Martingale_BuyOnly.mq5`

## 1) Konsep Inti
- EA khusus `BUY` untuk `XAUUSD` pada akun `Hedging`.
- Lot dan grid normal dari CSV (`InpTableFile`).
- Ada mode `Manual Resume` untuk nambah batch posisi saat pause.
- Ada proteksi close + cooldown + alert Telegram.

## 2) Alur OnTick
1. Hitung `posCount` (buy aktif untuk `symbol + magic`).
2. Jika mode close-lock aktif, fokus close sampai habis (tanpa entry baru).
3. Proses `Manual Resume`.
4. Proses exit basket (TP grid khusus / TP default / trailing sesuai rule).
5. Cek pause max positions.
6. Jika boleh entry, lanjut first entry atau grid entry.

## 3) Rule Exit (Paling Penting)
Rule saat `posCount > 0`:
- `Grid 1-3`: selalu pakai TP khusus:
- `InpBasketTPGrid1Money`
- `InpBasketTPGrid2Money`
- `InpBasketTPGrid3Money`
- `Grid >= 4`:
- jika trailing aktif untuk grid tersebut -> pakai trailing.
- jika trailing tidak aktif/di luar range -> pakai TP default (`InpBasketTPDefaultMoney`).

Trailing aktif per-grid jika semua true:
- `InpUseBasketTrail = true`
- `InpTrailDistanceMoney > 0`
- `posCount` berada di range `InpTrailGridFrom..InpTrailGridTo` (`InpTrailGridTo=0` berarti tanpa batas atas)

## 4) Close Mode (A/B Backtest)
Input:
- `InpUseCloseLock`
- `InpUsePriorityCloseOrder`

Perilaku:
- `InpUseCloseLock=true`
- Saat TP/Trail trigger, EA lock close dulu sampai posisi habis, baru lanjut flow normal.
- `InpUseCloseLock=false`
- Mode close langsung per trigger (mendekati behavior lama).

Urutan close:
- `InpUsePriorityCloseOrder=true`
- close `volume terbesar dulu`, lalu `profit terburuk`.
- `InpUsePriorityCloseOrder=false`
- close urutan legacy (index descending).

## 5) Cooldown
- `InpCooldownAfterCloseSeconds` aktif setelah semua posisi benar-benar sudah 0.
- Timestamp cooldown: `g_lastCloseAllTime`.
- Tujuan: mencegah re-entry terlalu cepat sesudah close-all.

## 6) First Entry
- Trigger per tick.
- Spread filter first entry: `InpMaxSpreadFirstEntryPips`.
- RSI first entry opsional (`InpUseFirstEntryRsiFilter`):
- `RSI_now < InpRsiThreshold`
- `(RSI_now - RSI_prev) >= InpRsiMinRise`
- RSI pakai candle close (`shift 1` vs `shift 2`).
- Saat manual resume aktif, filter RSI first entry di-bypass.

## 7) Grid Entry
- Grid trigger saat `bid <= latest_buy_open_price - gridPrice`.
- Spread filter grid: `InpMaxSpreadGridEntryPips`.
- Lot+grid dari CSV level sesuai jumlah posisi, atau last level jika melebihi tabel (`InpUseLastLevelIfExceeded`).

## 8) Manual Resume
Input:
- `InpManualResumeCycleId`
- `InpManualResumeLot`
- `InpManualResumeGridPips`
- `InpManualResumeCount`

Aturan:
- Resume baru hanya diproses jika `InpManualResumeCycleId` naik.
- Batch selesai saat penambahan posisi mencapai `InpManualResumeCount`.
- Setelah batch selesai, EA pause lagi dan kirim warning.

## 9) Floating Loss Alert Telegram
Input:
- `InpWarnOnFloatingLevels`
- `InpFloatingLossLevels` (contoh: `5000,10000,20000,...`)

Perilaku:
- Alert kirim saat floating <= -level.
- Tiap level dikirim sekali per siklus posisi.
- Level otomatis sort ascending, nilai duplikat dibuang.
- Jika input invalid, fallback ke default level.

## 10) Telegram Warning
Trigger utama:
- Max positions reached.
- Manual resume batch completed.
- Floating loss level touched (jika diaktifkan).

Catatan:
- Token/chat hardcoded: `TG_BOT_TOKEN`, `TG_CHAT_ID`.
- Aktifkan WebRequest URL: `https://api.telegram.org`.

## 11) CSV Level
Format:
```csv
lot,gridPips
0.01,20
0.01,25
0.02,30
```

Lokasi:
- `InpUseCommonFiles=false`: `MQL5/Files/...` (live), `MQL5/Tester/Files/...` (tester).
- `InpUseCommonFiles=true`: `Terminal/Common/Files/...`.

## 12) Set Replikasi Mode Lama
Untuk hasil mendekati versi lama (`..._20260415`):
- `InpUseCloseLock=false`
- `InpUsePriorityCloseOrder=false`
- `InpTrailGridFrom=4`
- `InpTrailGridTo=1000000`
- `InpBasketTPDefaultMoney=0`
- `InpWarnOnFloatingLevels=false`

## 13) Risiko
- Ini tetap strategi grid/martingale buy-only.
- Gunakan lot konservatif, kontrol jumlah posisi, dan validasi di backtest + forward test.
