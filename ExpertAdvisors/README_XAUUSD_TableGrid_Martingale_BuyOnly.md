# README - XAUUSD_TableGrid_Martingale_BuyOnly

Panduan algoritma + operasional EA versi terbaru.
File utama: `ExpertAdvisors/XAUUSD_TableGrid_Martingale_BuyOnly.mq5`

## 1) Tujuan EA
- EA `BUY-only` untuk `XAUUSD` di akun `Hedging`.
- Entry berbasis grid dari tabel CSV (`lot,gridPips`).
- Exit berbasis kombinasi:
- TP khusus grid 1-3.
- TP default basket.
- Trailing basket pada rentang grid tertentu.
- Dilengkapi `manual resume`, `close lock`, `cooldown`, dan alert Telegram.

## 2) Ringkasan Alur OnTick
1. Hitung `posCount` (buy aktif untuk `symbol + magic`).
2. Jika `close-lock` aktif, EA fokus close sampai habis dan stop flow entry.
3. Proses `manual resume`.
4. Proses rule exit basket.
5. Cek batas `max positions`.
6. Jika lolos semua filter, lakukan first entry / grid entry.

## 3) Rule Exit (Final)
Saat `posCount > 0`, rule yang berlaku:
1. `Grid 1-3`:
- selalu pakai TP khusus:
- `InpBasketTPGrid1Money`
- `InpBasketTPGrid2Money`
- `InpBasketTPGrid3Money`
2. `Grid >= 4`:
- jika trailing aktif untuk grid tersebut -> pakai trailing.
- jika trailing tidak aktif / grid di luar range trailing -> pakai TP default `InpBasketTPDefaultMoney`.

Trailing dianggap aktif untuk grid saat semua syarat true:
- `InpUseBasketTrail = true`
- `InpTrailDistanceMoney > 0`
- `posCount` berada di `InpTrailGridFrom..InpTrailGridTo`
- `InpTrailGridTo = 0` berarti tanpa batas atas.

## 4) Exit Decision Matrix
Gunakan matrix ini agar tidak salah interpretasi:

| Kondisi | Exit yang dipakai |
|---|---|
| `posCount = 1` | `InpBasketTPGrid1Money` |
| `posCount = 2` | `InpBasketTPGrid2Money` |
| `posCount = 3` | `InpBasketTPGrid3Money` |
| `posCount >= 4`, trail aktif untuk grid ini | Basket trailing |
| `posCount >= 4`, trail tidak aktif untuk grid ini | `InpBasketTPDefaultMoney` |

## 5) Close Mode (A/B Test)
Input penting:
- `InpUseCloseLock`
- `InpUsePriorityCloseOrder`

Perilaku:
1. `InpUseCloseLock=true`:
- Saat TP/Trail hit, EA lock close dulu sampai semua posisi habis.
- Entry baru diblok sementara.
2. `InpUseCloseLock=false`:
- Close langsung tiap trigger (mendekati behavior lama).

Urutan close:
1. `InpUsePriorityCloseOrder=true`:
- close `volume terbesar dulu`, tie-break `profit terburuk dulu`.
2. `InpUsePriorityCloseOrder=false`:
- close urutan legacy (index descending).

## 6) Cooldown
- `InpCooldownAfterCloseSeconds` aktif setelah posisi benar-benar 0.
- Waktu referensi cooldown: `g_lastCloseAllTime`.
- Tujuan: hindari re-entry terlalu cepat setelah close-all.

## 7) Entry Rules
### First Entry
- Dieksekusi per tick.
- Filter spread first entry: `InpMaxSpreadFirstEntryPips`.
- Filter RSI first entry (opsional):
- `RSI_now < InpRsiThreshold`
- `(RSI_now - RSI_prev) >= InpRsiMinRise`
- RSI pakai candle close (`shift 1` vs `shift 2`).
- RSI mengikuti timeframe chart aktif (`PERIOD_CURRENT`).
- Filter MA first entry (opsional):
- `InpUseFirstEntryMaFilter=true` untuk aktifkan filter MA.
- Mode MA:
- `InpUseFirstEntryFullCandleBelowMa=false` -> syarat `Bid < MA`.
- `InpUseFirstEntryFullCandleBelowMa=true` -> syarat candle sebelumnya full di bawah MA (`High[1] < MA[1]`).
- Tipe MA dari `InpFirstEntryMaType` (`SMA` / `EMA`), periode dari `InpFirstEntryMaPeriod`.
- Filter candle bullish first entry (opsional): `InpUseFirstEntryBullishCandle`.
- Saat `manual resume` aktif, filter RSI first entry di-bypass.

