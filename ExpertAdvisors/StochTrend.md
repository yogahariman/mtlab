# StochTrend

StochTrend adalah konsep Expert Advisor (EA) yang menggunakan arah tren dari EMA dan sinyal crossing dari Stochastic Oscillator.

Metode ini dibuat agar EA tidak langsung membuka posisi hanya karena Stochastic berada di area jenuh beli atau jenuh jual. EA tetap menunggu arah tren utama dan konfirmasi crossing sebelum melakukan entry.

## Konsep Dasar

EA menggunakan dua filter utama:

1. **EMA 50 dan EMA 200** untuk membaca arah tren.
2. **Stochastic Oscillator** untuk mencari momen entry.

Default indikator:

```text
Signal Timeframe = Current Chart

Use EMA Trend Filter = true
Use Stochastic Filter = true
Moving Average Type = Exponential
Fast EMA = 50
Slow EMA = 200

K Period   = 5
D Period   = 3
Slowing    = 3
Overbought = 80
Oversold   = 20
```

Jika EMA 50 berada di atas EMA 200, kondisi pasar dianggap cenderung naik. Dalam kondisi ini, EA hanya mencari peluang BUY.

Jika EMA 50 berada di bawah EMA 200, kondisi pasar dianggap cenderung turun. Dalam kondisi ini, EA hanya mencari peluang SELL.

Filter EMA dan Stochastic dapat dimatikan sementara untuk testing algoritma. Jika EMA Trend Filter dimatikan, EA tidak memakai arah EMA 50/200 sebagai syarat first entry. Jika Stochastic Filter dimatikan, EA tidak menunggu crossing Stochastic sebagai syarat first entry.

Jika kedua filter dimatikan, gunakan mode **Buy only** atau **Sell only** untuk testing first entry. Pada mode **Both Single Trade**, EA tidak membuka first entry jika EMA dan Stochastic sama-sama dimatikan karena arah entry tidak dapat ditentukan.

Moving Average Type dapat dipilih oleh user:

1. **Exponential**: lebih responsif terhadap perubahan harga terbaru. Ini menjadi pilihan default.
2. **Simple**: lebih halus, tetapi biasanya lebih lambat merespons perubahan harga.

## Price EMA Filter

Price EMA Filter adalah filter tambahan untuk memastikan harga berada di sisi yang sesuai dengan Fast EMA.

Default awal:

```text
Use Price EMA Filter = false
Price Filter MA      = Fast EMA
Apply Price          = Close
```

Jika filter ini aktif, aturan tambahannya adalah:

1. BUY hanya valid jika close candle berada di atas Fast EMA.
2. SELL hanya valid jika close candle berada di bawah Fast EMA.

Filter ini dapat membantu mengurangi entry saat harga sudah bergerak terlalu jauh melawan arah Fast EMA. Namun, karena bisa membuat entry lebih ketat, default awal dibuat `false`.

## Filter Kekuatan Tren untuk XAU

Karena EA ini difokuskan untuk XAU, arah tren dari EMA 50 dan EMA 200 sebaiknya tidak hanya dilihat dari posisi atas atau bawahnya saja. Jarak antara EMA 50 dan EMA 200 juga perlu diperhatikan.

Jika jarak EMA terlalu dekat, market bisa dianggap belum punya arah yang kuat. Dalam kondisi seperti ini, EA sebaiknya tidak membuka posisi walaupun sudah ada sinyal dari Stochastic.

Aturan sederhananya:

1. Untuk BUY, EMA 50 harus berada di atas EMA 200 dan jaraknya harus cukup jauh.
2. Untuk SELL, EMA 50 harus berada di bawah EMA 200 dan jaraknya harus cukup jauh.

Jarak EMA dapat dibuat dengan dua cara:

1. **Fixed distance**: menggunakan jarak tetap, misalnya minimal beberapa ratus point XAU.
2. **ATR based**: menggunakan ATR sebagai ukuran volatilitas, misalnya jarak EMA minimal harus sama dengan `ATR x 0.5`.

Untuk versi awal, fixed distance lebih mudah dipakai karena aturannya sederhana. Setelah EA diuji, aturan ini bisa dibandingkan dengan versi ATR based untuk melihat mana yang lebih cocok di XAU.

Default awal untuk XAU timeframe M1:

```text
EMA Min Distance = 1.50
```

Artinya, jarak EMA 50 dan EMA 200 minimal harus sebesar `1.50` harga XAU agar tren dianggap cukup kuat.

## Model Trade

EA memiliki beberapa pilihan model trade agar cara entry bisa disesuaikan dengan kebutuhan:

1. **Buy only**

   EA hanya mencari peluang BUY. Sinyal SELL akan diabaikan walaupun kondisi SELL terpenuhi.

