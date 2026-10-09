#!/usr/bin/env bash
# Remnawave Node Manager v0.2.9 — установка и аудит без изменений
set -Eeuo pipefail
umask 077
readonly NODE_DIR=/opt/remnanode
readonly COMPOSE_FILE="$NODE_DIR/docker-compose.yml"
readonly LOG_DIR=/var/log/remnanode
readonly ROTATE_FILE=/etc/logrotate.d/remnanode
readonly UFW_BEFORE=/etc/ufw/before.rules
info() { printf '\n[REMNAWAVE] %s\n' "$*"; }
fail() { printf '\n[REMNAWAVE] ОШИБКА: %s\n' "$*" >&2; exit 1; }
trap 'printf "\n[REMNAWAVE] Ошибка в строке %s (код %s).\n" "$LINENO" "$?" >&2' ERR

install_mode() {
[[ "$EUID" -eq 0 ]] || fail 'Запустите от root или через sudo.'
[[ -t 0 ]] || fail 'Нужен интерактивный терминал для ввода SECRET_KEY и IP панели.'
info 'Сначала введите параметры подключения Remnawave...'
read -r -s -p 'Введите SECRET_KEY из панели Remnawave: ' SECRET_KEY
printf '\n'
[[ -n "$SECRET_KEY" && "$SECRET_KEY" != *$'\r'* && "$SECRET_KEY" != *$'\n'* ]] || fail 'SECRET_KEY пустой или содержит недопустимые символы.'
read -r -p 'Публичный IPv4 панели (доступ к API ноды, порт 2222): ' PANEL_IP


[[ -r /etc/os-release ]] || fail 'Не удалось определить операционную систему.'
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == '24.04' ]] || fail 'Требуется Ubuntu 24.04 LTS.'
[[ ! -e "$COMPOSE_FILE" && ! -e "$NODE_DIR/.env" && ! -e "$NODE_DIR/docker-compose.override.yml" ]] || fail 'Обнаружена существующая конфигурация RemnaNode; перезапись запрещена.'
[[ ! -e "$ROTATE_FILE" ]] || fail "Файл $ROTATE_FILE уже существует; перезапись запрещена."

info 'ШАГ 1/9 — Обновление пакетов Ubuntu...'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl python3 openssh-server iproute2 ufw logrotate

# Avoid locking out an active SSH session when enabling the firewall.
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  read -r _ _ _ ssh_port <<< "$SSH_CONNECTION"
  [[ "$ssh_port" == '22' ]] || fail "Текущая SSH-сессия использует порт $ssh_port вместо 22."
fi
ss -H -ltn '( sport = :22 )' | grep -q . || fail 'SSH не слушает TCP-порт 22.'

info 'ШАГ 2/9 — Установка и проверка Docker...'
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  installer=$(mktemp /tmp/remnanode-docker.XXXXXXXX)
  curl -fsSL https://get.docker.com -o "$installer" || fail 'Не удалось скачать установщик Docker.'
  sh "$installer"
  rm -f "$installer"
fi
docker compose version >/dev/null || fail 'Плагин Docker Compose отсутствует.'
systemctl enable --now docker
systemctl is-active --quiet docker || fail 'Служба Docker не запущена.'

info 'ШАГ 3/9 — Создание конфигурации RemnaNode...'
validate_panel_ip "$PANEL_IP" || fail 'Укажите корректный публичный IPv4 панели.'
mkdir -p "$NODE_DIR" "$LOG_DIR"
chmod 700 "$NODE_DIR"
# Insert secret as a YAML-quoted scalar, not as shell-expanded text.
# Secret is passed over stdin, not command-line arguments or a .env file.
export REMNAWAVE_COMPOSE_FILE="$COMPOSE_FILE"
# Build file without placing the secret in argv or in a secondary file.
# The here-document contains only code; the key comes from the Bash variable via a pipe.
printf '%s' "$SECRET_KEY" | python3 -c '
import json,os,sys
secret=sys.stdin.read()
path=os.environ["REMNAWAVE_COMPOSE_FILE"]
with open(path,"x",encoding="utf-8") as f:
    f.write("services:\n  remnanode:\n    container_name: remnanode\n    hostname: remnanode\n    image: remnawave/node:latest\n    restart: always\n    network_mode: host\n    environment:\n      NODE_PORT: \"2222\"\n      SECRET_KEY: "+json.dumps(secret,ensure_ascii=True)+"\n    volumes:\n      - /var/log/remnanode:/var/log/remnanode\n")
