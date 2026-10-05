#!/usr/bin/env bash
# update.sh — обновление самого zapret-linux (не стратегий Flowseal).
# Скачивает свежую версию из своего репозитория и переустанавливает поверх,
# сохраняя текущую стратегию, режимы фильтров и пользовательские списки.
#
#   zapret update            проверить и обновить, если есть новая версия
#   zapret update --check    только проверить, ничего не менять
#   zapret update --force    переустановить даже если версия та же
set -uo pipefail

OPT_DIR="${OPT_DIR:-/opt/zapret-linux}"
ETC_DIR="${ETC_DIR:-/etc/zapret-linux}"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужны права root (sudo zapret update)"
command -v curl >/dev/null 2>&1 || die "нужен curl"

CHECK_ONLY=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    *) warn "неизвестный аргумент: $a" ;;
  esac
done

# настройки репозитория
UPDATE_REPO=""; UPDATE_BRANCH=main
[ -f "$OPT_DIR/repo.conf" ] && . "$OPT_DIR/repo.conf"
[ -n "${UPDATE_REPO:-}" ] && [ "$UPDATE_REPO" != "CHANGE_ME/zapret-linux" ] \
  || die "не задан репозиторий обновлений. Укажите UPDATE_REPO в $OPT_DIR/repo.conf"

local_ver="$(cat "$OPT_DIR/VERSION" 2>/dev/null || echo 0.0.0)"
say "установлено: $local_ver  (репозиторий: $UPDATE_REPO)"

remote_ver="$(curl -fsSL --max-time 15 \
  "https://raw.githubusercontent.com/$UPDATE_REPO/$UPDATE_BRANCH/VERSION" 2>/dev/null | tr -d '[:space:]')"
[ -n "$remote_ver" ] || die "не удалось получить версию из репозитория (нет сети или неверный UPDATE_REPO)"
say "доступно:   $remote_ver"

# сравнение версий: новее ли удалённая
newer() {
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

if [ "$FORCE" != 1 ] && ! newer "$local_ver" "$remote_ver"; then
  say "у вас актуальная версия, обновление не требуется"
  exit 0
fi
if [ "$CHECK_ONLY" = 1 ]; then
  say "доступно обновление $local_ver -> $remote_ver (запустите: sudo zapret update)"
  exit 0
fi

# запоминаем текущее состояние
strategy=general; gf=off; ips=loaded
if [ -f "$ETC_DIR/active.env" ]; then
  # shellcheck disable=SC1091
  . "$ETC_DIR/active.env"; strategy="${STRATEGY_FILE:-general}"
fi
[ -f "$ETC_DIR/gamefilter" ]   && gf="$(cat "$ETC_DIR/gamefilter")"
[ -f "$ETC_DIR/ipsetfilter" ] && ips="$(cat "$ETC_DIR/ipsetfilter")"
say "текущее состояние: стратегия=$strategy, gamefilter=$gf, ipset=$ips"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
say "скачиваю $remote_ver"
curl -fsSL --max-time 120 \
  "https://codeload.github.com/$UPDATE_REPO/tar.gz/refs/heads/$UPDATE_BRANCH" \
  -o "$tmp/src.tar.gz" || die "не удалось скачать архив"
tar -xzf "$tmp/src.tar.gz" -C "$tmp" || die "архив повреждён"
src="$(find "$tmp" -maxdepth 1 -type d -name '*zapret-linux*' | head -n1)"
[ -d "$src" ] || die "неожиданная структура архива"
[ -f "$src/install.sh" ] || die "в архиве нет install.sh"

# переиспользуем уже собранный движок, чтобы не пересобирать и не качать заново
if [ -x "$OPT_DIR/nfqws" ]; then
  mkdir -p "$src/zapret/nfq"
  cp -a "$OPT_DIR/nfqws" "$src/zapret/nfq/nfqws"
  say "движок nfqws переиспользован (без пересборки)"
fi
# сохраняем пользовательские списки и уже скачанные ресурсы
mkdir -p "$src/lists" "$src/bin"
cp -a "$OPT_DIR"/lists/. "$src/lists/" 2>/dev/null || true
cp -a "$OPT_DIR"/bin/.   "$src/bin/"   2>/dev/null || true

say "устанавливаю"
chmod +x "$src"/*.sh "$src"/zapret-cli "$src"/lib/*.sh "$src"/tools/*.sh 2>/dev/null || true
if SYNC=0 DEFAULT_STRATEGY="$strategy" bash "$src/install.sh"; then
  # восстанавливаем режимы фильтров
  echo "$gf"  > "$ETC_DIR/gamefilter"
  echo "$ips" > "$ETC_DIR/ipsetfilter"
  "$OPT_DIR/apply-strategy.sh" "$strategy" >/dev/null 2>&1 || \
    warn "не удалось переприменить стратегию '$strategy' — выберите вручную: zapret list"
  say "обновлено: $local_ver -> $remote_ver"
  echo "  Настройки сохранены: стратегия=$strategy, gamefilter=$gf, ipset=$ips"
  echo "  Стратегии Flowseal обновляются отдельно: sudo zapret sync"
else
  die "установка не удалась, прежняя версия осталась работать"
fi
