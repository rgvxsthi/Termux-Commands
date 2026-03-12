#!/data/data/com.termux/files/usr/bin/bash

PREFIX="/data/data/com.termux/files/usr"
BOOT_DIR="$HOME/.termux/boot"
BOOT_SCRIPT="$BOOT_DIR/start-services.sh"
STOP_SCRIPT="$BOOT_DIR/stop-services.sh"
CONFIG_DIR="$HOME/.media-stack"
CONFIG_FILE="$CONFIG_DIR/config.env"

DEFAULT_JELLYFIN_PORT="8096"
DEFAULT_COPYPARTY_PORT="3923"

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

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

print_banner() {
  clear 2>/dev/null || true
  echo
  echo -e "${CYAN}====================================================${NC}"
  echo -e "${YELLOW}        Jellyfin + Copyparty Termux Manager${NC}"
  echo -e "${CYAN}====================================================${NC}"
  echo
}

pause() {
  echo
  read -r -p "$(echo -e "${MAGENTA}Press Enter to continue...${NC}")" _
}

info() {
  echo -e "${BLUE}$1${NC}"
}

success() {
  echo -e "${GREEN}$1${NC}"
}

warn() {
  echo -e "${YELLOW}$1${NC}"
}

error_msg() {
  echo -e "${RED}$1${NC}"
}

get_ip() {
  MY_IP=$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')
  [ -z "$MY_IP" ] && MY_IP="127.0.0.1"
  echo "$MY_IP"
}

pkg_installed() {
  dpkg-query -W -f='${db:Status-Status}\n' "$1" 2>/dev/null | grep -qx installed
}

pip_pkg_installed() {
  python -m pip show "$1" >/dev/null 2>&1
}

get_port_by_match() {
  local match="$1"
  ss -ltnp 2>/dev/null | awk -v pat="$match" '
    $1 == "LISTEN" && $0 ~ pat {
      n=split($4, a, ":")
      print a[n]
      exit
    }
  '
}

get_jellyfin_port() {
  get_port_by_match "jellyfin"
}

get_copyparty_port() {
  get_port_by_match "copyparty|python"
}

jellyfin_running() {
  [ -n "$(get_jellyfin_port)" ]
}

copyparty_running() {
  [ -n "$(get_copyparty_port)" ]
}

jellyfin_installed() {
  pkg_installed jellyfin-server
}

copyparty_installed() {
  pip_pkg_installed copyparty
}

ensure_path_local_bin() {
  if ! grep -q 'PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
    echo 'PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
  fi
}

ensure_base_packages() {
  info "Updating packages and installing prerequisites..."
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
  ensure_path_local_bin
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

pkill -9 -f '/usr/lib/jellyfin/jellyfin' 2>/dev/null || true
pkill -9 -f 'python.*copyparty|copyparty' 2>/dev/null || true
sleep 2

if dpkg-query -W -f='\\\${db:Status-Status}\\n' jellyfin-server 2>/dev/null | grep -qx installed; then
  nohup jellyfin --ffmpeg "\$(command -v ffmpeg)" >/dev/null 2>&1 &
fi

sleep 8

if python -m pip show copyparty >/dev/null 2>&1; then
  nohup python -m copyparty \
    -p $DEFAULT_COPYPARTY_PORT \
    -v "\$COPYPARTY_VOLUME" \
    -a "\$COPYPARTY_USER:\$COPYPARTY_PASS" \
    -e2dsa \
    >/dev/null 2>&1 &
fi
EOF

  cat > "$STOP_SCRIPT" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
pkill -9 -f '/usr/lib/jellyfin/jellyfin' 2>/dev/null || true
pkill -9 -f 'python.*copyparty|copyparty' 2>/dev/null || true
sleep 1
EOF

  chmod +x "$BOOT_SCRIPT" "$STOP_SCRIPT"
}

stop_all_services() {
  if [ -f "$STOP_SCRIPT" ]; then
    bash "$STOP_SCRIPT" >/dev/null 2>&1 || true
  else
    pkill -9 -f '/usr/lib/jellyfin/jellyfin' 2>/dev/null || true
    pkill -9 -f 'python.*copyparty|copyparty' 2>/dev/null || true
    sleep 1
  fi
}

start_installed_services() {
  write_service_scripts
  bash "$BOOT_SCRIPT"
  sleep 5
}