### Grid Entry
- Trigger saat `bid <= latest_buy_open_price - gridPrice`.
- Filter spread grid: `InpMaxSpreadGridEntryPips`.
- Lot+grid dari CSV level sesuai jumlah posisi.

## 8) Manual Resume
Input:
- `InpManualResumeCycleId`
- `InpManualResumeLot`
- `InpManualResumeGridPips`
- `InpManualResumeCount`

Aturan:
1. Resume hanya dieksekusi jika `CycleId` naik.
2. Saat aktif, lot+grid pakai parameter manual resume.
3. Batch berhenti saat tambahan posisi mencapai target count.
4. Selesai batch -> EA pause lagi + warning.

## 9) Floating Loss Alert
Input:
- `InpWarnOnFloatingLevels`
- `InpFloatingLossLevels` (CSV angka, contoh `5000,10000,20000,...`)

Perilaku:
1. Alert kirim saat floating `<= -level`.
2. Tiap level hanya kirim sekali per siklus posisi.
3. Level otomatis sort ascending.
4. Level duplikat dibuang otomatis.
5. Jika input invalid, fallback ke default level.

## 10) Telegram
Trigger warning utama:
- Max positions reached.
- Manual resume batch completed.
- Floating loss level touched (jika aktif).

Catatan:
- Token/chat hardcoded di source (`TG_BOT_TOKEN`, `TG_CHAT_ID`).
- Wajib allow WebRequest: `https://api.telegram.org`.

## 11) CSV Level Table
Format:
```csv
lot,gridPips
0.01,20
0.01,25
0.02,30
```

Lokasi file:
1. `InpUseCommonFiles=false`:
- Live: `MQL5/Files/...`
- Tester: `MQL5/Tester/Files/...`
2. `InpUseCommonFiles=true`:
- `Terminal/Common/Files/...`

## 12) Preset Operasional
### A) Replikasi Mode Lama (`..._20260415`)
- `InpUseCloseLock=false`
- `InpUsePriorityCloseOrder=false`
- `InpTrailGridFrom=4`
- `InpTrailGridTo=1000000`
- `InpBasketTPDefaultMoney=0`
- `InpWarnOnFloatingLevels=false`

### B) Mode Stabil (disarankan untuk broker close lambat)
- `InpUseCloseLock=true`
- `InpUsePriorityCloseOrder=true`
- `InpTrailGridFrom=4` s/d `8` (atau lebih ketat)
- `InpBasketTPDefaultMoney > 0` (mis. 10-20, sesuaikan akun)
- `InpCooldownAfterCloseSeconds=60` atau lebih

## 13) Troubleshooting Cepat
### Error init symbol
- Jika muncul `symbol must contain XAUUSD`, cek simbol tester benar-benar mengandung `XAUUSD`.

### Hasil backtest beda dari versi lama
Cek parameter ini dulu:
- `InpUseCloseLock`
- `InpUsePriorityCloseOrder`
- `InpTrailGridFrom`, `InpTrailGridTo`
- `InpBasketTPDefaultMoney`
- `InpWarnOnFloatingLevels`

### Profit kebocoran saat spike
- Aktifkan `close-lock`.
- Aktifkan `priority close order`.
- Kurangi rentang trailing.
- Gunakan TP default + buffer yang realistis.

## 14) Risiko
- Tetap strategi grid/martingale buy-only.
- Gunakan lot konservatif dan batasi eksposur.
- Validasi wajib: backtest + forward test.
- Fokus pada ketahanan DD, bukan hanya profit sesaat.
