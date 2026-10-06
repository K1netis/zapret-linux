#!/usr/bin/env bash
# apply-strategy.sh: подстановка меток, рабочие файлы, проверки перед запуском.
. "$(dirname "$0")/lib.sh"
OPT="$TMP/opt"; ETC="$TMP/etc"; mkdir -p "$ETC"
make_opt "$OPT"
CMD="$ETC/nfqws.cmd"

section "Применение стратегии"
apply test > "$TMP/out" 2>&1; code=$?
check "завершается успешно"                       test "$code" -eq 0
( . "$ETC/active.env" 2>"$TMP/env_err"; echo "$STRATEGY_NAME|$STRATEGY_FILE" > "$TMP/env" )
check "active.env читается, хотя в имени скобки"  test ! -s "$TMP/env_err"
check "сохранены имя и файл стратегии"            has "$TMP/env" "general (TEST)|test"
check_not "в команде nfqws не осталось меток"     has_re "$CMD" "@[A-Z_]+@"
check "пути подставлены абсолютные"               has "$CMD" "$OPT/lists/list-general.txt"
check "добавлены --qnum и --dpi-desync-fwmark"    has "$CMD" "'--qnum=200' '--dpi-desync-fwmark=0x40000000'"
check "созданы *-user.txt"                       test -f "$OPT/lists/list-general-user.txt" -a -f "$OPT/lists/ipset-exclude-user.txt"

section "Игровой фильтр"
. "$ETC/active.env"
check "выключен: игровой диапазон не в firewall"  test "$PORTS_TCP" = "80,443,2053"
check "выключен: профиль получает порт-заглушку"  has "$CMD" "'--filter-tcp=1'"
check "выключен: заглушка и для UDP"              has "$CMD" "'--filter-udp=1'"
echo udp > "$ETC/gamefilter"; apply test >/dev/null 2>&1; . "$ETC/active.env"
check "udp: диапазон добавлен в UDP"              test "$PORTS_UDP" = "443,50000-50100,1024-65535"
check "udp: TCP без изменений"                    test "$PORTS_TCP" = "80,443,2053"
check "udp: профиль UDP с диапазоном"             has "$CMD" "'--filter-udp=1024-65535'"
printf 'TCP=1024-1934,1936-65535\nUDP=1024-65535\n' > "$ETC/gamefilter-ports"
echo all > "$ETC/gamefilter"; apply test >/dev/null 2>&1; . "$ETC/active.env"
check "свои порты попадают в firewall"            test "$PORTS_TCP" = "80,443,2053,1024-1934,1936-65535"
check "свои порты попадают в профиль"             has "$CMD" "'--filter-tcp=1024-1934,1936-65535'"
rm -f "$ETC/gamefilter" "$ETC/gamefilter-ports"

section "Режимы IPSet"
IPA="$ETC/ipset-active.txt"; STUB="203.0.113.113/32"
only_stub() { [ "$(cat "$IPA")" = "$STUB" ]; }
rm -f "$ETC/ipsetfilter" "$ETC/ipsetfilter-chosen" "$OPT/lists/ipset-all.txt.backup"
apply test >/dev/null 2>&1
check "нет файла режима: none (заглушка)"         only_stub
echo any  > "$ETC/ipsetfilter"; apply test >/dev/null 2>&1
check "any: любые адреса IPv4"                    has "$IPA" "0.0.0.0/0"
check "any: любые адреса IPv6"                    has "$IPA" "::/0"
echo none > "$ETC/ipsetfilter"; apply test >/dev/null 2>&1
check "none: ровно одна строка-заглушка"          only_stub
check "none: файл не пуст"                        test -s "$IPA"
check "в active.env записан режим none"           has "$ETC/active.env" 'IPSET_MODE="none"'

