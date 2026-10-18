#!/usr/bin/env bash
#================================================================
#  setup.sh — первоначальная настройка VPS
#
#  Поддержка: Ubuntu 20.04+ / Debian 11+, запуск от root.
#  Без аргументов — интерактивный мастер: спросит всё и покажет план.
#  С флагами — автоматический режим (заданное флагами не спрашивается).
#  Повторный запуск безопасен — конфиги перезаписываются идемпотентно.
#================================================================

set -euo pipefail

#----------------------- ОТВЕТЫ (флаги/визард) ------------------
SSH_PORT=""            # пусто = не менять
OPEN_PORTS=""          # список порт[/tcp|udp|both] через запятую
TIMEZONE=""            # пусто = не менять
ADMIN_USER=""          # пусто = не создавать, работать под root
ADMIN_KEY_MODE=""      # paste | root | generate | skip
ADMIN_SSH_KEYS=()
GENERATED_KEY_PATH=""
HOSTNAME_NEW=""        # пусто = не менять
INSTALL_DOCKER=true
HARDEN_SSH=true
DISABLE_IPV6=false
BLOCK_PING=true
SETUP_SWAP=true
SKIP_FAIL2BAN=false
PURGE_CLOUDINIT=false
DISABLE_SSH_PASSWORD=false

#----------------------- СОСТОЯНИЕ ------------------------------
FLAGS_SEEN=" "
INTERACTIVE=false
WIZARD_RAN=false
LEGACY_CLEANED=false
CURR_SSH_PORT="22"
PORTS_NUM=()
PORTS_PROTO=()
LISTEN_NET=()
LISTEN_PORT=()
LISTEN_ADDR=()
LISTEN_PROC=()

#----------------------- ЛОГИ -----------------------------------
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
CURRENT_STEP="инициализация"
log()  { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
die()  { echo -e "${R}[x]${N} $*" >&2; exit 1; }
step() { CURRENT_STEP="$*"; echo -e "\n${C}━━━ $* ━━━${N}"; }
trap 'echo -e "\n${R}Ошибка на шаге: ${CURRENT_STEP}. Текущая SSH-сессия не закрыта — сервер доступен.${N}"' ERR

#----------------------- ВВОД -----------------------------------
have_tty() { [[ -t 0 ]] || { [[ -e /dev/tty && -r /dev/tty && -w /dev/tty ]]; }; }

# Ответ в $REPLY; 1 = читать неоткуда (нет терминала / EOF)
read_answer() {
  REPLY=""
  if [[ -t 0 ]]; then
    read -r -p "$1" REPLY
  elif have_tty; then
    read -r -p "$1" REPLY </dev/tty
  else
    return 1
  fi
}

# get_answer ИМЯ_ПЕРЕМЕННОЙ "промпт" "дефолт"
get_answer() {
  local __var="$1" __prompt="$2" __def="${3:-}"
  local __p="$__prompt"
  [[ -n "$__def" ]] && __p+=" [$__def]"
  __p+=": "
  if ! read_answer "$__p" || [[ -z "$REPLY" ]]; then
    REPLY="$__def"
  fi
  printf -v "$__var" '%s' "$REPLY"
}

# ask_yes "вопрос" y|n → 0 = да
ask_yes() {
  local __def="${2:-n}"
  if ! read_answer "$1 [${__def}]: " || [[ -z "$REPLY" ]]; then
    REPLY="$__def"
  fi
  [[ "$REPLY" =~ ^[YyДд]$ ]]
}

# Вопрос задаётся только если соответствующий флаг не задан
flag_seen() { [[ "$FLAGS_SEEN" == *" $1 "* ]]; }

#----------------------- ВАЛИДАЦИЯ ------------------------------
is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

is_valid_pubkey() {
  if command -v ssh-keygen >/dev/null 2>&1; then
    printf '%s\n' "$1" | ssh-keygen -lf - >/dev/null 2>&1
  else
    [[ "$1" =~ ^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+ ]]
  fi
}

is_valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

RESERVED_USERS="root daemon bin sys sync games man lp mail news uucp www-data backup list irc gnats nobody sshd syslog uuidd tcpdump messagebus systemd-network systemd-resolve systemd-timesync lxd landscape pollinate apt tss"
is_reserved_username() { [[ " $RESERVED_USERS " == *" $1 "* ]]; }

is_valid_hostname() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }

is_valid_timezone() { timedatectl list-timezones 2>/dev/null | grep -qxF "$1"; }

# «Снаружи» = wildcard или публичный IP. Локальные/приватные/служебные диапазоны — мимо,
# фаервол на них всё равно не влияет.
addr_is_external() {
  local ip="$1"
  case "$ip" in
    '*'|0.0.0.0|'[::]'|'::') return 0 ;;
    127.*|::1|'[::1]'|169.254.*|10.*|192.168.*) return 1 ;;
    172.*)
      local o2="${ip#*.}"
      o2="${o2%%.*}"
      if [[ "$o2" =~ ^[0-9]+$ ]] && (( o2 >= 16 && o2 <= 31 )); then return 1; fi
      return 0 ;;
    224.*|225.*|226.*|227.*|228.*|229.*|23[0-9].*|2[4-9][0-9].*) return 1 ;;
    *) return 0 ;;
  esac
}

# «1 порт / 2 порта / 5 портов»
ru_plural() {
  local n="$1" one="$2" few="$3" many="$4"
  local m10=$(( n % 10 )) m100=$(( n % 100 ))
  if (( m10 == 1 && m100 != 11 )); then printf '%s' "$one"
  elif (( m10 >= 2 && m10 <= 4 && ( m100 < 10 || m100 >= 20 ) )); then printf '%s' "$few"
  else printf '%s' "$many"; fi
}

