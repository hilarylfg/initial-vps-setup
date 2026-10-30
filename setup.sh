#!/usr/bin/env bash
#================================================================
#  setup.sh — первоначальная настройка VPS
#
#  Поддержка: Ubuntu 20.04+ / Debian 11+, запуск от root.
#  Без аргументов — интерактивный мастер: спросит всё и покажет план.
#  Флаги задают ответы заранее; --doctor — только проверка, без изменений.
#  Каждое действие проверяется по факту; итог — таблица [OK]/[WARN]/[FAIL].
#  Полный лог: /var/log/vps-setup-<дата>.log (права 600).
#================================================================

set -euo pipefail
set -E   # errtrace: ERR-trap срабатывает и внутри функций

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
NO_UPDATE=false     # пропустить apt upgrade (update всё равно выполняется)
NO_FIREWALL=false   # не трогать UFW и порты вообще
NO_SSH=false        # не менять настройки sshd вообще
DOCTOR=false        # только проверка, без изменений

#----------------------- СОСТОЯНИЕ ------------------------------
FLAGS_SEEN=" "
INTERACTIVE=false
LEGACY_CLEANED=false
CURR_SSH_PORT="22"
CURR_SSH_SOURCE="default"   # ss | socket | sshd-t | default
LOG_FILE=""
FAIL_COUNT=0
PORTS_NUM=()
PORTS_PROTO=()
LISTEN_NET=()
LISTEN_PORT=()
LISTEN_ADDR=()
LISTEN_PROC=()
STATE_DIR="/var/lib/vps-setup"
SSH_HARDENING_CFG="/etc/ssh/sshd_config.d/00-hardening.conf"
SSH_LEGACY_CFG="/etc/ssh/sshd_config.d/99-hardening.conf"

#----------------------- ЛОГИ -----------------------------------
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
CURRENT_STEP="инициализация"
log()  { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
die()  { echo -e "${R}[x]${N} $*" >&2; exit 1; }
step() { CURRENT_STEP="$*"; echo -e "\n${C}━━━ $* ━━━${N}"; }
trap 'echo -e "\n${R}Неожиданная ошибка на шаге «${CURRENT_STEP}» (строка $LINENO). Текущая SSH-сессия не закрыта — сервер доступен. Лог: ${LOG_FILE:-нет}${N}"' ERR

#----------------------- ОТЧЁТ (выполнил → проверил → отчитался) --
declare -A CHECK_STATUS=()
declare -A CHECK_HINT=()
CHECK_ORDER=()
FAILED_STEPS=()

report() { # report "Имя" ok|warn|fail "пояснение"
  local name="$1" st="$2" hint="${3:-}"
  if [[ -z "${CHECK_STATUS[$name]:-}" ]]; then
    CHECK_ORDER+=("$name")
  fi
  CHECK_STATUS[$name]="$st"
  CHECK_HINT[$name]="$hint"
  case "$st" in
    ok)   log "$name: OK${hint:+ — $hint}" ;;
    warn) warn "$name: ВНИМАНИЕ${hint:+ — $hint}" ;;
    *)    echo -e "${R}[✗]${N} $name: НЕ УДАЛОСЬ${hint:+ — $hint}" >&2 ;;
  esac
}

run_step() { # run_step "Имя шага" функция — падение шага не убивает остальные
  local name="$1"; shift
  step "$name"
  local rc=0
  "$@" || rc=$?
  if (( rc != 0 )); then
    FAILED_STEPS+=("$name")
    warn "Шаг «$name» завершился с ошибкой (код $rc) — продолжаю остальные, смотри отчёт в конце"
  fi
}

print_report() {
  echo
  echo -e "${C}──────────── Результат (проверено по факту) ────────────${N}"
  local name st ok=0 wn=0 fl=0
  for name in "${CHECK_ORDER[@]}"; do
    st="${CHECK_STATUS[$name]}"
    case "$st" in
      ok)   printf '  %b[ OK ]%b %-22s %s\n' "$G" "$N" "$name" "${CHECK_HINT[$name]}"; ok=$((ok+1)) ;;
      warn) printf '  %b[WARN]%b %-22s %s\n' "$Y" "$N" "$name" "${CHECK_HINT[$name]}"; wn=$((wn+1)) ;;
      *)    printf '  %b[FAIL]%b %-22s %s\n' "$R" "$N" "$name" "${CHECK_HINT[$name]}"; fl=$((fl+1)) ;;
    esac
  done
  echo -e "${C}─────────────────────────────────────────────────────────${N}"
  printf '  Итог: %d OK, %d предупреждений, %d неудач\n' "$ok" "$wn" "$fl"
  FAIL_COUNT=$fl
  if (( fl > 0 )); then
    warn "Не всё применилось — сервер работает, но проверь позиции FAIL. Лог: ${LOG_FILE:-нет}"
  fi
}

setup_log() {
  LOG_FILE="/var/log/vps-setup-$(date +%Y%m%d-%H%M%S).log"
  if touch "$LOG_FILE" 2>/dev/null; then
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "Лог установки: $LOG_FILE"
  else
    LOG_FILE=""
    warn "Не удалось создать лог-файл в /var/log — работаю без лога"
  fi
}

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

# ask_yes "вопрос" y|n → 0 = да. Сравнение целых строк — работает в любой локали
# (в C-локали срез ${var:0:1} отрезает байт, а не символ, и кириллица ломается)
ask_yes() {
  local __def="${2:-n}"
  if ! read_answer "$1 [${__def}]: " || [[ -z "$REPLY" ]]; then
    REPLY="$__def"
  fi
  case "$REPLY" in
    y|Y|yes|Yes|YES|д|Д|да|Да|ДА) return 0 ;;
    *) return 1 ;;
  esac
}

# Вопрос задаётся только если соответствующий флаг не задан
flag_seen() { [[ "$FLAGS_SEEN" == *" $1 "* ]]; }

