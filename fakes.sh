#!/usr/bin/env bash
# fakes.sh — аналог "Replace active fakes" из Flowseal 1.10.0.
# Позволяет подменить .bin-фейк, используемый для конкретного типа, не правя
# саму стратегию. Подмена применяется поверх любой выбранной стратегии.
#
#   fakes.sh list                       # какие .bin есть в bin/
#   fakes.sh types                      # какие типы фейков использует стратегия
#   fakes.sh set discord quic_initial_dbankcloud_ru.bin
#   fakes.sh set unknown-udp my_fake.bin
#   fakes.sh unset discord
#   fakes.sh status
#
# Тип — это суффикс флага nfqws --dpi-desync-fake-<тип>, например:
#   quic, tls, http, stun, discord, unknown-udp, unknown
set -euo pipefail

ETC_DIR="${ETC_DIR:-/etc/zapret-linux}"
OPT_DIR="${OPT_DIR:-/opt/zapret-linux}"
BIN_DIR="$OPT_DIR/bin"
STRAT_DIR="$OPT_DIR/strategies"
APPLY="$OPT_DIR/apply-strategy.sh"
if [ ! -x "$APPLY" ]; then
  HERE="$(cd "$(dirname "$0")" && pwd)"
  APPLY="$HERE/apply-strategy.sh"; BIN_DIR="$HERE/bin"; STRAT_DIR="$HERE/strategies"
fi
MAP="$ETC_DIR/fakes.conf"

current_strategy() {
  if [ -f "$ETC_DIR/active.env" ]; then
    # shellcheck disable=SC1091
    . "$ETC_DIR/active.env"; echo "${STRATEGY_FILE:-${STRATEGY_NAME:-general}}"
  else echo general; fi
}

case "${1:-status}" in
  list)
    echo "доступные .bin в $BIN_DIR:"
    ls -1 "$BIN_DIR"/*.bin 2>/dev/null | xargs -rn1 basename | sed 's/^/  /' \
      || echo "  (пусто — запустите sync-flowseal.sh)"
    ;;
  types)
    s="$(current_strategy)"
    echo "типы фейков в стратегии '$s':"
    grep -oE -- '--dpi-desync-fake-[a-z-]+' "$STRAT_DIR/$s.conf" 2>/dev/null \
      | sed 's/--dpi-desync-fake-//' | sort -u | sed 's/^/  /' \
      || echo "  (стратегия не найдена)"
    ;;
  set)
    type="${2:-}"; file="${3:-}"
    [ -n "$type" ] && [ -n "$file" ] || { echo "использование: fakes.sh set <тип> <файл.bin>" >&2; exit 2; }
    [[ "$type" =~ ^[a-z][a-z-]*$ ]] || { echo "fakes.sh: недопустимый тип '$type' (строчные латинские буквы и '-', например tls, quic, unknown-udp)" >&2; exit 1; }
    [[ "$file" =~ ^[A-Za-z0-9._-]+\.bin$ ]] || { echo "fakes.sh: недопустимое имя файла '$file' (только имя .bin из каталога bin/, без пути)" >&2; exit 1; }
    [ -f "$BIN_DIR/$file" ] || { echo "fakes.sh: нет файла $BIN_DIR/$file" >&2; exit 1; }
    mkdir -p "$ETC_DIR"; touch "$MAP"
    awk -v t="$type" '$1 != t' "$MAP" > "$MAP.tmp" 2>/dev/null || true
    echo "$type $file" >> "$MAP.tmp"; mv "$MAP.tmp" "$MAP"
    echo "fakes: $type -> $file, переприменяю стратегию..."
    exec "$APPLY" "$(current_strategy)"
    ;;
  unset)
    type="${2:-}"
    [ -n "$type" ] || { echo "использование: fakes.sh unset <тип>" >&2; exit 2; }
    [ -f "$MAP" ] || { echo "fakes: подмен нет"; exit 0; }
    awk -v t="$type" '$1 != t' "$MAP" > "$MAP.tmp" || true; mv "$MAP.tmp" "$MAP"
    echo "fakes: подмена для '$type' убрана, переприменяю стратегию..."
    exec "$APPLY" "$(current_strategy)"
    ;;
  status)
    if [ -s "$MAP" ]; then
      echo "активные подмены фейков:"; sed 's/^/  /' "$MAP"
    else
      echo "активных подмен нет (используются фейки из стратегии)"
    fi
    ;;
  *)
    echo "использование: fakes.sh {list|types|set <тип> <файл>|unset <тип>|status}" >&2; exit 2 ;;
esac