show_main_status() {
  local IP JF_PORT CP_PORT
  IP=$(get_ip)
  JF_PORT=$(get_jellyfin_port)
  CP_PORT=$(get_copyparty_port)

  echo -e "${WHITE}Current IP:${NC} ${GREEN}$IP${NC}"
  echo

  if jellyfin_installed; then
    if [ -n "$JF_PORT" ]; then
      echo -e "${WHITE}Jellyfin:${NC}   ${GREEN}RUNNING${NC} on port ${YELLOW}$JF_PORT${NC}"
      echo -e "${WHITE}           URL:${NC} ${CYAN}http://$IP:$JF_PORT${NC}"
    else
      echo -e "${WHITE}Jellyfin:${NC}   ${YELLOW}INSTALLED${NC} but ${RED}STOPPED${NC}"
    fi
  else
    echo -e "${WHITE}Jellyfin:${NC}   ${DIM}NOT INSTALLED${NC}"
  fi

  echo

  if copyparty_installed; then
    if [ -n "$CP_PORT" ]; then
      echo -e "${WHITE}Copyparty:${NC}  ${GREEN}RUNNING${NC} on port ${YELLOW}$CP_PORT${NC}"
      echo -e "${WHITE}           URL:${NC} ${CYAN}http://$IP:$CP_PORT${NC}"
      echo -e "${WHITE}         Login:${NC} ${YELLOW}$COPYPARTY_USER / $COPYPARTY_PASS${NC}"
    else
      echo -e "${WHITE}Copyparty:${NC}  ${YELLOW}INSTALLED${NC} but ${RED}STOPPED${NC}"
    fi
  else
    echo -e "${WHITE}Copyparty:${NC}  ${DIM}NOT INSTALLED${NC}"
  fi

  echo

  if [ "$AUTOSTART_ENABLED" = "1" ]; then
    echo -e "${WHITE}Background Autostart:${NC} ${GREEN}ENABLED${NC}"
  else
    echo -e "${WHITE}Background Autostart:${NC} ${RED}DISABLED${NC}"
  fi

  echo
}

show_jellyfin_status() {
  local IP JF_PORT
  IP=$(get_ip)
  JF_PORT=$(get_jellyfin_port)

  echo -e "${CYAN}---------------- Jellyfin Status ----------------${NC}"
  if jellyfin_installed; then
    echo -e "${WHITE}Installed:${NC} ${GREEN}Yes${NC}"
    if [ -n "$JF_PORT" ]; then
      echo -e "${WHITE}Running:${NC}   ${GREEN}Yes${NC}"
      echo -e "${WHITE}Port:${NC}      ${YELLOW}$JF_PORT${NC}"
      echo -e "${WHITE}URL:${NC}       ${CYAN}http://$IP:$JF_PORT${NC}"
    else
      echo -e "${WHITE}Running:${NC}   ${RED}No${NC}"
      echo -e "${WHITE}Port:${NC}      ${DIM}N/A${NC}"
      echo -e "${WHITE}URL:${NC}       ${DIM}N/A${NC}"
    fi
  else
    echo -e "${WHITE}Installed:${NC} ${RED}No${NC}"
    echo -e "${WHITE}Running:${NC}   ${DIM}N/A${NC}"
    echo -e "${WHITE}Port:${NC}      ${DIM}N/A${NC}"
    echo -e "${WHITE}URL:${NC}       ${DIM}N/A${NC}"
  fi
  echo
}

