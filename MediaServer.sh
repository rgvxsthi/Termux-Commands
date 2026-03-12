#!/data/data/com.termux/files/usr/bin/bash

PREFIX="/data/data/com.termux/files/usr"

APP_DIR="$HOME/.media-stack"
LOG_DIR="$APP_DIR/logs"
CONFIG_FILE="$APP_DIR/config.env"

START_SCRIPT="$APP_DIR/start-services.sh"
STOP_SCRIPT="$APP_DIR/stop-services.sh"

BOOT_DIR="$HOME/.termux/boot"
BOOT_SCRIPT="$BOOT_DIR/start-services.sh"

DEFAULT_JELLYFIN_PORT="8096"
DEFAULT_COPYPARTY_PORT="3923"

mkdir -p "$APP_DIR" "$LOG_DIR"

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
  local my_ip
  my_ip=$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')
  [ -z "$my_ip" ] && my_ip="127.0.0.1"
  echo "$my_ip"
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

write_runtime_scripts() {
  mkdir -p "$APP_DIR" "$LOG_DIR"

  cat > "$START_SCRIPT" <<EOF
#!/data/data/com.termux/files/usr/bin/bash

PREFIX="/data/data/com.termux/files/usr"
APP_DIR="\$HOME/.media-stack"
LOG_DIR="\$APP_DIR/logs"
CONFIG_FILE="\$APP_DIR/config.env"

mkdir -p "\$APP_DIR" "\$LOG_DIR"

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
  nohup jellyfin --ffmpeg "\$(command -v ffmpeg)" > "\$LOG_DIR/jellyfin.log" 2>&1 &
fi

sleep 8

if python -m pip show copyparty >/dev/null 2>&1; then
  nohup python -m copyparty \
    -p $DEFAULT_COPYPARTY_PORT \
    -v "\$COPYPARTY_VOLUME" \
    -a "\$COPYPARTY_USER:\$COPYPARTY_PASS" \
    -e2dsa \
    > "\$LOG_DIR/copyparty.log" 2>&1 &
fi
EOF

  cat > "$STOP_SCRIPT" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
pkill -9 -f '/usr/lib/jellyfin/jellyfin' 2>/dev/null || true
pkill -9 -f 'python.*copyparty|copyparty' 2>/dev/null || true
sleep 1
EOF

  chmod +x "$START_SCRIPT" "$STOP_SCRIPT"
}

write_boot_script() {
  mkdir -p "$BOOT_DIR"
  cat > "$BOOT_SCRIPT" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
nohup bash "$START_SCRIPT" > "$LOG_DIR/boot-start.log" 2>&1 &
EOF
  chmod +x "$BOOT_SCRIPT"
}

remove_boot_script() {
  rm -f "$BOOT_SCRIPT"
}

sync_boot_script_state() {
  write_runtime_scripts
  if [ "$AUTOSTART_ENABLED" = "1" ]; then
    write_boot_script
  else
    remove_boot_script
  fi
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
  sync_boot_script_state
  nohup bash "$START_SCRIPT" > "$LOG_DIR/startup.log" 2>&1 &
  sleep 5
}

show_main_status() {
  local ip jf_port cp_port
  ip=$(get_ip)
  jf_port=$(get_jellyfin_port)
  cp_port=$(get_copyparty_port)

  echo -e "${WHITE}Current IP:${NC} ${GREEN}$ip${NC}"
  echo

  if jellyfin_installed; then
    if [ -n "$jf_port" ]; then
      echo -e "${WHITE}Jellyfin:${NC}   ${GREEN}RUNNING${NC} on port ${YELLOW}$jf_port${NC}"
      echo -e "${WHITE}           URL:${NC} ${CYAN}http://$ip:$jf_port${NC}"
    else
      echo -e "${WHITE}Jellyfin:${NC}   ${YELLOW}INSTALLED${NC} but ${RED}STOPPED${NC}"
    fi
  else
    echo -e "${WHITE}Jellyfin:${NC}   ${DIM}NOT INSTALLED${NC}"
  fi

  echo

  if copyparty_installed; then
    if [ -n "$cp_port" ]; then
      echo -e "${WHITE}Copyparty:${NC}  ${GREEN}RUNNING${NC} on port ${YELLOW}$cp_port${NC}"
      echo -e "${WHITE}           URL:${NC} ${CYAN}http://$ip:$cp_port${NC}"
      echo -e "${WHITE}         Login:${NC} ${YELLOW}$COPYPARTY_USER / $COPYPARTY_PASS${NC}"
    else
      echo -e "${WHITE}Copyparty:${NC}  ${YELLOW}INSTALLED${NC} but ${RED}STOPPED${NC}"
    fi
  else
    echo -e "${WHITE}Copyparty:${NC}  ${DIM}NOT INSTALLED${NC}"
  fi

  echo

  if [ "$AUTOSTART_ENABLED" = "1" ] && [ -f "$BOOT_SCRIPT" ]; then
    echo -e "${WHITE}Background Autostart:${NC} ${GREEN}ENABLED${NC}"
    echo -e "${WHITE}Boot Script:${NC}          ${CYAN}$BOOT_SCRIPT${NC}"
  else
    echo -e "${WHITE}Background Autostart:${NC} ${RED}DISABLED${NC}"
  fi

  echo
}

