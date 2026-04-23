# README - XAU_GridMarti_BuyOnly

Panduan ringkas EA sesuai implementasi terbaru.
File utama: `ExpertAdvisors/XAU_GridMarti_BuyOnly.mq5`

## 1) Tujuan EA
- EA `BUY-only` untuk `XAUUSD` pada akun `Hedging`.
- Entry grid berbasis tabel CSV (`lot,gridPips,tpMoney`).
- Exit memakai kombinasi:
- `Level TP` dari kolom ke-3 CSV.
- `Basket TP default` sebagai fallback.
- `Basket trailing` mulai grid tertentu.
- Proteksi tambahan: `close-lock`, cooldown, spread filter, session filter, dan stop trading saat floating DD menyentuh batas.

## 2) Input Inti
- `InpTableFile`: nama file CSV level.
- `InpUseCommonFiles`: baca dari `Common/Files` jika `true`.
- `InpSkipFirstCsvRow`: skip header CSV.
- `InpUseLastLevelIfExceeded`: pakai level terakhir saat posisi melebihi jumlah baris CSV.
- `InpMaxPositions`: batas maksimum posisi aktif.
- `InpCooldownAfterCloseSeconds`: jeda setelah close-all.
- `InpMinSecondsBetweenOrders`: jeda antar order.
- `InpUseCloseLock`: mode paksa close sampai habis sebelum lanjut flow normal.
- `InpUsePriorityCloseOrder`: urut close volume terbesar dulu.
- `InpUseAsyncClose`: close async (lebih cepat untuk batch).

## 3) Format CSV
Format utama:
```csv
lot,gridPips,tpMoney
0.01,20,1.0
0.01,25,2.4
0.02,30,4.8
```

Catatan:
- Mendukung pemisah `,` atau `;`.
- Mendukung format lama 2 kolom (`lot,gridPips`) untuk kompatibilitas.
- Jika 3 kolom dipakai, `tpMoney` harus > 0.

## 4) Lokasi File CSV
- Jika `InpUseCommonFiles=false`:
- Live: `TERMINAL_DATA_PATH/MQL5/Files/`
- Tester: folder agent tester aktif (`.../MQL5/Files/`)
- Jika `InpUseCommonFiles=true`:
- `TERMINAL_COMMONDATA_PATH/Files/`

## 5) Alur OnTick (Ringkas)
1. Hitung jumlah posisi buy (`posCount`) untuk `symbol + magic`.
2. Jika `close-lock` aktif, EA fokus menutup semua posisi dulu.
3. Update status session pause (jika time filter aktif).
4. Jika mode stop-trading karena floating DD aktif, EA tidak entry baru.
5. Jika ada posisi:
- evaluasi TP/trailing/forced close.
6. Jika tidak ada trigger close:
- cek limit `max positions`, cooldown, delay antar order.
- lakukan first entry atau grid entry.

## 6) Entry Rules
### First Entry
- Hanya saat `posCount == 0`.
- Wajib lolos:
- Session filter (jika aktif).
- Spread filter `InpMaxSpreadFirstEntryPips`.
- RSI filter (opsional).
- MA filter (opsional).
- Bullish candle filter (opsional).

### Grid Entry
- Saat `bid < latest_buy_price - (gridPips * PipPoint)`.
- Wajib lolos:
- Session grid rule (`IsGridEntryAllowedNow`).
- Spread filter `InpMaxSpreadGridEntryPips`.

## 7) Exit Rules
Prioritas utama saat `posCount > 0`:
1. Floating DD stop:
- Jika `profit <= -InpFloatingDDStopMoney`, close all dan stop trading sampai EA restart manual.
2. Forced TP untuk grid di bawah `InpTrailGridFrom`:
- Trailing dimatikan untuk grid ini.
- Target profit pakai `tpMoney` level aktif (atau fallback legacy `InpBasketTPByGridMoney`).
3. Level TP:
- Jika `currentLevelTpMoney > 0` dan trailing tidak dipakai di grid tersebut.
4. Basket TP default:
- Dipakai jika tidak trailing dan target default > 0.
5. Basket trailing:
- Aktif jika `InpUseBasketTrail=true`, `posCount >= InpTrailGridFrom`, `InpTrailDistancePercent > 0`.
- Start trail saat profit >= `trailStartMoney`.
- Close saat profit turun <= `peak * (1 - distance%)`.

## 8) Time Filter
- `InpUseTimeFilter=true` mengaktifkan window entry awal:
- `InpStartHourBroker` sampai sebelum `InpPauseHourBroker`.
- Time reference mengikuti `InpSessionTimeMode`:
- `BROKER`, `UTC`, atau `WIB(UTC+7)`.
- Setelah jam pause dan basket flat, EA masuk pause hingga window start berikutnya.

## 9) Telegram
- Trigger notifikasi utama:
- Floating DD stop trigger (jika `InpNotifyFloatingSLStop=true`).
- Token/chat masih hardcoded di source (`TG_BOT_TOKEN`, `TG_CHAT_ID`).
- Wajib allow WebRequest:
- `https://api.telegram.org`

## 10) Troubleshooting Cepat
- `Init fail | symbol must contain XAUUSD`:
- Jalankan EA di simbol yang mengandung `XAUUSD`.
- `Init fail | account type must be HEDGING`:
- EA wajib akun hedging.
- `CSV open fail`:
- cek nama file `InpTableFile`, lokasi file, dan mode `InpUseCommonFiles`.
- Tidak ada entry:
- cek session filter, spread filter, cooldown, dan delay order.

## 11) Risiko
- Strategi ini tetap grid/martingale buy-only.
- Wajib uji di backtest + forward test.
- Pakai lot konservatif dan batas DD yang jelas.