show_copyparty_status() {
  local IP CP_PORT
  IP=$(get_ip)
  CP_PORT=$(get_copyparty_port)

  echo -e "${CYAN}--------------- Copyparty Status ----------------${NC}"
  if copyparty_installed; then
    echo -e "${WHITE}Installed:${NC} ${GREEN}Yes${NC}"
    if [ -n "$CP_PORT" ]; then
      echo -e "${WHITE}Running:${NC}   ${GREEN}Yes${NC}"
      echo -e "${WHITE}Port:${NC}      ${YELLOW}$CP_PORT${NC}"
      echo -e "${WHITE}URL:${NC}       ${CYAN}http://$IP:$CP_PORT${NC}"
      echo -e "${WHITE}Login:${NC}     ${YELLOW}$COPYPARTY_USER / $COPYPARTY_PASS${NC}"
    else
      echo -e "${WHITE}Running:${NC}   ${RED}No${NC}"
      echo -e "${WHITE}Port:${NC}      ${DIM}N/A${NC}"
      echo -e "${WHITE}URL:${NC}       ${DIM}N/A${NC}"
      echo -e "${WHITE}Login:${NC}     ${YELLOW}$COPYPARTY_USER / $COPYPARTY_PASS${NC}"
    fi
  else
    echo -e "${WHITE}Installed:${NC} ${RED}No${NC}"
    echo -e "${WHITE}Running:${NC}   ${DIM}N/A${NC}"
    echo -e "${WHITE}Port:${NC}      ${DIM}N/A${NC}"
    echo -e "${WHITE}URL:${NC}       ${DIM}N/A${NC}"
  fi
  echo
}

install_jellyfin() {
  print_banner
  show_jellyfin_status
  info "Installing Jellyfin..."
  echo

  ensure_base_packages
  yes | pkg install jellyfin-server dotnet9.0 dotnet-sdk-9.0
  write_service_scripts

  echo
  success "Jellyfin installed successfully."
  warn "It is installed but may not be running yet."
  warn "Use the start option in the Jellyfin submenu if you want to launch it now."
  pause
}

update_jellyfin() {
  print_banner
  show_jellyfin_status

  if ! jellyfin_installed; then
    error_msg "Jellyfin is not installed."
    warn "Go back and choose Install Jellyfin first."
    pause
    return
  fi

  info "Updating Jellyfin..."
  echo
  ensure_base_packages
  yes | pkg install jellyfin-server dotnet9.0 dotnet-sdk-9.0

  echo
  success "Jellyfin updated."
  warn "If something looks broken, you can use Restart Jellyfin from this submenu."
  pause
}

start_jellyfin() {
  print_banner
  show_jellyfin_status

  if ! jellyfin_installed; then
    error_msg "Jellyfin is not installed."
    warn "Use Install Jellyfin first."
    pause
    return
  fi

  info "Starting Jellyfin..."
  pkill -9 -f '/usr/lib/jellyfin/jellyfin' 2>/dev/null || true
  sleep 1

  export PATH="$HOME/.local/bin:$PREFIX/bin:$PATH"
  export DOTNET_ROOT="$PREFIX/lib/dotnet"
  export PATH="$DOTNET_ROOT:$PATH"
  export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
  nohup jellyfin --ffmpeg "$(command -v ffmpeg)" >/dev/null 2>&1 &
  sleep 5

  print_banner
  show_jellyfin_status
  if jellyfin_running; then
    success "Jellyfin started successfully."
  else
    error_msg "Jellyfin did not start."
    warn "A common cause is a stale old process or port conflict."
    warn "Try Restart Jellyfin or uninstall and reinstall from this submenu."
  fi
  pause
}

stop_jellyfin() {
  print_banner
  show_jellyfin_status

  if ! jellyfin_installed; then
    error_msg "Jellyfin is not installed."
    pause
    return
  fi

  info "Stopping Jellyfin..."
  pkill -9 -f '/usr/lib/jellyfin/jellyfin' 2>/dev/null || true
  sleep 2

  print_banner
  show_jellyfin_status
  success "Jellyfin stop command completed."
  warn "If it still appears running, wait 2 to 3 seconds and refresh again."
  pause
}

restart_jellyfin() {
  print_banner
  show_jellyfin_status

  if ! jellyfin_installed; then
    error_msg "Jellyfin is not installed."
    pause
    return
  fi

  info "Restarting Jellyfin..."
  pkill -9 -f '/usr/lib/jellyfin/jellyfin' 2>/dev/null || true
  sleep 2

  export PATH="$HOME/.local/bin:$PREFIX/bin:$PATH"
  export DOTNET_ROOT="$PREFIX/lib/dotnet"
  export PATH="$DOTNET_ROOT:$PATH"
  export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
  nohup jellyfin --ffmpeg "$(command -v ffmpeg)" >/dev/null 2>&1 &
  sleep 5

  print_banner
  show_jellyfin_status
  if jellyfin_running; then
    success "Jellyfin restarted successfully."
  else
    error_msg "Jellyfin restart appears to have failed."
    warn "You can still uninstall and reinstall from this submenu if needed."
  fi
  pause
}