'
chmod 600 "$COMPOSE_FILE"
unset SECRET_KEY
unset REMNAWAVE_COMPOSE_FILE
(cd "$NODE_DIR" && docker compose config -q) || fail 'Ошибка проверки конфигурации Docker Compose.'

info 'ШАГ 4/9 — Загрузка образа и запуск RemnaNode...'
(cd "$NODE_DIR" && docker compose pull && docker compose up -d)
(cd "$NODE_DIR" && docker compose ps)

info 'ШАГ 5/9 — Проверка TCP-соединения с панелью (до 60 секунд)...'
if ! check_panel_connection "$PANEL_IP" 60; then
  fail 'Нет активного TCP-соединения rw-node с указанным IP панели. UFW пока не настроен. Проверьте IP и подключение, затем используйте пункт 3.'
fi
configure_security
}

# Confirm a live connection owned by rw-node, from the expected panel IP.
# This verifies the TCP channel, not full application-level health.
check_panel_connection() {
  local panel_ip="$1" max_wait="${2:-60}" i count
  command -v ss >/dev/null 2>&1 || fail 'Для проверки панели требуется ss (iproute2).'
  command -v python3 >/dev/null 2>&1 || fail 'Для проверки панели требуется python3.'
  for ((i=0; i<max_wait; i+=2)); do
    [[ "$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null || true)" == running ]] || fail 'Контейнер RemnaNode не запущен.'
    count=$(ss -Htnp state established '( sport = :2222 )' 2>/dev/null | python3 -c '
import ipaddress,sys
expected=ipaddress.IPv4Address(sys.argv[1]); count=0
for line in sys.stdin:
    if "rw-node" not in line: continue
    parts=line.split()
    if len(parts)<5: continue
    remote=parts[3].rsplit(":",1)[0].strip("[]")
    if remote.lower().startswith("::ffff:"): remote=remote[7:]
    try:
        if ipaddress.ip_address(remote)==expected: count+=1
    except ValueError: pass
print(count)
' "$panel_ip")
    if (( count > 0 )); then
      printf '[OK] TCP-соединение rw-node с панелью %s подтверждено (соединений: %s).\n' "$panel_ip" "$count"
      return 0
    fi
    sleep 2
  done
  return 1
}

validate_panel_ip() {
  python3 - "$1" <<'PYIP'
import ipaddress,sys
try:
    ip=ipaddress.ip_address(sys.argv[1]); assert ip.version==4 and ip.is_global
except (ValueError, AssertionError): sys.exit(1)
PYIP
}

configure_security() {
info 'ШАГ 6/9 — Настройка Logrotate...'
if [[ ! -e "$ROTATE_FILE" ]]; then
cat > "$ROTATE_FILE" <<'ROTATE'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
ROTATE
fi
logrotate -d "$ROTATE_FILE" >/dev/null 2>&1 || fail 'Ошибка проверки Logrotate.'

info 'ШАГ 7/9 — Отключение автоматических блокировок Fail2Ban...'
# Fail2Ban may have been installed by an older release. Stop it to prevent
# dynamically generated UFW REJECT/DENY rules; leave its files untouched.
if systemctl list-unit-files fail2ban.service --no-legend 2>/dev/null | grep -q '^fail2ban.service'; then
  systemctl disable --now fail2ban || fail 'Не удалось остановить Fail2Ban.'
  systemctl is-active --quiet fail2ban && fail 'Fail2Ban всё ещё активен.'
fi
printf '[OK] Автоматические блокировки Fail2Ban отключены.\n'

info 'ШАГ 8/9 — Настройка UFW...'
# Existing rules may weaken the intended policy. Refuse to proceed rather
# than resetting the firewall or deleting the user's existing rules.
if ufw status | grep -Eiq '^2222(/tcp)?[[:space:]]+ALLOW[[:space:]]+Anywhere'; then
  fail 'Обнаружено правило UFW, открывающее порт 2222 для всех. Удалите его вручную.'
fi
[[ -f "$UFW_BEFORE" ]] || fail "Файл $UFW_BEFORE отсутствует."
# No backup by request. Stage changes in memory and atomically replace the file.
python3 - "$UFW_BEFORE" <<'PY'
import os,re,sys,tempfile
p=sys.argv[1]
with open(p,encoding='utf-8') as f: text=f.read()
lines=text.splitlines(keepends=True)
heads={'INPUT':'# ok icmp codes for INPUT','FORWARD':'# ok icmp code for FORWARD'}
chains={'INPUT':'ufw-before-input','FORWARD':'ufw-before-forward'}
expected={'INPUT':['destination-unreachable','time-exceeded','parameter-problem','echo-request','source-quench'],
          'FORWARD':['destination-unreachable','time-exceeded','parameter-problem','echo-request']}
for section in ('INPUT','FORWARD'):
    matches=[i for i,l in enumerate(lines) if l.strip()==heads[section]]
    if len(matches)!=1: raise SystemExit(f'Expected exactly one {section} ICMP heading; unchanged.')
    start=matches[0]+1
    end=next((i for i in range(start,len(lines)) if lines[i].strip()=='' or lines[i].lstrip().startswith('#')),len(lines))
    block=lines[start:end]
    chain=chains[section]
    pat=re.compile(r'^(-A\s+'+re.escape(chain)+r'\s+-p\s+icmp\s+--icmp-type\s+)([\w-]+)(\s+-j\s+)(ACCEPT|DROP)(\s*)$')
    found=set(); revised=[]
    for line in block:
        raw=line.rstrip('\r\n'); m=pat.fullmatch(raw)
        if m:
            typ=m.group(2)
            if typ in found: raise SystemExit(f'Duplicate {section} ICMP type {typ}; unchanged.')
            found.add(typ)
            revised.append(m.group(1)+typ+m.group(3)+'DROP'+m.group(5)+'\n')
        else:
            revised.append(line)
    missing=[typ for typ in expected[section] if typ not in found]
    if any(typ not in ('echo-request','source-quench') for typ in missing):
        raise SystemExit(f'Missing standard {section} ICMP rules: {missing}; unchanged.')
    for typ in ('echo-request','source-quench'):
        if typ in missing and (section=='INPUT' or typ=='echo-request'):
            revised.append(f'-A {chain} -p icmp --icmp-type {typ} -j DROP\n')
    lines[start:end]=revised
# Verify both blocks before writing any changes.
result=''.join(lines)
for section in ('INPUT','FORWARD'):
    for typ in expected[section]:
        rule=f'-A {chains[section]} -p icmp --icmp-type {typ} -j DROP'
        if result.count(rule+'\n')!=1: raise SystemExit(f'Unexpected {section} {typ} rule; unchanged.')
stat=os.stat(p)
fd,tmp=tempfile.mkstemp(prefix='.before.rules.',dir=os.path.dirname(p))
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        f.write(result); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,stat.st_mode & 0o7777)
    os.replace(tmp,p)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
# Check the iptables syntax of UFW's edited IPv4 rules.
if command -v iptables-restore >/dev/null 2>&1; then
  iptables-restore --test < "$UFW_BEFORE" || fail 'Ошибка синтаксиса UFW before.rules.'
fi
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'Remnawave Xray Inbound'
ufw allow from "$PANEL_IP" to any port 2222 proto tcp comment 'Remnawave Node API'
unset PANEL_IP
ufw --force enable
ufw reload

info 'ШАГ 9/9 — Итоговая проверка...'
systemctl is-active --quiet docker || fail 'Docker не запущен.'
if systemctl is-active --quiet fail2ban 2>/dev/null; then fail 'Fail2Ban активен и может добавлять динамические правила UFW.'; fi
[[ "$(docker inspect -f '{{.State.Running}}' remnanode)" == true ]] || fail 'RemnaNode остановлена.'
ufw status | grep -q '^Status: active' || fail 'UFW неактивен.'
mount_ok=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/log/remnanode"}}{{.Source}}{{end}}{{end}}' remnanode)
[[ "$mount_ok" == "$LOG_DIR" ]] || fail 'Каталог логов не примонтирован в RemnaNode.'
logrotate -d "$ROTATE_FILE" >/dev/null 2>&1 || fail 'Ошибка проверки Logrotate.'
printf '\n========== REMNAWAVE NODE MANAGER — УСТАНОВКА ЗАВЕРШЕНА ==========\n'
printf '[OK] Docker: работает\n[OK] RemnaNode: запущена\n[OK] Панель: активное TCP-соединение подтверждено\n'
printf '[OK] Fail2Ban: отключён (нет автоматических блокировок)\n[OK] Logrotate: настроен\n[OK] UFW: работает\n[OK] Логи Xray: каталог примонтирован\n'
printf '\n'
ufw status verbose
printf '\nПРИМЕЧАНИЕ: Включите запись логов Xray в файлы через профиль панели Remnawave.\n'
printf 'ВНИМАНИЕ: Блокировка ICMP может нарушать PMTU Discovery и диагностику сети.\n'
if [[ -f /var/run/reboot-required ]]; then
  printf 'ПРИМЕЧАНИЕ: После обновлений требуется перезагрузка Ubuntu. Выполните её вручную.\n'
fi

}

