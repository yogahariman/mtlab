#!/usr/bin/env bash
#chmod +x start_mt5.sh
set -euo pipefail

WINEPREFIX_PATH="/home/admin/.wine/dosdevices/d:/.wine"
BASE_EXE_DIR="C:\\Program Files"
START_INDEX=1
END_INDEX=8

ensure_x11_env() {
  if [ -z "${DISPLAY:-}" ]; then
    for d in 0 1 2 3; do
      if [ -S "/tmp/.X11-unix/X${d}" ]; then
        export DISPLAY=":${d}"
        break
      fi
    done
  fi

  if [ -z "${XAUTHORITY:-}" ] && [ -f "${HOME}/.Xauthority" ]; then
    export XAUTHORITY="${HOME}/.Xauthority"
  fi
}

minimize_all() {
  ensure_x11_env

  if [ -z "${DISPLAY:-}" ]; then
    echo "minimize_all: DISPLAY tidak tersedia; jalankan dari session GUI/X11" >&2
    return 0
  fi

  if command -v wmctrl >/dev/null 2>&1; then
    wmctrl -k on || true
    return 0
  fi

  if command -v xdotool >/dev/null 2>&1; then
    xdotool search --onlyvisible --all . windowminimize || true
    return 0
  fi

  echo "minimize_all: xdotool/wmctrl not found" >&2
}

launch() {
  local idx="$1"
  local exe_path="${BASE_EXE_DIR}\\MetaTrader 5-${idx}\\terminal64.exe"
  env WINEPREFIX="${WINEPREFIX_PATH}" wine-stable "${exe_path}" /portable &
}

for i in $(seq "${START_INDEX}" "${END_INDEX}"); do
  launch "${i}"
  sleep 15
  minimize_all
  if [ "${i}" -lt "${END_INDEX}" ]; then
    sleep 1
  fi
done
