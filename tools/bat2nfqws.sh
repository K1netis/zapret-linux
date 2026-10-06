#!/usr/bin/env bash
# bat2nfqws.sh — перевод стратегии Flowseal (.bat для winws.exe) в стратегию
# для Linux-движка nfqws.
#
# Использование:
#   tools/bat2nfqws.sh путь/к/"general.bat" [> strategies/general.conf]
#
# Что делает:
#   * склеивает многострочную команду "winws.exe ... ^" в одну строку
#   * снимает экранирование cmd.exe: вне кавычек "^x" -> "x"
#   * вынимает --wf-tcp / --wf-udp — это становится списком портов для nftables
#   * заменяет пути %BIN% / %LISTS% на подстановочные метки @BIN@ / @LISTS@
#   * заменяет %GameFilterTCP% / %GameFilterUDP% на метки, которые
#     apply-strategy.sh подставляет при запуске
#   * все --filter-*, --dpi-desync-*, --hostlist*, --ipset*, --new переносит
#     без изменений: эти параметры одинаковы у winws и nfqws
#
# Результат — фрагмент shell-кода с тремя переменными:
#   PORTS_TCP, PORTS_UDP, NFQWS_OPT
#
# Безопасность: .conf потом читает apply-strategy.sh от root, а команда уходит
# в службу, поэтому перенос непроверенного текста недопустим. Имя стратегии
# очищается от кавычек, $, обратной кавычки, \ и управляющих символов; строка
# параметров и списки портов обязаны состоять из безопасного набора символов.
#
# Коды выхода: 0 — готово; 1 — ошибка использования или нет файла/winws.exe;
#   3 — незнакомый %Макрос%; 4 — недопустимые символы в стратегии.
set -euo pipefail

die() { echo "bat2nfqws: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "использование: bat2nfqws.sh <стратегия.bat>"
SRC="$1"
[ -f "$SRC" ] || die "файл не найден: $SRC"

name="$(basename "$SRC")"; name="${name%.bat}"
# Имя попадает в .conf и в сообщения: убираем всё, что в shell имеет силу
# (" $ ` \ '), и управляющие символы, в том числе перевод строки.
name="$(printf '%s' "$name" | LC_ALL=C tr -d '"$`\\'"'"'[:cntrl:]')"
[ -n "$name" ] || name="strategy"

# 1) Склеиваем строки с переносом (^), выделяем команду winws.exe, убираем CR.
joined="$(
  tr -d '\r' < "$SRC" \
  | sed -e ':a' -e '/\^[[:space:]]*$/{N;s/\^[[:space:]]*\n/ /;ba}'
)"

cmd="$(printf '%s\n' "$joined" | grep -i 'winws\.exe' || true)"
[ -n "$cmd" ] || die "в $SRC не найден запуск winws.exe"

# Оставляем только то, что идёт после самой winws.exe.
cmd="${cmd#*winws.exe\"}"
cmd="${cmd#*winws.exe}"

# 1b) Экранирование cmd.exe: вне двойных кавычек «^x» означает просто «x»
#     (в том числе «^^» -> «^»), winws получает уже без каретки. Например,
#     --dpi-desync-fake-tls=^! превращается в --dpi-desync-fake-tls=!.
#     Внутри кавычек каретка остаётся как есть. Делается до снятия кавычек.
cmd="$(printf '%s\n' "$cmd" | LC_ALL=C awk '{
  out = ""; inq = 0; n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (c == "\"") { inq = !inq; out = out c }
    else if (c == "^" && !inq) { i++; if (i <= n) out = out substr($0, i, 1) }
    else out = out c
  }
  print out
}')"

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
  echo "bat2nfqws: ОШИБКА — незнакомые макросы в $name.bat:" >&2
  printf '  %s\n' $unknown >&2
  echo "  -> транслятор нужно доработать, прежде чем использовать эту стратегию." >&2
  exit 3
fi

# 5c) Безопасный набор символов. Всё остальное (`$ ( ) ` | & ; < > " ' \` и т.п.)
#      в стратегии Flowseal не встречается, а в .conf или nfqws.cmd стало бы
#      выполнением кода от root. Проверка идёт после макросов: код 3 первичен.
bad_chars() { # $1 — текст, $2 — допустимый набор для bracket-выражения
  printf '%s\n' "$1" | LC_ALL=C grep -o "[^$2]" | LC_ALL=C sort -u \
    | tr '\n' ' ' | tr '[:cntrl:]' '?' || true
}
bad="$(bad_chars "$cmd" 'A-Za-z0-9 @=._/,+!:^-')"
bad_t="$(bad_chars "$PORTS_TCP" 'A-Za-z0-9_@,-')"
bad_u="$(bad_chars "$PORTS_UDP" 'A-Za-z0-9_@,-')"
if [ -n "$bad$bad_t$bad_u" ]; then
  echo "bat2nfqws: ОШИБКА — недопустимые символы в $name.bat: $bad$bad_t$bad_u" >&2
  echo "  -> такая стратегия не переводится из соображений безопасности:" >&2
  echo "     её текст попал бы в команду, которую служба выполняет от root." >&2
  exit 4
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