#----------------------- HELP -----------------------------------
usage() {
  cat <<'EOF'
Использование: bash setup.sh

  Без аргументов — интерактивный мастер: спросит всё и покажет план
  перед изменениями. Флаги задают ответы заранее — такие вопросы
  пропускаются (удобно для автоматического разворачивания).

  --ssh-port PORT           сменить порт SSH (например 2222)
  --ports СПИСОК            открыть порты: порт или диапазон с протоколом
                            [/tcp|udp|both] через запятую, например
                            443/tcp,8443/udp,30000-40000/udp (по умолчанию tcp)
  --timezone TZ             установить таймзону (Europe/Moscow)
  --admin USER              создать пользователя с sudo без пароля (NOPASSWD)
  --ssh-key "KEY"           публичный SSH-ключ для admin (или для root, если
                            admin не задан); можно указывать несколько раз
  --key-from-root           скопировать ключи из /root/.ssh/authorized_keys
  --generate-key            сгенерировать ed25519-пару на сервере
                            (приватный ключ будет показан один раз)
  --hostname NAME           задать hostname
  --disable-ipv6            отключить IPv6 (по умолчанию остаётся включённым)
  --no-docker               не ставить Docker
  --no-fail2ban             пропустить fail2ban
  --no-block-ping           НЕ блокировать ответы на ping
  --no-swap                 не создавать swap
  --no-ssh-harden           не применять харденинг SSH
  --disable-ssh-password    отключить вход по паролю (нужен ключ на сервере!)
  --purge-cloudinit         удалить cloud-init (только если VPS без него обходится)
  -h, --help                эта справка

Примеры:
  bash setup.sh                                          # мастер
  bash setup.sh --admin deploy --ssh-key "$(cat ~/.ssh/id_ed25519.pub)" \
       --ssh-port 2222 --ports 443/tcp,8443/udp --timezone Europe/Amsterdam
EOF
}

need() { [[ -n "${2:-}" ]] || die "$1: укажи значение"; }

parse() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-port)             need "$1" "${2:-}"; SSH_PORT="$2"; FLAGS_SEEN+="ssh-port "; shift 2 ;;
      --ports)                need "$1" "${2:-}"; OPEN_PORTS="$2"; FLAGS_SEEN+="ports "; shift 2 ;;
      --timezone)             need "$1" "${2:-}"; TIMEZONE="$2"; FLAGS_SEEN+="timezone "; shift 2 ;;
      --admin)                need "$1" "${2:-}"; ADMIN_USER="$2"; FLAGS_SEEN+="admin "; shift 2 ;;
      --ssh-key)              need "$1" "${2:-}"; ADMIN_SSH_KEYS+=("$2"); ADMIN_KEY_MODE="paste"; FLAGS_SEEN+="ssh-key "; shift 2 ;;
      --key-from-root)        ADMIN_KEY_MODE="root"; FLAGS_SEEN+="key-from-root "; shift ;;
      --generate-key)         ADMIN_KEY_MODE="generate"; FLAGS_SEEN+="generate-key "; shift ;;
      --hostname)             need "$1" "${2:-}"; HOSTNAME_NEW="$2"; FLAGS_SEEN+="hostname "; shift 2 ;;
      --disable-ipv6)         DISABLE_IPV6=true; FLAGS_SEEN+="disable-ipv6 "; shift ;;
      --no-docker)            INSTALL_DOCKER=false; FLAGS_SEEN+="no-docker "; shift ;;
      --no-fail2ban)          SKIP_FAIL2BAN=true; FLAGS_SEEN+="no-fail2ban "; shift ;;
      --no-block-ping)        BLOCK_PING=false; FLAGS_SEEN+="no-block-ping "; shift ;;
      --no-swap)              SETUP_SWAP=false; FLAGS_SEEN+="no-swap "; shift ;;
      --no-ssh-harden)        HARDEN_SSH=false; FLAGS_SEEN+="no-ssh-harden "; shift ;;
      --disable-ssh-password) DISABLE_SSH_PASSWORD=true; FLAGS_SEEN+="disable-ssh-password "; shift ;;
      --purge-cloudinit)      PURGE_CLOUDINIT=true; FLAGS_SEEN+="purge-cloudinit "; shift ;;
      -h|--help)              usage; exit 0 ;;
      *)                      die "Неизвестный флаг: $1 (см. --help)" ;;
    esac
  done
}