uninstall_jellyfin() {
  print_banner
  show_jellyfin_status

  if ! jellyfin_installed; then
    warn "Jellyfin is already not installed."
    pause
    return
  fi

  echo -e "${YELLOW}This removes Jellyfin and its .NET runtime packages used by this setup.${NC}"
  echo -e "${YELLOW}You can reinstall later from the Jellyfin submenu.${NC}"
  echo
  read -r -p "$(echo -e "${MAGENTA}Type REMOVE to uninstall Jellyfin: ${NC}")" confirm
  [ "$confirm" != "REMOVE" ] && { warn "Cancelled."; pause; return; }

  info "Stopping Jellyfin..."
  pkill -9 -f '/usr/lib/jellyfin/jellyfin' 2>/dev/null || true
  sleep 2

  info "Uninstalling Jellyfin..."
  yes | pkg uninstall jellyfin-server dotnet9.0 dotnet-sdk-9.0 >/dev/null 2>&1 || true
  yes | pkg autoremove >/dev/null 2>&1 || true
  hash -r
  sleep 2

  print_banner
  show_jellyfin_status
  success "Jellyfin uninstall complete."
  warn "You can reinstall it anytime from the Jellyfin submenu."
  pause
}

configure_jellyfin() {
  print_banner
  show_jellyfin_status
  echo -e "${CYAN}--------------- Jellyfin Settings -----------------${NC}"
  echo -e "${WHITE}FFmpeg binary:${NC} ${YELLOW}$(command -v ffmpeg 2>/dev/null || echo not-found)${NC}"
  echo -e "${WHITE}DOTNET_ROOT:${NC}  ${YELLOW}$PREFIX/lib/dotnet${NC}"
  echo
  warn "Jellyfin port changes are not exposed in this script yet."
  warn "It currently uses Jellyfin's default port unless you manually reconfigure Jellyfin."
  warn "Safe revert path: uninstall Jellyfin here, then reinstall it cleanly."
  pause
}

install_copyparty() {
  print_banner
  show_copyparty_status
  info "Installing Copyparty..."
  echo

  ensure_base_packages
  python -m pip install --user -U copyparty pillow
  write_service_scripts

  echo
  success "Copyparty installed successfully."
  warn "It is installed but may not be running yet."
  warn "Use the start option in the Copyparty submenu if you want to launch it now."
  pause
}

update_copyparty() {
  print_banner
  show_copyparty_status

  if ! copyparty_installed; then
    error_msg "Copyparty is not installed."
    warn "Go back and choose Install Copyparty first."
    pause
    return
  fi

  info "Updating Copyparty..."
  echo
  ensure_base_packages
  python -m pip install --user -U copyparty pillow

  echo
  success "Copyparty updated."
  warn "If something looks wrong, use Restart Copyparty from this submenu."
  pause
}

start_copyparty() {
  print_banner
  show_copyparty_status

  if ! copyparty_installed; then
    error_msg "Copyparty is not installed."
    warn "Use Install Copyparty first."
    pause
    return
  fi

  info "Starting Copyparty..."
  pkill -9 -f 'python.*copyparty|copyparty' 2>/dev/null || true
  sleep 2

  export PATH="$HOME/.local/bin:$PREFIX/bin:$PATH"
  nohup python -m copyparty \
    -p "$DEFAULT_COPYPARTY_PORT" \
    -v "$COPYPARTY_VOLUME" \
    -a "$COPYPARTY_USER:$COPYPARTY_PASS" \
    -e2dsa \
    >/dev/null 2>&1 &
  sleep 5

  print_banner
  show_copyparty_status
  if copyparty_running; then
    success "Copyparty started successfully."
  else
    error_msg "Copyparty did not start."
    warn "Try Restart Copyparty. If needed, uninstall and reinstall from this submenu."
  fi
  pause
}

stop_copyparty() {
  print_banner
  show_copyparty_status

  if ! copyparty_installed; then
    error_msg "Copyparty is not installed."
    pause
    return
  fi

  info "Stopping Copyparty..."
  pkill -9 -f 'python.*copyparty|copyparty' 2>/dev/null || true
  sleep 2

  print_banner
  show_copyparty_status
  success "Copyparty stop command completed."
  warn "If it still appears running, wait 2 to 3 seconds and refresh again."
  pause
}

