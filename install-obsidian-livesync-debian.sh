#!/usr/bin/env bash
# Устанавливает плагин Self-hosted LiveSync в хранилище Obsidian (Debian/Ubuntu).
#
#   bash install-obsidian-livesync-debian.sh              # найти хранилище и поставить
#   bash install-obsidian-livesync-debian.sh -n           # только показать план
#   bash install-obsidian-livesync-debian.sh -v ~/Vault   # указать хранилище вручную
#   bash install-obsidian-livesync-debian.sh -d ~/lsync   # офлайн: файлы уже скачаны сюда
#
# Ставит только плагин и включает его в списке. Логин/пароль/адрес CouchDB
# в файлы не пишет — их вводят в мастере плагина внутри Obsidian.

set -euo pipefail

ID="obsidian-livesync"
REPO="vrtmrz/obsidian-livesync"
FALLBACK_TAG="1.0.52"
MIN_SIZE=200000

VAULT=""; SRC=""; TAG=""; DRY=0; FORCE=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--vault)   VAULT="${2:?-v требует путь}"; shift 2 ;;
    -d|--dir)     SRC="${2:?-d требует путь}"; shift 2 ;;
    -t|--tag)     TAG="${2:?-t требует версию}"; shift 2 ;;
    -n|--dry-run) DRY=1; shift ;;
    -f|--force)   FORCE=1; shift ;;
    -h|--help)    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "неизвестный аргумент: $1 (см. -h)" ;;
  esac
done

step "1/4 Проверка системы"
command -v curl >/dev/null 2>&1 || die "нет curl. Поставь: sudo apt update && sudo apt install -y curl"
[ -z "$SRC" ] || [ -d "$SRC" ] || die "папка с файлами не найдена: $SRC"

# Obsidian не должен быть запущен: при выходе он перезапишет список плагинов
# (ps -eo comm= — имя исполняемого файла, поэтому сам скрипт сюда не попадёт)
if ps -eo comm= | grep -qiE '^obsidian'; then
  warn "Obsidian сейчас запущен — закрой его: список плагинов лучше менять при закрытом Obsidian."
  RUNNING=1
else
  ok "Obsidian не запущен"
  RUNNING=0
fi

if command -v obsidian >/dev/null 2>&1 || dpkg-query -W obsidian >/dev/null 2>&1; then
  ok "Obsidian установлен"
else
  warn "Obsidian в системе не вижу — плагин поставлю, но включить его можно будет только после установки Obsidian (obsidian.md → .deb)"
fi

# --- где хранилище ----------------------------------------------------------
if [ -z "$VAULT" ]; then
  mapfile -t FOUND < <(find "$HOME" -maxdepth 5 -type d -name .obsidian 2>/dev/null | sed 's|/\.obsidian$||' | sort -u)
  if [ "${#FOUND[@]}" -eq 0 ]; then
    die "не нашёл ни одного хранилища Obsidian в $HOME. Укажи путь: -v \"/путь/к/хранилищу\""
  elif [ "${#FOUND[@]}" -eq 1 ]; then
    VAULT="${FOUND[0]}"
  else
    printf 'Найдено несколько хранилищ:\n'
    i=1; for v in "${FOUND[@]}"; do printf '  %2d) %s\n' "$i" "$v"; i=$((i+1)); done
    printf 'Номер: '; read -r n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#FOUND[@]}" ] || die "нет такого номера"
    VAULT="${FOUND[$((n-1))]}"
  fi
fi
VAULT="${VAULT%/}"; VAULT="${VAULT/#\~/$HOME}"
[ -d "$VAULT" ] || die "папка не существует: $VAULT"
[ -d "$VAULT/.obsidian" ] || die "$VAULT не похожа на хранилище Obsidian (нет .obsidian). Открой её в Obsidian один раз, потом запусти скрипт снова."

TARGET="$VAULT/.obsidian/plugins/$ID"
COMMUNITY="$VAULT/.obsidian/community-plugins.json"
ok "хранилище: $VAULT"

# --- что уже стоит ----------------------------------------------------------
if [ -f "$TARGET/manifest.json" ] && [ "$FORCE" = 0 ] && [ -z "$TAG" ] && [ -z "$SRC" ]; then
  V="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$TARGET/manifest.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  warn "плагин уже стоит ($V)"
  if grep -q "\"$ID\"" "$COMMUNITY" 2>/dev/null; then
    [ "$RUNNING" = 1 ] && die "Обсидиан запущен, но плагин уже включён — просто перезапусти Obsidian."
    ok "и включён в списке — ничего не делаю. Переустановить: -f"
    exit 0
  fi
  [ "$RUNNING" = 1 ] && die "закрой Obsidian и запусти скрипт снова, чтобы включить плагин"