resume_mode() {
  [[ "$EUID" -eq 0 && -t 0 ]] || fail 'Требуется root и интерактивный терминал.'
  [[ -r /etc/os-release ]] || fail 'Не удалось определить ОС.'
  . /etc/os-release
  [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == '24.04' ]] || fail 'Требуется Ubuntu 24.04 LTS.'
  [[ -f "$COMPOSE_FILE" ]] || fail "Конфигурация $COMPOSE_FILE отсутствует. Используйте пункт 1."
  for cmd in docker python3 ss ufw logrotate iptables-restore; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Не найдена команда $cmd. Для завершения сначала установите необходимый пакет вручную."
  done
  docker compose version >/dev/null 2>&1 || fail 'Docker Compose отсутствует.'
  (cd "$NODE_DIR" && docker compose config -q) || fail 'Конфигурация Compose некорректна.'
  [[ "$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null || true)" == running ]] || fail 'RemnaNode не запущена.'
  local mount
  mount=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/log/remnanode"}}{{.Source}}{{end}}{{end}}' remnanode)
  [[ "$mount" == "$LOG_DIR" ]] || fail 'У RemnaNode отсутствует ожидаемое подключение каталога логов.'
  ss -H -ltn '( sport = :22 )' | grep -q . || fail 'SSH не слушает порт 22.'
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    local a b c ssh_port
    read -r a b c ssh_port <<< "$SSH_CONNECTION"
    [[ "$ssh_port" == 22 ]] || fail "Текущая SSH-сессия использует порт $ssh_port вместо 22."
  fi
  read -r -p 'Публичный IPv4 панели Remnawave: ' PANEL_IP
  validate_panel_ip "$PANEL_IP" || fail 'Некорректный публичный IPv4 панели.'
  info 'Проверка текущего TCP-соединения с панелью (до 60 секунд)...'
  if ! check_panel_connection "$PANEL_IP" 60; then
    fail 'Не удалось подтвердить TCP-соединение с панелью. Настройки безопасности не изменены.'
  fi
  info 'Продолжаем только шаги 6–9. Ubuntu, Docker и RemnaNode не переустанавливаются.'
  configure_security
}

