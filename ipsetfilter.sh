#!/usr/bin/env bash
# ipsetfilter.sh — аналог "IPSet Filter" из service.bat у Flowseal.
# Управляет тем, какие IP попадают под профили, ограниченные ipset-all.txt.
#
#   ipsetfilter.sh none     # заглушка 203.0.113.113/32: под профили с ipset
#                           # не попадает ничего (по умолчанию, как у Flowseal)
#   ipsetfilter.sh loaded   # полный список IP Flowseal (lists/ipset-all.txt.backup,
#                           # загружается командой zapret sync)
#   ipsetfilter.sh any      # любой IP попадает под фильтр (0.0.0.0/0, ::/0)
#   ipsetfilter.sh status
#
# ВНИМАНИЕ: режим 'any' затрагивает весь трафик и может ломать сайты и игры,
# которые без zapret работают. Использовать только для диагностики.
set -euo pipefail

ETC_DIR="${ETC_DIR:-/etc/zapret-linux}"
OPT_DIR="${OPT_DIR:-/opt/zapret-linux}"
APPLY="$OPT_DIR/apply-strategy.sh"
[ -x "$APPLY" ] || APPLY="$(cd "$(dirname "$0")" && pwd)/apply-strategy.sh"

mode="${1:-status}"

current_strategy() {
  if [ -f "$ETC_DIR/active.env" ]; then
    # shellcheck disable=SC1091
    . "$ETC_DIR/active.env"; echo "${STRATEGY_FILE:-${STRATEGY_NAME:-general}}"
  else
    echo general
  fi
}

# Загружен ли полный список IP: ipset-all.txt.backup либо содержательный
# ipset-all.txt (есть строки, кроме пустых, комментариев и заглушки).
full_list_loaded() {
  local d="$OPT_DIR/lists"
  [ -s "$d/ipset-all.txt.backup" ] && return 0
  [ -s "$d/ipset-all.txt" ] || return 1
  tr -d '\r' < "$d/ipset-all.txt" | grep -vE '^[[:space:]]*(#|$)' \
    | grep -qvxF '203.0.113.113/32'
}

case "$mode" in
  none|loaded|any)
    mkdir -p "$ETC_DIR"
    echo "$mode" > "$ETC_DIR/ipsetfilter"
    : > "$ETC_DIR/ipsetfilter-chosen"      # метка явного выбора режима
    if [ "$mode" = loaded ] && ! full_list_loaded; then
      echo "ipsetfilter: предупреждение — полный список IP не загружен, пока действует заглушка (как в режиме none)." >&2
      echo "  Загрузите его: sudo zapret sync" >&2
    fi
    [ "$mode" = any ] && \
      echo "ipsetfilter: ВНИМАНИЕ — режим 'any' фильтрует весь трафик, возможны сбои." >&2
    echo "ipsetfilter: режим '$mode', переприменяю стратегию..."
    exec "$APPLY" "$(current_strategy)"
    ;;
  status)
    m=none; [ -f "$ETC_DIR/ipsetfilter" ] && m="$(cat "$ETC_DIR/ipsetfilter")"
    echo "режим IPSet Filter: $m"
    if [ "$m" = loaded ]; then
      if full_list_loaded; then
        echo "полный список IP: загружен"
      else
        echo "полный список IP: не загружен — действует заглушка (как в режиме none)"
        echo "  Загрузите его: sudo zapret sync"
      fi
    fi
    if [ -f "$ETC_DIR/ipset-active.txt" ]; then
      echo "записей в активном ipset: $(grep -cvE '^\s*(#|$)' "$ETC_DIR/ipset-active.txt" || true)"
    fi
    echo "активная стратегия: $(current_strategy)"
    ;;
  *)
    echo "usage: ipsetfilter.sh {none|loaded|any|status}" >&2; exit 2 ;;
esac