#----------------------- ВАЛИДАЦИЯ ------------------------------
# 10# — принудительно десятичная база: «022» это 22, а не октал
is_valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
  local p=$((10#$1))
  (( p >= 1 && p <= 65535 ))
}

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

is_valid_timezone() { grep -qxF "$1" <<< "$(timedatectl list-timezones 2>/dev/null)"; }

# «Снаружи» = wildcard или публичный IP. Локальные/приватные/служебные — мимо.
addr_is_external() {
  local ip="$1"
  case "$ip" in
    '*'|0.0.0.0|'[::]'|'::') return 0 ;;
    127.*|::1|'[::1]'|169.254.*|10.*|192.168.*) return 1 ;;
    # CGNAT 100.64.0.0/10
    100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 1 ;;
    172.*)
      local o2="${ip#*.}"
      o2="${o2%%.*}"
      if [[ "$o2" =~ ^[0-9]+$ ]] && (( o2 >= 16 && o2 <= 31 )); then return 1; fi
      return 0 ;;
    224.*|225.*|226.*|227.*|228.*|229.*|23[0-9].*|2[4-9][0-9].*) return 1 ;;
    # IPv6: ULA fc00::/7, link-local fe80::/10, multicast ff00::/8
    f[cd]*|F[CD]*|fe[89ab]*|FE[89AB]*|ff*|FF*) return 1 ;;
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

  --doctor                  только проверить сервер и показать отчёт,
                            ничего не меняя
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
  --disable-ipv6            отключить IPv6
  --no-update               не обновлять пакеты (apt update всё равно пройдёт)
  --no-firewall             не трогать фаервол и порты: UFW остаётся как есть
  --no-ssh                  не менять настройки sshd: порт, харденинг, пароли
  --no-docker               не ставить Docker
  --no-fail2ban             не ставить и не настраивать fail2ban
  --no-block-ping           НЕ блокировать ответы на ping
  --no-swap                 не создавать swap
  --no-ssh-harden           не применять харденинг SSH
  --disable-ssh-password    отключить вход по паролю (нужен ключ на сервере!)
  --purge-cloudinit         удалить cloud-init (только если VPS без него обходится)
  -h, --help                эта справка

Примеры:
  bash setup.sh                                          # мастер
  bash setup.sh --doctor                                 # только проверка
  bash setup.sh --admin deploy --ssh-key "$(cat ~/.ssh/id_ed25519.pub)" \
       --ssh-port 2222 --ports 443/tcp,8443/udp --timezone Europe/Amsterdam
EOF
}

need() { [[ -n "${2:-}" ]] || die "$1: укажи значение"; }