mark() {
  local status="$1" description="$2"
  case "$status" in
    OK) printf '  [OK]   %s\n' "$description"; PASS=$((PASS+1));;
    WARN) printf '  [WARN] %s\n' "$description"; WARN=$((WARN+1));;
    FAIL) printf '  [FAIL] %s\n' "$description"; FAIL=$((FAIL+1));;
  esac
}
check_service() {
  local name="$1"
  if systemctl is-active --quiet "$name" 2>/dev/null; then mark OK "$name: работает"; else mark FAIL "$name неактивен или отсутствует"; fi
}

# Audit reads configuration and runtime state only. No installation, restart, reload or file writes.
audit_mode() {
  PASS=0 WARN=0 FAIL=0
  printf '\n========== АУДИТ REMNAWAVE NODE v0.2.9 ==========\n'
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == '24.04' ]]; then mark OK 'Ubuntu 24.04 LTS'; else mark WARN "ОС: ${PRETTY_NAME:-неизвестна} (установка рассчитана на Ubuntu 24.04)"; fi
  else mark WARN 'Не удалось определить ОС'; fi
  if command -v docker >/dev/null 2>&1; then
    mark OK "Docker установлен ($(docker --version 2>/dev/null || echo unknown))"
    check_service docker
    if docker compose version >/dev/null 2>&1; then mark OK 'Docker Compose доступен'; else mark FAIL 'Docker Compose отсутствует'; fi
  else mark FAIL 'Docker отсутствует'; fi
  if [[ -f "$COMPOSE_FILE" ]]; then
    mark OK "Файл Compose найден: $COMPOSE_FILE"
    if command -v docker >/dev/null 2>&1 && (cd "$NODE_DIR" && docker compose config -q >/dev/null 2>&1); then
      mark OK 'Конфигурация Compose корректна'
    else mark WARN 'Проверка Compose не удалась'; fi
  else mark FAIL "Файл Compose отсутствует: $COMPOSE_FILE"; fi
  if command -v docker >/dev/null 2>&1; then
    local state
    state=$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null || true)
    if [[ "$state" == running ]]; then mark OK 'RemnaNode запущена'; else mark FAIL "Состояние RemnaNode: ${state:-не найден}"; fi
    # TCP state is more reliable than a log line that may have aged out.
    # The expected panel IP is requested below, before UFW checks.
    local mount
    mount=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/log/remnanode"}}{{.Source}}{{end}}{{end}}' remnanode 2>/dev/null || true)
    if [[ "$mount" == "$LOG_DIR" ]]; then mark OK 'Каталог логов примонтирован'; else mark WARN 'Каталог логов не примонтирован или путь отличается'; fi
  fi
  if [[ -f "$ROTATE_FILE" ]]; then
    if command -v logrotate >/dev/null 2>&1 && logrotate -d "$ROTATE_FILE" >/dev/null 2>&1; then mark OK 'Конфигурация Logrotate корректна'; else mark WARN 'Logrotate не установлен или конфигурация некорректна'; fi
  else mark FAIL 'Конфигурация Logrotate отсутствует'; fi
  if systemctl is-active --quiet fail2ban 2>/dev/null; then mark WARN 'Fail2Ban активен и может добавлять динамические правила UFW'; else mark OK 'Fail2Ban отключён: автоматических блокировок нет'; fi
  printf '\n--- ПРАВИЛА UFW ---\n'
  if command -v ufw >/dev/null 2>&1; then
    local rules panel_ip
    rules=$(ufw status numbered 2>&1 || true)
    if printf '%s\n' "$rules" | grep -q '^Status: active'; then mark OK 'UFW активен'; else mark FAIL 'UFW неактивен'; fi
    printf '%s\n' "$rules"
    printf '\nIPv4 панели для проверки подключения и порта 2222 (Enter — определить по UFW): '
    read -r panel_ip
    if [[ -z "$panel_ip" ]]; then
      panel_ip=$(printf '%s\n' "$rules" | sed -nE 's/^\[[[:space:]]*[0-9]+\][[:space:]]+2222\/tcp[[:space:]]+ALLOW IN[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)([[:space:]]+.*)?$/\1/p' | sort -u)
      if [[ "$panel_ip" == *$'\n'* ]]; then panel_ip=''; fi
      [[ -z "$panel_ip" ]] || printf '  [INFO] IP панели из правила UFW: %s (не подтверждён пользователем)\n' "$panel_ip"
    fi
    printf '\n--- СОЕДИНЕНИЕ С ПАНЕЛЬЮ ---\n'
    if [[ -n "$panel_ip" ]] && command -v ss >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
      local established count
      established=$(ss -Htnp state established '( sport = :2222 )' 2>/dev/null || true)
      count=$(PANEL_CONNECTIONS="$established" python3 - "$panel_ip" <<'PYCONN'
import ipaddress,os,re,sys
try: expected=ipaddress.IPv4Address(sys.argv[1])
except ValueError: print(0); sys.exit(0)
n=0
for line in os.environ.get('PANEL_CONNECTIONS','').splitlines():
    if '"rw-node"' not in line: continue
    fields=line.split()
    if len(fields)<5: continue
    remote=fields[3].rsplit(':',1)[0].strip('[]')
    if remote.lower().startswith('::ffff:'): remote=remote[7:]
    try:
        if ipaddress.ip_address(remote)==expected: n+=1
    except ValueError: pass
print(n)
PYCONN
)
      if (( count > 0 )); then
        mark OK "Активных TCP-соединений rw-node с $panel_ip: $count"
      else
        mark WARN "Нет текущих TCP-соединений rw-node с $panel_ip на 2222 (не доказывает отключение)"
      fi
    else
      mark WARN 'Невозможно проверить TCP-соединение: не определён IP панели или отсутствует ss/python3'
    fi
    if command -v python3 >/dev/null 2>&1; then
      local result
      result=$(UFW_AUDIT_RULES="$rules" python3 - "$panel_ip" <<'PYUFW'
import ipaddress,os,re,sys
ip=sys.argv[1].strip()
if ip:
    try:
        a=ipaddress.ip_address(ip)
        if a.version!=4: raise ValueError()
    except ValueError:
        print('WARN|Введён некорректный IPv4 панели'); sys.exit(0)
rows=[]
for line in os.environ.get('UFW_AUDIT_RULES','').splitlines():
    m=re.match(r'^\[\s*\d+\]\s+(\S+)\s+(ALLOW|DENY|REJECT)\s+IN\s+(\S+)',line)
    if not m: continue
    dest,action,source=m.groups()
    if re.fullmatch(r'2222(?:/tcp)?(?:\s*\(v6\))?',dest,re.I):
        rows.append((dest,action,source))
if not rows:
    print('WARN|Нет явного правила UFW для 2222/tcp'); sys.exit(0)
allows=[(d,a,src) for d,a,src in rows if a=='ALLOW']
if any(src.lower() in ('anywhere','anywhere (v6)') for _,_,src in allows):
    print('FAIL|Порт 2222 открыт для всех адресов в UFW'); sys.exit(0)
if any('/tcp' not in d.lower() for d,_,_ in allows):
    print('WARN|Есть правило 2222 без указания TCP; проверьте протокол'); sys.exit(0)
if ip:
    if len(allows)==1 and allows[0][2]==ip:
        print('OK|Порт 2222/TCP разрешён только IPv4 панели '+ip)
    else:
        print('WARN|Разрешения 2222/TCP не совпадают однозначно с IPv4 панели '+ip)
else:
    print('WARN|Порт 2222 ограничен в UFW, но IPv4 панели не указан для сравнения')
PYUFW
)
      case "$result" in
        OK\|*) mark OK "${result#*|}" ;;
        FAIL\|*) mark FAIL "${result#*|}" ;;
        *) mark WARN "${result#*|}" ;;
      esac
    else mark WARN 'Для проверки правил 2222 нужен Python 3'; fi
  else mark FAIL 'UFW отсутствует'; fi
  if [[ -r "$UFW_BEFORE" ]]; then
    if python3 - "$UFW_BEFORE" <<'PYCHECK'
