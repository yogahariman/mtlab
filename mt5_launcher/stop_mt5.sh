#!/usr/bin/env bash
set -euo pipefail

WINEPREFIX_PATH="/home/admin/.wine/dosdevices/d:/.wine"

export WINEPREFIX="${WINEPREFIX_PATH}"

if ! command -v wine-stable >/dev/null 2>&1; then
  echo "stop_mt5: wine-stable tidak ditemukan" >&2
  exit 1
fi

echo "Menutup semua instance MetaTrader 5..."

# Minta MT5 berhenti secara normal terlebih dahulu.
wine-stable taskkill /IM terminal64.exe /T >/dev/null 2>&1 || true

for _ in $(seq 1 15); do
  if ! pgrep -af 'terminal64\.exe' >/dev/null 2>&1; then
    echo "MetaTrader 5 sudah berhenti."
    exit 0
  fi
  sleep 1
done

# Jika masih ada yang menggantung, hentikan proses MT5 saja.
echo "Sebagian instance belum berhenti; menghentikan proses yang tersisa..."
pkill -f 'terminal64\.exe' >/dev/null 2>&1 || true

sleep 2
if pgrep -af 'terminal64\.exe' >/dev/null 2>&1; then
  echo "Gagal menghentikan semua proses terminal64.exe" >&2
  exit 1
fi

echo "Semua instance MetaTrader 5 sudah berhenti."
