# Setup MT5 Linux Bridge untuk VS Code

Panduan ini dipakai agar script Python di Linux/VS Code bisa mengakses MetaTrader 5 yang berjalan lewat Wine dengan import:

```python
from mt5linux import MetaTrader5
```

Arsitekturnya:

- Python Windows di dalam Wine menjalankan bridge `mt5linux`.
- Python Linux yang dipakai VS Code menghubungi bridge tersebut lewat `rpyc`.
- Script Python tetap dijalankan dari VS Code/Linux.

## Quick Start

Kalau semua komponen sudah pernah diinstall, biasanya cukup:

```bash
cd /Drive/D/mtlab
chmod +x python/start_mt5_bridge.sh
./python/start_mt5_bridge.sh
```

Lalu di terminal VS Code lain:

```bash
python python/FrameworkDataFeaturesPrototypes/Scripts/Integration/load_data.py
```

Bridge harus dibiarkan tetap menyala selama script Python membutuhkan koneksi ke MT5.

## 1. Prasyarat

Pastikan sudah ada:

- Wine
- MetaTrader 5 terinstall di Wine prefix, contoh: `/home/rfi212/.mt5`
- Python Windows terinstall di Wine
- Python Linux/venv untuk VS Code

Contoh path MT5 yang dipakai di script:

```text
/home/rfi212/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe
```

Path penting yang perlu dicek di mesin ini:

```text
Wine prefix MT5 : /home/rfi212/.mt5
MT5 terminal    : /home/rfi212/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe
Bridge script   : /Drive/D/mtlab/python/start_mt5_bridge.sh
```

## 2. Install Python Windows di Wine

Download installer Python Windows, lalu jalankan lewat Wine:

```bash
wine Downloads/python-3.14.5rc1-amd64.exe
```

Catatan:

- Install Python Windows di prefix Wine yang sama dengan MT5 kalau memungkinkan.
- Centang opsi `Add python.exe to PATH` jika tersedia.
- Jika memakai prefix khusus MT5, jalankan dengan `WINEPREFIX`.

Contoh:

```bash
export WINEPREFIX="/home/rfi212/.mt5"
wine Downloads/python-3.14.5rc1-amd64.exe
```

## 3. Install Package di Python Windows/Wine

Package ini dipakai oleh bridge yang berjalan di Wine:

```bash
export WINEPREFIX="/home/rfi212/.mt5"
wine python -m pip install MetaTrader5 rpyc mt5linux
```

Jika `wine python` belum mengarah ke Python yang benar, panggil `python.exe` langsung. Contoh:

```bash
export WINEPREFIX="/home/rfi212/.mt5"
wine "/home/rfi212/.mt5/drive_c/users/rfi212/AppData/Local/Programs/Python/Python314/python.exe" -m pip install MetaTrader5 rpyc mt5linux
```

Sesuaikan path `Python314` dengan versi Python yang terinstall.

## 4. Install Package di Python Linux/VS Code

Di terminal Linux atau terminal VS Code, install package client:

```bash
pip install rpyc mt5linux
```

Jika memakai virtual environment:

```bash
python -m venv .venv
source .venv/bin/activate
pip install rpyc mt5linux pandas numpy pytz seaborn matplotlib ta
```

Di VS Code, pilih interpreter dari venv tersebut:

1. Buka Command Palette.
2. Pilih `Python: Select Interpreter`.
3. Pilih interpreter dari `.venv`.

## 5. Jalankan MT5 Bridge

Repository ini sudah punya script:

```bash
python/start_mt5_bridge.sh
```

Pastikan executable:

```bash
chmod +x python/start_mt5_bridge.sh
```

Jalankan bridge:

```bash
./python/start_mt5_bridge.sh
```

Isi script saat ini memakai:

```bash
export WINEPREFIX="/home/rfi212/.mt5"
PYTHON_WINE="/home/rfi212/.wine/drive_c/users/rfi212/AppData/Local/Programs/Python/Python314/python.exe"
wine "$PYTHON_WINE" -m mt5linux
```

Jika Python Windows dipasang di prefix `.mt5`, ubah `PYTHON_WINE` menjadi path di dalam `.mt5`, misalnya:

```bash
PYTHON_WINE="/home/rfi212/.mt5/drive_c/users/rfi212/AppData/Local/Programs/Python/Python314/python.exe"
```

Cara cepat mencari lokasi `python.exe` di prefix MT5:

```bash
find /home/rfi212/.mt5/drive_c -iname python.exe
```

Bridge harus tetap berjalan selama script Python di VS Code memakai MT5.

## 6. Test dari VS Code

Buat atau jalankan script Python Linux dengan contoh minimal:

```python
from mt5linux import MetaTrader5

mt5 = MetaTrader5()

mt5_path = "/home/rfi212/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe"

if not mt5.initialize(path=mt5_path):
    print("Initialize gagal:", mt5.last_error())
else:
    print("Koneksi MT5 berhasil")
    print(mt5.terminal_info())
    mt5.shutdown()
```

Script yang sudah memakai pola ini:

```text
python/FrameworkDataFeaturesPrototypes/Scripts/Integration/load_data.py
```

## 7. Troubleshooting

Jika muncul error import:

```text
ModuleNotFoundError: No module named 'mt5linux'
```

Berarti package belum terinstall di interpreter Linux yang dipilih VS Code. Jalankan:

```bash
pip install rpyc mt5linux
```

Jika bridge tidak tersambung:

- Pastikan `./python/start_mt5_bridge.sh` sedang berjalan.
- Pastikan package `MetaTrader5`, `rpyc`, dan `mt5linux` sudah terinstall di Python Windows/Wine.
- Pastikan `WINEPREFIX` mengarah ke prefix yang berisi MT5.
- Pastikan path `terminal64.exe` benar.

Jika `mt5.initialize()` gagal:

- Buka MT5 lewat Wine dulu dan pastikan terminal bisa login.
- Cek symbol broker, misalnya `EURUSD_i` bisa berbeda di tiap broker.
- Cek output `mt5.last_error()`.