section "IPSet loaded: источник списка"
touch "$ETC/ipsetfilter-chosen"; echo loaded > "$ETC/ipsetfilter"
apply test >/dev/null 2>&1
check "без .backup: копия ipset-all.txt"          same "$OPT/lists/ipset-all.txt" "$IPA"
printf '10.0.0.0/8\n172.16.0.0/12\n' > "$OPT/lists/ipset-all.txt.backup"
apply test >/dev/null 2>&1
check "есть .backup: копия .backup"               same "$OPT/lists/ipset-all.txt.backup" "$IPA"
check "это не ipset-all.txt"                      test "$(cat "$IPA")" != "$(cat "$OPT/lists/ipset-all.txt")"
: > "$OPT/lists/ipset-all.txt.backup"
apply test > "$TMP/out" 2>&1
check "пустой .backup: берётся ipset-all.txt"     same "$OPT/lists/ipset-all.txt" "$IPA"
rm -f "$OPT/lists/ipset-all.txt.backup"
cp "$OPT/lists/ipset-all.txt" "$TMP/ipset_real"
printf '# заглушка\n\n203.0.113.113/32\n' > "$OPT/lists/ipset-all.txt"
apply test > "$TMP/out" 2>&1; code=$?
check "только заглушка в ipset-all.txt: успех"    test "$code" -eq 0
check "...в active лежит заглушка"                only_stub
check "...выдано предупреждение про zapret sync"  has "$TMP/out" "zapret sync"
rm -f "$OPT/lists/ipset-all.txt"
apply test > "$TMP/out" 2>&1; code=$?
check "нет ни .backup, ни ipset-all.txt: успех"   test "$code" -eq 0
check "...в active лежит заглушка"                only_stub
check "...предупреждение про zapret sync"         has "$TMP/out" "zapret sync"
cp "$TMP/ipset_real" "$OPT/lists/ipset-all.txt"
printf '10.0.0.0/8\n203.0.113.113/32\n' > "$OPT/lists/ipset-all.txt"
apply test > "$TMP/out" 2>&1
check "заглушка плюс адреса: это настоящий список" same "$OPT/lists/ipset-all.txt" "$IPA"
cp "$TMP/ipset_real" "$OPT/lists/ipset-all.txt"

section "IPSet: переход loaded -> none без явного выбора"
rm -f "$ETC/ipsetfilter-chosen"; echo loaded > "$ETC/ipsetfilter"
apply test > "$TMP/out" 2>&1; code=$?
check "успешно"                                   test "$code" -eq 0
check "файл режима стал none"                     test "$(cat "$ETC/ipsetfilter")" = none
check "применена заглушка"                        only_stub
check "в выводе подсказка zapret ipset loaded"    has "$TMP/out" "zapret ipset loaded"
check "метка выбора не появилась сама"            test ! -e "$ETC/ipsetfilter-chosen"
echo loaded > "$ETC/ipsetfilter"; apply test >/dev/null 2>&1
check "повторная запись loaded (как старый update.sh): снова none" test "$(cat "$ETC/ipsetfilter")" = none
touch "$ETC/ipsetfilter-chosen"; echo loaded > "$ETC/ipsetfilter"
apply test > "$TMP/out" 2>&1
check "с меткой loaded остаётся"                  test "$(cat "$ETC/ipsetfilter")" = loaded
check "с меткой грузится полный список"           same "$OPT/lists/ipset-all.txt" "$IPA"
check_not "с меткой нет сообщения о переходе"     has "$TMP/out" "zapret ipset loaded"
echo any > "$ETC/ipsetfilter"; rm -f "$ETC/ipsetfilter-chosen"; apply test >/dev/null 2>&1
check "any без метки не меняется"                 test "$(cat "$ETC/ipsetfilter")" = any
echo none > "$ETC/ipsetfilter"; apply test >/dev/null 2>&1
check "none без метки не меняется"                test "$(cat "$ETC/ipsetfilter")" = none

section "IPSet: отказ apply не трогает ipset-active.txt"
echo any > "$ETC/ipsetfilter"; apply test >/dev/null 2>&1
cp "$IPA" "$TMP/ipa_before"
echo none > "$ETC/ipsetfilter"
mv "$OPT/lists/list-general.txt" "$TMP/"
apply test > "$TMP/out" 2>&1; code=$?
check "отказ из-за отсутствующего списка"         test "$code" -ne 0
check "ipset-active.txt прежний"                  same "$TMP/ipa_before" "$IPA"
mv "$TMP/list-general.txt" "$OPT/lists/"
rm -f "$ETC/ipsetfilter" "$ETC/ipsetfilter-chosen"; apply test >/dev/null 2>&1

section "Файлы *-user.txt"
rm -f "$OPT/lists/list-general-user.txt" "$OPT/lists/ipset-exclude-user.txt"
apply test >/dev/null 2>&1
check "отсутствующий list-general-user.txt: заглушка домена" test "$(cat "$OPT/lists/list-general-user.txt")" = "domain.example.abc"
check "отсутствующий ipset-exclude-user.txt: заглушка IP"    test "$(cat "$OPT/lists/ipset-exclude-user.txt")" = "$STUB"
: > "$OPT/lists/list-general-user.txt"; : > "$OPT/lists/ipset-exclude-user.txt"
apply test >/dev/null 2>&1
check "пустой list-general-user.txt заполняется"  test "$(cat "$OPT/lists/list-general-user.txt")" = "domain.example.abc"
check "пустой ipset-exclude-user.txt заполняется" test "$(cat "$OPT/lists/ipset-exclude-user.txt")" = "$STUB"
printf 'мой.сайт\n' > "$OPT/lists/list-general-user.txt"; printf '9.9.9.9\n' > "$OPT/lists/ipset-exclude-user.txt"
apply test >/dev/null 2>&1
check "непустой list-general-user.txt не меняется" test "$(cat "$OPT/lists/list-general-user.txt")" = "мой.сайт"
check "непустой ipset-exclude-user.txt не меняется" test "$(cat "$OPT/lists/ipset-exclude-user.txt")" = "9.9.9.9"