show_jellyfin_status() {
  local ip jf_port
  ip=$(get_ip)
  jf_port=$(get_jellyfin_port)

  echo -e "${CYAN}---------------- Jellyfin Status ----------------${NC}"
  if jellyfin_installed; then
    echo -e "${WHITE}Installed:${NC} ${GREEN}Yes${NC}"
    if [ -n "$jf_port" ]; then
      echo -e "${WHITE}Running:${NC}   ${GREEN}Yes${NC}"
      echo -e "${WHITE}Port:${NC}      ${YELLOW}$jf_port${NC}"
      echo -e "${WHITE}URL:${NC}       ${CYAN}http://$ip:$jf_port${NC}"
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
  local ip cp_port
  ip=$(get_ip)
  cp_port=$(get_copyparty_port)

  echo -e "${CYAN}--------------- Copyparty Status ----------------${NC}"
  if copyparty_installed; then
    echo -e "${WHITE}Installed:${NC} ${GREEN}Yes${NC}"
    if [ -n "$cp_port" ]; then
      echo -e "${WHITE}Running:${NC}   ${GREEN}Yes${NC}"
      echo -e "${WHITE}Port:${NC}      ${YELLOW}$cp_port${NC}"
      echo -e "${WHITE}URL:${NC}       ${CYAN}http://$ip:$cp_port${NC}"
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

show_logs_menu() {
  while true; do
    print_banner
    echo -e "${CYAN}------------------ Service Logs ------------------${NC}"
    echo -e "${WHITE}1)${NC} Jellyfin log"
    echo -e "${WHITE}2)${NC} Copyparty log"
    echo -e "${WHITE}3)${NC} Startup log"
    echo -e "${WHITE}4)${NC} Boot start log"
    echo -e "${WHITE}5)${NC} Back"
    echo
    read -r -p "$(echo -e "${MAGENTA}Select option: ${NC}")" choice

    case "$choice" in
      1) print_banner; [ -f "$LOG_DIR/jellyfin.log" ] && tail -n 100 "$LOG_DIR/jellyfin.log" || warn "No Jellyfin log found."; pause ;;
      2) print_banner; [ -f "$LOG_DIR/copyparty.log" ] && tail -n 100 "$LOG_DIR/copyparty.log" || warn "No Copyparty log found."; pause ;;
      3) print_banner; [ -f "$LOG_DIR/startup.log" ] && tail -n 100 "$LOG_DIR/startup.log" || warn "No startup log found."; pause ;;
      4) print_banner; [ -f "$LOG_DIR/boot-start.log" ] && tail -n 100 "$LOG_DIR/boot-start.log" || warn "No boot start log found."; pause ;;
      5) return ;;
      *) error_msg "Invalid option."; pause ;;
    esac
  done
}

install_jellyfin() {
  print_banner
  show_jellyfin_status
  info "Installing Jellyfin..."
  echo

  ensure_base_packages
  yes | pkg install jellyfin-server dotnet9.0 dotnet-sdk-9.0
  sync_boot_script_state

  echo
  success "Jellyfin installed successfully."
  warn "Revert path: use Uninstall Jellyfin from this submenu."
  warn "If you want it running now, choose Start Jellyfin or Start / Stop Installed Services."
  pause
}

