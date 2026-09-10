#!/usr/bin/env bash
#================================================================
#  setup.sh — первоначальная настройка VPS
#
#  Поддержка: Ubuntu 20.04+ / Debian 11+, запуск от root.
#  Повторный запуск безопасен — система просто обновится заново.
#================================================================

set -euo pipefail

#----------------------- НАСТРОЙКИ ------------------------------
SSH_PORT=""
OPEN_PORTS=""  
TIMEZONE="" 
INSTALL_DOCKER=true   
HARDEN_SSH=true
DISABLE_IPV6=true
BLOCK_PING=true
SETUP_SWAP=true
SKIP_FAIL2BAN=false
PURGE_CLOUDINIT=false    
DISABLE_SSH_PASSWORD=false 

#----------------------- ЛОГИ -----------------------------------
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
CURRENT_STEP="инициализация"
log()  { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
die()  { echo -e "${R}[x]${N} $*" >&2; exit 1; }
step() { CURRENT_STEP="$*"; echo -e "\n${C}━━━ $* ━━━${N}"; }
trap 'echo -e "\n${R}Ошибка на шаге: ${CURRENT_STEP}. Текущая SSH-сессия не закрыта — сервер доступен.${N}"' ERR

#----------------------- HELP -----------------------------------
usage() {
  cat <<'EOF'
Использование: bash setup.sh [опции]

  --ssh-port PORT          сменить порт SSH (например 2222)
  --ports 443,8443         открыть порты ноды в фаерволе
  --timezone Europe/Moscow установить таймзону
  --no-docker              не ставить Docker
  --no-fail2ban            пропустить fail2ban
  --no-ipv6-off            НЕ отключать IPv6
  --no-block-ping          НЕ блокировать ответы на ping
  --no-swap                не создавать swap
  --no-ssh-harden          не трогать конфиг SSH
  --disable-ssh-password   отключить вход по паролю (нужны настроенные ключи!)
  --purge-cloudinit        удалить cloud-init (только если VPS без него обходится)
  -h, --help               эта справка

Пример:
  bash setup.sh --ssh-port 2222 --ports 443 --timezone Europe/Moscow
EOF
}

parse() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-port)             [[ -n "${2:-}" ]] || die "--ssh-port: укажи порт"; SSH_PORT="$2"; shift 2 ;;
      --ports)                [[ -n "${2:-}" ]] || die "--ports: укажи порты"; OPEN_PORTS="$2"; shift 2 ;;
      --timezone)             [[ -n "${2:-}" ]] || die "--timezone: укажи таймзону"; TIMEZONE="$2"; shift 2 ;;
      --no-docker)            INSTALL_DOCKER=false; shift ;;
      --no-fail2ban)          SKIP_FAIL2BAN=true; shift ;;
      --no-ipv6-off)          DISABLE_IPV6=false; shift ;;
      --no-block-ping)        BLOCK_PING=false; shift ;;
      --no-swap)              SETUP_SWAP=false; shift ;;
      --no-ssh-harden)        HARDEN_SSH=false; shift ;;
      --disable-ssh-password) DISABLE_SSH_PASSWORD=true; shift ;;
      --purge-cloudinit)      PURGE_CLOUDINIT=true; shift ;;
      -h|--help)              usage; exit 0 ;;
      *)                      die "Неизвестный флаг: $1 (см. --help)" ;;
    esac
  done
}

#----------------------- ШАГИ -----------------------------------
precheck() {
  [[ $EUID -eq 0 ]] || die "Запусти от root: sudo bash $0"
  [[ -f /etc/os-release ]] && . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) log "ОС: ${PRETTY_NAME:-$ID}" ;;
    *) warn "ОС '${ID:-?}' не тестировалась (жижу Ubuntu/Debian). Продолжаю..." ;;
  esac
}

update_system() {
  step "Обновление системы"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get update -y
  apt-get -y -o Dpkg::Options::="--force-confold" upgrade
  apt-get -y -o Dpkg::Options::="--force-confold" full-upgrade
  apt-get autoremove -y
  apt-get autoclean -y
  log "Система обновлена"
}

