#!/usr/bin/env bash
#chmod +x start_mt5_all.sh
set -euo pipefail

WINEPREFIX_PATH="/home/admin/.wine/dosdevices/d:/.wine"
BASE_LNK_DIR="C:\\users\\admin\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs"
START_INDEX=1
END_INDEX=8

launch() {
  local idx="$1"
  local lnk_path="${BASE_LNK_DIR}\\MetaTrader 5-${idx}\\MetaTrader 5.lnk"
  env WINEPREFIX="${WINEPREFIX_PATH}" wine-stable "${lnk_path}" &
}

for i in $(seq "${START_INDEX}" "${END_INDEX}"); do
  launch "${i}"
  if [ "${i}" -lt "${END_INDEX}" ]; then
    sleep 15
  fi
done
