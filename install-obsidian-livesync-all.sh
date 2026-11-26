#!/usr/bin/env bash
# Всё-в-одном для Debian/Ubuntu: поднимает свой сервер CouchDB для Obsidian
# и ставит клиент-плагин Self-hosted LiveSync в хранилище Obsidian.
#
#   sudo bash install-obsidian-livesync-all.sh
#   sudo bash install-obsidian-livesync-all.sh -v /home/user/Vault     # хранилище вручную
#   sudo bash install-obsidian-livesync-all.sh                         # сервер в локалке + пароль
#   sudo bash install-obsidian-livesync-all.sh --local                 # только этот ноут
#   sudo bash install-obsidian-livesync-all.sh -n                      # только план
#
# Скрипт можно запускать дважды: он не пересоздаёт данные и не меняет пароль.

set -euo pipefail

PLUGIN_ID="obsidian-livesync"
REPO="vrtmrz/obsidian-livesync"
FALLBACK_TAG="1.0.52"
MIN_SIZE=200000
SRV_DIR="/opt/obsidian-livesync"
BIND="0.0.0.0"   # по умолчанию доступен в локальной сети, всегда с паролем
PORT="5984"
DB="obsidian"
VAULT=""; DRY=0; FORCE=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--vault)  VAULT="${2:?-v требует путь}"; shift 2 ;;
    -t|--tag)    TAG_OVERRIDE="${2:?-t требует версию}"; shift 2 ;;
    -n|--dry-run) DRY=1; shift ;;
    -f|--force)  FORCE=1; shift ;;
    --lan)       BIND="0.0.0.0"; shift ;;
    --local)     BIND="127.0.0.1"; shift ;;
    --port)      PORT="${2:?--port требует номер}"; shift 2 ;;
    --data)      SRV_DIR="${2:?--data требует путь}"; shift 2 ;;
    -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "неизвестный аргумент: $1 (см. -h)" ;;
  esac
done
TAG="${TAG_OVERRIDE:-}"

# --- root -------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "нужны права root (sudo не найден)"
  exec sudo -E bash "$0" "$@"
fi
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="/root"

step "1/6 Проверка системы"
. /etc/os-release 2>/dev/null || true
case "${ID:-}${ID_LIKE:-}" in
  *debian*|*ubuntu*) ok "${PRETTY_NAME:-Debian}" ;;
  *) warn "это не Debian/Ubuntu (${PRETTY_NAME:-неизвестно}) — работаю, но не гарантирую" ;;
esac
[ "$PORT" -gt 1023 ] || die "порт $PORT требует root-привилегий на некоторых системах, возьми >1023"

need_pkgs=()
command -v curl >/dev/null 2>&1 || need_pkgs+=(curl)
command -v openssl >/dev/null 2>&1 || need_pkgs+=(openssl)
command -v python3 >/dev/null 2>&1 || need_pkgs+=(python3)
command -v docker >/dev/null 2>&1 || need_pkgs+=(docker.io)
if [ "${#need_pkgs[@]}" -gt 0 ]; then
  say_pkgs="${need_pkgs[*]}"
  if [ "$DRY" = 1 ]; then
    warn "(dry-run) установил бы пакеты: $say_pkgs"
  else
    printf '  ставлю: %s (может занять пару минут)\n' "$say_pkgs"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "${need_pkgs[@]}" >/dev/null || die "не удалось поставить: $say_pkgs"
    ok "пакеты установлены"
  fi
fi

# docker compose: плагин v2 или старый docker-compose
if ! command -v docker >/dev/null 2>&1 || { ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; }; then
  if [ "$DRY" = 0 ]; then
    printf '  ставлю docker compose...\n'
    apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 || apt-get install -y -qq docker-compose >/dev/null 2>&1 || warn "соmpose не встал из apt"
  fi
fi

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    die "нет ни 'docker compose', ни 'docker-compose'. Поставь: apt install docker-compose-v2"
  fi
}

