#!/usr/bin/env bash
# apply-strategy.sh --print-args: те же разбор и проверки, что при применении,
# но ничего не пишется в /etc и служба не трогается (нужно для zapret test).
. "$(dirname "$0")/lib.sh"
OPT="$TMP/opt"; ETC="$TMP/etc"; mkdir -p "$ETC"
make_opt "$OPT"

# Аргументы из nfqws.cmd: по одному в строке, без бинарника, --qnum и fwmark.
cmd_args() {
  grep -o "'[^']*'" "$1" | sed "s/^'//; s/'\$//" | tail -n +2 \
    | grep -v -e '^--qnum=' -e '^--dpi-desync-fwmark='
}

section "--print-args: обычный вывод"
apply test >/dev/null 2>&1
cmd_args "$ETC/nfqws.cmd" > "$TMP/want"
cp -a "$ETC" "$TMP/snap"
MOCK_SYSTEMCTL_LOG="$TMP/sc.log" apply --print-args test > "$TMP/out" 2> "$TMP/err"; code=$?
check "код 0"                                      test "$code" -eq 0
check "вывод не пуст"                              test -s "$TMP/out"
check "аргументы совпадают с nfqws.cmd"            same "$TMP/out" "$TMP/want"
check_not "в выводе нет посторонних строк"         grep -vq '^--' "$TMP/out"
check_not "нет --qnum и --dpi-desync-fwmark"       grep -qE '^--(qnum|dpi-desync-fwmark)' "$TMP/out"
check_not "нет кавычек"                            grep -q "'" "$TMP/out"
check "файлы в ETC не изменились"                  diff -r "$TMP/snap" "$ETC"
check "systemctl не вызывался"                     test ! -s "$TMP/sc.log"

section "--print-args: режим loaded без метки не переключается"
echo loaded > "$ETC/ipsetfilter"; rm -f "$ETC/ipsetfilter-chosen"
cp -a "$ETC" "$TMP/snap2"
apply --print-args test > "$TMP/out" 2>/dev/null; code=$?
check "код 0"                                      test "$code" -eq 0
check "ipsetfilter по-прежнему loaded"             test "$(cat "$ETC/ipsetfilter")" = loaded
check "ipset-active.txt не изменён"                same "$TMP/snap2/ipset-active.txt" "$ETC/ipset-active.txt"
check "метка выбора не создана"                    test ! -e "$ETC/ipsetfilter-chosen"
check "active.env не изменён"                      same "$TMP/snap2/active.env" "$ETC/active.env"
rm -f "$ETC/ipsetfilter"

section "--print-args: ошибки"
rm -f "$ETC/ipset-active.txt"
apply --print-args test > "$TMP/out" 2> "$TMP/err"; code=$?
check "нет ipset-active.txt: код не 0"             test "$code" -ne 0
check "нет ipset-active.txt: подсказка zapret use" has "$TMP/err" "zapret use"
check "нет ipset-active.txt: файл не создан"       test ! -e "$ETC/ipset-active.txt"
apply test >/dev/null 2>&1

sed 's/^NFQWS_OPT="/NFQWS_OPT="--x=a|b /' "$OPT/strategies/test.conf" > "$OPT/strategies/pipe.conf"
check "в тесте символ | действительно попал в файл" has "$OPT/strategies/pipe.conf" 'a|b'
apply --print-args pipe > "$TMP/out" 2> "$TMP/err"; code=$?
check "символ | в параметрах: код не 0"            test "$code" -ne 0
check "символ | в параметрах: stdout пуст"         test ! -s "$TMP/out"
check "символ | в параметрах: названа причина"     has "$TMP/err" '|'

apply --print-args net-takoj > "$TMP/out" 2> "$TMP/err"; code=$?
check "нет файла стратегии: код не 0"              test "$code" -ne 0
check "нет файла стратегии: stdout пуст"           test ! -s "$TMP/out"
check "нет файла стратегии: названо имя"           has "$TMP/err" "net-takoj"

finish