import sys,re
s=open(sys.argv[1]).read()
for chain,types in [('ufw-before-input',['destination-unreachable','time-exceeded','parameter-problem','echo-request','source-quench']),('ufw-before-forward',['destination-unreachable','time-exceeded','parameter-problem','echo-request'])]:
    for t in types:
        pattern=r'^-A '+chain+r' -p icmp --icmp-type '+t+r' -j DROP\s*$'
        if len(re.findall(pattern,s,re.M))!=1: sys.exit(1)
PYCHECK
    then mark OK 'Правила ICMP INPUT/FORWARD соответствуют ожидаемым'; else mark WARN 'Правила ICMP отличаются от ожидаемых'; fi
  else mark WARN 'Файл UFW before.rules недоступен'; fi

  printf '\n========== ПРОСЛУШИВАЕМЫЕ ПОРТЫ (TCP/UDP) ==========\n'
  if command -v ss >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    python3 - <<'PYPORTS'
import ipaddress,re,subprocess

def run(*args):
    try: return subprocess.run(args,capture_output=True,text=True,check=False)
    except OSError: return None

ss=run('ss','-H','-tulnp')
ufw=run('ufw','status','numbered')
fw=ufw.stdout if ufw else ''
active=bool(re.search(r'^Status:\s*active\s*$',fw,re.M))
# Parse both numbered and unnumbered UFW output; do not assume English comments.
rules=[]
for line in fw.splitlines():
    line=re.sub(r'^\s*\[\s*\d+\]\s*','',line)
    m=re.match(r'^\s*(\d+(?:/(?:tcp|udp))?(?:\s+\(v6\))?)\s+(ALLOW|DENY|REJECT)\s+IN\s+(.+?)\s*$',line)
    if not m: continue
    dest,action,source=m.groups()
    source=source.split(' #',1)[0].strip()
    ipv6='(v6)' in dest or '(v6)' in source
    dest=dest.replace('(v6)','').strip()
    # Port ranges, application profiles, interface rules and addresses are not guessed.
    port_match=re.fullmatch(r'(\d+)(?:/(tcp|udp))?',dest,re.I)
    if port_match:
        rules.append((int(port_match.group(1)),(port_match.group(2) or '').lower(),action,source,ipv6))

