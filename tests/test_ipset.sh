#!/usr/bin/env bash
# ipsetfilter.sh: явный выбор режима IPSet (метка ipsetfilter-chosen).
. "$(dirname "$0")/lib.sh"
OPT="$TMP/opt"; ETC="$TMP/etc"; mkdir -p "$ETC"
make_opt "$OPT"
cp "$ROOT/apply-strategy.sh" "$OPT/"; chmod +x "$OPT/apply-strategy.sh"
printf '10.0.0.0/8\n172.16.0.0/12\n' > "$OPT/lists/ipset-all.txt.backup"
IPA="$ETC/ipset-active.txt"
ips() { OPT_DIR="$OPT" ETC_DIR="$ETC" mocked bash "$ROOT/ipsetfilter.sh" "$@"; }
apply test >/dev/null 2>&1      # создаёт active.env с активной стратегией

section "ipsetfilter.sh: метка явного выбора"
check "метки нет до первого выбора"              test ! -e "$ETC/ipsetfilter-chosen"
ips none > "$TMP/out" 2>&1; code=$?
check "none: успех"                              test "$code" -eq 0
check "none: создана метка"                      test -e "$ETC/ipsetfilter-chosen"
check "none: режим записан"                      test "$(cat "$ETC/ipsetfilter")" = none
check "none: применена заглушка"                 test "$(cat "$IPA")" = "203.0.113.113/32"
rm -f "$ETC/ipsetfilter-chosen"
ips any > "$TMP/out" 2>&1; code=$?
check "any: успех"                               test "$code" -eq 0
check "any: создана метка"                       test -e "$ETC/ipsetfilter-chosen"
check "any: применены любые адреса"              has "$IPA" "0.0.0.0/0"
rm -f "$ETC/ipsetfilter-chosen"
ips loaded > "$TMP/out" 2>&1; code=$?
check "loaded: успех"                            test "$code" -eq 0
check "loaded: создана метка"                    test -e "$ETC/ipsetfilter-chosen"
check "loaded: режим записан"                    test "$(cat "$ETC/ipsetfilter")" = loaded
check "loaded: грузится полный список (.backup)" same "$OPT/lists/ipset-all.txt.backup" "$IPA"

section "Выбор loaded переживает переприменение"
apply test > "$TMP/out" 2>&1
check "apply оставляет loaded"                   test "$(cat "$ETC/ipsetfilter")" = loaded
check "apply грузит полный список"               same "$OPT/lists/ipset-all.txt.backup" "$IPA"
echo loaded > "$ETC/ipsetfilter"       # так делает старый update.sh
apply test > "$TMP/out" 2>&1
check "после перезаписи loaded с меткой — по-прежнему loaded" test "$(cat "$ETC/ipsetfilter")" = loaded

section "ipsetfilter.sh status"
rm -f "$ETC/ipsetfilter"
ips status > "$TMP/out" 2>&1; code=$?
check "status без файла режима: успех"           test "$code" -eq 0
check "status без файла режима показывает none"  has "$TMP/out" "режим IPSet Filter: none"
echo any > "$ETC/ipsetfilter"
ips status > "$TMP/out" 2>&1
check "status показывает записанный режим"       has "$TMP/out" "режим IPSet Filter: any"
check_not "ipsetfilter.sh с неверным режимом — ошибка" ips bogus

finish