parse() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --doctor)               DOCTOR=true; FLAGS_SEEN+="doctor "; shift ;;
      --ssh-port)             need "$1" "${2:-}"; SSH_PORT="$2"; FLAGS_SEEN+="ssh-port "; shift 2 ;;
      --ports)                need "$1" "${2:-}"; OPEN_PORTS="$2"; FLAGS_SEEN+="ports "; shift 2 ;;
      --timezone)             need "$1" "${2:-}"; TIMEZONE="$2"; FLAGS_SEEN+="timezone "; shift 2 ;;
      --admin)                need "$1" "${2:-}"; ADMIN_USER="$2"; FLAGS_SEEN+="admin "; shift 2 ;;
      --ssh-key)              need "$1" "${2:-}"; ADMIN_SSH_KEYS+=("$2"); ADMIN_KEY_MODE="paste"; FLAGS_SEEN+="ssh-key "; shift 2 ;;
      --key-from-root)        ADMIN_KEY_MODE="root"; FLAGS_SEEN+="key-from-root "; shift ;;
      --generate-key)         ADMIN_KEY_MODE="generate"; FLAGS_SEEN+="generate-key "; shift ;;
      --hostname)             need "$1" "${2:-}"; HOSTNAME_NEW="$2"; FLAGS_SEEN+="hostname "; shift 2 ;;
      --disable-ipv6)         DISABLE_IPV6=true; FLAGS_SEEN+="disable-ipv6 "; shift ;;
      --no-update)            NO_UPDATE=true; FLAGS_SEEN+="no-update "; shift ;;
      --no-firewall)          NO_FIREWALL=true; FLAGS_SEEN+="no-firewall "; shift ;;
      --no-ssh)               NO_SSH=true; FLAGS_SEEN+="no-ssh "; shift ;;
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
      lo=$((10#$lo)); hi=$((10#$hi))
      (( lo <= hi )) || die "Диапазон «$p»: начало больше конца"
      PORTS_NUM+=("${lo}:${hi}")
    else
      is_valid_port "$p" || die "Порт «$p» — не число из диапазона 1–65535"
      PORTS_NUM+=("$((10#$p))")
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

#----------------------- СИСТЕМНЫЕ УТИЛИТЫ ----------------------
aptget() {
  apt-get -y -o DPkg::Lock::Timeout=600 "$@"
}

# Фактический порт sshd: из реального прослушивания → из сокета → из конфига → 22
# Вывод сначала читается целиком в переменную: «writer | grep -q» под pipefail
# ловит SIGPIPE от раннего выхода grep и даёт ложный негатив на загруженных серверах.
detect_ssh_port() {
  local all port=""
  if command -v ss >/dev/null 2>&1; then
    all="$(ss -H -tlnp 2>/dev/null | awk '/users:\(\("sshd"/ {n=split($4,a,":"); print a[n]}' || true)"
    port="${all%%$'\n'*}"
    [[ -n "$port" ]] && { echo "$port"; return; }
  fi
  if systemctl is-active ssh.socket >/dev/null 2>&1; then
    all="$(systemctl show ssh.socket -p ListenStream --value 2>/dev/null || true)"
    port="${all%%$'\n'*}"
    [[ -n "$port" ]] && { echo "$port"; return; }
  fi
  port="$(timeout 5 sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2}' || true)"
  port="${port%%$'\n'*}"
  [[ -n "$port" ]] && { echo "$port"; return; }
  echo 22
}

port_is_listening() { # $1 = порт
  local ports
  ports="$(ss -H -tln 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}' || true)"
  printf '%s\n' "$ports" | grep -qx "$1"
}

virt_kind() { systemd-detect-virt 2>/dev/null || echo "unknown"; }

#----------------------- ШАГИ -----------------------------------
precheck() {
  if [[ $EUID -ne 0 ]]; then
    if [[ "$0" == /dev/fd/* ]]; then
      die "Скрипт должен работать от root. Скачай и запусти через sudo:
  curl -fsSL <адрес_скрипта> -o /tmp/setup.sh && sudo bash /tmp/setup.sh"
    fi
    die "Запусти от root: sudo bash $0"
  fi
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) log "ОС: ${PRETTY_NAME:-$ID}" ;;
      *) warn "ОС '${ID:-?}' не тестировалась (ориентируюсь на Ubuntu/Debian). Продолжаю..." ;;
    esac
  fi
  CURR_SSH_PORT="$(detect_ssh_port)"
  if [[ "$CURR_SSH_PORT" == "22" ]]; then
    if command -v ss >/dev/null 2>&1 && ss -H -tlnp 2>/dev/null | grep -q 'users:(("sshd"'; then
      CURR_SSH_SOURCE="ss"
    elif systemctl is-active ssh.socket >/dev/null 2>&1; then
      CURR_SSH_SOURCE="socket"
    elif timeout 5 sshd -T >/dev/null 2>&1; then
      CURR_SSH_SOURCE="sshd-t"
    fi
  else
    if ss -H -tlnp 2>/dev/null | grep -q 'users:(("sshd"'; then CURR_SSH_SOURCE="ss"
    elif systemctl is-active ssh.socket >/dev/null 2>&1; then CURR_SSH_SOURCE="socket"
    else CURR_SSH_SOURCE="sshd-t"; fi
  fi
  log "Текущий порт SSH: $CURR_SSH_PORT (определён по: $CURR_SSH_SOURCE)"
  log "Виртуализация: $(virt_kind)"
}

update_system() {
  aptget update
  if $NO_UPDATE; then
    report "Обновление" ok "apt update выполнен, upgrade пропущен (--no-update)"
    return 0
  fi
  aptget -o Dpkg::Options::="--force-confold" upgrade
  aptget -o Dpkg::Options::="--force-confold" full-upgrade
  aptget autoremove
  aptget autoclean
  report "Обновление" ok "apt update + full-upgrade"
}

install_base() {
  local pkgs="curl wget git jq unzip ca-certificates socat cron procps sudo"
  pkgs+=" htop vnstat mtr-tiny iperf3 netcat-openbsd speedtest-cli"
  if ! $NO_FIREWALL; then pkgs+=" ufw"; fi
  if ! $SKIP_FAIL2BAN; then pkgs+=" fail2ban"; fi
  # shellcheck disable=SC2086  # список пакетов — намеренное разделение на слова
  aptget -o Dpkg::Options::="--force-confold" install $pkgs
  systemctl enable --now vnstat >/dev/null 2>&1 || true
  local missing="" p
  # shellcheck disable=SC2086
  for p in $pkgs; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=" $p"
  done
  if [[ -z "$missing" ]]; then
    report "Базовые пакеты" ok "все на месте"
  else
    report "Базовые пакеты" fail "не установились:$missing"
    return 1
  fi
}

set_time_and_host() {
  timedatectl set-ntp true
  if [[ -n "$TIMEZONE" ]]; then
    timedatectl set-timezone "$TIMEZONE"
  fi
  if [[ -n "$HOSTNAME_NEW" ]]; then
    hostnamectl set-hostname "$HOSTNAME_NEW"
    if grep -qE '^127\.0\.1\.1' /etc/hosts; then
      sed -i "s/^127\\.0\\.1\\.1.*/127.0.1.1 ${HOSTNAME_NEW}/" /etc/hosts
    else
      echo "127.0.1.1 ${HOSTNAME_NEW}" >> /etc/hosts
    fi
  fi
  # проверка по факту
  local tz_now ntp_ok hn_now ok=true
  tz_now="$(timedatectl show -p Timezone --value 2>/dev/null || echo '?')"
  if [[ -n "$TIMEZONE" ]]; then
    if [[ "$tz_now" == "$TIMEZONE" ]]; then
      report "Таймзона" ok "$tz_now"
    else
      report "Таймзона" fail "ждали $TIMEZONE, фактически $tz_now"; ok=false
    fi
  else
    report "Таймзона" ok "$tz_now (не меняли)"
  fi
  ntp_ok="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)"
  if [[ "$ntp_ok" == "yes" ]]; then
    report "Время (NTP)" ok "синхронизировано"
  else
    report "Время (NTP)" warn "ещё не синхронизировалось — проверь позже: timedatectl"
  fi
  if [[ -n "$HOSTNAME_NEW" ]]; then
    hn_now="$(hostname)"
    if [[ "$hn_now" == "$HOSTNAME_NEW" ]]; then
      report "Hostname" ok "$hn_now"
    else
      report "Hostname" fail "ждали $HOSTNAME_NEW, фактически $hn_now"; ok=false
    fi
  fi
  $ok || return 1
}

create_admin() {
  [[ -n "$ADMIN_USER" ]] || return 0
  if id "$ADMIN_USER" &>/dev/null; then
    log "Пользователь $ADMIN_USER уже существует — использую"
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
  fi
  # проверяем на деле: sudo без пароля и группа на месте
  local sudo_ok=false grp_ok=false
  if runuser -u "$ADMIN_USER" -- sudo -n true 2>/dev/null; then sudo_ok=true; fi
  if id -nG "$ADMIN_USER" | grep -qw sudo; then grp_ok=true; fi
  if $sudo_ok && $grp_ok; then
    report "Пользователь $ADMIN_USER" ok "sudo без пароля работает (root-шелл: sudo -i)"
  else
    local why=""
    $grp_ok  || why+="нет в группе sudo; "
    $sudo_ok || why+="sudo без пароля не работает"
    report "Пользователь $ADMIN_USER" fail "$why — проверь /etc/sudoers.d/90-${ADMIN_USER}"
    return 1
  fi
  if [[ "$ADMIN_KEY_MODE" == "skip" || -z "$ADMIN_KEY_MODE" ]] && [[ ! -s "/home/${ADMIN_USER}/.ssh/authorized_keys" ]]; then
    warn "У $ADMIN_USER нет ключа и нет пароля (вход заблокирован) — добавь ключ в /home/${ADMIN_USER}/.ssh/authorized_keys"
  fi
}

install_key_line() { # $1 = authorized_keys, $2 = строка ключа; вывод: число добавленных
  local ak="$1" key="$2"
  if command -v ssh-keygen >/dev/null 2>&1 && ! printf '%s\n' "$key" | ssh-keygen -lf - >/dev/null 2>&1; then
    warn "Ключ невалиден, пропускаю: $(awk '{print $1}' <<< "$key") ..."
    return 1
  fi
  touch "$ak"
  chmod 600 "$ak"
  grep -qxF "$key" "$ak" && return 0
  echo "$key" >> "$ak"
  return 0
}

count_keys_in() { grep -cE '^(ssh-|ecdsa-|sk-)' "$1" 2>/dev/null || true; }

install_admin_keys() {
  [[ -n "$ADMIN_USER" ]] || return 0
  local home="/home/${ADMIN_USER}"
  local ak="${home}/.ssh/authorized_keys"
  mkdir -p "${home}/.ssh"

  # 1) Вставленные ключи (--ssh-key / визард) ставим в любом режиме
  local k added=0
  for k in "${ADMIN_SSH_KEYS[@]}"; do
    if install_key_line "$ak" "$k"; then
      log "Ключ добавлен: $(awk '{print $1}' <<< "$k")"
      added=$((added+1))
    fi
  done

  # 2) Основной режим
  case "$ADMIN_KEY_MODE" in
    root)
      if [[ -s /root/.ssh/authorized_keys ]]; then
        while IFS= read -r k; do
          [[ -z "$k" ]] && continue
          if install_key_line "$ak" "$k"; then added=$((added+1)); fi
        done < /root/.ssh/authorized_keys
        log "Ключи скопированы из root"
      else
        warn "У root ключей нет — копировать нечего"
      fi
      ;;
    generate)
      local kp="/root/${ADMIN_USER}-ed25519"
      if [[ -f "$kp" ]]; then
        log "Пара уже существует: $kp — приватный ключ повторно не показываю"
        install_key_line "$ak" "$(cat "${kp}.pub")" || true
      else
        ssh-keygen -t ed25519 -f "$kp" -N '' -C "${ADMIN_USER}@${HOSTNAME_NEW:-$(hostname)}" >/dev/null
        GENERATED_KEY_PATH="$kp"
        install_key_line "$ak" "$(cat "${kp}.pub")" || true
        chmod 600 "$kp"
        echo
        warn "────────────── СКАЧАЙ ПРИВАТНЫЙ КЛЮЧ ПРЯМО СЕЙЧАС ──────────────"
        cat "$kp"
        warn "Сохрани его локально (~/.ssh/), затем удали с сервера: shred -u $kp"
        warn "(он также записан в лог $LOG_FILE — файл закрыт правами 600)"
        warn "─────────────────────────────────────────────────────────────────"
      fi
      ;;
  esac

  chmod 700 "${home}/.ssh"
  chown -R "${ADMIN_USER}:${ADMIN_USER}" "${home}/.ssh"

  local n
  n="$(count_keys_in "$ak")"
  if (( n > 0 )); then
    report "SSH-ключи $ADMIN_USER" ok "ключей в authorized_keys: $n"
  else
    report "SSH-ключи $ADMIN_USER" warn "ключей нет — вход по паролю останется"
  fi
}

# Ключи, переданные через --ssh-key без --admin, кладём root-у
install_root_keys() {
  [[ -z "$ADMIN_USER" && "${#ADMIN_SSH_KEYS[@]}" -gt 0 ]] || return 0
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  local k added=0
  for k in "${ADMIN_SSH_KEYS[@]}"; do
    if install_key_line /root/.ssh/authorized_keys "$k"; then
      log "Ключ добавлен root: $(awk '{print $1}' <<< "$k")"
      added=$((added+1))
    fi
  done
  local n
  n="$(count_keys_in /root/.ssh/authorized_keys)"
  if (( n > 0 )); then
    report "SSH-ключи root" ok "ключей: $n"
  else
    report "SSH-ключи root" warn "ключей нет"
  fi
}

tune_network() {
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

  rm -f /etc/sysctl.d/99-disable-ipv6.conf
  rm -f /etc/sysctl.d/99-block-ping.conf
  if $DISABLE_IPV6; then
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  fi
  if $BLOCK_PING; then
    echo "net.ipv4.icmp_echo_ignore_all = 1" > /etc/sysctl.d/99-block-ping.conf
  fi

  sysctl --system >/dev/null 2>&1 || true

  # --- BBR + fq: проверяем оба параметра ---
  local cc q
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  q="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  if [[ "$cc" == "bbr" && "$q" == "fq" ]]; then
    report "BBR + fq" ok
  elif [[ "$cc" == "bbr" ]]; then
    report "BBR + fq" warn "bbr включён, но qdisc=$q (ожидали fq) — проверь ядро"
  else
    report "BBR + fq" fail "congestion=$cc — ядро без BBR (нужно 4.9+)"
  fi

  # --- IPv6 ---
  rm -f /etc/sysctl.d/99-disable-ipv6.conf.tmp
  if $DISABLE_IPV6; then
    local v6off
    v6off="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)"
    if [[ "$v6off" == "1" ]]; then
      report "IPv6" ok "отключён"
    else
      local v
      v="$(virt_kind)"
      report "IPv6" fail "sysctl не применился (виртуализация: $v) — на контейнерах отключается только в панели хостера"
    fi
  else
    # сбросить живое значение, если прошлый запуск отключал
    sysctl -w net.ipv6.conf.all.disable_ipv6=0     >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.lo.disable_ipv6=0      >/dev/null 2>&1 || true
    local v6off2
    v6off2="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)"
    if [[ "$v6off2" == "0" ]]; then
      report "IPv6" ok "включён (как и выбрано)"
    else
      report "IPv6" warn "сейчас отключён (настройка хостера/прошлых запусков) — включится после перезагрузки"
    fi
  fi

  # --- Ping ---
  if $BLOCK_PING; then
    sysctl -w net.ipv4.icmp_echo_ignore_all=1 >/dev/null 2>&1 || true
    if [[ "$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null || echo 0)" == "1" ]]; then
      report "Ping (ICMP)" ok "заблокирован через sysctl"
    elif command -v nft >/dev/null 2>&1; then
      # фолбэк для контейнеров: тихий drop echo-request через nftables
      nft list table inet vps-pingdrop >/dev/null 2>&1 || nft add table inet vps-pingdrop >/dev/null 2>&1 || true
      nft list chain inet vps-pingdrop input >/dev/null 2>&1 \
        || nft add chain inet vps-pingdrop input '{ type filter hook input priority -10; policy accept; }' >/dev/null 2>&1 || true
      nft add rule inet vps-pingdrop input icmp type echo-request drop >/dev/null 2>&1 || true
      if nft list chain inet vps-pingdrop input 2>/dev/null | grep -q 'echo-request drop'; then
        setup_pingdrop_unit
        report "Ping (ICMP)" warn "sysctl запрещён контейнером — echo-request режется nftables (переживает ребут через юнит vps-pingdrop)"
      else
        report "Ping (ICMP)" fail "ни sysctl, ни nftables не сработали — сервер отвечает на ping (проверь панель хостера)"
      fi
    else
      report "Ping (ICMP)" fail "sysctl не применился, nftables нет — сервер отвечает на ping"
    fi
  else
    # сбросить живое значение и наши следы, чтобы выбор «разрешить» сработал сразу
    sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1 || true
    rm -f /etc/sysctl.d/99-block-ping.conf
    if nft list table inet vps-pingdrop >/dev/null 2>&1; then
      nft delete table inet vps-pingdrop >/dev/null 2>&1 || true
    fi
    systemctl disable --now vps-pingdrop.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/vps-pingdrop.service
    if [[ "$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null || echo 0)" == "0" ]] \
       && ! nft list ruleset 2>/dev/null | grep -q 'echo-request drop'; then
      report "Ping (ICMP)" ok "разрешён (как и выбрано)"
    else
      report "Ping (ICMP)" warn "всё ещё блокируется (настройка хостера?) — проверь после перезагрузки"
    fi
  fi

  if $LEGACY_CLEANED; then
    warn "Из /etc/sysctl.conf удалён тюнинг от старой версии скрипта — после работы скрипта сделай reboot"
  fi
}

# персистентный юнит для nft-фолбэка ping (на случай, если хостер не поднимает наши правила)
setup_pingdrop_unit() {
  cat > /etc/systemd/system/vps-pingdrop.service <<EOF
[Unit]
Description=Drop incoming ICMP echo (fallback where sysctl is blocked)
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
ExecStart=$(command -v nft) add table inet vps-pingdrop
ExecStart=$(command -v nft) add chain inet vps-pingdrop input "{ type filter hook input priority -10; policy accept; }"
ExecStart=$(command -v nft) add rule inet vps-pingdrop input icmp type echo-request drop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable vps-pingdrop.service >/dev/null 2>&1 || true
}

system_limits() {
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
  if [[ -s /etc/security/limits.d/99-increase-limits.conf ]]; then
    report "Лимиты и журнал" ok "nofile 1M, журнал до 200M"
  else
    report "Лимиты и журнал" fail "конфиг не записался"
    return 1
  fi
}

#----------------------- SSH ------------------------------------
# Проверка эффективной конфигурации sshd (то, что реально действует)
sshd_effective() { # sshd_effective passwordauthentication → no
  timeout 5 sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==tolower(k){print $2; exit}'
}

configure_ssh() {
  if $NO_SSH; then
    report "SSH" ok "не трогали (--no-ssh)"
    return 0
  fi
  mkdir -p /etc/ssh/sshd_config.d
  if [[ -f "$SSH_LEGACY_CFG" ]]; then
    rm -f "$SSH_LEGACY_CFG"
    log "Удалён старый 99-hardening.conf (заменён на 00-hardening.conf — у него приоритет выше cloud-init-настроек)"
  fi

  local target_port="${SSH_PORT:-$CURR_SSH_PORT}"
  local pin_port=false
  if [[ -n "$SSH_PORT" || "$CURR_SSH_SOURCE" != "default" ]]; then
    pin_port=true
  fi

  # новый порт не должен быть занят кем-то другим
  if [[ -n "$SSH_PORT" && "$SSH_PORT" != "$CURR_SSH_PORT" ]] && port_is_listening "$SSH_PORT"; then
    report "SSH" fail "порт $SSH_PORT уже занят другим сервисом — порт не меняю"
    return 1
  fi

  # Политика доступа: ключ должен быть у того, кому оставляем вход
  local admin_key=false root_key=false
  [[ -n "$ADMIN_USER" && -s "/home/${ADMIN_USER}/.ssh/authorized_keys" ]] && admin_key=true
  [[ -s /root/.ssh/authorized_keys ]] && root_key=true

  local conf=""
  if $pin_port; then
    conf+="Port ${target_port}"$'\n'
  fi
  if $HARDEN_SSH; then
    conf+="X11Forwarding no"$'\n'
    conf+="AllowAgentForwarding no"$'\n'
    conf+="MaxAuthTries 3"$'\n'
    conf+="LoginGraceTime 20"$'\n'
    conf+="ClientAliveInterval 120"$'\n'
    conf+="ClientAliveCountMax 3"$'\n'
  fi
  local disabled=false
  if $DISABLE_SSH_PASSWORD; then
    if $admin_key; then
      conf+="PasswordAuthentication no"$'\n'
      conf+="KbdInteractiveAuthentication no"$'\n'
      conf+="PermitRootLogin no"$'\n'
      disabled=true
    elif $root_key; then
      conf+="PasswordAuthentication no"$'\n'
      conf+="KbdInteractiveAuthentication no"$'\n'
      conf+="PermitRootLogin prohibit-password"$'\n'
      disabled=true
      warn "У $ADMIN_USER нет ключа — root остаётся доступен по ключу (иначе потерял бы доступ)"
    else
      warn "Ключей на сервере нет — вход по паролю НЕ отключаю (иначе потеряешь доступ)"
    fi
  fi

  # запись с бэкапом и откатом: провал валидации не портит рабочий конфиг
  local backup=""
  if [[ -f "$SSH_HARDENING_CFG" ]]; then
    backup="$(mktemp)"
    cp "$SSH_HARDENING_CFG" "$backup"
  fi
  printf '%s' "$conf" > "$SSH_HARDENING_CFG"
  if ! sshd -t 2>/tmp/vps-sshd-t.err; then
    if [[ -n "$backup" ]]; then mv "$backup" "$SSH_HARDENING_CFG"; else rm -f "$SSH_HARDENING_CFG"; fi
    report "SSH" fail "новый конфиг не прошёл sshd -t, предыдущий восстановлен: $(tail -1 /tmp/vps-sshd-t.err 2>/dev/null || echo '?')"
    return 1
  fi

  # socket activation: через сокет порт из sshd_config не действует
  local socket_mode=false
  if systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
    socket_mode=true
    if $pin_port; then
      mkdir -p /etc/systemd/system/ssh.socket.d
      printf '[Socket]\nListenStream=\nListenStream=%s\n' "$target_port" > /etc/systemd/system/ssh.socket.d/00-port.conf
      systemctl daemon-reload 2>/dev/null || true
    fi
  fi

  if $socket_mode; then
    systemctl restart ssh.socket 2>/dev/null || systemctl restart ssh 2>/dev/null || true
  else
    if ! systemctl restart ssh 2>/dev/null; then
      if ! systemctl restart sshd 2>/dev/null; then
        if [[ -n "$backup" ]]; then mv "$backup" "$SSH_HARDENING_CFG"; fi
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        report "SSH" fail "sshd не перезапустился — конфиг откачен к предыдущему"
        return 1
      fi
    fi
  fi
  [[ -n "$backup" ]] && rm -f "$backup"

  # проверка по факту: слушаем нужный порт? политика применилась?
  sleep 1
  local ok=true
  if ! port_is_listening "$target_port"; then
    report "SSH порт" fail "sshd не слушает $target_port (смена порта не сработала — проверь ssh.socket/конфиг)"
    ok=false
  else
    report "SSH порт" ok "$target_port (слушается)"
  fi
  if $disabled; then
    local eff_pa
    eff_pa="$(sshd_effective passwordauthentication)"
    if [[ "$eff_pa" == "no" ]]; then
      report "Вход по паролю" ok "отключён (проверено в действующем конфиге)"
    else
      report "Вход по паролю" fail "просили отключить, а действует: $eff_pa — вероятно, настройки хостера перекрывают наши"
      ok=false
    fi
  fi
  $ok || return 1
}

setup_fail2ban() {
  if $SKIP_FAIL2BAN; then
    if command -v fail2ban-client >/dev/null 2>&1; then
      report "Fail2ban" warn "стоит на сервере, но по флагу --no-fail2ban я его конфиг не трогаю"
    else
      report "Fail2ban" ok "пропущено (--no-fail2ban)"
    fi
    return 0
  fi
  local port="${SSH_PORT:-$CURR_SSH_PORT}"
  mkdir -p /etc/fail2ban
  if [[ -f /etc/fail2ban/jail.local ]]; then
    cp /etc/fail2ban/jail.local "/etc/fail2ban/jail.local.bak.$(date +%Y%m%d%H%M%S)"
  fi
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
  systemctl restart fail2ban 2>/dev/null || true
  systemctl enable fail2ban >/dev/null 2>&1 || true
  if fail2ban-client status sshd >/dev/null 2>&1; then
    report "Fail2ban" ok "jail sshd активен (порт $port, бан 1ч → до 1 недели)"
  else
    report "Fail2ban" fail "jail sshd не поднялся — смотри journalctl -u fail2ban"
    return 1
  fi
}

setup_firewall() {
  if $NO_FIREWALL; then
    report "Фаервол" ok "не трогали (--no-firewall) — UFW и порты как были"
    return 0
  fi
  local ssh_p="${SSH_PORT:-$CURR_SSH_PORT}"

  # rate-limit SSH: если на порту уже есть allow — убираем (первое совпадение
  # в UFW побеждает, allow отменил бы лимит)
  if ufw status 2>/dev/null | grep -qE "^${ssh_p}/tcp[[:space:]]+ALLOW"; then
    ufw delete allow "${ssh_p}/tcp" >/dev/null 2>&1 || true
  fi
  ufw limit "${ssh_p}/tcp" comment 'SSH' >/dev/null

  # при смене порта правило старого порта больше не нужно
  # (sshd уже переключён и подтверждён — окно блокировки отсутствует)
  if [[ "$ssh_p" != "22" ]]; then
    ufw delete limit 22/tcp >/dev/null 2>&1 || true
    ufw delete allow 22/tcp >/dev/null 2>&1 || true
  fi

  # идемпотентность: сносим правила прошлого прогона и добавляем текущие
  mkdir -p "$STATE_DIR"
  if [[ -f "$STATE_DIR/ufw-node.rules" ]]; then
    local old
    while read -r old; do
      [[ -z "$old" ]] && continue
      ufw delete allow "$old" >/dev/null 2>&1 || true
    done < "$STATE_DIR/ufw-node.rules"
  fi

  local i p pr specs_file="$STATE_DIR/ufw-node.rules.new"
  : > "$specs_file"
  for i in "${!PORTS_NUM[@]}"; do
    p="${PORTS_NUM[$i]}"; pr="${PORTS_PROTO[$i]}"
    case "$pr" in
      tcp)  ufw allow "${p}/tcp" comment 'node' >/dev/null; echo "${p}/tcp" >> "$specs_file" ;;
      udp)  ufw allow "${p}/udp" comment 'node' >/dev/null; echo "${p}/udp" >> "$specs_file" ;;
      both) ufw allow "${p}/tcp" comment 'node' >/dev/null
            ufw allow "${p}/udp" comment 'node' >/dev/null
            echo "${p}/tcp" >> "$specs_file"; echo "${p}/udp" >> "$specs_file" ;;
    esac
    log "Открыт порт: $p/$pr"
  done
  if (( ${#PORTS_NUM[@]} == 0 )); then
    warn "Порты не открывались. Для сервисов потом: ufw allow ПОРТ/tcp (или /udp)"
  fi
  mv -f "$specs_file" "$STATE_DIR/ufw-node.rules"

  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable >/dev/null

  # проверка по факту
  if ! ufw status 2>/dev/null | head -n1 | grep -q "Status: active"; then
    report "Фаервол UFW" fail "ufw не активировался"
    return 1
  fi
  if ! ufw status 2>/dev/null | grep -qE "^${ssh_p}/tcp[[:space:]]+(LIMIT|ALLOW)"; then
    report "Фаервол UFW" fail "правило для SSH-порта $ssh_p не найдено в ufw status"
    return 1
  fi
  report "Фаервол UFW" ok "active, SSH $ssh_p под rate-limit, node-портов: ${#PORTS_NUM[@]}"
}

setup_swap() {
  if [[ -n "$(swapon --show 2>/dev/null)" ]]; then
    report "Swap" ok "уже настроен: $(swapon --show --noheadings 2>/dev/null | awk '{print $1, $3}' | tr '\n' ' ')"
    return 0
  fi
  local ram_mb size_mb
  ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  if (( ram_mb <= 2000 )); then size_mb=2048; else size_mb=1024; fi
  if ! fallocate -l "${size_mb}M" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none
  fi
  chmod 600 /swapfile
  if ! mkswap /swapfile >/dev/null 2>&1 || ! swapon /swapfile 2>/dev/null; then
    # откат: не оставляем мёртвый файл и запись в fstab
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    sed -i '\|^/swapfile[[:space:]]|d' /etc/fstab
    report "Swap" fail "$(virt_kind): swapon запрещён (типично для контейнеров) — файл и запись в fstab откачены. Обычно это не критично"
    return 1
  fi
  grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  report "Swap" ok "${size_mb}M активен"
}

cleanup() {
  if command -v snap >/dev/null 2>&1; then
    local s
    while read -r s; do snap remove --purge "$s" >/dev/null 2>&1 || true; done \
      < <(snap list 2>/dev/null | awk 'NR>1{print $1}')
    if aptget purge snapd >/dev/null 2>&1; then
      rm -rf /snap /var/snap /var/lib/snapd ~/snap 2>/dev/null || true
      log "Snap удалён"
    else
      warn "snapd не удалось вычистить (занят?) — каталоги не трогаю"
    fi
  fi
  if $PURGE_CLOUDINIT && command -v cloud-init >/dev/null 2>&1; then
    aptget purge cloud-init >/dev/null 2>&1 || true
    rm -rf /etc/cloud
    log "cloud-init удалён"
  fi
  pro config set apt_news=false >/dev/null 2>&1 || true
  [[ -f /etc/default/motd-news ]] && sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
  report "Чистка" ok "snap/motd${PURGE_CLOUDINIT:+, cloud-init}"
}

install_docker() {
  if ! $INSTALL_DOCKER; then
    report "Docker" ok "пропущено (--no-docker)"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    local tmpf
    tmpf="$(mktemp)"
    if ! curl -fsSL https://get.docker.com -o "$tmpf"; then
      rm -f "$tmpf"
      report "Docker" fail "не удалось скачать установщик"
      return 1
    fi
    sh "$tmpf" >/dev/null
    rm -f "$tmpf"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  if docker info >/dev/null 2>&1; then
    report "Docker" ok "$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,) — демон жив"
  else
    report "Docker" fail "установлен, но демон не отвечает — journalctl -u docker"
    return 1
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
  ssh_p="$(detect_ssh_port)"
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
  echo -e "Вход паролем: $(sshd_effective passwordauthentication || echo '?') (действующий sshd)"
  echo -e "BBR:          $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  echo -e "Ping (ICMP):  $( [[ $(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null || echo 0) -eq 1 ]] && echo 'заблокирован' || echo 'sysctl разрешён (возможен nft-фолбэк)' )"
  echo -e "IPv6:         $( [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0) -eq 1 ]] && echo 'отключён' || echo 'включён' )"
  echo -e "Fail2ban:     $(fail2ban-client status sshd >/dev/null 2>&1 && echo 'активен' || echo 'выключен')"
  echo -e "UFW:          $(ufw status 2>/dev/null | head -n1 | awk '{print $2}')"
  echo -e "Docker:       $(command -v docker >/dev/null 2>&1 && (docker info >/dev/null 2>&1 && docker --version || echo 'демон не отвечает') || echo 'нет')"
  echo -e "Лог:          ${LOG_FILE:-нет}"
  if [[ -f /var/run/reboot-required ]]; then
    echo -e "${Y}Внимание:    требуется перезагрузка (reboot) — обновились системные компоненты${N}"
  fi
  if $LEGACY_CLEANED; then
    echo -e "${Y}Внимание:    удалён старый тюнинг из /etc/sysctl.conf — рекомендуется reboot${N}"
  fi
  echo -e "${C}══════════════════════════════════════════════${N}"
}

#----------------------- DOCTOR (только проверка) ---------------
doctor_checks() {
  local cc q v6 ping_st eff_pa eff_prl swap_st
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  q="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  if [[ "$cc" == "bbr" && "$q" == "fq" ]]; then report "BBR + fq" ok
  elif [[ "$cc" == "bbr" ]]; then report "BBR + fq" warn "bbr включён, qdisc=$q"
  else report "BBR + fq" fail "congestion=$cc — BBR не работает"; fi

  v6="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)"
  if [[ "$v6" == "1" ]]; then report "IPv6" ok "отключён"
  elif [[ -f /etc/sysctl.d/99-disable-ipv6.conf ]]; then
    report "IPv6" warn "должен быть отключён конфигом, но сейчас включён — проверь после перезагрузки или в панели хостера"
  else report "IPv6" ok "включён"; fi

  ping_st="$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null || echo 0)"
  if [[ "$ping_st" == "1" ]]; then report "Ping (ICMP)" ok "заблокирован (sysctl)"
  elif nft list ruleset 2>/dev/null | grep -q 'echo-request drop'; then
    report "Ping (ICMP)" ok "заблокирован (nftables-фолбэк)"
  elif [[ -f /etc/sysctl.d/99-block-ping.conf ]]; then
    report "Ping (ICMP)" warn "должен блокироваться конфигом, но сейчас разрешён — проверь после перезагрузки или в панели хостера"
  else report "Ping (ICMP)" ok "разрешён"; fi

  local tz ntp
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo '?')"
  ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)"
  if [[ "$ntp" == "yes" ]]; then report "Время" ok "$tz, синхронизировано"
  else report "Время" warn "$tz, NTP не синхронизирован"; fi

  if ufw status 2>/dev/null | head -n1 | grep -q "active"; then
    local ssh_p
    ssh_p="$(detect_ssh_port)"
    if ufw status 2>/dev/null | grep -qE "^${ssh_p}/tcp"; then
      report "Фаервол UFW" ok "active, правило для SSH $ssh_p есть"
    else
      report "Фаервол UFW" fail "active, но для SSH-порта $ssh_p правила нет — вход может быть заблокирован!"
    fi
  elif command -v ufw >/dev/null 2>&1; then report "Фаервол UFW" warn "установлен, но не активен"
  else report "Фаервол UFW" ok "не установлен"; fi

  if fail2ban-client status sshd >/dev/null 2>&1; then
    local banned
    banned="$(fail2ban-client status sshd 2>/dev/null | awk -F': ' '/Currently banned/{print $2}')"
    report "Fail2ban" ok "jail sshd активен, в бане: ${banned:-0}"
  elif command -v fail2ban-client >/dev/null 2>&1; then
    report "Fail2ban" fail "установлен, но jail sshd не работает — journalctl -u fail2ban"
  else report "Fail2ban" ok "не установлен"; fi

  swap_st="$(swapon --show --noheadings 2>/dev/null | awk '{print $1, $3}' | tr '\n' ' ')"
  if [[ -n "$swap_st" ]]; then report "Swap" ok "$swap_st"
  else report "Swap" warn "отсутствует (на контейнерах может быть запрещён)"; fi

  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then report "Docker" ok "$(docker --version | awk '{print $3}' | tr -d ,)"
    else report "Docker" fail "демон не отвечает — journalctl -u docker"; fi
  else report "Docker" ok "не установлен"; fi

  if [[ -f "$SSH_HARDENING_CFG" ]]; then
    eff_pa="$(sshd_effective passwordauthentication || echo '?')"
    eff_prl="$(sshd_effective permitrootlogin || echo '?')"
    local file_pa
    file_pa="$(awk 'tolower($1)=="passwordauthentication"{print $2}' "$SSH_HARDENING_CFG" | head -n1)"
    if [[ -n "$file_pa" && "$file_pa" != "$eff_pa" ]]; then
      report "SSH конфиг" fail "00-hardening.conf требует PasswordAuthentication $file_pa, а действует $eff_pa — настройки хостера перекрывают наши"
    else
      report "SSH конфиг" ok "port $(detect_ssh_port), passwordauthentication=$eff_pa, permitrootlogin=$eff_prl"
    fi
  else
    report "SSH конфиг" ok "харденинг не применялся (00-hardening.conf отсутствует)"
  fi

  if systemctl is-active ssh.socket >/dev/null 2>&1; then
    report "SSH socket" ok "ssh.socket активен (порт задаёт сокет, не sshd_config)"
  fi
}

