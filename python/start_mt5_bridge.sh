#!/bin/bash
#chmod +x start_mt5_bridge.sh

# 1. Tentukan Prefix tempat MetaTrader berada
export WINEPREFIX="/home/rfi212/.mt5"

# 2. Path lengkap ke python.exe yang ada di folder .wine
# Kita gunakan path Windows-nya (biasanya C: merujuk ke drive_c di prefix aktif)
# Tapi karena beda prefix, kita panggil executable-nya langsung:
PYTHON_WINE="/home/rfi212/.wine/drive_c/users/rfi212/AppData/Local/Programs/Python/Python314/python.exe"

echo "Memulai MT5 Bridge Server pada port 18812..."
wine "$PYTHON_WINE" -m mt5linux