if [ "$DRY" = 0 ]; then
  systemctl enable --now docker >/dev/null 2>&1 || true
  for i in $(seq 1 20); do docker info >/dev/null 2>&1 && break; sleep 1; done
  docker info >/dev/null 2>&1 || die "демон docker не поднялся (systemctl status docker)"
  ok "docker работает"
fi

# --- хранилище Obsidian (клиентская часть) -----------------------------------
step "2/6 Хранилище Obsidian"
if [ -z "$VAULT" ]; then
  mapfile -t FOUND < <(find "$TARGET_HOME" -maxdepth 5 -type d -name .obsidian 2>/dev/null | sed 's|/\.obsidian$||' | sort -u)
  if [ "${#FOUND[@]}" -eq 0 ]; then
    die "не нашёл хранилище Obsidian в $TARGET_HOME. Создай его в Obsidian (или укажи -v /путь/к/хранилищу)"
  elif [ "${#FOUND[@]}" -eq 1 ]; then
    VAULT="${FOUND[0]}"
  else
    printf '  найдено несколько хранилищ:\n'
    i=1; for v in "${FOUND[@]}"; do printf '   %2d) %s\n' "$i" "$v"; i=$((i+1)); done
    printf '  Номер: '; read -r n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#FOUND[@]}" ] || die "нет такого номера"
    VAULT="${FOUND[$((n-1))]}"
  fi
fi
VAULT="${VAULT%/}"; VAULT="${VAULT/#\~/$HOME}"
[ -d "$VAULT/.obsidian" ] || die "$VAULT не похожа на хранилище Obsidian (нет .obsidian). Открой её в Obsidian один раз"
PLUGINS="$VAULT/.obsidian/plugins"
TARGET="$PLUGINS/$PLUGIN_ID"
COMMUNITY="$VAULT/.obsidian/community-plugins.json"
ok "хранилище: $VAULT"

# --- сервер CouchDB ---------------------------------------------------------
step "3/6 Сервер CouchDB"
mkdir -p "$SRV_DIR/conf" "$SRV_DIR/data"
if [ -f "$SRV_DIR/.env" ]; then
  DB_PASS="$(grep -E '^COUCHDB_PASSWORD=' "$SRV_DIR/.env" | cut -d= -f2-)"
  ok "настройки уже есть в $SRV_DIR — использую их (пароль не меняю)"
else
  DB_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
fi

if [ "$DRY" = 1 ]; then
  warn "(dry-run) создал бы $SRV_DIR/{compose.yml,conf/10-livesync.ini,.env} и запустил контейнер couchdb:3.3 на ${BIND}:${PORT}"
else
  cat > "$SRV_DIR/.env" <<EOF
COUCHDB_USER=admin
COUCHDB_PASSWORD=$DB_PASS
BIND_ADDR=$BIND
PORT=$PORT
EOF
  chmod 600 "$SRV_DIR/.env"

  cat > "$SRV_DIR/conf/10-livesync.ini" <<'EOF'
; Настройки CouchDB под Obsidian Self-hosted LiveSync
[couchdb]
single_node = true
max_document_size = 50000000

[httpd]
enable_cors = true

[chttpd]
require_valid_user = true
enable_cors = true
WWW-Authenticate = Basic realm="couchdb"
max_http_request_size = 4294967296

[chttpd_auth]
same_site = None

[cors]
origins = *
credentials = true
headers = accept, authorization, content-type, origin, referer
methods = GET, PUT, POST, HEAD, DELETE

[cluster]
q = 1
n = 1
EOF

  cat > "$SRV_DIR/compose.yml" <<EOF