#----------------------- АУДИТ ПОРТОВ ---------------------------
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

# Сопоставление «слушается» ↔ «открываем». Предупреждения — по процессам.
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

#----------------------- ВАЛИДАЦИЯ ОТВЕТОВ ----------------------
validate_settings() {
  if $NO_SSH; then
    if [[ -n "$SSH_PORT" ]]; then
      warn "--no-ssh: смену SSH-порта пропускаю"
      SSH_PORT=""
    fi
    HARDEN_SSH=false
    DISABLE_SSH_PASSWORD=false
  fi
  if $NO_FIREWALL && [[ -n "$OPEN_PORTS" ]]; then
    warn "--no-firewall: список --ports игнорирую, фаервол не трогаю"
    OPEN_PORTS=""
  fi
  if [[ -n "$SSH_PORT" ]]; then
    is_valid_port "$SSH_PORT" || die "Порт SSH «$SSH_PORT» — не число из диапазона 1–65535"
    SSH_PORT="$((10#$SSH_PORT))"
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

  if ! flag_seen "no-ssh"; then
    ask_yes "Настраивать SSH (порт, харденинг, запрет паролей)?" y || NO_SSH=true
  fi
  if $NO_SSH; then
    log "SSH: настройки sshd не трогаю"
  fi

  if ! $NO_SSH && [[ -z "$SSH_PORT" ]]; then
    local _p
    while true; do
      get_answer _p "Порт SSH (пусто — оставить $CURR_SSH_PORT)" ""
      if [[ -z "$_p" ]]; then break; fi
      if ! is_valid_port "$_p"; then warn "Число от 1 до 65535"; continue; fi
      _p="$((10#$_p))"
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

  if ! flag_seen "no-firewall"; then
    ask_yes "Настраивать фаервол и порты (UFW)?" y || NO_FIREWALL=true
  fi
  if $NO_FIREWALL; then
    log "Фаервол и порты: не трогаю — остаётся как есть"
  else
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
  fi
  echo

  if ! flag_seen "no-update"; then
    ask_yes "Обновлять систему (apt update/upgrade, может занять несколько минут)?" y || NO_UPDATE=true
  fi
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
  if ! flag_seen "no-ssh-harden" && ! $NO_SSH; then
    ask_yes "Харденинг SSH (без X11/агента, лимит попыток)?" y || HARDEN_SSH=false
  fi
  if ! flag_seen "no-docker"; then
    ask_yes "Установить Docker?" y || INSTALL_DOCKER=false
  fi
  if ! flag_seen "purge-cloudinit"; then
    ask_yes "Удалить cloud-init? (если хостер раздаёт через него сеть/порт SSH — НЕ надо)" n && PURGE_CLOUDINIT=true
  fi
  if ! flag_seen "disable-ssh-password" && ! $NO_SSH; then
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
  echo "  Обновление:    $( $NO_UPDATE && echo 'пропустить upgrade' || echo 'apt update/upgrade' )"
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
  if $NO_FIREWALL; then
    echo "  Фаервол:       не трогать (UFW и порты остаются как есть)"
  else
    echo "  Порты наружу:  $specs"
  fi
  if $NO_SSH; then
    echo "  SSH:           не трогать (настройки sshd остаются как есть)"
  elif $DISABLE_SSH_PASSWORD; then
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
  setup_log

  if $DOCTOR; then
    step "Doctor: проверка сервера (ничего не меняю)"
    doctor_checks
    print_report
    if (( FAIL_COUNT > 0 )); then exit 1; fi
    exit 0
  fi

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
  fi

  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  run_step "Обновление системы" update_system
  run_step "Базовые пакеты" install_base
  run_step "Время и hostname" set_time_and_host
  run_step "Пользователь admin" create_admin
  run_step "SSH-ключи" install_root_keys
  run_step "SSH-ключи admin" install_admin_keys
  run_step "Сеть (BBR, IPv6, ping)" tune_network
  run_step "Лимиты и журнал" system_limits
  run_step "SSH" configure_ssh
  run_step "Fail2ban" setup_fail2ban
  run_step "Фаервол UFW" setup_firewall
  if $SETUP_SWAP; then run_step "Swap" setup_swap; else report "Swap" ok "пропущено (--no-swap)"; fi
  run_step "Чистка" cleanup
  run_step "Docker" install_docker

  print_report
  summary

  if (( FAIL_COUNT > 0 )); then
    exit 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  parse "$@"
  main
fi