2. **Sell only**

   EA hanya mencari peluang SELL. Sinyal BUY akan diabaikan walaupun kondisi BUY terpenuhi.

3. **Both Single Trade**

   EA hanya boleh memiliki satu posisi aktif dalam satu waktu. Jika EA sudah membuka posisi BUY dan posisi tersebut belum close, maka EA tidak akan membuka posisi SELL.

   Begitu juga sebaliknya, jika EA sudah membuka posisi SELL dan posisi tersebut belum close, maka EA tidak akan membuka posisi BUY.

Model ini membantu mencegah EA membuka posisi berlawanan arah secara bersamaan.

## Money Management

EA menggunakan fixed lot yang diatur langsung oleh user.

Default awal:

```text
Initial Lot = 0.10
```

Lot awal ini dipakai untuk first entry. Jika martingale grid aktif, lot layer berikutnya dihitung dari lot sebelumnya menggunakan lot multiplier.

Default martingale:

```text
Lot Multiplier = 2.0
Max Grid Layer = 4
```

Contoh:

```text
Layer 1 = 0.10 lot
Layer 2 = 0.20 lot
Layer 3 = 0.40 lot
Layer 4 = 0.80 lot
```

Max Grid Layer membatasi jumlah total layer dalam satu basket, termasuk first entry, agar EA tidak terus menambah posisi tanpa batas.

## Konsep Jarak untuk XAU

Untuk XAU, aturan jarak seperti take profit, stop loss, grid, dan martingale sebaiknya menggunakan **price distance**, bukan langsung menggunakan point broker.

Alasannya, setiap broker bisa memiliki digit harga yang berbeda. Ada broker XAU 2 digit dan ada juga broker XAU 3 digit.

Contoh:

```text
Broker 2 digit:
XAUUSD = 2350.25
Point  = 0.01

Broker 3 digit:
XAUUSD = 2350.256
Point  = 0.001
```

Jika EA memakai nilai point mentah, maka jarak yang sama bisa menghasilkan arti berbeda di setiap broker.

Contoh jika grid diisi `1000 point`:

```text
Broker 2 digit:
1000 point x 0.01 = 10.00

Broker 3 digit:
1000 point x 0.001 = 1.00
```

Padahal secara konsep, grid yang diinginkan mungkin adalah jarak harga sebesar `8.00`.

Karena itu, input jarak EA lebih baik menggunakan jarak harga:

```text
Grid Distance = 8.00
```

Artinya, grid dibuka setiap jarak harga `8.00`.

Dengan cara ini, konsep strategi tetap sama di broker 2 digit maupun 3 digit. EA yang akan menyesuaikan nilai tersebut ke point broker secara otomatis.

Rumus konsepnya:

```text
points = price_distance / point_value
```

Contoh untuk grid distance `8.00`:

```text
Broker 2 digit:
point_value = 0.01
points      = 8.00 / 0.01
points      = 800

Broker 3 digit:
point_value = 0.001
points      = 8.00 / 0.001
points      = 8000
```

Nilai point broker berbeda, tetapi jarak harga XAU tetap sama, yaitu `8.00`.

## Martingale Grid Setelah First Entry

First entry tetap diambil dari sinyal utama, yaitu arah EMA dan crossing Stochastic. Namun, jika setelah first entry harga bergerak melawan arah posisi, EA dapat menggunakan martingale grid sebagai mekanisme recovery.

Martingale grid bukan sinyal entry utama. Fungsinya hanya aktif ketika posisi pertama sedang floating loss dan harga sudah bergerak sejauh grid distance.

Contoh untuk BUY:

```text
First BUY      = 2350.00
Grid Distance  = 8.00

Layer 1 BUY    = 2350.00
Layer 2 BUY    = 2342.00
Layer 3 BUY    = 2334.00
```

Jika harga turun dari first entry, EA membuka posisi BUY tambahan pada jarak grid berikutnya. Lot pada layer berikutnya dapat dibuat lebih besar menggunakan lot multiplier.

Contoh:

```text
Layer 1 = 0.10 lot
Layer 2 = 0.20 lot
Layer 3 = 0.40 lot
```

Tujuannya adalah memperbaiki average price, sehingga EA tidak harus menunggu harga kembali ke titik entry pertama untuk keluar profit. Semua posisi dalam rangkaian ini dihitung sebagai satu basket.

Untuk SELL, konsepnya sama tetapi arah grid berlawanan. Jika first entry SELL dan harga naik sejauh grid distance, EA membuka layer SELL berikutnya.

Aturan penting untuk martingale grid:

