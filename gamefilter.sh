#!/usr/bin/env bash
# gamefilter.sh — the Linux equivalent of Flowseal's GameFilter toggle.
# Сохраняет режим и заново применяет текущую стратегию, чтобы firewall начал
# (или перестал) направлять в очередь широкий диапазон игровых портов.
#
#   gamefilter.sh off     # по умолчанию: игровой трафик не трогаем
#   gamefilter.sh tcp     # игровой диапазон только для TCP
#   gamefilter.sh udp     # игровой диапазон только для UDP
#   gamefilter.sh all     # игровой диапазон для TCP и UDP
#   gamefilter.sh status  # показать текущий режим
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
  off|tcp|udp|all)
    mkdir -p "$ETC_DIR"
    echo "$mode" > "$ETC_DIR/gamefilter"
    echo "gamefilter: mode set to '$mode', re-applying strategy..."
    exec "$APPLY" "$(current_strategy)"
    ;;
  status)
    m=off; [ -f "$ETC_DIR/gamefilter" ] && m="$(cat "$ETC_DIR/gamefilter")"
    echo "gamefilter mode: $m"
    echo "active strategy: $(current_strategy)"
    ;;
  *)
    echo "usage: gamefilter.sh {off|tcp|udp|all|status}" >&2; exit 2 ;;
esac