def family_of(addr):
    if addr.startswith('[::ffff:'): return 4
    if addr.startswith('['): return 6
    if addr in ('*','::'): return 0
    if ':' in addr: return 6
    return 4

def scope_of(addr):
    clean=addr.strip('[]').split('%',1)[0]
    try:
        ip=ipaddress.ip_address(clean)
        if ip.is_loopback: return 'локальный'
        if ip.is_unspecified: return 'все адреса'
        return 'конкретный IP'
    except ValueError:
        return 'все адреса' if clean=='*' else 'неизвестно'

def firewall_state(port,proto,family,scope):
    if scope=='локальный': return 'локальный'
    if not active: return 'UFW выключен' if ufw else 'неизвестно'
    # Wildcard dual-stack listeners may serve both families: show both independently.
    families=(4,6) if family==0 else (family,)
    def one(fam):
        applicable=[(act,src) for p,pr,act,src,v6 in rules
                    if p==port and (not pr or pr==proto) and v6==(fam==6)]
        if not applicable: return 'нет явного ALLOW'
        # Conservative: don't claim access when deny and allow rules coexist.
        if any(act!='ALLOW' for act,_ in applicable): return 'смешанные правила'
        if any(src in ('Anywhere','Anywhere (v6)') for _,src in applicable): return 'ALLOW всем'
        return 'ALLOW по IP'
    results=[one(fam) for fam in families]
    if len(results)==1: return results[0]
    return 'v4:'+results[0]+' / v6:'+results[1]