name: obsidian-livesync
services:
  couchdb:
    image: couchdb:3.3
    container_name: obsidian-livesync
    restart: unless-stopped
    env_file: $SRV_DIR/.env
    ports:
      - "\${BIND_ADDR}:\${PORT}:5984"
    volumes:
      - $SRV_DIR/data:/opt/couchdb/data
      - $SRV_DIR/conf/10-livesync.ini:/opt/couchdb/etc/local.d/10-livesync.ini
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS -u \$\$COUCHDB_USER:\$\$COUCHDB_PASSWORD http://localhost:5984/_up || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s
EOF
  chown -R 5984:5984 "$SRV_DIR/data"
  ok "конфиг записан в $SRV_DIR"

  printf '  запускаю контейнер (первый раз качает образ ~150 МБ)...\n'
  ( cd "$SRV_DIR" && compose up -d >/dev/null 2>&1 ) || die "docker compose не запустился. Смотри: cd $SRV_DIR && docker compose up"
  ok "контейнер запущен"
fi

# --- ожидание и проверка ----------------------------------------------------
api() { curl -sS --max-time 5 -u "admin:$DB_PASS" "http://127.0.0.1:$PORT$1" "${@:2}"; }

if [ "$DRY" = 0 ]; then
  step "4/6 Проверка сервера"
  up=0
  for i in $(seq 1 60); do
    if api /_up 2>/dev/null | grep -q '"ok"'; then up=1; break; fi
    sleep 2
  done
  [ "$up" = 1 ] || die "CouchDB не отвечает за 2 минуты. Логи: docker logs obsidian-livesync"
  ok "CouchDB отвечает (_up: ok)"

  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")"
  [ "$code" = "401" ] || warn "без пароля отвечает $code (ожидал 401) — проверь require_valid_user"

  api "/$DB" -X PUT >/dev/null 2>&1 || true
  if api "/$DB" | grep -q "\"db_name\":\"$DB\""; then ok "база '$DB' готова"; else die "база '$DB' не создалась"; fi

  resp="$(api "/$DB/livesync-selftest" -X PUT -H 'Content-Type: application/json' -d '{"t":1}' 2>&1 || true)"
  rev="$(printf '%s' "$resp" | grep -o '"rev":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
  if [ -n "$rev" ]; then
    api "/$DB/livesync-selftest?rev=$rev" -X DELETE >/dev/null || warn "тестовый документ не удалился"
    ok "запись/чтение/удаление в базе работают"
  else
    die "не смог записать документ в базу $DB (ответ: $resp)"
  fi

  cors="$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS "http://127.0.0.1:$PORT/$DB" \
      -H 'Origin: app://obsidian.md' -H 'Access-Control-Request-Method: PUT' \
      -H 'Access-Control-Request-Headers: authorization,content-type')"
  if [ "$cors" = "204" ] || [ "$cors" = "200" ]; then
    ok "CORS для Obsidian разрешён (preflight $cors)"
  else
    warn "CORS preflight вернул $cors — плагин может ругаться"
  fi
fi

# --- клиент: плагин ---------------------------------------------------------
step "5/6 Плагин Self-hosted LiveSync"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if [ "$DRY" = 0 ]; then
  if [ -z "$TAG" ]; then
    TAG="$(curl -fsSL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
           | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')" || true
    [ -n "$TAG" ] || { TAG="$FALLBACK_TAG"; warn "GitHub API не ответил, беру версию $TAG"; }
  fi
  for f in main.js manifest.json styles.css; do
    printf '  качаю %-14s' "$f"
    curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 -o "$WORK/$f" \
      "https://github.com/$REPO/releases/download/$TAG/$f" || { echo; die "не скачалось: $TAG/$f"; }
    echo " ok"
  done
  [ "$(wc -c < "$WORK/main.js")" -ge "$MIN_SIZE" ] || die "main.js слишком маленький — битая загрузка"
  grep -q "\"$PLUGIN_ID\"" "$WORK/manifest.json" || die "manifest.json не от этого плагина"

  if [ "$FORCE" = 0 ] && [ -f "$TARGET/manifest.json" ]; then
    V="$(grep -o '"version"[^,]*' "$TARGET/manifest.json" | cut -d'"' -f4)"
    ok "плагин уже стоит ($V) — файлы не трогаю"
  else
    mkdir -p "$PLUGINS"
    if [ -d "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
      BAK="$VAULT/.obsidian/.plugin-backups/$PLUGIN_ID.$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$(dirname "$BAK")"; mv "$TARGET" "$BAK"
      ok "старая версия сохранена: $BAK"
    fi
    mkdir -p "$TARGET"
    install -m 644 "$WORK/main.js" "$WORK/manifest.json" "$WORK/styles.css" "$TARGET/"
    ok "файлы плагина на месте ($TAG)"
  fi

  if ps -eo comm= | grep -qiE '^obsidian' && ! grep -q "\"$PLUGIN_ID\"" "$COMMUNITY" 2>/dev/null; then
    warn "Obsidian запущен — включи плагин вручную в списке после закрытия"
  else
    python3 - "$COMMUNITY" "$PLUGIN_ID" <<'PY'
import json, os, sys
path, pid = sys.argv[1], sys.argv[2]
data = []
if os.path.exists(path) and os.path.getsize(path):
    try:
        data = json.load(open(path, encoding="utf-8"))
        assert isinstance(data, list)
    except Exception:
        data = []
if pid not in data:
    data.append(pid)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False); fh.write("\n")
