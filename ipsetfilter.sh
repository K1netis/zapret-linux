#!/usr/bin/env bash
# ipsetfilter.sh — аналог "IPSet Filter" из service.bat у Flowseal.
# Управляет тем, какие IP попадают под профили, ограниченные ipset-all.txt.
#
#   ipsetfilter.sh none     # ни один IP не попадает под проверку
#   ipsetfilter.sh loaded   # IP проверяется по списку lists/ipset-all.txt (по умолчанию)
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

case "$mode" in
  none|loaded|any)
    mkdir -p "$ETC_DIR"
    echo "$mode" > "$ETC_DIR/ipsetfilter"
    [ "$mode" = any ] && \
      echo "ipsetfilter: ВНИМАНИЕ — режим 'any' фильтрует весь трафик, возможны сбои." >&2
    echo "ipsetfilter: режим '$mode', переприменяю стратегию..."
    exec "$APPLY" "$(current_strategy)"
    ;;
  status)
    m=loaded; [ -f "$ETC_DIR/ipsetfilter" ] && m="$(cat "$ETC_DIR/ipsetfilter")"
    echo "режим IPSet Filter: $m"
    if [ -f "$ETC_DIR/ipset-active.txt" ]; then
      echo "записей в активном ipset: $(grep -cvE '^\s*(#|$)' "$ETC_DIR/ipset-active.txt" || true)"
    fi
    echo "активная стратегия: $(current_strategy)"
    ;;
  *)
    echo "usage: ipsetfilter.sh {none|loaded|any|status}" >&2; exit 2 ;;
esac
