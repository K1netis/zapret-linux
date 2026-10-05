#!/usr/bin/env bash
# gamefilter.sh — аналог GameFilter из service.bat у Flowseal.
# Сохраняет режим и заново применяет текущую стратегию, чтобы firewall начал
# (или перестал) направлять в очередь широкий диапазон игровых портов.
#
#   gamefilter.sh off      # по умолчанию: игровой трафик не трогаем
#   gamefilter.sh tcp      # игровой диапазон только для TCP
#   gamefilter.sh udp      # игровой диапазон только для UDP
#   gamefilter.sh all      # игровой диапазон для TCP и UDP
#   gamefilter.sh status   # текущий режим и порты
#
# Свои порты (как в Flowseal 1.10.3):
#   gamefilter.sh ports                           # показать
#   gamefilter.sh ports tcp 1024-1934,1936-65535  # например, исключить RTMP
#   gamefilter.sh ports udp 1024-65535
#   gamefilter.sh ports reset                     # вернуть 1024-65535
set -euo pipefail

ETC_DIR="${ETC_DIR:-/etc/zapret-linux}"
OPT_DIR="${OPT_DIR:-/opt/zapret-linux}"
APPLY="$OPT_DIR/apply-strategy.sh"
[ -x "$APPLY" ] || APPLY="$(cd "$(dirname "$0")" && pwd)/apply-strategy.sh"
PORTS_FILE="$ETC_DIR/gamefilter-ports"
DEFAULT_PORTS="1024-65535"

current_strategy() {
  if [ -f "$ETC_DIR/active.env" ]; then
    # shellcheck disable=SC1091
    . "$ETC_DIR/active.env"; echo "${STRATEGY_FILE:-${STRATEGY_NAME:-general}}"
  else
    echo general
  fi
}

# Читает сохранённые порты; при отсутствии файла — значения по умолчанию.
load_ports() {
  GF_TCP="$DEFAULT_PORTS"; GF_UDP="$DEFAULT_PORTS"
  if [ -f "$PORTS_FILE" ]; then
    local v
    v="$(sed -n 's/^TCP=//p' "$PORTS_FILE" | head -n1)"; [ -n "$v" ] && GF_TCP="$v"
    v="$(sed -n 's/^UDP=//p' "$PORTS_FILE" | head -n1)"; [ -n "$v" ] && GF_UDP="$v"
  fi
}

save_ports() {
  mkdir -p "$ETC_DIR"
  printf 'TCP=%s\nUDP=%s\n' "$GF_TCP" "$GF_UDP" > "$PORTS_FILE"
}

# Проверка списка портов: числа и диапазоны через запятую, 1..65535,
# начало диапазона не больше конца. Пробелы недопустимы.
validate_ports() {
  local list="$1" item a b
  [ -n "$list" ] || { echo "пустой список портов" >&2; return 1; }
  case "$list" in *[!0-9,-]*) echo "допустимы только цифры, '-' и ','" >&2; return 1 ;; esac
  local IFS=','
  for item in $list; do
    [ -n "$item" ] || { echo "лишняя запятая в списке" >&2; return 1; }
    case "$item" in
      *-*-*) echo "некорректный диапазон: $item" >&2; return 1 ;;
      *-*)   a="${item%-*}"; b="${item#*-}" ;;
      *)     a="$item"; b="$item" ;;
    esac
    [ -n "$a" ] && [ -n "$b" ] || { echo "некорректный диапазон: $item" >&2; return 1; }
    if [ "$a" -lt 1 ] || [ "$b" -gt 65535 ] || [ "$a" -gt "$b" ]; then
      echo "порт вне 1-65535 или перевёрнутый диапазон: $item" >&2; return 1
    fi
  done
}

mode="${1:-status}"

case "$mode" in
  off|tcp|udp|all)
    mkdir -p "$ETC_DIR"
    echo "$mode" > "$ETC_DIR/gamefilter"
    echo "gamefilter: режим '$mode', переприменяю стратегию..."
    exec "$APPLY" "$(current_strategy)"
    ;;

  ports)
    load_ports
    proto="${2:-}"
    case "$proto" in
      "")
        echo "порты игрового фильтра:"
        echo "  TCP: $GF_TCP"
        echo "  UDP: $GF_UDP"
        exit 0 ;;
      reset)
        GF_TCP="$DEFAULT_PORTS"; GF_UDP="$DEFAULT_PORTS"
        save_ports
        echo "gamefilter: порты сброшены на $DEFAULT_PORTS" ;;
      tcp|udp)
        list="${3:-}"
        validate_ports "$list" || { echo "gamefilter: порты не изменены" >&2; exit 1; }
        if [ "$proto" = tcp ]; then GF_TCP="$list"; else GF_UDP="$list"; fi
        save_ports
        echo "gamefilter: порты $proto -> $list" ;;
      *)
        echo "usage: gamefilter.sh ports [tcp <список> | udp <список> | reset]" >&2
        exit 2 ;;
    esac
    # Новые порты вступают в силу сразу, только если фильтр включён.
    m=off; [ -f "$ETC_DIR/gamefilter" ] && m="$(cat "$ETC_DIR/gamefilter")"
    if [ "$m" != off ]; then
      echo "gamefilter: переприменяю стратегию..."
      exec "$APPLY" "$(current_strategy)"
    else
      echo "  Фильтр сейчас выключен — порты применятся при включении (zapret game udp)."
    fi
    ;;

  status)
    load_ports
    m=off; [ -f "$ETC_DIR/gamefilter" ] && m="$(cat "$ETC_DIR/gamefilter")"
    echo "режим игрового фильтра: $m"
    echo "  порты TCP: $GF_TCP"
    echo "  порты UDP: $GF_UDP"
    echo "активная стратегия: $(current_strategy)"
    ;;

  *)
    echo "usage: gamefilter.sh {off|tcp|udp|all|status|ports}" >&2; exit 2 ;;
esac