if not ss or ss.returncode:
    print('Не удалось получить список портов: '+(ss.stderr.strip() if ss else 'ss отсутствует'))
else:
    entries=[]
    for line in ss.stdout.splitlines():
        fields=line.split(maxsplit=6)
        if len(fields)<5: continue
        proto,_,_,_,local=fields[:5]
        if proto.lower() not in ('tcp','udp'): continue
        names=list(dict.fromkeys(re.findall(r'\("([^"]+)"',fields[6] if len(fields)>6 else '')))
        proc=', '.join(names) if names else 'не определён'
        try: port=int(local.rsplit(':',1)[-1])
        except ValueError: continue
        addr=local.rsplit(':',1)[0]
        family=family_of(addr)
        scope=scope_of(addr)
        state=firewall_state(port,proto.lower(),family,scope)
        entries.append((proto.upper(),local,proc,scope,state))
    headers=['ПРОТОКОЛ','АДРЕС:ПОРТ','ПРОЦЕСС','ПРИВЯЗКА','UFW (оценка)']
    widths=[9,27,22,15,43]
    print('  '.join(f'{h:<{w}}' for h,w in zip(headers,widths)))
    print('-'*125)
    for entry in entries:
        print('  '.join(f'{str(x)[:w]:<{w}}' for x,w in zip(entry,widths)))
    print('\nПРИМЕЧАНИЕ: UFW (оценка) — только явные правила из ufw status numbered.')
    print('Правила с диапазонами, интерфейсами, порядок обработки, default policy, Docker, IPv6 и firewall провайдера могут изменить результат.')
    print('Слушающий порт не обязательно доступен извне. Для проверки доступности нужен внешний тест.')
    risky=[(proto,local,proc) for proto,local,proc,scope,_ in entries if scope=='все адреса' and local.rsplit(':',1)[-1] in ('1080','3306','5432','6379','27017','2375','9200')]
    if risky:
        print('\n[!] СЛУЖБЫ, ТРЕБУЮЩИЕ ВНИМАНИЯ (привязаны ко всем адресам):')
        for proto,local,proc in risky: print(f'    {proto} {local} — {proc}')
        print('    Проверьте авторизацию и ограничения доступа. Это не доказывает доступность извне.')
PYPORTS
  else mark WARN 'Для таблицы портов нужны ss (iproute2) и Python 3'; fi
  printf '\n========== ИТОГ АУДИТА ==========\n'
  printf 'УСПЕШНО: %s | ПРЕДУПРЕЖДЕНИЯ: %s | ОШИБКИ: %s\n' "$PASS" "$WARN" "$FAIL"
  printf 'Режим аудита не изменяет файлы, службы и правила файрвола.\n'

}

[[ "$EUID" -eq 0 ]] || fail 'Запустите от root или через sudo.'
[[ -t 0 ]] || fail 'Нужен интерактивный терминал.'
printf '\n╔══════════════════════════════════════════╗\n║     REMNAWAVE NODE MANAGER v0.2.9       ║\n╚══════════════════════════════════════════╝\n'
printf '  1. Установить новую RemnaNode\n  2. Проверить существующую ноду (без изменений)\n  3. Завершить незавершённую установку\n  0. Выход\n\n'
read -r -p 'Выберите пункт: ' choice
case "$choice" in
  1) install_mode ;;
  2) audit_mode ;;
  3) resume_mode ;;
  0) exit 0 ;;
  *) fail 'Неверный пункт меню.' ;;
esac