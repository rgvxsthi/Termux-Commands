#!/data/data/com.termux/files/usr/bin/bash

PREFIX="/data/data/com.termux/files/usr"
BOOT_DIR="$HOME/.termux/boot"
BOOT_SCRIPT="$BOOT_DIR/start-services.sh"
STOP_SCRIPT="$BOOT_DIR/stop-services.sh"
CONFIG_DIR="$HOME/.media-stack"
CONFIG_FILE="$CONFIG_DIR/config.env"

JELLYFIN_PORT="8096"
COPYPARTY_PORT="3923"

mkdir -p "$CONFIG_DIR"

if [ ! -f "$CONFIG_FILE" ]; then
  cat > "$CONFIG_FILE" <<EOF
COPYPARTY_USER=admin
COPYPARTY_PASS=password
COPYPARTY_VOLUME=/storage/emulated/0:/root:rwadm,admin
AUTOSTART_ENABLED=0
EOF
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

save_config() {
  cat > "$CONFIG_FILE" <<EOF
COPYPARTY_USER=$COPYPARTY_USER
COPYPARTY_PASS=$COPYPARTY_PASS
COPYPARTY_VOLUME=$COPYPARTY_VOLUME
AUTOSTART_ENABLED=$AUTOSTART_ENABLED
EOF
}

print_banner() {
  clear 2>/dev/null || true
  echo
  echo "===================================================="
  echo "     Jellyfin + Copyparty Termux Manager"
  echo "===================================================="
  echo
}

pause() {
  echo
  read -r -p "Press Enter to continue..."
}

get_ip() {
  MY_IP=$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')
  [ -z "$MY_IP" ] && MY_IP="127.0.0.1"
  echo "$MY_IP"
}

pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

pip_pkg_installed() {
  python -m pip show "$1" >/dev/null 2>&1
}

jellyfin_running() {
  pgrep -af "jellyfin" >/dev/null 2>&1
}

copyparty_running() {
  pgrep -af "python.*copyparty|copyparty" >/dev/null 2>&1
}

get_listening_port() {
  local pattern="$1"
  ss -ltnp 2>/dev/null | awk -v pat="$pattern" '
    $0 ~ pat {
      split($4, a, ":")
      print a[length(a)]
      exit
    }
  '
}

get_jellyfin_port() {
  PORT=$(get_listening_port "jellyfin")
  [ -z "$PORT" ] && PORT="$JELLYFIN_PORT"
  echo "$PORT"
}

get_copyparty_port() {
  PORT=$(get_listening_port "copyparty|python")
  [ -z "$PORT" ] && PORT="$COPYPARTY_PORT"
  echo "$PORT"
}

ensure_base_packages() {
  pkg update -y
  yes | pkg upgrade
  termux-setup-storage
  yes | pkg install \
    python \
    termux-api \
    ffmpeg \
    net-tools \
    iproute2 \
    procps \
    nano \
    curl
  python -m ensurepip --upgrade 2>/dev/null || true
  python -m pip install --user -U pip setuptools wheel
}

write_service_scripts() {
  mkdir -p "$BOOT_DIR"

  cat > "$BOOT_SCRIPT" <<EOF
#!/data/data/com.termux/files/usr/bin/bash

PREFIX="/data/data/com.termux/files/usr"
CONFIG_FILE="\$HOME/.media-stack/config.env"

[ -f "\$CONFIG_FILE" ] && . "\$CONFIG_FILE"

export PATH="\$HOME/.local/bin:\$PREFIX/bin:\$PATH"
export DOTNET_ROOT="\$PREFIX/lib/dotnet"
export PATH="\$DOTNET_ROOT:\$PATH"
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
export DOTNET_GCHeapHardLimit=500000000

command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock

pkill -9 -f jellyfin 2>/dev/null || true
pkill -9 -f "python.*copyparty|copyparty" 2>/dev/null || true
sleep 2

if dpkg -s jellyfin-server >/dev/null 2>&1; then
  nohup jellyfin --ffmpeg "\$(command -v ffmpeg)" >/dev/null 2>&1 &
fi

sleep 8

if python -m pip show copyparty >/dev/null 2>&1; then
  nohup python -m copyparty \
    -p $COPYPARTY_PORT \
    -v "\$COPYPARTY_VOLUME" \
    -a "\$COPYPARTY_USER:\$COPYPARTY_PASS" \
    -e2dsa \
    >/dev/null 2>&1 &
fi
EOF

  cat > "$STOP_SCRIPT" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
pkill -9 -f jellyfin 2>/dev/null || true
pkill -9 -f "python.*copyparty|copyparty" 2>/dev/null || true
EOF

  chmod +x "$BOOT_SCRIPT" "$STOP_SCRIPT"
}

show_status_header() {
  local IP
  local JF_PORT
  local CP_PORT

  IP=$(get_ip)

  echo "Current IP: $IP"
  echo

  if jellyfin_running; then
    JF_PORT=$(get_jellyfin_port)
    echo "Jellyfin:   RUNNING on port $JF_PORT"
  else
    echo "Jellyfin:   STOPPED"
  fi

  if copyparty_running; then
    CP_PORT=$(get_copyparty_port)
    echo "Copyparty:  RUNNING on port $CP_PORT"
  else
    echo "Copyparty:  STOPPED"
  fi

  if [ "$AUTOSTART_ENABLED" = "1" ]; then
    echo "Autostart:  ENABLED"
  else
    echo "Autostart:  DISABLED"
  fi

  echo
}