fi

# --- получаем файлы ---------------------------------------------------------
step "2/4 Файлы плагина"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if [ -n "$SRC" ]; then
  for f in main.js manifest.json styles.css; do
    [ -f "$SRC/$f" ] || die "в $SRC нет $f"
    cp "$SRC/$f" "$WORK/$f"
  done
  V="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$WORK/manifest.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  ok "взял из $SRC (версия $V)"
else
  if [ -z "$TAG" ]; then
    TAG="$(curl -fsSL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
           | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')" || true
    [ -n "$TAG" ] || { TAG="$FALLBACK_TAG"; warn "GitHub API не ответил, беру версию $TAG"; }
  fi
  for f in main.js manifest.json styles.css; do
    printf '  качаю %-14s' "$f"
    curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 \
      -o "$WORK/$f" "https://github.com/$REPO/releases/download/$TAG/$f" \
      || { echo; die "не скачалось: $TAG/$f. Если GitHub недоступен — скачай файлы на другой машине и запусти с -d ПАПКА"; }
    echo " ok ($(du -h "$WORK/$f" | cut -f1))"
  done
  V="$TAG"
fi

[ "$(wc -c < "$WORK/main.js")" -ge "$MIN_SIZE" ] || die "main.js слишком маленький — загрузка битая"
grep -q "\"$ID\"" "$WORK/manifest.json" || die "manifest.json не от этого плагина"
MAN_V="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$WORK/manifest.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
[ "$MAN_V" = "$V" ] || die "версия в manifest.json ($MAN_V) не совпадает с $V"

# --- минимальная версия Obsidian -------------------------------------------
MIN_APP="$(grep -o '"minAppVersion"[[:space:]]*:[[:space:]]*"[^"]*"' "$WORK/manifest.json" | sed 's/.*"\([^"]*\)"$/\1/')"
OBS_V=""
if command -v dpkg >/dev/null 2>&1; then
  OBS_V="$(dpkg-query -W -f='${Version}' obsidian 2>/dev/null | sed 's/-.*//' || true)"
fi
if [ -n "$OBS_V" ]; then
  newest="$(printf '%s\n%s\n' "$OBS_V" "$MIN_APP" | sort -V | tail -1)"
  if [ "$newest" = "$MIN_APP" ] && [ "$OBS_V" != "$MIN_APP" ]; then
    warn "Obsidian $OBS_V старее требуемых $MIN_APP — плагин может не включиться, обнови Obsidian"
  else
    ok "Obsidian $OBS_V (нужно ≥ $MIN_APP)"
  fi
else
  warn "версию Obsidian определить не смог (не .deb?) — плагину нужна версия ≥ $MIN_APP"
fi

if [ "$DRY" = 1 ]; then
  step "План (dry-run, ничего не меняю)"
  echo "  каталог: $TARGET"
  [ -d "$TARGET" ] && echo "  старая версия уедет в $VAULT/.obsidian/.plugin-backups/"
  echo "  включить \"$ID\" в $COMMUNITY"
  exit 0
fi

# --- установка --------------------------------------------------------------
step "3/4 Установка"
mkdir -p "$VAULT/.obsidian/plugins"
if [ -d "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
  BAK="$VAULT/.obsidian/.plugin-backups/$ID.$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$(dirname "$BAK")" && mv "$TARGET" "$BAK"
  ok "старая версия сохранена: $BAK"
fi
mkdir -p "$TARGET"
install -m 644 "$WORK/main.js" "$TARGET/main.js"
install -m 644 "$WORK/manifest.json" "$TARGET/manifest.json"
install -m 644 "$WORK/styles.css" "$TARGET/styles.css"
ok "файлы на месте: $TARGET"

step "4/4 Включение в списке плагинов"
if [ "$RUNNING" = 1 ]; then
  warn "Obsidian был запущен — после его закрытия запусти скрипт ещё раз, чтобы включить плагин"
else
  python3 - "$COMMUNITY" "$ID" <<'PY'
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
  ok "включён: $COMMUNITY"
fi

cat <<EOF

Готово: $ID $V
Хранилище: $VAULT

Дальше в Obsidian:
  1. Настройки → Сторонние плагины → выключить «Ограниченный режим».
  2. В списке появится «Self-hosted LiveSync» — включить.
  3. Ctrl+P → «Self-hosted LiveSync: Setup Wizard» → CouchDB, дальше адрес,
     имя базы, логин, пароль и Passphrase (одна на все устройства).
EOF