1. **Grid Distance** menentukan jarak harga antar layer.
2. **Lot Multiplier** menentukan pembesaran lot setiap layer.
3. **Max Grid Layer** membatasi jumlah total layer dalam satu basket, termasuk first entry.
4. **Basket TP Distance** menutup semua posisi ketika profit basket sudah setara dengan target jarak harga dari initial lot.
5. **Max Drawdown** membatasi kerugian maksimal agar EA tidak terus menambah posisi tanpa batas.

Layer berikutnya hanya boleh dibuka jika harga sudah melewati level grid berikutnya dan belum ada layer pada level tersebut. Aturan ini mencegah EA membuka layer dobel pada level harga yang sama.

## Basket Take Profit dan Close All

Take profit utama menggunakan target uang dinamis yang dihitung dari initial lot dan Basket TP Distance.

Default awal:

```text
Basket TP Distance = 1.00
XAU Money Per Price Unit = 100.00
```

Rumus target basket:

```text
Basket TP Money = Initial Lot x Money Per Price Unit Per Lot x Basket TP Distance
```

Untuk XAU, jika `Initial Lot = 0.10` dan `Basket TP Distance = 1.00`, target basket kira-kira menjadi `10.00 USD`.

Contoh target XAU untuk `Basket TP Distance = 1.00`:

```text
Initial Lot 0.01 = 1.00 USD
Initial Lot 0.10 = 10.00 USD
Initial Lot 1.00 = 100.00 USD
```

Target ini tetap memakai initial lot, bukan total lot basket. Jadi ketika layer martingale bertambah, target take profit tidak ikut membesar. Tujuannya agar basket lebih mudah keluar saat recovery.

Aturan close all:

1. EA hanya menutup posisi yang sesuai symbol dan magic number milik EA.
2. Jika basket BUY mencapai target, semua posisi BUY dalam basket ditutup.
3. Jika basket SELL mencapai target, semua posisi SELL dalam basket ditutup.
4. Setelah semua posisi basket close, EA boleh mencari first entry baru jika waktu dan filter lain mengizinkan.

Close all menggunakan **Close Lock**. Artinya, ketika Basket TP Distance atau Max Drawdown terkena, EA masuk mode khusus untuk menutup semua posisi dalam basket sampai benar-benar habis.

Default awal:

```text
Use Close Lock          = true
Use Priority Close Order = true
Use Async Close         = true
Close Deviation         = 0.30
Close Attempts Per Run  = 1
Close Lock Timer        = 300 ms
```

Priority close order berarti EA menutup posisi dengan lot terbesar lebih dulu. Jika lot sama, posisi dengan profit paling buruk ditutup lebih dulu. Tujuannya agar exposure basket berkurang lebih cepat saat proses close all berjalan.

Jika sebagian posisi gagal close karena requote, slippage, atau trade context, Close Lock akan tetap aktif dan EA akan mencoba menutup lagi pada tick atau timer berikutnya.

## Max Grid dan Max Drawdown

Jika jumlah layer sudah mencapai Max Grid Layer, EA tidak membuka layer tambahan lagi. Basket tetap dikelola sampai salah satu kondisi berikut terjadi:

1. Basket mencapai target profit dari Basket TP Distance, lalu semua posisi ditutup.
2. Floating loss basket mencapai Max Drawdown, lalu EA melakukan cut loss.

Max Drawdown dihitung berdasarkan floating loss per basket dalam nominal uang.

Default awal:

```text
Max Drawdown = 3000.00 USD
```

Jika floating loss basket menyentuh Max Drawdown, EA menutup semua posisi dalam basket tersebut dan masuk ke mode pause.

Setelah Max Drawdown terkena, ada dua pilihan perilaku:

1. **Stop and Resume Next Day**

   EA berhenti trading setelah cut loss dan otomatis aktif kembali pada hari trading berikutnya.

2. **Stop Until Manual Resume**

   EA berhenti trading setelah cut loss sampai user mengaktifkan kembali EA secara manual.

Dengan aturan ini, Max Drawdown menjadi batas cut loss utama untuk basket yang gagal recovery.

## Spread Filter dan TP Kecil

Karena EA ini dapat menggunakan Basket TP Distance kecil, misalnya sekitar `1.00`, spread broker harus diperhatikan. Pada XAU, spread bisa cukup besar dan dapat memakan sebagian target profit.

EA perlu memiliki **Max Spread Filter** agar tidak membuka posisi saat spread terlalu tinggi.

Default awal:

```text
Max Spread = 0.40
```

Nilai ini dibuat karena pada beberapa broker XAU, spread bisa berada di sekitar `0.30` sampai `0.35`. Jika spread sedang lebih besar dari `0.40`, EA sebaiknya tidak membuka entry baru.

Aturan sederhananya:

```text
Jika spread > Max Spread:
EA tidak membuka posisi baru
```

Spread juga perlu diperhatikan karena cara close posisi BUY dan SELL berbeda:

1. Posisi BUY dibuka di Ask dan ditutup di Bid.
2. Posisi SELL dibuka di Bid dan ditutup di Ask.

Artinya, walaupun harga di chart terlihat sudah bergerak mendekati target, profit bersih belum tentu cukup jika spread masih besar.

Untuk martingale grid, take profit dihitung dari profit aktual basket. Dengan cara ini, spread yang sedang berjalan ikut tercermin dalam floating profit sebelum EA melakukan close all.

## Magic Number

EA menggunakan magic number berbeda untuk membedakan posisi BUY dan SELL.

Default awal:

```text
Magic Number BUY  = 111111
Magic Number SELL = 222222
```

Magic number ini membantu EA hanya mengelola posisi miliknya sendiri dan tidak mengganggu posisi manual atau posisi dari EA lain.

## Slippage

Slippage adalah selisih antara harga yang diminta EA dan harga eksekusi yang diberikan broker. Pada XAU, slippage bisa terjadi saat market bergerak cepat.

Default awal:

```text
Max Slippage = 0.30
```

Nilai ini menggunakan price distance XAU. Artinya, EA masih menerima eksekusi jika selisih harga maksimal sekitar `0.30`. Jika slippage lebih besar dari nilai ini, order sebaiknya dibatalkan agar entry tidak terlalu jauh dari rencana.

## Manual Time Filter untuk First Entry

EA menggunakan filter waktu manual agar first entry hanya dibuka pada jam yang dianggap aman. Untuk versi awal, jadwal pause diatur langsung oleh user tanpa kalender news otomatis.

Time filter ini hanya berlaku untuk **first entry**. Jika sudah ada posisi atau basket yang berjalan, EA tetap mengelola posisi tersebut sampai selesai.

Time filter memiliki pilihan acuan waktu:

1. **WIB**
2. **Broker Time**
3. **UTC**

Default acuan waktu:

```text
Time Zone = WIB
```

Saat masuk jam pause, EA tidak membuka first entry baru. Namun, jika masih ada posisi atau basket yang belum close, EA tetap mengelola posisi tersebut sampai selesai.

Jika basket masih aktif saat jam pause:

1. EA tetap boleh membuka layer martingale grid sesuai aturan.
2. EA tetap boleh menutup basket jika target profit tercapai.
3. EA tetap wajib berhenti jika Max DD terkena.

Setelah semua posisi close, jika waktu masih berada dalam jam pause, EA baru masuk mode pause penuh dan menunggu jam aktif berikutnya.

Default jadwal pause:

```text
Pause Windows = 03:30-08:30;11:50-13:00;16:50-23:59
```

Pause Windows memakai format `HH:MM-HH:MM` dan dipisahkan dengan tanda `;`. Jika user ingin menambah jam pause, cukup tambahkan window baru di input tersebut.

Contoh:

```text
Pause Windows = 03:30-08:30;11:50-13:00;16:50-23:59;01:55-02:10
```

Jika Pause Windows dikosongkan, maka tidak ada jam pause yang digunakan walaupun Time Filter aktif.

Di luar jam pause tersebut, EA boleh mencari sinyal first entry selama semua filter lain terpenuhi.

## Sinyal BUY

Sinyal BUY muncul ketika tren sedang naik, lalu Stochastic sempat turun ke area oversold di bawah level 20.

Setelah itu, EA menunggu garis Main Stochastic memotong ke atas garis Signal. Entry hanya dicek saat candle baru terbentuk, sehingga crossing yang dipakai adalah crossing dari candle yang sudah tertutup.

Dengan cara ini, EA mencoba masuk saat harga mulai memantul kembali searah tren naik.

## Sinyal SELL

Sinyal SELL muncul ketika tren sedang turun, lalu Stochastic sempat naik ke area overbought di atas level 80.

Setelah itu, EA menunggu garis Main Stochastic memotong ke bawah garis Signal. Entry hanya dicek saat candle baru terbentuk, sehingga crossing yang dipakai adalah crossing dari candle yang sudah tertutup.

Dengan cara ini, EA mencoba masuk saat harga mulai turun kembali searah tren utama.

## Catatan

Logika ini membantu mengurangi entry yang terlalu cepat, karena EA tidak hanya melihat level Stochastic, tetapi juga menunggu crossing yang sudah terkonfirmasi.

Kelemahannya, sinyal bisa sedikit terlambat karena EA menunggu candle tertutup terlebih dahulu. Namun, konfirmasi ini dapat membantu menghindari sinyal palsu yang muncul saat candle masih berjalan.