update_jellyfin() {
  print_banner
  show_jellyfin_status

  if ! jellyfin_installed; then
    error_msg "Jellyfin is not installed."
    warn "Install Jellyfin first."
    pause
    return
  fi

  info "Updating Jellyfin..."
  ensure_base_packages
  yes | pkg install jellyfin-server dotnet9.0 dotnet-sdk-9.0
  sync_boot_script_state

  echo
  success "Jellyfin updated."
  warn "Revert path: restart Jellyfin, or uninstall and reinstall if needed."
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
  export PATH="$HOME/.local/bin:$PREFIX/bin:$PATH"
  export DOTNET_ROOT="$PREFIX/lib/dotnet"
  export PATH="$DOTNET_ROOT:$PATH"
  export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

  pkill -9 -f '/usr/lib/jellyfin/jellyfin' 2>/dev/null || true
  sleep 1
  nohup jellyfin --ffmpeg "$(command -v ffmpeg)" > "$LOG_DIR/jellyfin.log" 2>&1 &
  sleep 5

  print_banner
  show_jellyfin_status
  if jellyfin_running; then
    success "Jellyfin started successfully."
  else
    error_msg "Jellyfin did not start."
    warn "Check the Jellyfin log from the logs menu."
    warn "Revert path: restart Jellyfin, or uninstall and reinstall."
  fi
  pause
}

stop_jellyfin() {
  print_banner
  show_jellyfin_status

  if ! jellyfin_installed; then
    warn "Jellyfin is not installed."
    pause
    return
  fi

  info "Stopping Jellyfin..."
  pkill -9 -f '/usr/lib/jellyfin/jellyfin' 2>/dev/null || true
  sleep 2

  print_banner
  show_jellyfin_status
  success "Jellyfin stop command completed."
  warn "If it still appears running, refresh after a few seconds."
  pause
}

restart_jellyfin() {
  print_banner
  show_jellyfin_status

  if ! jellyfin_installed; then
    warn "Jellyfin is not installed."
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
  nohup jellyfin --ffmpeg "$(command -v ffmpeg)" > "$LOG_DIR/jellyfin.log" 2>&1 &
  sleep 5

  print_banner
  show_jellyfin_status
  if jellyfin_running; then
    success "Jellyfin restarted successfully."
  else
    error_msg "Jellyfin restart appears to have failed."
    warn "Check the Jellyfin log."
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

  echo -e "${YELLOW}This removes Jellyfin and its .NET packages used by this setup.${NC}"
  echo -e "${YELLOW}Revert path: reinstall from this submenu later.${NC}"
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
  sync_boot_script_state
  sleep 2

  print_banner
  show_jellyfin_status
  success "Jellyfin uninstall complete."
  pause
}

configure_jellyfin() {
  print_banner
  show_jellyfin_status
  echo -e "${CYAN}--------------- Jellyfin Settings -----------------${NC}"
  echo -e "${WHITE}FFmpeg binary:${NC} ${YELLOW}$(command -v ffmpeg 2>/dev/null || echo not-found)${NC}"
  echo -e "${WHITE}DOTNET_ROOT:${NC}  ${YELLOW}$PREFIX/lib/dotnet${NC}"
  echo
  warn "Jellyfin port changes are not exposed in this script."
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
  sync_boot_script_state

  echo
  success "Copyparty installed successfully."
  warn "Revert path: use Uninstall Copyparty from this submenu."
  warn "If you want it running now, choose Start Copyparty or Start / Stop Installed Services."
  pause
}

update_copyparty() {
  print_banner
  show_copyparty_status

  if ! copyparty_installed; then
    error_msg "Copyparty is not installed."
    warn "Install Copyparty first."
    pause
    return
  fi

  info "Updating Copyparty..."
  ensure_base_packages
  python -m pip install --user -U copyparty pillow
  sync_boot_script_state

  echo
  success "Copyparty updated."
  warn "Revert path: restart Copyparty, or uninstall and reinstall if needed."
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
  export PATH="$HOME/.local/bin:$PREFIX/bin:$PATH"

  pkill -9 -f 'python.*copyparty|copyparty' 2>/dev/null || true
  sleep 2
  nohup python -m copyparty \
    -p "$DEFAULT_COPYPARTY_PORT" \
    -v "$COPYPARTY_VOLUME" \
    -a "$COPYPARTY_USER:$COPYPARTY_PASS" \
    -e2dsa \
    > "$LOG_DIR/copyparty.log" 2>&1 &
  sleep 5

  print_banner
  show_copyparty_status
  if copyparty_running; then
    success "Copyparty started successfully."
  else
    error_msg "Copyparty did not start."
    warn "Check the Copyparty log from the logs menu."
  fi
  pause
}