restart_copyparty() {
  print_banner
  show_copyparty_status

  if ! copyparty_installed; then
    error_msg "Copyparty is not installed."
    pause
    return
  fi

  info "Restarting Copyparty..."
  pkill -9 -f 'python.*copyparty|copyparty' 2>/dev/null || true
  sleep 2

  export PATH="$HOME/.local/bin:$PREFIX/bin:$PATH"
  nohup python -m copyparty \
    -p "$DEFAULT_COPYPARTY_PORT" \
    -v "$COPYPARTY_VOLUME" \
    -a "$COPYPARTY_USER:$COPYPARTY_PASS" \
    -e2dsa \
    >/dev/null 2>&1 &
  sleep 5

  print_banner
  show_copyparty_status
  if copyparty_running; then
    success "Copyparty restarted successfully."
  else
    error_msg "Copyparty restart appears to have failed."
    warn "You can still uninstall and reinstall from this submenu if needed."
  fi
  pause
}

uninstall_copyparty() {
  print_banner
  show_copyparty_status

  if ! copyparty_installed; then
    warn "Copyparty is already not installed."
    pause
    return
  fi

  echo -e "${YELLOW}This removes Copyparty and Pillow installed by this setup.${NC}"
  echo -e "${YELLOW}Your media files themselves are not deleted.${NC}"
  echo
  read -r -p "$(echo -e "${MAGENTA}Type REMOVE to uninstall Copyparty: ${NC}")" confirm
  [ "$confirm" != "REMOVE" ] && { warn "Cancelled."; pause; return; }

  info "Stopping Copyparty..."
  pkill -9 -f 'python.*copyparty|copyparty' 2>/dev/null || true
  sleep 2

  info "Uninstalling Copyparty..."
  python -m pip uninstall -y copyparty pillow >/dev/null 2>&1 || true
  hash -r
  sleep 2

  print_banner
  show_copyparty_status
  success "Copyparty uninstall complete."
  warn "You can reinstall it anytime from the Copyparty submenu."
  pause
}

configure_copyparty() {
  print_banner
  show_copyparty_status

  echo -e "${CYAN}-------------- Copyparty Settings -----------------${NC}"
  echo -e "${WHITE}Current username:${NC} ${YELLOW}$COPYPARTY_USER${NC}"
  echo -e "${WHITE}Current password:${NC} ${YELLOW}$COPYPARTY_PASS${NC}"
  echo -e "${WHITE}Current volume:${NC}   ${YELLOW}$COPYPARTY_VOLUME${NC}"
  echo
  warn "Changing settings here does not delete files."
  warn "If you enter something wrong, reopen this screen and fix it."
  warn "For a full reset, uninstall and reinstall Copyparty from this submenu."
  echo

  read -r -p "$(echo -e "${MAGENTA}New username [blank keeps current]: ${NC}")" NEW_USER
  read -r -p "$(echo -e "${MAGENTA}New password [blank keeps current]: ${NC}")" NEW_PASS
  read -r -p "$(echo -e "${MAGENTA}New volume mapping [blank keeps current]: ${NC}")" NEW_VOL

  [ -n "$NEW_USER" ] && COPYPARTY_USER="$NEW_USER"
  [ -n "$NEW_PASS" ] && COPYPARTY_PASS="$NEW_PASS"
  [ -n "$NEW_VOL" ] && COPYPARTY_VOLUME="$NEW_VOL"

  save_config
  write_service_scripts

  echo
  success "Copyparty settings saved."
  warn "Restart Copyparty from this submenu for changes to fully apply."
  pause
}

enable_background_autostart() {
  print_banner
  echo -e "${CYAN}----------- Background Autostart Settings ---------${NC}"
  echo
  warn "This enables background startup using Termux:Boot."
  warn "Required steps:"
  echo -e "${WHITE}1.${NC} Install ${CYAN}Termux:Boot${NC}"
  echo -e "${WHITE}2.${NC} Open ${CYAN}Termux:Boot${NC} once"
  echo
  read -r -p "$(echo -e "${MAGENTA}Type ENABLE to continue: ${NC}")" confirm
  [ "$confirm" != "ENABLE" ] && { warn "Cancelled."; pause; return; }

  write_service_scripts
  AUTOSTART_ENABLED=1
  save_config

  echo
  success "Background autostart enabled."
  echo -e "${WHITE}Boot script path:${NC} ${CYAN}$BOOT_SCRIPT${NC}"
  warn "Revert path: open this submenu again and choose Disable Background Autostart."
  pause
}