install_base() {
  step "Базовые пакеты"
  apt-get install -y \
    curl wget git jq unzip ca-certificates socat cron \
    htop vnstat mtr-tiny iperf3 netcat-openbsd speedtest-cli \
    ufw fail2ban
  systemctl enable --now vnstat >/dev/null 2>&1 || true
  log "Базовые пакеты установлены"
}

set_timezone() {
  step "Время"
  timedatectl set-ntp true
  if [[ -n "$TIMEZONE" ]]; then
    timedatectl set-timezone "$TIMEZONE" && log "Таймзона: $TIMEZONE"
  fi
  log "Время: $(date '+%F %T %Z')"
}

disable_ipv6() {
  step "Отключение IPv6"
  cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1 || true
  log "IPv6 отключён (до конца применится после перезагрузки)"
}

tune_network() {
  step "Сеть: BBR + тюнинг TCP"
  modprobe tcp_bbr 2>/dev/null || true
  echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf

  cat > /etc/sysctl.d/99-vpn-tune.conf <<'EOF'
# --- BBR ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Буферы TCP (важно для скорости через прокси) ---
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432

# --- TCP не «остывает» после простоя + MTU probing (для туннелей) ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 131072

# --- Очереди соединений ---
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_fin_timeout = 15

# --- Разное ---
net.ipv4.ip_forward = 1
fs.file-max = 2097152
vm.swappiness = 10
EOF
  sysctl -p /etc/sysctl.d/99-vpn-tune.conf >/dev/null 2>&1 || true

  cat > /etc/security/limits.d/99-vpn.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/size.conf <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
  systemctl restart systemd-journald 2>/dev/null || true

  if sysctl -n net.ipv4.tcp_congestion_control | grep -q bbr; then
    log "BBR включён"
  else
    warn "BBR не применился — проверь версию ядра (нужна 4.9+)"
  fi
}

block_ping() {
  step "Блокировка ping (ICMP)"
  cat > /etc/sysctl.d/99-block-ping.conf <<'EOF'
net.ipv4.icmp_echo_ignore_all = 1
EOF
  sysctl -p /etc/sysctl.d/99-block-ping.conf >/dev/null 2>&1 || true
  log "Сервер больше не отвечает на ping снаружи (исходящий ping работает)"
}

setup_fail2ban() {
  step "Fail2ban"
  local port="${SSH_PORT:-22}"
  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ${port}
backend  = systemd
maxretry = 4
EOF
  systemctl restart fail2ban
  systemctl enable fail2ban >/dev/null 2>&1
  log "Fail2ban: бан после 4 неудачных входов, эскалация до 1 недели"
}

setup_firewall() {
  step "Фаервол UFW"
  local ssh_p="${SSH_PORT:-22}"
  ufw limit "${ssh_p}/tcp" comment 'SSH' >/dev/null

  if [[ -n "$OPEN_PORTS" ]]; then
    local p
    IFS=',' read -ra ports <<< "$OPEN_PORTS"
    for p in "${ports[@]}"; do
      p="$(echo "$p" | tr -d ' ')"
      [[ -z "$p" ]] && continue
      ufw allow "$p" comment 'node' >/dev/null
      log "Открыт порт: $p"
    done
  else
    warn "Порты не указаны (--ports). Не забудь открыть позже: ufw allow ПОРТ"
  fi

  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable >/dev/null
  ufw status verbose | sed 's/^/    /'
}