install_jellyfin() {
  print_banner
  echo "Installing Jellyfin..."
  echo

  ensure_base_packages
  yes | pkg install jellyfin-server dotnet9.0 dotnet-sdk-9.0

  write_service_scripts

  echo
  echo "Jellyfin installed successfully."
  pause
}

install_copyparty() {
  print_banner
  echo "Installing Copyparty..."
  echo

  ensure_base_packages
  python -m pip install --user -U copyparty pillow

  if ! grep -q 'PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
    echo 'PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
  fi

  write_service_scripts

  echo
  echo "Copyparty installed successfully."
  pause
}

update_jellyfin() {
  print_banner
  echo "Updating Jellyfin..."
  echo

  ensure_base_packages
  yes | pkg install jellyfin-server dotnet9.0 dotnet-sdk-9.0

  echo
  echo "Jellyfin updated."
  pause
}

update_copyparty() {
  print_banner
  echo "Updating Copyparty..."
  echo

  ensure_base_packages
  python -m pip install --user -U copyparty pillow

  echo
  echo "Copyparty updated."
  pause
}

uninstall_jellyfin() {
  print_banner
  read -r -p "Type REMOVE to uninstall Jellyfin: " confirm
  [ "$confirm" != "REMOVE" ] && return

  pkill -9 -f jellyfin 2>/dev/null || true
  yes | pkg uninstall jellyfin-server dotnet9.0 dotnet-sdk-9.0

  echo
  echo "Jellyfin removed."
  pause
}

uninstall_copyparty() {
  print_banner
  read -r -p "Type REMOVE to uninstall Copyparty: " confirm
  [ "$confirm" != "REMOVE" ] && return

  pkill -9 -f "python.*copyparty|copyparty" 2>/dev/null || true
  python -m pip uninstall -y copyparty pillow >/dev/null 2>&1 || true

  echo
  echo "Copyparty removed."
  pause
}

toggle_services() {
  print_banner

  if jellyfin_running || copyparty_running; then
    echo "Stopping running services..."
    bash "$STOP_SCRIPT" 2>/dev/null || true
    echo
    echo "Services stopped."
  else
    echo "Starting installed services..."
    write_service_scripts
    bash "$BOOT_SCRIPT"
    sleep 5
    echo
    echo "Services started."
  fi

  pause
}

enable_autostart() {
  print_banner

  mkdir -p "$BOOT_DIR"
  write_service_scripts

  AUTOSTART_ENABLED=1
  save_config

  echo
  echo "Autostart has been enabled."
  echo
  echo "For this to work after a phone reboot:"
  echo "1. Install Termux:Boot"
  echo "2. Open Termux:Boot once"
  echo
  echo "At boot, Termux:Boot will run:"
  echo "$BOOT_SCRIPT"

  pause
}

disable_autostart() {
  print_banner

  AUTOSTART_ENABLED=0
  save_config

  if [ -f "$BOOT_SCRIPT" ]; then
    rm -f "$BOOT_SCRIPT"
  fi

  echo
  echo "Autostart has been disabled."
  pause
}

configure_copyparty() {
  print_banner

  echo "Current Copyparty username: $COPYPARTY_USER"
  echo "Current Copyparty password: $COPYPARTY_PASS"
  echo "Current Copyparty volume:   $COPYPARTY_VOLUME"
  echo

  read -r -p "New username [leave blank to keep current]: " NEW_USER
  read -r -p "New password [leave blank to keep current]: " NEW_PASS
  read -r -p "New volume mapping [leave blank to keep current]: " NEW_VOL

  [ -n "$NEW_USER" ] && COPYPARTY_USER="$NEW_USER"
  [ -n "$NEW_PASS" ] && COPYPARTY_PASS="$NEW_PASS"
  [ -n "$NEW_VOL" ] && COPYPARTY_VOLUME="$NEW_VOL"

  save_config
  write_service_scripts

  echo
  echo "Copyparty configuration updated."
  pause
}

show_urls() {
  print_banner

  local IP
  IP=$(get_ip)

  echo "Current IP: $IP"
  echo

  if jellyfin_running; then
    echo "Jellyfin URL:   http://$IP:$(get_jellyfin_port)"
  else
    echo "Jellyfin URL:   not running"
  fi

  if copyparty_running; then
    echo "Copyparty URL:  http://$IP:$(get_copyparty_port)"
    echo "Login:          $COPYPARTY_USER / $COPYPARTY_PASS"
  else
    echo "Copyparty URL:  not running"
  fi

  pause
}

menu() {
  while true; do
    print_banner
    show_status_header

    echo "1) Start / Stop Services"
    echo "2) Show Current URLs"
    echo "3) Install Jellyfin"
    echo "4) Install Copyparty"
    echo "5) Update Jellyfin"
    echo "6) Update Copyparty"
    echo "7) Uninstall Jellyfin"
    echo "8) Uninstall Copyparty"
    echo "9) Configure Copyparty Login / Path"
    echo "10) Enable Background Autostart"
    echo "11) Disable Background Autostart"
    echo "12) Refresh Status"
    echo "13) Exit"
    echo

    read -r -p "Select option: " choice

    case "$choice" in
      1) toggle_services ;;
      2) show_urls ;;
      3) install_jellyfin ;;
      4) install_copyparty ;;
      5) update_jellyfin ;;
      6) update_copyparty ;;
      7) uninstall_jellyfin ;;
      8) uninstall_copyparty ;;
      9) configure_copyparty ;;
      10) enable_autostart ;;
      11) disable_autostart ;;
      12) ;;
      13) exit 0 ;;
      *) echo; echo "Invalid option."; pause ;;
    esac
  done
}

write_service_scripts
menu