stop_copyparty() {
  print_banner
  show_copyparty_status

  if ! copyparty_installed; then
    warn "Copyparty is not installed."
    pause
    return
  fi

  info "Stopping Copyparty..."
  pkill -9 -f 'python.*copyparty|copyparty' 2>/dev/null || true
  sleep 2

  print_banner
  show_copyparty_status
  success "Copyparty stop command completed."
  warn "If it still appears running, refresh after a few seconds."
  pause
}

restart_copyparty() {
  print_banner
  show_copyparty_status

  if ! copyparty_installed; then
    warn "Copyparty is not installed."
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
    > "$LOG_DIR/copyparty.log" 2>&1 &
  sleep 5

  print_banner
  show_copyparty_status
  if copyparty_running; then
    success "Copyparty restarted successfully."
  else
    error_msg "Copyparty restart appears to have failed."
    warn "Check the Copyparty log."
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
  echo -e "${YELLOW}Your actual media files are not deleted.${NC}"
  echo -e "${YELLOW}Revert path: reinstall from this submenu later.${NC}"
  echo
  read -r -p "$(echo -e "${MAGENTA}Type REMOVE to uninstall Copyparty: ${NC}")" confirm
  [ "$confirm" != "REMOVE" ] && { warn "Cancelled."; pause; return; }

  info "Stopping Copyparty..."
  pkill -9 -f 'python.*copyparty|copyparty' 2>/dev/null || true
  sleep 2

  info "Uninstalling Copyparty..."
  python -m pip uninstall -y copyparty pillow >/dev/null 2>&1 || true
  hash -r
  sync_boot_script_state
  sleep 2

  print_banner
  show_copyparty_status
  success "Copyparty uninstall complete."
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
  warn "If you enter something wrong, come back here and fix it."
  warn "For a full reset, uninstall and reinstall Copyparty."
  echo

  read -r -p "$(echo -e "${MAGENTA}New username [blank keeps current]: ${NC}")" new_user
  read -r -p "$(echo -e "${MAGENTA}New password [blank keeps current]: ${NC}")" new_pass
  read -r -p "$(echo -e "${MAGENTA}New volume mapping [blank keeps current]: ${NC}")" new_vol

  [ -n "$new_user" ] && COPYPARTY_USER="$new_user"
  [ -n "$new_pass" ] && COPYPARTY_PASS="$new_pass"
  [ -n "$new_vol" ] && COPYPARTY_VOLUME="$new_vol"

  save_config
  sync_boot_script_state

  echo
  success "Copyparty settings saved."
  warn "Restart Copyparty for changes to fully apply."
  pause
}

enable_background_autostart() {
  print_banner
  echo -e "${CYAN}----------- Background Autostart Settings ---------${NC}"
  echo
  warn "This creates the Termux:Boot start-services boot script."
  warn "Required steps for boot-time startup:"
  echo -e "${WHITE}1.${NC} Install ${CYAN}Termux:Boot${NC}"
  echo -e "${WHITE}2.${NC} Open ${CYAN}Termux:Boot${NC} once"
  echo
  read -r -p "$(echo -e "${MAGENTA}Type ENABLE to continue: ${NC}")" confirm
  [ "$confirm" != "ENABLE" ] && { warn "Cancelled."; pause; return; }

  AUTOSTART_ENABLED=1
  save_config
  sync_boot_script_state

  echo
  success "Background autostart enabled."
  echo -e "${WHITE}Boot script path:${NC} ${CYAN}$BOOT_SCRIPT${NC}"
  warn "Revert path: use Disable Background Autostart from this submenu."
  pause
}

disable_background_autostart() {
  print_banner
  echo -e "${CYAN}----------- Background Autostart Settings ---------${NC}"
  echo
  warn "This deletes the Termux:Boot start-services boot script."
  warn "Manual starts from the menu will still work."
  echo
  read -r -p "$(echo -e "${MAGENTA}Type DISABLE to continue: ${NC}")" confirm
  [ "$confirm" != "DISABLE" ] && { warn "Cancelled."; pause; return; }

  AUTOSTART_ENABLED=0
  save_config
  sync_boot_script_state

  echo
  success "Background autostart disabled."
  warn "Revert path: enable it again from this submenu."
  pause
}