section "Отсутствующий файл в любом параметре --имя=/путь"
printf 'STRATEGY_NAME="pat"\nPORTS_TCP="443"\nPORTS_UDP=""\n' > "$TMP/pat.head"
pat_conf() { { cat "$TMP/pat.head"; printf 'NFQWS_OPT="%s"\n' "$1"; } > "$OPT/strategies/pat.conf"; }
apply test >/dev/null 2>&1; cp "$CMD" "$TMP/cmd_b"; cp "$ETC/active.env" "$TMP/env_b"
pat_conf '--filter-tcp=443 --dpi-desync=fakedsplit --dpi-desync-fakedsplit-pattern=@BIN@/nofile.bin'
apply pat > "$TMP/out" 2>&1; code=$?
check "fakedsplit-pattern с отсутствующим файлом: отказ" test "$code" -ne 0
check "сообщение называет nofile.bin"             has "$TMP/out" "nofile.bin"
check "nfqws.cmd не изменён"                      same "$TMP/cmd_b" "$CMD"
check "active.env не изменён"                     same "$TMP/env_b" "$ETC/active.env"
pat_conf '--filter-tcp=443 --some-new-param=@LISTS@/nolist.txt'
apply pat > "$TMP/out" 2>&1; code=$?
check "произвольный параметр с отсутствующим путём: отказ" test "$code" -ne 0
check "сообщение называет nolist.txt"             has "$TMP/out" "nolist.txt"
pat_conf '--filter-tcp=443 --dpi-desync=fakedsplit --dpi-desync-fakedsplit-pattern=@BIN@/tls_clienthello_www_google_com.bin'
apply pat > "$TMP/out" 2>&1; code=$?
check "тот же параметр с существующим файлом: успех" test "$code" -eq 0
pat_conf '--filter-tcp=443 --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq --dpi-desync-fake-tls=0x00000000'
apply pat > "$TMP/out" 2>&1; code=$?
check "значения без пути не считаются файлами"    test "$code" -eq 0

section "Старый --dpi-desync-fake-tls=^!"
pat_conf '--filter-tcp=443 --dpi-desync=fake --dpi-desync-fake-tls=^!'
apply pat > "$TMP/out" 2>&1; code=$?
check "успешно"                                   test "$code" -eq 0
check "в nfqws.cmd аргумент =!"                   has "$CMD" "'--dpi-desync-fake-tls=!'"
check_not "в nfqws.cmd нет ^"                     has "$CMD" "^"
pat_conf '--filter-tcp=443 --dpi-desync-fake-tls=^! --new --filter-udp=443 --dpi-desync-fake-tls=^!'
apply pat > "$TMP/out" 2>&1
check "все вхождения исправлены"                  test "$(grep -o "'--dpi-desync-fake-tls=!'" "$CMD" | wc -l)" -eq 2
rm -f "$OPT/strategies/pat.conf"
apply test >/dev/null 2>&1

section "Подмена фейков"
echo other > "$OPT/bin/my_fake.bin"
echo "tls my_fake.bin" > "$ETC/fakes.conf"; apply test >/dev/null 2>&1
check "фейк заменён"                              has "$CMD" "'--dpi-desync-fake-tls=$OPT/bin/my_fake.bin'"
echo "tls missing.bin" > "$ETC/fakes.conf"; apply test > "$TMP/out" 2>&1
check "отсутствующий фейк не подставляется"       has "$CMD" "'--dpi-desync-fake-tls=$OPT/bin/tls_clienthello_www_google_com.bin'"
rm -f "$ETC/fakes.conf"

section "Нехватка файлов"
cp "$CMD" "$TMP/cmd_before"
mv "$OPT/lists/list-general.txt" "$TMP/"
apply test > "$TMP/out" 2>&1; code=$?
check "отказ при отсутствующем списке"            test "$code" -ne 0
check "сообщение называет файл"                   has "$TMP/out" "list-general.txt"
check "рабочая команда не перезаписана"           same "$TMP/cmd_before" "$CMD"
mv "$TMP/list-general.txt" "$OPT/lists/"
check_not "несуществующая стратегия — ошибка"     apply nosuch

finish
