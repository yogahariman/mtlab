# XAU Broker Probe

`XAU_BrokerProbe.mq5` adalah EA diagnostik, bukan EA trading.

Fungsinya untuk membaca karakter broker dan simbol XAU/GOLD, lalu menampilkan data penting di Experts Log:

- nama simbol
- digits
- point
- bid/ask dan spread
- tick size dan tick value
- contract size
- volume min, step, max
- swap long/short
- margin initial dan hedged
- simulasi profit untuk beberapa ukuran lot dan beberapa ukuran pergerakan harga

Mode pakai yang disarankan:

```text
InpUseTimer = false
```

Dengan begitu EA hanya print sekali saat dipasang ke chart.

Kalau ingin memantau spread atau karakter simbol secara berkala, aktifkan:

```text
InpUseTimer = true
InpTimerSeconds = 60
```

EA ini membantu menentukan apakah broker memakai karakter XAU seperti:

- standard / ultra low standard
- micro / ultra low micro
- GOLD atau XAU sebagai nama simbol

Hasil dari probe ini dipakai sebagai referensi saat menyetel EA trading utama seperti `StochTrend`.