# OPEN_PORTS → массивы PORTS_NUM / PORTS_PROTO (tcp | udp | both).
# Порт можно задать диапазоном: 30000-40000/udp → в UFW уйдёт как 30000:40000/udp
parse_port_specs() {
  PORTS_NUM=(); PORTS_PROTO=()
  [[ -z "$OPEN_PORTS" ]] && return 0
  local items p pr lo hi
  IFS=',' read -ra items <<< "$OPEN_PORTS"
  for p in "${items[@]}"; do
    p="${p//[[:space:]]/}"
    [[ -z "$p" ]] && continue
    if [[ "$p" == */* ]]; then
      pr="${p##*/}"; p="${p%%/*}"
    else
      pr="tcp"
    fi
    case "$pr" in
      tcp|udp|both) ;;
      *) die "Протокол «$pr» у порта $p не понят: tcp, udp или both" ;;
    esac
    if [[ "$p" == *-* ]]; then
      lo="${p%%-*}"; hi="${p#*-}"
      is_valid_port "$lo" || die "Начало диапазона «$p» — не число 1–65535"
      is_valid_port "$hi" || die "Конец диапазона «$p» — не число 1–65535"
      (( lo <= hi )) || die "Диапазон «$p»: начало больше конца"
      PORTS_NUM+=("${lo}:${hi}")
    else
      is_valid_port "$p" || die "Порт «$p» — не число из диапазона 1–65535"
      PORTS_NUM+=("$p")
    fi
    PORTS_PROTO+=("$pr")
  done
}

# Покрыт ли порт/протокол текущим списком открытия (учитывает диапазоны)
port_in_specs() {
  local net="$1" port="$2" i p pr lo hi
  for i in "${!PORTS_NUM[@]}"; do
    pr="${PORTS_PROTO[$i]}"; p="${PORTS_NUM[$i]}"
    [[ "$pr" == "$net" || "$pr" == "both" ]] || continue
    if [[ "$p" == *:* ]]; then
      lo="${p%%:*}"; hi="${p##*:}"
      if (( port >= lo && port <= hi )); then return 0; fi
    else
      if (( port == p )); then return 0; fi
    fi
  done
  return 1
}

#----------------------- ШАГИ -----------------------------------
precheck() {
  [[ $EUID -eq 0 ]] || die "Запусти от root: sudo bash $0"
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) log "ОС: ${PRETTY_NAME:-$ID}" ;;
      *) warn "ОС '${ID:-?}' не тестировалась (ориентируюсь на Ubuntu/Debian). Продолжаю..." ;;
    esac
  fi
  # Определяем текущий порт sshd. Никак не должен остановить скрипт:
  # ни зависнуть, ни упасть (странные конфиги/образы встречаются).
  CURR_SSH_PORT="$(timeout 5 sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2; exit}' || true)"
  CURR_SSH_PORT="${CURR_SSH_PORT:-22}"
}

update_system() {
  step "Обновление системы"
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
    curl wget git jq unzip ca-certificates socat cron procps sudo \
    htop vnstat mtr-tiny iperf3 netcat-openbsd speedtest-cli \
    ufw fail2ban
  systemctl enable --now vnstat >/dev/null 2>&1 || true
  log "Базовые пакеты установлены"
}

set_time_and_host() {
  step "Время и hostname"
  timedatectl set-ntp true
  if [[ -n "$TIMEZONE" ]]; then
    timedatectl set-timezone "$TIMEZONE"
    log "Таймзона: $TIMEZONE"
  fi
  if [[ -n "$HOSTNAME_NEW" ]]; then
    hostnamectl set-hostname "$HOSTNAME_NEW"
    if grep -qE '^127\.0\.1\.1' /etc/hosts; then
      sed -i "s/^127\\.0\\.1\\.1.*/127.0.1.1 ${HOSTNAME_NEW}/" /etc/hosts
    else
      echo "127.0.1.1 ${HOSTNAME_NEW}" >> /etc/hosts
    fi
    log "Hostname: $HOSTNAME_NEW"
  fi
  log "Время: $(date '+%F %T %Z')"
}

create_admin() {
  [[ -n "$ADMIN_USER" ]] || return 0
  step "Пользователь ${ADMIN_USER}"
  if id "$ADMIN_USER" &>/dev/null; then
    log "Уже существует — использую"
  else
    useradd -m -s /bin/bash "$ADMIN_USER"
    log "Создан"
  fi
  if ! id -nG "$ADMIN_USER" | grep -qw sudo; then
    usermod -aG sudo "$ADMIN_USER"
  fi
  local sf="/etc/sudoers.d/90-${ADMIN_USER}"
  if [[ ! -f "$sf" ]]; then
    mkdir -p /etc/sudoers.d
    echo "${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL" > "$sf"
    chmod 440 "$sf"
    visudo -cf "$sf" >/dev/null || { rm -f "$sf"; die "sudoers не прошёл проверку — файл удалён"; }
    log "sudo: команды от root без пароля (NOPASSWD)"
  fi
  if [[ "$ADMIN_KEY_MODE" == "skip" || -z "$ADMIN_KEY_MODE" ]]; then
    warn "У $ADMIN_USER нет ключа и нет пароля (аккаунт заблокирован для входа) —"
    warn "добавь ключ в /home/${ADMIN_USER}/.ssh/authorized_keys, иначе в аккаунт не войти"
  fi
}

install_key_line() { # $1 = authorized_keys, $2 = строка ключа
  local ak="$1" key="$2"
  if command -v ssh-keygen >/dev/null 2>&1 && ! printf '%s\n' "$key" | ssh-keygen -lf - >/dev/null 2>&1; then
    warn "Ключ невалиден, пропускаю: $(awk '{print $1}' <<< "$key") ..."
    return 1
  fi
  touch "$ak"
  chmod 600 "$ak"
  grep -qxF "$key" "$ak" || echo "$key" >> "$ak"
}

install_admin_keys() {
  [[ -n "$ADMIN_USER" ]] || return 0
  step "SSH-ключи для ${ADMIN_USER}"
  local home="/home/${ADMIN_USER}"
  local ak="${home}/.ssh/authorized_keys"
  mkdir -p "${home}/.ssh"
  case "$ADMIN_KEY_MODE" in
    root)
      if [[ -s /root/.ssh/authorized_keys ]]; then
        local k added=0
        while IFS= read -r k; do
          [[ -z "$k" ]] && continue
          if install_key_line "$ak" "$k"; then added=$((added+1)); fi
        done < /root/.ssh/authorized_keys
        log "Скопировано ключей из root: $added"
      else
        warn "У root ключей нет — пропускаю"
      fi
      ;;
    generate)
      local kp="/root/${ADMIN_USER}-ed25519"
      if [[ -f "$kp" ]]; then
        log "Пара уже существует: $kp — использую"
      else
        ssh-keygen -t ed25519 -f "$kp" -N '' -C "${ADMIN_USER}@${HOSTNAME_NEW:-$(hostname)}" >/dev/null
      fi
      GENERATED_KEY_PATH="$kp"
      install_key_line "$ak" "$(cat "${kp}.pub")"
      chmod 600 "$kp"
      echo
      warn "────────────── СКАЧАЙ ПРИВАТНЫЙ КЛЮЧ ПРЯМО СЕЙЧАС ──────────────"
      cat "$kp"
      warn "Сохрани его локально (~/ .ssh/), затем удали с сервера:"
      warn "  shred -u $kp"
      warn "─────────────────────────────────────────────────────────────────"
      ;;
    paste)
      local k
      for k in "${ADMIN_SSH_KEYS[@]}"; do
        if install_key_line "$ak" "$k"; then
          log "Ключ добавлен: $(awk '{print $1}' <<< "$k")"
        fi
      done
      ;;
    *)
      log "Ключи не устанавливаю"
      ;;
  esac
  chmod 700 "${home}/.ssh"
  chown -R "${ADMIN_USER}:${ADMIN_USER}" "${home}/.ssh"
}

# Ключи, переданные через --ssh-key без --admin, кладём root-у
install_root_keys() {
  [[ -z "$ADMIN_USER" && "${#ADMIN_SSH_KEYS[@]}" -gt 0 ]] || return 0
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  local k
  for k in "${ADMIN_SSH_KEYS[@]}"; do
    if install_key_line /root/.ssh/authorized_keys "$k"; then
      log "Ключ добавлен root: $(awk '{print $1}' <<< "$k")"
    fi
  done
}

