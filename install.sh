#!/usr/bin/env bash
# install.sh — установка zapret-linux на систему с systemd.
#
# Порядок действий:
#   1. загрузка движка bol-van/zapret
#   2. получение бинарника nfqws (готового или собранного из исходников)
#   3. загрузка стратегий, списков и фейков от Flowseal
#   4. копирование файлов в /opt/zapret-linux (nfqws — первым)
#   5. установка службы systemd, запись номера версии
#   6. применение стратегии (сохранённой или general при первой установке)
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
OPT_DIR=/opt/zapret-linux
ETC_DIR=/etc/zapret-linux
ENGINE_DIR="$SRC/zapret"
# Повторная установка поверх существующей (вручную или через zapret update):
# сохраняем выбранную пользователем стратегию, а не сбрасываем её на general.
PREV_VERSION="$(cat "$OPT_DIR/VERSION" 2>/dev/null || true)"
if [ -z "${DEFAULT_STRATEGY:-}" ] && [ -f "$ETC_DIR/active.env" ]; then
  DEFAULT_STRATEGY="$( . "$ETC_DIR/active.env" 2>/dev/null; echo "${STRATEGY_FILE:-}" )"
fi
DEFAULT_STRATEGY="${DEFAULT_STRATEGY:-general}"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужны права root: sudo bash install.sh"