configure_ssh() {
  step "SSH"
  local cfg=/etc/ssh/sshd_config.d/99-hardening.conf
  mkdir -p /etc/ssh/sshd_config.d

  local conf=""
  [[ -n "$SSH_PORT" ]] && conf+="Port ${SSH_PORT}"$'\n'
  if $HARDEN_SSH; then
    conf+="X11Forwarding no"$'\n'
    conf+="AllowAgentForwarding no"$'\n'
    conf+="MaxAuthTries 3"$'\n'
    conf+="LoginGraceTime 20"$'\n'
    conf+="ClientAliveInterval 120"$'\n'
    conf+="ClientAliveCountMax 3"$'\n'
  fi
  printf '%s' "$conf" > "$cfg"

  if $HARDEN_SSH; then
    local have_keys=false d
    for d in /root /home/*; do
      [[ -s "$d/.ssh/authorized_keys" ]] && have_keys=true
    done

    if $have_keys; then
      local ans="n"
      if $DISABLE_SSH_PASSWORD; then
        ans="y"
      else
        read -r -p "Отключить вход по паролю (только SSH-ключи)? [y/N]: " ans </dev/tty 2>/dev/null || ans="n"
      fi
      if [[ "$ans" =~ ^[Yy]$ ]]; then
        echo "PasswordAuthentication no"      >> "$cfg"
        echo "PermitRootLogin prohibit-password" >> "$cfg"
        log "Вход по паролю отключён"
      fi
    else
      warn "SSH-ключи не найдены — вход по паролю НЕ отключаю (иначе потеряешь доступ)."
      warn "Добавь свой публичный ключ в ~/.ssh/authorized_keys и запусти флаг --disable-ssh-password"
    fi
  fi

  sshd -t || die "Ошибка конфига sshd — проверь /etc/ssh/sshd_config.d/"
  systemctl restart ssh 2>/dev/null || systemctl restart sshd
  log "SSH перезапущен${SSH_PORT:+, новый порт: $SSH_PORT}"
}

setup_swap() {
  step "Swap"
  if [[ -n "$(swapon --show 2>/dev/null)" ]]; then
    log "Swap уже настроен:"; swapon --show | sed 's/^/    /'
    return 0
  fi
  local ram_mb size_mb
  ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  if (( ram_mb <= 2000 )); then size_mb=2048; else size_mb=1024; fi
  log "Создаю swap ${size_mb}M..."
  fallocate -l "${size_mb}M" /swapfile 2>/dev/null \
    || dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  log "Swap активен"
}

cleanup() {
  step "Очистка"
  if command -v snap >/dev/null 2>&1; then
    local s
    while read -r s; do snap remove --purge "$s" >/dev/null 2>&1 || true; done \
      < <(snap list 2>/dev/null | awk 'NR>1{print $1}')
    apt-get purge -y snapd >/dev/null 2>&1 || true
    rm -rf /snap /var/snap /var/lib/snapd ~/snap 2>/dev/null || true
    log "Snap удалён"
  fi
  if $PURGE_CLOUDINIT && command -v cloud-init >/dev/null 2>&1; then
    apt-get purge -y cloud-init >/dev/null 2>&1 || true
    rm -rf /etc/cloud
    log "cloud-init удалён"
  fi
  pro config set apt_news=false >/dev/null 2>&1 || true
  [[ -f /etc/default/motd-news ]] && sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
  log "Чистка завершена"
}

install_docker() {
  $INSTALL_DOCKER || return 0
  step "Docker"
  if command -v docker >/dev/null 2>&1; then
    log "Docker уже установлен: $(docker --version)"
    return 0
  fi
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  log "Docker установлен: $(docker --version)"
}

summary() {
  echo -e "\n${C}════════════════════ ИТОГ ════════════════════${N}"
  echo -e "Хостнейм:     $(hostname)"
  echo -e "IP:           $(curl -s4 -m 5 https://api.ipify.org || echo 'не удалось определить')"
  echo -e "SSH порт:     ${SSH_PORT:-22}"
  echo -e "BBR:          $(sysctl -n net.ipv4.tcp_congestion_control)"
  echo -e "Ping (ICMP):  $( [[ $(cat /proc/sys/net/ipv4/icmp_echo_ignore_all) -eq 1 ]] && echo 'заблокирован' || echo 'разрешён' )"
  echo -e "IPv6:         $( [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 1 ]] && echo 'отключён' || echo 'включён' )"
  echo -e "Fail2ban:     $(systemctl is-active fail2ban 2>/dev/null || echo 'выключен')"
  echo -e "UFW:          $(ufw status 2>/dev/null | head -n1 | awk '{print $2}')"
  echo -e "Docker:       $(command -v docker >/dev/null 2>&1 && docker --version || echo 'нет')"
  echo -e "${C}══════════════════════════════════════════════${N}"
  cat <<'EOF'

EOF
}

main() {
  precheck
  update_system
  install_base
  set_timezone
  $DISABLE_IPV6 && disable_ipv6
  tune_network
  $BLOCK_PING && block_ping
  $SKIP_FAIL2BAN || setup_fail2ban
  setup_firewall
  configure_ssh
  $SETUP_SWAP && setup_swap
  cleanup
  install_docker
  summary
}

parse "$@"
main