tune_network() {
  step "Сеть: BBR, IPv6, ping"

  modprobe tcp_bbr 2>/dev/null || true
  echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf 2>/dev/null || true

  cat > /etc/sysctl.d/99-net-tune.conf <<'EOF'
# BBR + fq. Больше ничего не трогаем: дефолтов ядра достаточно,
# а нестандартные значения давали нестабильность на части клиентов.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

  # Файл от старых версий скрипта — с другим именем и лишними словами
  if [[ -f /etc/sysctl.d/99-vpn-tune.conf ]]; then
    rm -f /etc/sysctl.d/99-vpn-tune.conf
    log "Удалён старый файл 99-vpn-tune.conf (заменён на 99-net-tune.conf)"
  fi

  local key
  local legacy_keys=(
    net.core.rmem_default net.core.wmem_default net.core.rmem_max net.core.wmem_max
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem
    net.ipv4.tcp_fastopen net.ipv4.tcp_slow_start_after_idle
    net.ipv4.tcp_mtu_probing net.ipv4.tcp_notsent_lowat
    net.core.somaxconn net.core.netdev_max_backlog
    net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_fin_timeout
    net.ipv4.ip_forward fs.file-max vm.swappiness
    net.ipv4.icmp_echo_ignore_all
    net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6
    net.core.default_qdisc net.ipv4.tcp_congestion_control
  )
  for key in "${legacy_keys[@]}"; do
    if grep -qE "^${key//./\\.}[[:space:]]*=" /etc/sysctl.conf 2>/dev/null; then
      sed -i "/^${key//./\\.}[[:space:]]*=/d" /etc/sysctl.conf
      LEGACY_CLEANED=true
    fi
  done
  if $LEGACY_CLEANED; then
    warn "Из /etc/sysctl.conf удалён тюнинг от старой версии скрипта."
    warn "Перезагрузи сервер (reboot) после работы скрипта, чтобы сбросились старые значения ядра."
  fi

  rm -f /etc/sysctl.d/99-disable-ipv6.conf
  if $DISABLE_IPV6; then
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    log "IPv6: отключаю"
  else
    sysctl -w net.ipv6.conf.all.disable_ipv6=0     >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.lo.disable_ipv6=0      >/dev/null 2>&1 || true
    log "IPv6: оставляю включённым (по умолчанию)"
  fi

  rm -f /etc/sysctl.d/99-block-ping.conf
  if $BLOCK_PING; then
    cat > /etc/sysctl.d/99-block-ping.conf <<'EOF'
net.ipv4.icmp_echo_ignore_all = 1
EOF
  fi

  sysctl --system >/dev/null 2>&1 || true

  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
    log "BBR включён"
  else
    warn "BBR не применился — проверь версию ядра (нужна 4.9+)"
  fi

  local ipv6_off
  ipv6_off="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)"
  if $DISABLE_IPV6; then
    if [[ "$ipv6_off" == "1" ]]; then
      log "IPv6 отключён"
    else
      warn "IPv6 не отключился (частая история на LXC) — проверь после перезагрузки или в панели хостера"
    fi
  else
    if [[ "$ipv6_off" == "0" ]]; then
      log "IPv6 включён"
    else
      warn "IPv6 сейчас отключён (остаток прошлых запусков/настройки хостера). Дроп-ин удалён — после перезагрузки IPv6 вернётся"
    fi
  fi

  if [[ "$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null)" == "1" ]]; then
    log "Входящий ping заблокирован"
  elif $BLOCK_PING; then
    warn "icmp_echo_ignore_all не применился (возможно, LXC) — проверь после перезагрузки"
  fi
}

system_limits() {
  step "Системные лимиты и журнал"
  mkdir -p /etc/security/limits.d
  cat > /etc/security/limits.d/99-increase-limits.conf <<'EOF'
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
  log "Лимиты и размер журнала настроены"
}

# Сканирование слушающих портов → LISTEN_* (не меняет ничего)
port_survey_scan() {
  LISTEN_NET=(); LISTEN_PORT=(); LISTEN_ADDR=(); LISTEN_PROC=()
  local -a f
  local proc_name port
  while read -r -a f; do
    case "${f[0]:-}" in tcp|udp) ;; *) continue ;; esac
    port="${f[4]##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    proc_name="$(sed -n 's/^users:(("\([^"]*\)".*/\1/p' <<< "${f[6]:-}")"
    [[ -z "$proc_name" ]] && proc_name="?"
    LISTEN_NET+=("${f[0]}"); LISTEN_PORT+=("$port"); LISTEN_ADDR+=("${f[4]}"); LISTEN_PROC+=("$proc_name")
  done < <(ss -H -tulnp 2>/dev/null || true)
}

