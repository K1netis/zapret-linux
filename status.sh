#!/usr/bin/env bash
# status.sh — сводка состояния: сервис, активная стратегия, режимы фильтров,
# правила nftables со счётчиками (сколько пакетов реально ушло в NFQUEUE).
#
#   sudo ./status.sh
set -uo pipefail

ETC_DIR="${ETC_DIR:-/etc/zapret-linux}"
OPT_DIR="${OPT_DIR:-/opt/zapret-linux}"
TABLE="inet zapret_linux"

hdr() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }

hdr "Сервис"
if command -v systemctl >/dev/null 2>&1; then
  systemctl is-active zapret-linux >/dev/null 2>&1 \
    && echo "  active (running)" || echo "  НЕ работает"
  systemctl show zapret-linux -p NRestarts --value 2>/dev/null \
    | sed 's/^/  перезапусков: /'
else
  echo "  systemd недоступен"
fi

hdr "Активная конфигурация"
if [ -f "$ETC_DIR/active.env" ]; then
  # shellcheck disable=SC1091
  . "$ETC_DIR/active.env"
  echo "  стратегия:   ${STRATEGY_NAME:-?}"
  echo "  gamefilter:  ${GAMEFILTER_MODE:-?}  (TCP ${GAMEFILTER_TCP_PORTS:-1024-65535}, UDP ${GAMEFILTER_UDP_PORTS:-1024-65535})"
  echo "  ipset:       ${IPSET_MODE:-?}"
  echo "  TCP порты:   ${PORTS_TCP:-}"
  echo "  UDP порты:   ${PORTS_UDP:-}"
else
  echo "  нет $ETC_DIR/active.env — стратегия не применялась"
fi

hdr "Доступные стратегии"
ls -1 "$OPT_DIR"/strategies/*.conf 2>/dev/null \
  | xargs -rn1 basename | sed 's/\.conf$//' | paste -sd' ' - | fold -sw 76 | sed 's/^/  /' \
  || echo "  нет стратегий"

hdr "Правила nftables (counter = пакеты, ушедшие в NFQUEUE)"
if command -v nft >/dev/null 2>&1 && nft list table $TABLE >/dev/null 2>&1; then
  nft list table $TABLE 2>/dev/null \
    | grep -E 'dport' \
    | sed -E 's/.*(tcp|udp) dport ([0-9-]+).*counter packets ([0-9]+) bytes ([0-9]+).*/  \1 \2  ->  пакетов: \3, байт: \4/' \
    | sed 's/^\t*//'
  echo
  # ВАЖНО: считаем только "counter packets N", не задевая "ct original packets 1-6"
  total=$(nft list table $TABLE 2>/dev/null \
    | grep -oE 'counter packets [0-9]+' | awk '{s+=$3} END {print s+0}')
  echo "  всего в очередь: $total пакетов"
  if [ "${total:-0}" = 0 ]; then
    echo "  ВНИМАНИЕ: 0 — трафик не попадает под правила."
    echo "  Проверьте: sudo zapret test"
  fi
else
  echo "  таблица не создана (служба не запущена?)"
fi

hdr "Последние сообщения nfqws"
journalctl -u zapret-linux -n 8 --no-pager 2>/dev/null \
  | sed 's/^/  /' || echo "  журнал недоступен"
