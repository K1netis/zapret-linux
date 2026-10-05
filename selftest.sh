#!/usr/bin/env bash
# selftest.sh — практическая проверка: попадает ли трафик в NFQUEUE и
# открываются ли заблокированные ресурсы на текущей стратегии.
#
#   sudo ./selftest.sh
#
# Логика: снимаем счётчики nftables -> делаем реальные запросы -> снимаем снова.
# Прирост счётчиков означает, что правила ловят трафик (наша часть работает).
# Успех запросов означает, что конкретная стратегия проходит DPI.
set -uo pipefail

TABLE="inet zapret_linux"
ETC_DIR="${ETC_DIR:-/etc/zapret-linux}"
TARGETS="${TARGETS:-https://www.youtube.com https://discord.com https://gateway.discord.gg https://media.discordapp.net}"

hdr() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }

counters() {
  nft list table $TABLE 2>/dev/null \
    | grep -oE 'counter packets [0-9]+' | awk '{s+=$3} END {print s+0}'
}

command -v nft >/dev/null 2>&1 || { echo "нужен nft"; exit 1; }
nft list table $TABLE >/dev/null 2>&1 || { echo "таблица $TABLE не создана — служба не запущена?"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "нужен curl"; exit 1; }

if [ -f "$ETC_DIR/active.env" ]; then
  # shellcheck disable=SC1091
  . "$ETC_DIR/active.env"
  echo "стратегия: ${STRATEGY_NAME:-?}  (файл: ${STRATEGY_FILE:-?})"
fi

before="$(counters)"
hdr "Счётчик до теста"
echo "  $before пакетов"

hdr "Запросы"
ok=0; fail=0
for url in $TARGETS; do
  host="${url#https://}"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null)"
  if [ "${code:-000}" != "000" ] && [ "${code:-0}" -ge 200 ] 2>/dev/null; then
    printf '  \033[1;32mOK\033[0m    %-28s HTTP %s\n' "$host" "$code"; ok=$((ok+1))
  else
    printf '  \033[1;31mFAIL\033[0m  %-28s (нет ответа)\n' "$host"; fail=$((fail+1))
  fi
done

sleep 1
after="$(counters)"
delta=$((after - before))

hdr "Счётчик после теста"
echo "  $after пакетов (прирост: $delta)"

hdr "DNS (частая причина проблем с Discord)"
resolver="$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd', ' -)"
echo "  системный резолвер: ${resolver:-неизвестен}"
if command -v resolvectl >/dev/null 2>&1; then
  dot="$(resolvectl status 2>/dev/null | grep -iE 'DNSOverTLS|DNS over TLS' | head -1 | sed 's/^ *//')"
  [ -n "$dot" ] && echo "  $dot"
fi
case "${resolver:-}" in
  127.0.0.53*|127.0.0.1*|::1*) echo "  (локальный стаб — проверьте, настроен ли DoT/DoH выше по цепочке)" ;;
esac
for d in discord.com gateway.discord.gg; do
  ips="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd', ' -)"
  echo "  $d -> ${ips:-НЕ РЕЗОЛВИТСЯ}"
done
echo "  Десктопный Discord использует СИСТЕМНЫЙ резолвер, а не DoH браузера."

hdr "Счётчики по портам Discord"
for spec in "tcp 2053" "tcp 2083" "tcp 2087" "tcp 2096" "tcp 8443" "udp 19294-19344" "udp 50000-50100"; do
  proto="${spec% *}"; port="${spec#* }"
  n="$(nft list table $TABLE 2>/dev/null \
      | grep -E "$proto dport $port " | grep -oE 'counter packets [0-9]+' | awk '{print $3}')"
  printf '  %-4s %-14s %s\n' "$proto" "$port" "${n:-нет правила}"
done
gf="off"; [ -f "$ETC_DIR/gamefilter" ] && gf="$(cat "$ETC_DIR/gamefilter")"
if [ "$gf" = off ]; then
  echo "  GameFilter выключен: голосовые порты Discord выше 50100 НЕ обрабатываются."
  echo "  Попробуйте: sudo zapret game udp   (или all)"
fi

hdr "Вывод"
if [ "$delta" -gt 0 ]; then
  echo "  ✓ Правила nftables ловят трафик — наша часть настроена верно."
  if [ "$fail" = 0 ]; then
    echo "  ✓ Все ресурсы открылись: стратегия рабочая, можно фиксировать."
  else
    echo "  ✗ Часть ресурсов недоступна ($fail из $((ok+fail)))."
    echo "    Это нормально: стратегия не подошла вашему провайдеру."
    echo "    Перебирайте: zapret list, затем zapret use <другая>, и снова zapret test"
  fi
else
  echo "  ✗ Прирост нулевой — трафик НЕ попадает в NFQUEUE."
  echo "    Возможные причины:"
  echo "    - весь трафик шёл по IPv6 или уже установленным соединениям"
  echo "      (правило ловит только первые пакеты новых соединений);"
  echo "    - другой firewall перехватывает пакеты раньше;"
  echo "    - неверный хук/приоритет в lib/fw.sh."
  echo "    Покажите вывод: sudo nft list table $TABLE"
fi