# Архивы и загрузки из браузера теряют признак исполняемости — восстанавливаем,
# чтобы дальнейшая работа не зависела от способа получения файлов.
chmod +x "$SRC"/*.sh "$SRC"/lib/*.sh "$SRC"/tools/*.sh 2>/dev/null || true
command -v nft >/dev/null 2>&1 || warn "не найден nftables (nft) — установите его перед запуском службы."

# 1) Движок ------------------------------------------------------------------
if [ ! -e "$ENGINE_DIR/nfq/Makefile" ] && [ ! -x "$OPT_DIR/nfqws" ]; then
  say "загружаю движок bol-van/zapret"
  git clone --depth=1 https://github.com/bol-van/zapret "$ENGINE_DIR" \
    || die "не удалось загрузить движок (нет сети или не установлен git)"
fi

# 2) Бинарник nfqws ----------------------------------------------------------
NFQWS=""
# уже установленный движок переиспользуем: не качаем исходники и не пересобираем
if [ -z "${NFQWS:-}" ] && [ -x "$OPT_DIR/nfqws" ] && [ ! -x "$ENGINE_DIR/nfq/nfqws" ]; then
  NFQWS="$OPT_DIR/nfqws"
  say "используется уже собранный nfqws"
fi
if [ -z "$NFQWS" ] && [ -x "$ENGINE_DIR/nfq/nfqws" ]; then
  NFQWS="$ENGINE_DIR/nfq/nfqws"
else
  arch="$(uname -m)"
  for cand in "$ENGINE_DIR"/binaries/*"$arch"*/nfqws "$ENGINE_DIR"/binaries/*/nfqws; do
    [ -x "$cand" ] && { NFQWS="$cand"; break; }
  done
fi
if [ -z "$NFQWS" ]; then
  say "собираю nfqws из исходников"
  make -C "$ENGINE_DIR/nfq" nfqws \
    || die "сборка nfqws не удалась. Установите зависимости: gcc make zlib1g-dev libnetfilter-queue-dev libnfnetlink-dev libmnl-dev"
  NFQWS="$ENGINE_DIR/nfq/nfqws"
fi
[ -x "$NFQWS" ] || die "не удалось получить рабочий бинарник nfqws"

# 3) Загрузка стратегий, списков и фейков от Flowseal -------------------------
SYNC="${SYNC:-auto}"   # auto | 1 | 0
need_sync=0; ls "$SRC"/lists/*.txt >/dev/null 2>&1 || need_sync=1
case "$SYNC" in 1) do_sync=1 ;; 0) do_sync=0 ;; *) do_sync=$need_sync ;; esac
if [ "$do_sync" = 1 ]; then
  if command -v curl >/dev/null 2>&1; then
    say "загружаю стратегии, списки и фейки от Flowseal"
    bash "$SRC/sync-flowseal.sh" || warn "загрузка от Flowseal не удалась — заполните lists/ и bin/ вручную."
  else
    warn "curl не найден — пропускаю загрузку от Flowseal."
  fi
fi

# 4) Копирование файлов проекта ----------------------------------------------
say "копирую файлы в $OPT_DIR"
mkdir -p "$OPT_DIR"/{lib,tools,strategies,lists,bin,systemd}

# Все файлы заменяем через новую копию рядом и переименование. Перезапись на
# месте ломает тех, кто файл сейчас использует: поверх работающего nfqws писать
# нельзя («Текстовый файл занят»), а bash, исполняющий update.sh, читает скрипт
# по ходу работы и после подмены содержимого продолжил бы читать из середины
# нового файла. При переименовании они дорабатывают со старой копией.
put() { # источник назначение
  if [ -f "$2" ] && cmp -s "$1" "$2"; then
    return 0                                   # не изменился — не трогаем
  fi
  cp -a "$1" "$2.new.$$" && mv -f "$2.new.$$" "$2"
}
put_dir() { # каталог-источник каталог-назначение (файлы верхнего уровня)
  local f
  for f in "$1"/* "$1"/.[!.]*; do
    [ -f "$f" ] || continue
    put "$f" "$2/$(basename "$f")" || return 1
  done
}

# Бинарник — первым: если что-то пойдёт не так, остальные файлы ещё не тронуты.
put "$NFQWS" "$OPT_DIR/nfqws" || die "не удалось установить nfqws"
chmod +x "$OPT_DIR/nfqws"

for f in apply-strategy.sh gamefilter.sh ipsetfilter.sh fakes.sh status.sh \
         selftest.sh sync-flowseal.sh uninstall.sh update.sh zapret-cli; do
  put "$SRC/$f" "$OPT_DIR/$f" || die "не удалось установить $f"
done
put_dir "$SRC/lib"        "$OPT_DIR/lib"        || die "не удалось установить lib/"
put_dir "$SRC/tools"      "$OPT_DIR/tools"      || die "не удалось установить tools/"
put_dir "$SRC/strategies" "$OPT_DIR/strategies" || die "не удалось установить strategies/"
# файл службы нужен при удалении и переустановке — держим рядом
put_dir "$SRC/systemd"    "$OPT_DIR/systemd"    || die "не удалось установить systemd/"
# repo.conf не трогаем: там настройки обновления, заданные пользователем
[ -f "$OPT_DIR/repo.conf" ] || put "$SRC/repo.conf" "$OPT_DIR/repo.conf" || true
# списки и фейки копируем без перезаписи: не затираем то, что уже установлено
cp -an "$SRC"/lists/. "$OPT_DIR/lists/" 2>/dev/null || true
cp -an "$SRC"/bin/.   "$OPT_DIR/bin/"   2>/dev/null || true
chmod +x "$OPT_DIR"/*.sh "$OPT_DIR"/lib/*.sh "$OPT_DIR"/tools/*.sh "$OPT_DIR/zapret-cli"

# единая команда управления
ln -sf "$OPT_DIR/zapret-cli" /usr/local/bin/zapret

# предупреждаем о фейках, на которые ссылаются стратегии, но которых нет
missing=0
for b in $(grep -rhoE '@BIN@/[a-zA-Z0-9_.-]+\.bin' "$OPT_DIR/strategies" | sed 's|@BIN@/||' | sort -u); do
  [ -f "$OPT_DIR/bin/$b" ] || { warn "нет файла-фейка: bin/$b"; missing=1; }
done
[ "$missing" = 0 ] || warn "стратегии, ссылающиеся на отсутствующие фейки, работать не будут."

# без списков nfqws не запустится так же, как без фейков
if ! ls "$OPT_DIR"/lists/*.txt >/dev/null 2>&1; then
  warn "lists/ пуст — nfqws не запустится. Выполните: bash $SRC/sync-flowseal.sh"
  ASSETS_OK=0
else
  ASSETS_OK=1
fi
[ "$missing" = 0 ] || ASSETS_OK=0

# 5) Служба systemd ----------------------------------------------------------
say "устанавливаю службу systemd"
install -m644 "$SRC/systemd/zapret-linux.service" /etc/systemd/system/zapret-linux.service
systemctl daemon-reload

# Номер версии записываем последним, когда все файлы уже на месте. Если установка
# сорвётся раньше, останется прежний номер, и zapret update повторит попытку.
put "$SRC/VERSION" "$OPT_DIR/VERSION"

# 6) Применение стратегии ----------------------------------------------------
mkdir -p "$ETC_DIR"
[ -f "$ETC_DIR/gamefilter" ] || echo off > "$ETC_DIR/gamefilter"
[ -f "$ETC_DIR/ipsetfilter" ] || echo loaded > "$ETC_DIR/ipsetfilter"
if [ "${ASSETS_OK:-1}" != 1 ]; then
  warn "пропускаю запуск сервиса: сначала доставьте списки и фейки, затем:"
  warn "  bash $SRC/sync-flowseal.sh && sudo $OPT_DIR/apply-strategy.sh $DEFAULT_STRATEGY"
  exit 1
fi
say "применяю стратегию: $DEFAULT_STRATEGY"
OPT_DIR="$OPT_DIR" ETC_DIR="$ETC_DIR" "$OPT_DIR/apply-strategy.sh" "$DEFAULT_STRATEGY" || \
  warn "не удалось применить стратегию — проверьте наличие списков и фейков."

systemctl enable zapret-linux >/dev/null 2>&1 || true
NEW_VERSION="$(cat "$OPT_DIR/VERSION" 2>/dev/null || echo '?')"
if [ -n "$PREV_VERSION" ]; then
  if [ "$PREV_VERSION" = "$NEW_VERSION" ]; then
    say "готово: zapret-linux $NEW_VERSION переустановлен"
  else
    say "готово: zapret-linux $PREV_VERSION -> $NEW_VERSION"
  fi
  echo "  Справка по командам: zapret help"
  exit 0
fi

cat <<EOF

$(say "готово")  Управление одной командой:

  zapret                 краткая сводка
  zapret status          полная диагностика (счётчики nftables)
  zapret test            проверка обхода на текущей стратегии
  zapret list            список стратегий ($(ls -1 "$OPT_DIR"/strategies/*.conf 2>/dev/null | wc -l) шт.)
  zapret use <имя>       переключить стратегию
  zapret game all        игровой фильтр (off|tcp|udp|all)
  zapret ipset loaded    режим IPSet (none|loaded|any)
  zapret fakes list      подмена .bin-фейков
  zapret sync            обновить стратегии Flowseal
  zapret update          обновить сам zapret-linux
  zapret log             журнал службы
  zapret uninstall       полное удаление
  zapret help            все команды

  Установка самодостаточна: каталог с исходниками больше не нужен.
EOF