PY
    ok "плагин включён в community-plugins.json"
  fi
  chown -R "$TARGET_USER":"$TARGET_USER" "$VAULT/.obsidian/plugins" "$COMMUNITY" 2>/dev/null || true
else
  warn "(dry-run) скачал бы плагин $REPO и положил в $TARGET"
fi

# --- итог -------------------------------------------------------------------
if [ "$BIND" = "0.0.0.0" ]; then
  HOST_SHOWN="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$HOST_SHOWN" ] || HOST_SHOWN="<ip-этой-машины>"
else
  HOST_SHOWN="127.0.0.1"
fi

CRED_DIR="$TARGET_HOME/.config/obsidian-livesync"
if [ "$DRY" = 0 ]; then
  mkdir -p "$CRED_DIR"
  cat > "$CRED_DIR/server.txt" <<EOF
Сервер CouchDB для Obsidian Self-hosted LiveSync

URI сервера:   http://$HOST_SHOWN:$PORT
База:          $DB
Пользователь:  admin
Пароль:        $DB_PASS

Passphrase (E2EE) задаётся в мастере плагина и должна совпадать
на всех устройствах. Восстановить её нельзя — сохрани в надёжном месте.

Данные сервера: $SRV_DIR/data  (бэкапить; контейнер: obsidian-livesync)
EOF
  chmod 600 "$CRED_DIR/server.txt"
  chown -R "$TARGET_USER":"$TARGET_USER" "$CRED_DIR" 2>/dev/null || true
fi

step "6/6 Готово"
if [ "$DRY" = 0 ]; then
  cat <<EOF
  Сервер: http://$HOST_SHOWN:$PORT   база: $DB   пользователь: admin
  Пароль: $DB_PASS
  (эти же данные сохранены в $CRED_DIR/server.txt, доступ только владельцу)

  В Obsidian:
    1. Настройки → Сторонние плагины → выключить «Ограниченный режим».
    2. Включить «Self-hosted LiveSync».
    3. Ctrl+P → «Self-hosted LiveSync: Setup Wizard» → CouchDB:
         URI: http://$HOST_SHOWN:$PORT
         Database: $DB
         Username: admin   Password: (из server.txt)
         Passphrase: придумай свою — ОДНА на все устройства.
    4. «Test connection» → Save → «Use the existing remote database» на втором устройстве.
EOF
  if [ "$BIND" = "127.0.0.1" ]; then
    warn "режим --local: сервер слушает только эту машину, телефон и второй ПК не подключатся"
  else
    ok "сервер слушает ${HOST_SHOWN}:$PORT — доступен в локальной сети, вход по паролю"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
      warn "включён ufw: если не подключается, разреши порт — sudo ufw allow $PORT/tcp"
    fi
  fi
  ok "всё на месте"
else
  warn "(dry-run) ничего не изменено"
fi