rebuild_service_scripts() {
  print_banner
  echo -e "${CYAN}---------------- Script Maintenance ----------------${NC}"
  echo
  warn "This recreates the runtime start/stop scripts and updates or removes the boot script based on current settings."
  warn "Use this if something was manually edited or deleted."
  echo
  read -r -p "$(echo -e "${MAGENTA}Type REBUILD to continue: ${NC}")" confirm
  [ "$confirm" != "REBUILD" ] && { warn "Cancelled."; pause; return; }

  sync_boot_script_state

  echo
  success "Service scripts rebuilt successfully."
  echo -e "${WHITE}Runtime start script:${NC} ${CYAN}$START_SCRIPT${NC}"
  echo -e "${WHITE}Runtime stop script:${NC}  ${CYAN}$STOP_SCRIPT${NC}"
  if [ "$AUTOSTART_ENABLED" = "1" ] && [ -f "$BOOT_SCRIPT" ]; then
    echo -e "${WHITE}Boot script:${NC}          ${CYAN}$BOOT_SCRIPT${NC}"
  else
    echo -e "${WHITE}Boot script:${NC}          ${DIM}Not present because autostart is disabled${NC}"
  fi
  pause
}

restart_all_services() {
  print_banner
  show_main_status

  warn "This restarts all installed services managed by this script."
  warn "Useful after changing settings or if status looks stale."
  echo
  read -r -p "$(echo -e "${MAGENTA}Type RESTART to continue: ${NC}")" confirm
  [ "$confirm" != "RESTART" ] && { warn "Cancelled."; pause; return; }

  stop_all_services
  start_installed_services

  print_banner
  show_main_status
  success "Installed services restarted."
  warn "If something still failed to start, check the logs menu."
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
    warn "Revert path: use this same option again to start installed services."
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
    success "Installed services start command sent."
    warn "If a service is still not running, check the logs menu."
  fi

  pause
}

clean_uninstall_all() {
  print_banner
  show_main_status

  error_msg "This will remove Jellyfin, Copyparty, related packages, config, logs, runtime scripts, and the boot script."
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

  info "Removing config, logs, runtime scripts, and boot script..."
  rm -f "$START_SCRIPT" "$STOP_SCRIPT" "$BOOT_SCRIPT"
  rm -rf "$APP_DIR"

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
    if [ "$AUTOSTART_ENABLED" = "1" ] && [ -f "$BOOT_SCRIPT" ]; then
      echo -e "${WHITE}Current status:${NC} ${GREEN}ENABLED${NC}"
      echo -e "${WHITE}Boot script:${NC}    ${CYAN}$BOOT_SCRIPT${NC}"
    else
      echo -e "${WHITE}Current status:${NC} ${RED}DISABLED${NC}"
      echo -e "${WHITE}Boot script:${NC}    ${DIM}Not present${NC}"
    fi
    echo
    echo -e "${CYAN}1)${NC} Enable Background Autostart"
    echo -e "${CYAN}2)${NC} Disable Background Autostart"
    echo -e "${CYAN}3)${NC} Restart All Installed Services Now"
    echo -e "${CYAN}4)${NC} Rebuild Start/Stop/Boot Scripts"
    echo -e "${CYAN}5)${NC} Back"
    echo
    read -r -p "$(echo -e "${MAGENTA}Select option: ${NC}")" choice

    case "$choice" in
      1) enable_background_autostart ;;
      2) disable_background_autostart ;;
      3) restart_all_services ;;
      4) rebuild_service_scripts ;;
      5) return ;;
      *) error_msg "Invalid option."; pause ;;
    esac
  done
}

main_menu() {
  sync_boot_script_state

  while true; do
    print_banner
    show_main_status
    echo -e "${CYAN}1)${NC} Start / Stop Installed Services"
    echo -e "${CYAN}2)${NC} Jellyfin Menu"
    echo -e "${CYAN}3)${NC} Copyparty Menu"
    echo -e "${CYAN}4)${NC} Background Services Menu"
    echo -e "${CYAN}5)${NC} View Logs"
    echo -e "${CYAN}6)${NC} Clean Uninstall All"
    echo -e "${CYAN}7)${NC} Refresh Status"
    echo -e "${CYAN}8)${NC} Exit"
    echo
    read -r -p "$(echo -e "${MAGENTA}Select option: ${NC}")" choice

    case "$choice" in
      1) toggle_main_services ;;
      2) jellyfin_menu ;;
      3) copyparty_menu ;;
      4) background_menu ;;
      5) show_logs_menu ;;
      6) clean_uninstall_all ;;
      7) ;;
      8) exit 0 ;;
      *) error_msg "Invalid option."; pause ;;
    esac
  done
}

main_menu