port_survey_print() {
  step "Аудит портов"
  port_survey_scan
  if (( ${#LISTEN_PORT[@]} == 0 )); then
    warn "Слушающих портов не нашлось (или ss не сработал)"
    return 0
  fi
  local ssh_p="${SSH_PORT:-$CURR_SSH_PORT}"
  local -A grp=()
  local -a grp_keys=()
  local -A seen=()
  local -a loc=()
  local i net port proc ip key
  for i in "${!LISTEN_PORT[@]}"; do
    net="${LISTEN_NET[$i]}"; port="${LISTEN_PORT[$i]}"; proc="${LISTEN_PROC[$i]}"
    ip="${LISTEN_ADDR[$i]%:*}"; ip="${ip#[}"; ip="${ip%]}"
    key="$net:$port"
    [[ -n "${seen[$key]:-}" ]] && continue   # один порт в v4+v6 — показываем один раз
    seen[$key]=1
    if addr_is_external "$ip"; then
      key="$net|$proc"
      if [[ -z "${grp[$key]:-}" ]]; then
        grp_keys+=("$key"); grp[$key]="$port"
      else
        grp[$key]+=" $port"
      fi
    else
      loc+=("$port/$net ($proc)")
    fi
  done
  echo "  Слушается снаружи:"
  if (( ${#grp_keys[@]} == 0 )); then
    echo "    (ничего)"
  fi
  local k nl mark cnt label
  local -a ports=()
  for k in "${grp_keys[@]}"; do
    net="${k%%|*}"; proc="${k#*|}"
    # shellcheck disable=SC2086  # список числовых портов — разворот в столбец для sort
    nl="$(printf '%s\n' ${grp[$k]} | sort -n | tr '\n' ' ')"
    read -r -a ports <<< "$nl"
    local count=${#ports[@]}
    if (( count == 1 )); then
      label="${ports[0]}"
    elif (( count <= 6 )); then
      label="$(printf '%s, ' "${ports[@]}")"
      label="${label%, }"
    else
      label="$(printf '%s, ' "${ports[0]}" "${ports[1]}" "${ports[2]}")… +ещё $(( count - 3 ))"
    fi
    cnt=""
    if (( count > 1 )); then
      cnt="$count $(ru_plural "$count" порт порта портов): "
    fi
    mark=""
    if [[ "$net" == tcp && " ${grp[$k]} " == *" $ssh_p "* ]]; then
      mark="   ← порт SSH (открою отдельно)"
    fi
    printf '    %-4s %-14s %s%s\n' "$net" "$proc" "$cnt$label" "$mark"
  done
  if (( ${#loc[@]} > 0 )); then
    echo "  Локальные (127.0.0.0/8 и т.п. — фаервол их не касается): ${loc[*]}"
  fi
}

# Сколько внешних (не локальных, не SSH) портов слушается: → tcp, udp
count_external_ports() {
  local __t="$1" __u="$2"
  local i ip port net key ext_t=0 ext_u=0
  local -A seen=()
  local ssh_p="${SSH_PORT:-$CURR_SSH_PORT}"
  for i in "${!LISTEN_PORT[@]}"; do
    net="${LISTEN_NET[$i]}"; port="${LISTEN_PORT[$i]}"
    ip="${LISTEN_ADDR[$i]%:*}"; ip="${ip#[}"; ip="${ip%]}"
    addr_is_external "$ip" || continue
    [[ "$net" == tcp && "$port" == "$ssh_p" ]] && continue
    key="$net:$port"
    [[ -n "${seen[$key]:-}" ]] && continue
    seen[$key]=1
    if [[ "$net" == tcp ]]; then ext_t=$((ext_t+1)); else ext_u=$((ext_u+1)); fi
  done
  printf -v "$__t" '%s' "$ext_t"
  printf -v "$__u" '%s' "$ext_u"
}

# Заполняет OPEN_PORTS всеми внешними слушающими портами (с их протоколами)
collect_external_ports() {
  local i ip port net key
  local -A seen=()
  local ssh_p="${SSH_PORT:-$CURR_SSH_PORT}"
  OPEN_PORTS=""
  for i in "${!LISTEN_PORT[@]}"; do
    net="${LISTEN_NET[$i]}"; port="${LISTEN_PORT[$i]}"
    ip="${LISTEN_ADDR[$i]%:*}"; ip="${ip#[}"; ip="${ip%]}"
    addr_is_external "$ip" || continue
    [[ "$net" == tcp && "$port" == "$ssh_p" ]] && continue
    key="$net:$port"
    [[ -n "${seen[$key]:-}" ]] && continue
    seen[$key]=1
    OPEN_PORTS+="${OPEN_PORTS:+,}${port}/${net}"
  done
}

# Сопоставление «слушается» ↔ «открываем». Предупреждения — по процессам, не по портам.
audit_ports() {
  local ssh_p="${SSH_PORT:-$CURR_SSH_PORT}"
  local -A miss=()
  local -a miss_keys=()
  local i ip port net proc key
  for i in "${!LISTEN_PORT[@]}"; do
    net="${LISTEN_NET[$i]}"; port="${LISTEN_PORT[$i]}"; proc="${LISTEN_PROC[$i]}"
    ip="${LISTEN_ADDR[$i]%:*}"; ip="${ip#[}"; ip="${ip%]}"
    addr_is_external "$ip" || continue
    [[ "$net" == tcp && "$port" == "$ssh_p" ]] && continue
    port_in_specs "$net" "$port" && continue
    key="$net|$proc"
    if [[ -z "${miss[$key]:-}" ]]; then
      miss_keys+=("$key"); miss[$key]="$port"
    else
      miss[$key]+=" $port"
    fi
  done
  local k nl count what
  local -a mports=()
  for k in "${miss_keys[@]}"; do
    net="${k%%|*}"; proc="${k#*|}"
    # shellcheck disable=SC2086  # список числовых портов — разворот в столбец для sort
    nl="$(printf '%s\n' ${miss[$k]} | sort -n | tr '\n' ' ')"
    read -r -a mports <<< "$nl"
    count=${#mports[@]}
    if (( count <= 3 )); then
      nl="$(printf '%s, ' "${mports[@]}")"
      nl="${nl%, }"
    else
      nl="$(printf '%s, ' "${mports[0]}" "${mports[1]}" "${mports[2]}")… +ещё $(( count - 3 ))"
    fi
    what="$(ru_plural "$count" порт порта портов)"
    if (( count == 1 )); then
      warn "«$proc» ($net): порт $nl слушается, но его нет в списке — UFW закроет доступ извне"
    else
      warn "«$proc» ($net): $count $what слушаются, но их нет в списке — UFW закроет доступ извне: $nl"
    fi
  done

  # Наоборот: открыли, а никто не слушает — норма до деплоя
  local j p pr pr2 lo hi found seen_info=" "
  local -a protos=()
  for j in "${!PORTS_NUM[@]}"; do
    p="${PORTS_NUM[$j]}"; pr="${PORTS_PROTO[$j]}"
    protos=("$pr")
    [[ "$pr" == "both" ]] && protos=(tcp udp)
    for pr2 in "${protos[@]}"; do
      key="$pr2:$p"
      [[ "$seen_info" == *" $key "* ]] && continue
      found=false
      for i in "${!LISTEN_PORT[@]}"; do
        [[ "${LISTEN_NET[$i]}" == "$pr2" ]] || continue
        if [[ "$p" == *:* ]]; then
          lo="${p%%:*}"; hi="${p##*:}"
          port="${LISTEN_PORT[$i]}"
          if (( port >= lo && port <= hi )); then found=true; break; fi
        else
          if (( LISTEN_PORT[i] == p )); then found=true; break; fi
        fi
      done
      if ! $found; then
        seen_info+=" $key "
        log "Порт $p/$pr2 открыт — пока никто не слушает (норма до деплоя)"
      fi
    done
  done
}

setup_fail2ban() {
  step "Fail2ban"
  local port="${SSH_PORT:-$CURR_SSH_PORT}"
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
  log "Fail2ban: бан после 4 неудачных входов, эскалация до 1 недели (порт $port)"
}

setup_firewall() {
  step "Фаервол UFW"
  local ssh_p="${SSH_PORT:-$CURR_SSH_PORT}"
  ufw limit "${ssh_p}/tcp" comment 'SSH' >/dev/null

  # При смене порта старое правило для 22 убираем
  if [[ "$ssh_p" != "22" ]] && ufw status | grep -qE '^22/tcp'; then
    ufw delete limit 22/tcp >/dev/null 2>&1 || true
    ufw delete allow 22/tcp >/dev/null 2>&1 || true
    log "Старое правило для порта 22 убрано из UFW"
  fi

  local i p pr
  for i in "${!PORTS_NUM[@]}"; do
    p="${PORTS_NUM[$i]}"; pr="${PORTS_PROTO[$i]}"
    case "$pr" in
      tcp)  ufw allow "${p}/tcp" comment 'node' >/dev/null ;;
      udp)  ufw allow "${p}/udp" comment 'node' >/dev/null ;;
      both) ufw allow "${p}/tcp" comment 'node' >/dev/null
            ufw allow "${p}/udp" comment 'node' >/dev/null ;;
    esac
    log "Открыт порт: $p/$pr"
  done
  if (( ${#PORTS_NUM[@]} == 0 )); then
    warn "Порты не открыты. Для сервисов потом: ufw allow ПОРТ/tcp (или /udp)"
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

  # Ключи есть хотя бы у кого-то на сервере?
  local have_keys=false d
  for d in /root /home/*; do
    [[ -s "$d/.ssh/authorized_keys" ]] && have_keys=true
  done

  if $DISABLE_SSH_PASSWORD; then
    if $have_keys; then
      conf+="PasswordAuthentication no"$'\n'
      conf+="KbdInteractiveAuthentication no"$'\n'
      if [[ -n "$ADMIN_USER" ]]; then
        conf+="PermitRootLogin no"$'\n'
        log "Вход по паролю отключён, root по SSH закрыт (работаем под $ADMIN_USER)"
      else
        conf+="PermitRootLogin prohibit-password"$'\n'
        log "Вход по паролю отключён (root — только по ключу)"
      fi
    else
      warn "Просили отключить пароли, но ключей на сервере нет — НЕ отключаю (иначе потеряешь доступ)"
    fi
  fi

  printf '%s' "$conf" > "$cfg"
  sshd -t || die "Конфиг sshd не проходит проверку — смотри $cfg"
  systemctl restart ssh 2>/dev/null || systemctl restart sshd

  local eport="${SSH_PORT:-$CURR_SSH_PORT}"
  echo
  warn "ВАЖНО: проверь вход В НОВОМ окне терминала, не закрывая текущую сессию:"
  warn "  ssh -p ${eport} ${ADMIN_USER:-root}@<IP сервера>"
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
  if ! $INSTALL_DOCKER; then return 0; fi
  step "Docker"
  if command -v docker >/dev/null 2>&1; then
    log "Docker уже установлен: $(docker --version)"
  else
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    systemctl enable --now docker
    log "Docker установлен: $(docker --version)"
  fi
  if [[ -n "$ADMIN_USER" ]] && id "$ADMIN_USER" &>/dev/null; then
    if ! id -nG "$ADMIN_USER" | grep -qw docker; then
      usermod -aG docker "$ADMIN_USER"
      log "$ADMIN_USER добавлен в группу docker (вступит в силу при следующем входе)"
    fi
  fi
}

summary() {
  local ipaddr ssh_p
  ssh_p="${SSH_PORT:-$CURR_SSH_PORT}"
  ipaddr="$(curl -s4 -m 5 https://api.ipify.org || echo 'не удалось определить')"
  echo -e "\n${C}════════════════════ ИТОГ ════════════════════${N}"
  echo -e "Хостнейм:     $(hostname)"
  echo -e "IP:           $ipaddr"
  echo -e "SSH порт:     $ssh_p"
  if [[ -n "$ADMIN_USER" ]]; then
    echo -e "Пользователь: $ADMIN_USER (sudo без пароля)"
  fi
  echo -e "Вход:         ssh -p $ssh_p ${ADMIN_USER:-root}@$ipaddr"
  if [[ -n "$GENERATED_KEY_PATH" ]]; then
    echo -e "Приват.ключ:  $GENERATED_KEY_PATH — скачай и удали: shred -u $GENERATED_KEY_PATH"
  fi
  if grep -qs '^PasswordAuthentication no' /etc/ssh/sshd_config.d/99-hardening.conf; then
    echo -e "Вход паролем: выключен (только ключи)"
  else
    echo -e "Вход паролем: включён"
  fi
  echo -e "BBR:          $(sysctl -n net.ipv4.tcp_congestion_control)"
  echo -e "Ping (ICMP):  $( [[ $(cat /proc/sys/net/ipv4/icmp_echo_ignore_all) -eq 1 ]] && echo 'заблокирован' || echo 'разрешён' )"
  echo -e "IPv6:         $( [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 1 ]] && echo 'отключён' || echo 'включён' )"
  echo -e "Fail2ban:     $(systemctl is-active fail2ban 2>/dev/null || echo 'выключен')"
  echo -e "UFW:          $(ufw status 2>/dev/null | head -n1 | awk '{print $2}')"
  echo -e "Docker:       $(command -v docker >/dev/null 2>&1 && docker --version || echo 'нет')"
  if [[ -f /var/run/reboot-required ]]; then
    echo -e "${Y}Внимание:    требуется перезагрузка (reboot) — обновились системные компоненты${N}"
  fi
  if $LEGACY_CLEANED; then
    echo -e "${Y}Внимание:    удалён старый тюнинг из /etc/sysctl.conf — рекомендуется reboot${N}"
  fi
  echo -e "${C}══════════════════════════════════════════════${N}"
}

#----------------------- ВАЛИДАЦИЯ ОТВЕТОВ ----------------------
validate_settings() {
  if [[ -n "$SSH_PORT" ]]; then
    is_valid_port "$SSH_PORT" || die "Порт SSH «$SSH_PORT» — не число из диапазона 1–65535"
    if [[ "$SSH_PORT" == "$CURR_SSH_PORT" ]]; then
      warn "Порт SSH совпадает с текущим — оставляю как есть"
      SSH_PORT=""
    fi
  fi
  if [[ -n "$TIMEZONE" ]] && ! is_valid_timezone "$TIMEZONE"; then
    die "Таймзоны «$TIMEZONE» нет в системе (список: timedatectl list-timezones)"
  fi
  if [[ -n "$HOSTNAME_NEW" ]] && ! is_valid_hostname "$HOSTNAME_NEW"; then
    die "Hostname «$HOSTNAME_NEW» не подходит: латиница, цифры, дефис, до 63 символов"
  fi
  parse_port_specs

  if [[ -n "$ADMIN_USER" ]]; then
    is_valid_username "$ADMIN_USER" || die "Имя «$ADMIN_USER» не подходит: маленькие латинские буквы, цифры, '-' и '_', до 32 символов"
    is_reserved_username "$ADMIN_USER" && die "Имя «$ADMIN_USER» занято системным пользователем"
  fi

  case "$ADMIN_KEY_MODE" in
    ""|paste|root|generate|skip) ;;
    *) die "Неизвестный режим ключа: $ADMIN_KEY_MODE" ;;
  esac
  if [[ "$ADMIN_KEY_MODE" == "root" && ! -s /root/.ssh/authorized_keys ]]; then
    warn "У root нет ключей — режим «взять ключи root» пропускаю"
    ADMIN_KEY_MODE="skip"
  fi
  if [[ "$ADMIN_KEY_MODE" == "paste" && ${#ADMIN_SSH_KEYS[@]} -eq 0 ]]; then
    if $INTERACTIVE; then
      warn "Ключей не вставлено — вход по ключу не настраиваю"
      ADMIN_KEY_MODE="skip"
    else
      die "--ssh-key: передай хотя бы один публичный ключ"
    fi
  fi
  local k
  for k in "${ADMIN_SSH_KEYS[@]}"; do
    is_valid_pubkey "$k" || die "Строка не похожа на публичный SSH-ключ: ${k:0:30}..."
  done

  # Не-интерактивный --admin без ключа = аккаунт, в который невозможно войти
  if [[ -n "$ADMIN_USER" && ( -z "$ADMIN_KEY_MODE" || "$ADMIN_KEY_MODE" == "skip" ) ]] && ! $INTERACTIVE; then
    die "--admin без ключа в неинтерактивном режиме: у аккаунта нет пароля, войти будет нельзя. Добавь --ssh-key / --key-from-root / --generate-key"
  fi
}

#----------------------- МАСТЕР ---------------------------------
read_pasted_keys() {
  log "Вставь публичный ключ: ssh-ed25519 AAAA... комментарий"
  log "Пустая строка — закончить ввод."
  ADMIN_SSH_KEYS=()
  local n=0
  while true; do
    REPLY=""
    if ! read_answer "  ключ > "; then break; fi
    [[ -z "$REPLY" ]] && break
    if is_valid_pubkey "$REPLY"; then
      ADMIN_SSH_KEYS+=("$REPLY")
      n=$((n+1))
      log "  принят: $(awk '{print $1}' <<< "$REPLY")"
    else
      warn "  не похоже на SSH-ключ — не принято"
    fi
  done
  if (( n == 0 )); then
    warn "Ни одного ключа не введено"
    ADMIN_KEY_MODE="skip"
  fi
}

wizard_questions() {
  step "Мастер настройки"
  log "Отвечай на вопросы; Enter принимает значение в квадратных скобках."
  log "Ничего не меняется, пока в конце не подтвердишь план."
  echo

  if [[ -z "$TIMEZONE" ]]; then
    while true; do
      get_answer TIMEZONE "Таймзона, например Europe/Amsterdam (пусто — не менять)" ""
      if [[ -z "$TIMEZONE" ]]; then break; fi
      if is_valid_timezone "$TIMEZONE"; then break; fi
      warn "Такой таймзоны нет — список: timedatectl list-timezones"
      TIMEZONE=""
    done
  fi

  if [[ -z "$HOSTNAME_NEW" ]]; then
    while true; do
      get_answer HOSTNAME_NEW "Hostname (пусто — оставить «$(hostname)»)" ""
      if [[ -z "$HOSTNAME_NEW" ]]; then break; fi
      if is_valid_hostname "$HOSTNAME_NEW"; then break; fi
      warn "Латиница, цифры, дефис; не длиннее 63 символов"
      HOSTNAME_NEW=""
    done
  fi

  if [[ -z "$SSH_PORT" ]]; then
    local _p
    while true; do
      get_answer _p "Порт SSH (пусто — оставить $CURR_SSH_PORT)" ""
      if [[ -z "$_p" ]]; then break; fi
      if ! is_valid_port "$_p"; then warn "Число от 1 до 65535"; continue; fi
      if [[ "$_p" != "$CURR_SSH_PORT" ]]; then SSH_PORT="$_p"; fi
      break
    done
  fi

  if [[ -z "$ADMIN_USER" ]]; then
    local _u
    while true; do
      get_answer _u "Пользователь для работы ('-' — остаться под root)" "admin"
      if [[ "$_u" == "-" ]]; then break; fi
      if ! is_valid_username "$_u"; then warn "Маленькие латинские буквы, цифры, '-' и '_'; до 32 символов"; continue; fi
      if is_reserved_username "$_u"; then warn "Это имя занято системой"; continue; fi
      ADMIN_USER="$_u"
      break
    done
    if [[ -n "$ADMIN_USER" ]] && id "$ADMIN_USER" &>/dev/null; then
      log "Пользователь $ADMIN_USER уже существует — использую его"
    fi
  fi

  if [[ -n "$ADMIN_USER" && -z "$ADMIN_KEY_MODE" ]]; then
    local root_keys=0
    if [[ -s /root/.ssh/authorized_keys ]]; then
      root_keys="$(grep -cE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys || true)"
    fi
    echo
    log "Как дать $ADMIN_USER доступ по SSH-ключу?"
    echo -e "  ${C}1${N} — вставить публичный ключ (рекомендую)"
    if (( root_keys > 0 )); then
      echo -e "  ${C}2${N} — взять ключи root (найдено: $root_keys)"
    fi
    echo -e "  ${C}3${N} — сгенерировать пару на сервере (приватный покажу один раз)"
    echo -e "  ${C}4${N} — без ключа (настроишь потом)"
    local _choice
    while true; do
      get_answer _choice "Выбор" "1"
      case "$_choice" in
        1) ADMIN_KEY_MODE="paste"; break ;;
        2) if (( root_keys > 0 )); then ADMIN_KEY_MODE="root"; break; else warn "У root нет ключей"; fi ;;
        3) ADMIN_KEY_MODE="generate"; break ;;
        4) ADMIN_KEY_MODE="skip"; break ;;
        *) warn "Введи цифру варианта" ;;
      esac
    done
    if [[ "$ADMIN_KEY_MODE" == "paste" ]]; then
      echo
      read_pasted_keys
    fi
  fi

  port_survey_print

  if ! flag_seen "ports"; then
    local ext_tcp=0 ext_udp=0
    count_external_ports ext_tcp ext_udp
    local _choice
    echo
    log "Как поступить с портами для внешнего доступа?"
    echo -e "  ${C}1${N} — открыть всё, что уже слушается извне (tcp: $ext_tcp, udp: $ext_udp)"
    echo -e "  ${C}2${N} — задать список вручную (порт[/tcp|udp|both] или диапазон 30000-40000/udp, через запятую)"
    echo -e "  ${C}3${N} — ничего не открывать"
    local def="1"
    if (( ext_tcp + ext_udp == 0 )); then def="2"; fi
    while true; do
      get_answer _choice "Выбор" "$def"
      case "$_choice" in
        1)
          if (( ext_tcp + ext_udp > 0 )); then collect_external_ports; else OPEN_PORTS=""; fi
          break ;;
        2)
          get_answer OPEN_PORTS "Порты (например 443/tcp,8443/udp,30000-40000/udp)" ""
          OPEN_PORTS="${OPEN_PORTS// /}"
          break ;;
        3)
          OPEN_PORTS=""
          break ;;
        *) warn "Введи 1, 2 или 3" ;;
      esac
    done
  fi
  parse_port_specs
  audit_ports
  echo

  if ! flag_seen "disable-ipv6"; then
    ask_yes "Отключить IPv6?" n && DISABLE_IPV6=true
  fi
  if ! flag_seen "no-block-ping"; then
    ask_yes "Не отвечать на ping (ICMP)?" y || BLOCK_PING=false
  fi
  if ! flag_seen "no-swap"; then
    ask_yes "Создать swap?" y || SETUP_SWAP=false
  fi
  if ! flag_seen "no-fail2ban"; then
    ask_yes "Поставить fail2ban (бан брутфорса SSH)?" y || SKIP_FAIL2BAN=true
  fi
  if ! flag_seen "no-ssh-harden"; then
    ask_yes "Харденинг SSH (без X11/агента, лимит попыток)?" y || HARDEN_SSH=false
  fi
  if ! flag_seen "no-docker"; then
    ask_yes "Установить Docker?" y || INSTALL_DOCKER=false
  fi
  if ! flag_seen "purge-cloudinit"; then
    ask_yes "Удалить cloud-init? (только если VPS без него обходится)" n && PURGE_CLOUDINIT=true
  fi
  if ! flag_seen "disable-ssh-password"; then
    local keys_ahead=false
    if [[ -n "$ADMIN_USER" && "$ADMIN_KEY_MODE" != "skip" ]]; then keys_ahead=true; fi
    if [[ -s /root/.ssh/authorized_keys ]]; then keys_ahead=true; fi
    if [[ -n "$ADMIN_USER" && -s "/home/${ADMIN_USER}/.ssh/authorized_keys" ]]; then keys_ahead=true; fi
    if $keys_ahead; then
      ask_yes "Отключить вход по паролю (останутся только ключи)?" y && DISABLE_SSH_PASSWORD=true
    else
      ask_yes "Отключить вход по паролю? (ключей на сервере нет — сначала добавь ключ)" n && DISABLE_SSH_PASSWORD=true
    fi
  fi
  echo
}

show_plan() {
  local i specs="" total=${#PORTS_NUM[@]}
  for i in "${!PORTS_NUM[@]}"; do
    if (( i < 10 )); then specs+="${PORTS_NUM[$i]}/${PORTS_PROTO[$i]}  "; fi
  done
  if (( total > 10 )); then specs+="… (+ещё $(( total - 10 )))"; fi
  if [[ -z "$specs" ]]; then specs="никакие"; fi
  echo
  echo -e "${C}──────────────── План настройки ────────────────${N}"
  echo "  Таймзона:      ${TIMEZONE:-не менять}"
  echo "  Hostname:      ${HOSTNAME_NEW:-оставить «$(hostname)»}"
  echo "  Порт SSH:      ${SSH_PORT:-остаётся $CURR_SSH_PORT}"
  if [[ -n "$ADMIN_USER" ]]; then
    echo "  Пользователь:  $ADMIN_USER (sudo без пароля), ключ: ${ADMIN_KEY_MODE}"
    if [[ "$ADMIN_KEY_MODE" == "generate" ]]; then
      echo "                 приватный ключ будет показан в конце — сохрани его!"
    fi
  else
    echo "  Пользователь:  работаем под root"
  fi
  echo "  Порты наружу:  $specs"
  if $DISABLE_SSH_PASSWORD; then
    echo "  Пароли SSH:    отключить (только ключи)"
  else
    echo "  Пароли SSH:    оставить включёнными"
  fi
  echo "  IPv6:          $( $DISABLE_IPV6 && echo 'отключить' || echo 'оставить' )"
  echo "  Ping (ICMP):   $( $BLOCK_PING && echo 'блокировать' || echo 'разрешить' )"
  echo "  Swap:          $( $SETUP_SWAP && echo 'да' || echo 'нет' )"
  echo "  Fail2ban:      $( $SKIP_FAIL2BAN && echo 'нет' || echo 'да' )"
  echo "  Docker:        $( $INSTALL_DOCKER && echo 'да' || echo 'нет' )"
  echo "  cloud-init:    $( $PURGE_CLOUDINIT && echo 'удалить' || echo 'не трогать' )"
  echo -e "${C}─────────────────────────────────────────────────${N}"
}

#----------------------- MAIN -----------------------------------
main() {
  precheck

  if have_tty; then
    INTERACTIVE=true
    wizard_questions
  else
    log "Интерактивного терминала нет — работаю по флагам и значениям по умолчанию"
  fi

  validate_settings

  if $INTERACTIVE; then
    show_plan
    echo
    if ! ask_yes "Запускаем настройку?" y; then
      die "Отменено — ничего не менял."
    fi
    WIZARD_RAN=true
  fi

  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  update_system
  install_base
  set_time_and_host
  create_admin
  install_root_keys
  install_admin_keys
  tune_network
  system_limits
  if ! $WIZARD_RAN; then
    port_survey_print
    audit_ports
  fi
  if ! $SKIP_FAIL2BAN; then setup_fail2ban; fi
  setup_firewall
  configure_ssh
  if $SETUP_SWAP; then setup_swap; fi
  cleanup
  install_docker
  summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  parse "$@"
  main
fi
