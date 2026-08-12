#!/usr/bin/env bash
# bat2nfqws.sh — перевод стратегии Flowseal (.bat для winws.exe) в стратегию
# для Linux-движка nfqws.
#
# Использование:
#   tools/bat2nfqws.sh путь/к/"general.bat" [> strategies/general.conf]
#
# Что делает:
#   * склеивает многострочную команду "winws.exe ... ^" в одну строку
#   * вынимает --wf-tcp / --wf-udp — это становится списком портов для nftables
#   * заменяет пути %BIN% / %LISTS% на подстановочные метки @BIN@ / @LISTS@
#   * заменяет %GameFilterTCP% / %GameFilterUDP% на метки, которые
#     apply-strategy.sh подставляет при запуске
#   * все --filter-*, --dpi-desync-*, --hostlist*, --ipset*, --new переносит
#     без изменений: эти параметры одинаковы у winws и nfqws
#
# Результат — фрагмент shell-кода с тремя переменными:
#   PORTS_TCP, PORTS_UDP, NFQWS_OPT
set -euo pipefail

die() { echo "bat2nfqws: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: bat2nfqws.sh <strategy.bat>"
SRC="$1"
[ -f "$SRC" ] || die "no such file: $SRC"

name="$(basename "$SRC")"; name="${name%.bat}"

# 1) Склеиваем строки с переносом (^), выделяем команду winws.exe, убираем CR.
joined="$(
  tr -d '\r' < "$SRC" \
  | sed -e ':a' -e '/\^[[:space:]]*$/{N;s/\^[[:space:]]*\n/ /;ba}'
)"

cmd="$(printf '%s\n' "$joined" | grep -i 'winws\.exe' || true)"
[ -n "$cmd" ] || die "no winws.exe invocation found in $SRC"

# Оставляем только то, что идёт после самой winws.exe.
cmd="${cmd#*winws.exe\"}"
cmd="${cmd#*winws.exe}"

# 2) Вынимаем значения --wf-tcp / --wf-udp (порты для firewall) и убираем их.
extract_wf() {
  printf '%s\n' "$cmd" | grep -oE -- "--wf-$1=[^ ]+" | head -n1 | sed -E "s/--wf-$1=//"
}
PORTS_TCP="$(extract_wf tcp || true)"
PORTS_UDP="$(extract_wf udp || true)"
cmd="$(printf '%s\n' "$cmd" | sed -E 's/--wf-(tcp|udp)=[^ ]+ ?//g')"

# 3) Пути Windows превращаем в метки: "%BIN%файл" -> "@BIN@/файл".
cmd="$(printf '%s\n' "$cmd" \
  | sed -E 's|%BIN%|@BIN@/|g; s|%LISTS%|@LISTS@/|g' \
  | sed -E 's/\\/\//g' \
  | tr -d '"')"                  # кавычки не нужны: в путях нет пробелов

# 3b) Основной ipset (ipset-all.txt) переключается на ходу (режимы IPSet
#      none / loaded / any), поэтому у него отдельная метка.
#      Списки-исключения остаются как есть.
cmd="$(printf '%s\n' "$cmd" | sed -E 's|@LISTS@/ipset-all\.txt|@IPSET@|g')"

# 4) Макросы GameFilter — в метки (и в списке портов, и в строке параметров).
subst_gf() { sed -E 's/%GameFilterTCP%/@GAMEFILTER_TCP@/g; s/%GameFilterUDP%/@GAMEFILTER_UDP@/g'; }
PORTS_TCP="$(printf '%s' "$PORTS_TCP" | subst_gf)"
PORTS_UDP="$(printf '%s' "$PORTS_UDP" | subst_gf)"
cmd="$(printf '%s\n' "$cmd" | subst_gf)"

# 5) Убираем лишние пробелы.
cmd="$(printf '%s\n' "$cmd" | tr -s ' ' | sed -E 's/^ +//; s/ +$//')"

# 5b) Явно падаем на незнакомом %Макросе%. Flowseal со временем добавляет новые
#      (например, очередной переключатель фильтра). Молча оставить %Что-то% —
#      значит получить нерабочую команду nfqws уже во время запуска.
unknown="$(printf '%s\n%s\n%s\n' "$cmd" "$PORTS_TCP" "$PORTS_UDP" \
  | grep -oE '%[A-Za-z_][A-Za-z0-9_]*%' | sort -u || true)"
if [ -n "$unknown" ]; then
  echo "bat2nfqws: ERROR: untranslated macro(s) in $name.bat:" >&2
  printf '  %s\n' $unknown >&2
  echo "  -> teach the translator about them before using this strategy." >&2
  exit 3
fi

# 6) Выводим готовую стратегию
cat <<EOF
# Файл создан автоматически из $name.bat скриптом bat2nfqws.sh.
# Источник: Flowseal/zapret-discord-youtube
# Править вручную не нужно: после обновления Flowseal запустите перевод заново.
#
# Метки, которые подставляет apply-strategy.sh при запуске:
#   @GAMEFILTER_TCP@ / @GAMEFILTER_UDP@  — диапазон игровых портов либо удаление
#   @IPSET@                              — активный список IP (none/loaded/any)
#   @BIN@ / @LISTS@                      — абсолютные пути установки

STRATEGY_NAME="$name"

# Порты, которые firewall направляет в NFQUEUE (в Windows это --wf-tcp/--wf-udp).
PORTS_TCP="$PORTS_TCP"
PORTS_UDP="$PORTS_UDP"

# Цепочка профилей обхода для nfqws (параметры те же, что у winws).
NFQWS_OPT="$cmd"
EOF
