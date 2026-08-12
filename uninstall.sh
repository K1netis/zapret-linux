#!/usr/bin/env bash
# uninstall.sh — полностью удаляет zapret-linux: останавливает службу, снимает
# правила nftables, убирает файлы из /opt, /etc и symlink команды.
#
#   sudo ./uninstall.sh          с подтверждением
#   sudo ./uninstall.sh --yes    без вопросов
#   sudo ./uninstall.sh --keep-lists   сохранить ваши lists/*-user.txt
#
# Каталог с исходниками (там, откуда ставили) не трогается.
set -uo pipefail

OPT_DIR="${OPT_DIR:-/opt/zapret-linux}"
ETC_DIR="${ETC_DIR:-/etc/zapret-linux}"
UNIT=/etc/systemd/system/zapret-linux.service
LINK=/usr/local/bin/zapret
TABLE="inet zapret_linux"
SERVICE=zapret-linux

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

[ "$(id -u)" = 0 ] || { echo "запустите через sudo" >&2; exit 1; }

ASSUME_YES=0; KEEP_LISTS=0
for a in "$@"; do
  case "$a" in
    --yes|-y) ASSUME_YES=1 ;;
    --keep-lists) KEEP_LISTS=1 ;;
    *) warn "неизвестный аргумент: $a" ;;
  esac
done

if [ "$ASSUME_YES" != 1 ]; then
  echo "Будет удалено:"
  echo "  служба $SERVICE и её unit-файл"
  echo "  правила nftables ($TABLE)"
  echo "  $OPT_DIR  (движок, стратегии, списки, фейки)"
  echo "  $ETC_DIR  (активная конфигурация)"
  echo "  $LINK     (команда zapret)"
  [ "$KEEP_LISTS" = 1 ] && echo "  ваши lists/*-user.txt будут сохранены в /root/zapret-user-lists"
  printf 'Продолжить? [y/N] '
  read -r ans
  case "$ans" in y|Y|д|Д) ;; *) echo "отменено"; exit 0 ;; esac
fi

# 1) сохранить пользовательские списки, если попросили
if [ "$KEEP_LISTS" = 1 ] && ls "$OPT_DIR"/lists/*-user.txt >/dev/null 2>&1; then
  backup=/root/zapret-user-lists
  mkdir -p "$backup"
  cp -a "$OPT_DIR"/lists/*-user.txt "$backup"/ 2>/dev/null || true
  say "пользовательские списки сохранены в $backup"
fi

# 2) остановить и отключить службу
if command -v systemctl >/dev/null 2>&1; then
  say "останавливаю службу"
  systemctl stop "$SERVICE" 2>/dev/null || true
  systemctl disable "$SERVICE" 2>/dev/null || true
  systemctl reset-failed "$SERVICE" 2>/dev/null || true
fi

# 3) снять правила nftables (ExecStopPost мог не отработать)
if command -v nft >/dev/null 2>&1; then
  if nft list table $TABLE >/dev/null 2>&1; then
    say "удаляю правила nftables"
    nft delete table $TABLE 2>/dev/null || warn "не удалось удалить таблицу $TABLE"
  fi
fi

# 4) добить возможные оставшиеся процессы nfqws нашего пути
if pgrep -f "$OPT_DIR/nfqws" >/dev/null 2>&1; then
  say "завершаю оставшиеся процессы nfqws"
  pkill -f "$OPT_DIR/nfqws" 2>/dev/null || true
  sleep 1
  pkill -9 -f "$OPT_DIR/nfqws" 2>/dev/null || true
fi

# 5) файлы
[ -f "$UNIT" ] && { say "удаляю unit-файл"; rm -f "$UNIT"; }
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true
[ -L "$LINK" ] || [ -f "$LINK" ] && { say "удаляю команду zapret"; rm -f "$LINK"; }
[ -d "$OPT_DIR" ] && { say "удаляю $OPT_DIR"; rm -rf "$OPT_DIR"; }
[ -d "$ETC_DIR" ] && { say "удаляю $ETC_DIR"; rm -rf "$ETC_DIR"; }

# 6) проверка, что ничего не осталось
left=""
for p in "$OPT_DIR" "$ETC_DIR" "$UNIT" "$LINK"; do [ -e "$p" ] && left="$left $p"; done
command -v nft >/dev/null 2>&1 && nft list table $TABLE >/dev/null 2>&1 && left="$left $TABLE"

if [ -n "$left" ]; then
  warn "осталось (удалите вручную):$left"
  exit 1
fi

say "zapret-linux полностью удалён"
echo "  Каталог с исходниками не тронут — его можно удалить вручную."
