#!/usr/bin/env bash
# fw.sh — создание и снятие правил nftables, которые направляют нужные порты
# в очередь NFQUEUE для nfqws. На Linux это заменяет параметры --wf-tcp и
# --wf-udp из Windows-версии.
#
#   fw.sh up     # создать таблицу и правила по данным active.env
#   fw.sh down   # удалить таблицу
#
# Значения PORTS_TCP, PORTS_UDP, QNUM, FWMARK берутся из окружения (служба
# systemd передаёт их через EnvironmentFile) либо из /etc/zapret-linux/active.env
# при запуске вручную.
set -euo pipefail

ENV_FILE="${ZAPRET_ENV:-/etc/zapret-linux/active.env}"
[ -n "${PORTS_TCP:-}${PORTS_UDP:-}" ] || { [ -f "$ENV_FILE" ] && . "$ENV_FILE"; }

QNUM="${QNUM:-200}"
FWMARK="${FWMARK:-0x40000000}"
# Метку ставит zapret test на свой трафик: рабочая служба его пропускает,
# чтобы проверка стратегий не попадала в её очередь.
TESTMARK="${TESTMARK:-0x20000000}"
TABLE="inet zapret_linux"

have_nft() { command -v nft >/dev/null 2>&1; }

# На каждый порт из списка создаём отдельное правило. Так мы обходим ошибку
# nft о пересекающихся интервалах, когда широкий игровой диапазон перекрывает
# более узкие вроде 50000-50100.
add_rules() {
  local proto="$1" ports="$2" p
  local IFS=','
  for p in $ports; do
    [ -n "$p" ] || continue
    case "$p" in
      *[!0-9-]*|-*|*-|*-*-*)
        echo "fw.sh: некорректный порт '$p' в списке '$ports'" >&2; exit 1 ;;
    esac
    nft add rule $TABLE post meta l4proto "$proto" "$proto" dport "$p" \
      ct original packets 1-6 meta mark and "$FWMARK" != "$FWMARK" \
      meta mark and "$TESTMARK" == 0 \
      counter queue num "$QNUM" bypass
  done
}

fw_up() {
  have_nft || { echo "fw.sh: не найден nft (установите nftables)" >&2; exit 1; }
  fw_down
  nft add table $TABLE
  nft add chain $TABLE post \
    "{ type filter hook postrouting priority mangle; policy accept; }"
  [ -n "${PORTS_TCP:-}" ] && add_rules tcp "$PORTS_TCP"
  [ -n "${PORTS_UDP:-}" ] && add_rules udp "$PORTS_UDP"
  echo "fw.sh: правила созданы (qnum=$QNUM tcp=[${PORTS_TCP:-}] udp=[${PORTS_UDP:-}])"
}

fw_down() {
  have_nft || return 0
  nft list table $TABLE >/dev/null 2>&1 && nft delete table $TABLE || true
}

case "${1:-}" in
  up)   fw_up ;;
  down) fw_down ;;
  *)    echo "использование: fw.sh {up|down}" >&2; exit 2 ;;
esac