disable_background_autostart() {
  print_banner
  echo -e "${CYAN}----------- Background Autostart Settings ---------${NC}"
  echo
  warn "This disables boot-time background startup."
  warn "Your services can still be started manually anytime."
  echo
  read -r -p "$(echo -e "${MAGENTA}Type DISABLE to continue: ${NC}")" confirm
  [ "$confirm" != "DISABLE" ] && { warn "Cancelled."; pause; return; }

  AUTOSTART_ENABLED=0
  save_config

  if [ -f "$BOOT_SCRIPT" ]; then
    rm -f "$BOOT_SCRIPT"
  fi

  echo
  success "Background autostart disabled."
  warn "Revert path: come back here and enable it again."
  pause
}

restart_all_services() {
  print_banner
  show_main_status

  warn "This restarts all installed services managed by this script."
  warn "Useful if status looks stale or after changing settings."
  echo
  read -r -p "$(echo -e "${MAGENTA}Type RESTART to continue: ${NC}")" confirm
  [ "$confirm" != "RESTART" ] && { warn "Cancelled."; pause; return; }

  stop_all_services
  start_installed_services

  print_banner
  show_main_status
  success "Installed services restarted."
  pause
}

toggle_main_services() {
  print_banner
  show_main_status

  if jellyfin_running || copyparty_running; then
    warn "One or more services are currently running."
    read -r -p "$(echo -e "${MAGENTA}Type STOP to stop all running services: ${NC}")" confirm
    [ "$confirm" != "STOP" ] && { warn "Cancelled."; pause; return; }
    stop_all_services

    print_banner
    show_main_status
    success "Running services stopped."
    warn "Revert path: use Start/Stop Services again to start installed services."
  else
    warn "No managed services are currently running."
    read -r -p "$(echo -e "${MAGENTA}Type START to launch all installed services: ${NC}")" confirm
    [ "$confirm" != "START" ] && { warn "Cancelled."; pause; return; }

    if ! jellyfin_installed && ! copyparty_installed; then
      error_msg "Neither Jellyfin nor Copyparty is installed."
      warn "Install at least one service first."
      pause
      return
    fi

    start_installed_services

    print_banner
    show_main_status
    success "Installed services started."
    warn "Revert path: use this same option again to stop them."
  fi

  pause
}

clean_uninstall_all() {
  print_banner
  show_main_status

  error_msg "This will remove Jellyfin, Copyparty, related packages, config, and boot scripts."
  warn "Your actual media files are not deleted by this script."
  warn "Helper packages like ffmpeg, curl, net-tools, termux-api, iproute2, procps, and nano will also be removed."
  warn "Revert path: rerun this script later and reinstall what you need."
  echo

  read -r -p "$(echo -e "${MAGENTA}Type REMOVEALL to continue: ${NC}")" confirm
  [ "$confirm" != "REMOVEALL" ] && { warn "Cancelled."; pause; return; }

  info "Stopping all services..."
  stop_all_services
  sleep 2

  info "Removing Copyparty packages..."
  python -m pip uninstall -y copyparty pillow >/dev/null 2>&1 || true

  info "Removing Jellyfin and .NET packages..."
  yes | pkg uninstall jellyfin-server dotnet9.0 dotnet-sdk-9.0 ffmpeg >/dev/null 2>&1 || true
  yes | pkg autoremove >/dev/null 2>&1 || true
  hash -r

  info "Removing helper packages installed by this setup..."
  yes | pkg uninstall termux-api net-tools iproute2 procps nano curl >/dev/null 2>&1 || true

  info "Removing config and boot files..."
  rm -f "$BOOT_SCRIPT" "$STOP_SCRIPT"
  rm -rf "$CONFIG_DIR"

  echo
  success "Clean uninstall complete."
  warn "To revert, rerun this GitHub script and reinstall from the menus."
  pause
}

jellyfin_menu() {
  while true; do
    print_banner
    show_jellyfin_status
    echo -e "${CYAN}1)${NC} Install Jellyfin"
    echo -e "${CYAN}2)${NC} Start Jellyfin"
    echo -e "${CYAN}3)${NC} Stop Jellyfin"
    echo -e "${CYAN}4)${NC} Restart Jellyfin"
    echo -e "${CYAN}5)${NC} Update Jellyfin"
    echo -e "${CYAN}6)${NC} Jellyfin Settings"
    echo -e "${CYAN}7)${NC} Uninstall Jellyfin"
    echo -e "${CYAN}8)${NC} Back"
    echo
    read -r -p "$(echo -e "${MAGENTA}Select option: ${NC}")" choice

    case "$choice" in
      1) install_jellyfin ;;
      2) start_jellyfin ;;
      3) stop_jellyfin ;;
      4) restart_jellyfin ;;
      5) update_jellyfin ;;
      6) configure_jellyfin ;;
      7) uninstall_jellyfin ;;
      8) return ;;
      *) error_msg "Invalid option."; pause ;;
    esac
  done
}

copyparty_menu() {
  while true; do
    print_banner
    show_copyparty_status
    echo -e "${CYAN}1)${NC} Install Copyparty"
    echo -e "${CYAN}2)${NC} Start Copyparty"
    echo -e "${CYAN}3)${NC} Stop Copyparty"
    echo -e "${CYAN}4)${NC} Restart Copyparty"
    echo -e "${CYAN}5)${NC} Update Copyparty"
    echo -e "${CYAN}6)${NC} Copyparty Settings"
    echo -e "${CYAN}7)${NC} Uninstall Copyparty"
    echo -e "${CYAN}8)${NC} Back"
    echo
    read -r -p "$(echo -e "${MAGENTA}Select option: ${NC}")" choice

    case "$choice" in
      1) install_copyparty ;;
      2) start_copyparty ;;
      3) stop_copyparty ;;
      4) restart_copyparty ;;
      5) update_copyparty ;;
      6) configure_copyparty ;;
      7) uninstall_copyparty ;;
      8) return ;;
      *) error_msg "Invalid option."; pause ;;
    esac
  done
}

background_menu() {
  while true; do
    print_banner
    echo -e "${CYAN}--------- Background Services / Autostart ---------${NC}"
    echo
    if [ "$AUTOSTART_ENABLED" = "1" ]; then
      echo -e "${WHITE}Current status:${NC} ${GREEN}ENABLED${NC}"
      echo -e "${WHITE}Boot script:${NC}    ${CYAN}$BOOT_SCRIPT${NC}"
    else
      echo -e "${WHITE}Current status:${NC} ${RED}DISABLED${NC}"
      echo -e "${WHITE}Boot script:${NC}    ${DIM}Not active${NC}"
    fi
    echo
    echo -e "${CYAN}1)${NC} Enable Background Autostart"
    echo -e "${CYAN}2)${NC} Disable Background Autostart"
    echo -e "${CYAN}3)${NC} Restart All Installed Services Now"
    echo -e "${CYAN}4)${NC} Back"
    echo
    read -r -p "$(echo -e "${MAGENTA}Select option: ${NC}")" choice

    case "$choice" in
      1) enable_background_autostart ;;
      2) disable_background_autostart ;;
      3) restart_all_services ;;
      4) return ;;
      *) error_msg "Invalid option."; pause ;;
    esac
  done
}

main_menu() {
  write_service_scripts

  while true; do
    print_banner
    show_main_status
    echo -e "${CYAN}1)${NC} Start / Stop Installed Services"
    echo -e "${CYAN}2)${NC} Jellyfin Menu"
    echo -e "${CYAN}3)${NC} Copyparty Menu"
    echo -e "${CYAN}4)${NC} Background Services Menu"
    echo -e "${CYAN}5)${NC} Clean Uninstall All"
    echo -e "${CYAN}6)${NC} Refresh Status"
    echo -e "${CYAN}7)${NC} Exit"
    echo
    read -r -p "$(echo -e "${MAGENTA}Select option: ${NC}")" choice

    case "$choice" in
      1) toggle_main_services ;;
      2) jellyfin_menu ;;
      3) copyparty_menu ;;
      4) background_menu ;;
      5) clean_uninstall_all ;;
      6) ;;
      7) exit 0 ;;
      *) error_msg "Invalid option."; pause ;;
    esac
  done
}

main_menu
