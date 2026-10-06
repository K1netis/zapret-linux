#!/usr/bin/env bash
# Транслятор tools/bat2nfqws.sh: перевод стратегий Flowseal в формат nfqws.
. "$(dirname "$0")/lib.sh"
TR="$ROOT/tools/bat2nfqws.sh"

section "Транслятор"

make_bat "$TMP/general (ALT9).bat" tls_clienthello_www_google_com.bin
bash "$TR" "$TMP/general (ALT9).bat" > "$TMP/out.conf" 2> "$TMP/err"
check "стратегия в формате Flowseal (CRLF, переносы ^) переводится" test -s "$TMP/out.conf"

( . "$TMP/out.conf"
  printf '%s\n' "$STRATEGY_NAME" > "$TMP/name"
  printf '%s\n' "$PORTS_TCP"     > "$TMP/ptcp"
  printf '%s\n' "$PORTS_UDP"     > "$TMP/pudp"
  printf '%s\n' "$NFQWS_OPT"     > "$TMP/opt" ) 2> "$TMP/source_err"
check "результат подключается как shell-фрагмент"     test ! -s "$TMP/source_err"
check "имя со скобками сохраняется"                    has "$TMP/name" "general (ALT9)"
check "порты TCP из --wf-tcp с меткой игрового фильтра" has "$TMP/ptcp" "80,443,2053,@GAMEFILTER_TCP@"
check "порты UDP из --wf-udp с меткой игрового фильтра" has "$TMP/pudp" "443,50000-50100,@GAMEFILTER_UDP@"
check_not "параметры --wf-* убраны из строки nfqws"     has_re "$TMP/opt" "--wf-"
check_not "не осталось макросов %...%"                   has_re "$TMP/opt" "%[A-Za-z_]+%"
check_not "не осталось символов CR"                      grep -q $'\r' "$TMP/opt"
check_not "не осталось кавычек вокруг путей"             has "$TMP/opt" '"'
check "пути к фейкам заменены меткой @BIN@"              has "$TMP/opt" "@BIN@/tls_clienthello_www_google_com.bin"
check "пути к спискам заменены меткой @LISTS@"           has "$TMP/opt" "@LISTS@/list-general.txt"
check "ipset-all.txt заменён меткой @IPSET@"             has "$TMP/opt" "--ipset=@IPSET@"
check "списки-исключения не превращены в @IPSET@"        has "$TMP/opt" "@LISTS@/ipset-exclude-user.txt"
check "профили разделены --new"                          has_re "$TMP/opt" "--new .*--new"

section "Незнакомый макрос"
sed 's/%GameFilterUDP%/%BrandNewFilter%/g' "$TMP/general (ALT9).bat" > "$TMP/new.bat"
bash "$TR" "$TMP/new.bat" > "$TMP/new.conf" 2> "$TMP/new.err"; code=$?
check "завершается с кодом 3"             test "$code" -eq 3
check "называет незнакомый макрос"         has "$TMP/new.err" "%BrandNewFilter%"

section "Ошибочный ввод"
check_not "нет файла — ошибка"             bash "$TR" "$TMP/nope.bat"
printf '@echo off\r\necho hi\r\n' > "$TMP/empty.bat"
check_not "нет запуска winws.exe — ошибка" bash "$TR" "$TMP/empty.bat"

section "Экранирование ^ вне кавычек (cmd.exe)"
# bat с произвольным хвостом параметров
mk_tail() { printf '@echo off\r\nstart "z" /min "%%~dp0bin\\winws.exe" --wf-tcp=443 --filter-tcp=443 %s\r\n' "$1" > "$TMP/esc.bat"; }
tr_opt() { bash "$TR" "$TMP/esc.bat" 2>"$TMP/esc.err" | sed -n 's/^NFQWS_OPT="\(.*\)"$/\1/p'; }
mk_tail '--dpi-desync-fake-tls=^!'
check "^! переводится в !"                 test "$(tr_opt)" = "--filter-tcp=443 --dpi-desync-fake-tls=!"
mk_tail '--x=a^^b'
check "^^ переводится в ^"                 test "$(tr_opt)" = "--filter-tcp=443 --x=a^b"
mk_tail '--x=a^b'
check "a^b переводится в ab"               test "$(tr_opt)" = "--filter-tcp=443 --x=ab"
mk_tail '--x=a^^!b'
check "^^! переводится в ^!"               test "$(tr_opt)" = "--filter-tcp=443 --x=a^!b"
mk_tail '--x="a^b"'
check "внутри кавычек ^ остаётся"          test "$(tr_opt)" = "--filter-tcp=443 --x=a^b"
mk_tail '--x=a^|b'
bash "$TR" "$TMP/esc.bat" > "$TMP/esc.out" 2> "$TMP/esc.err"; code=$?
check "^| даёт | и код 4"                  test "$code" -eq 4
check "^|: stdout пуст"                    test ! -s "$TMP/esc.out"
mk_tail '--x=a^!b --y=%NoSuchMacro%'
bash "$TR" "$TMP/esc.bat" > "$TMP/esc.out" 2> "$TMP/esc.err"; code=$?
check "^! вместе с незнакомым макросом: код 3" test "$code" -eq 3

section "Перенос строки ^ в конце строки"
printf '@echo off\r\nstart "z" /min "%%~dp0bin\\winws.exe" --wf-tcp=443 ^\r\n--filter-tcp=443 --dpi-desync-fake-tls=^! --new ^\r\n--filter-udp=443 --dpi-desync=fake\r\n' > "$TMP/cont.bat"
check "перенос и ^! в одной стратегии"     test "$(tr_cont() { bash "$TR" "$TMP/cont.bat" | sed -n 's/^NFQWS_OPT="\(.*\)"$/\1/p'; }; tr_cont)" = "--filter-tcp=443 --dpi-desync-fake-tls=! --new --filter-udp=443 --dpi-desync=fake"
printf '@echo off\r\nstart "z" /min "%%~dp0bin\\winws.exe" --wf-tcp=443 ^   \r\n--filter-tcp=443\r\n' > "$TMP/cont2.bat"
check "пробелы после ^ в конце строки"      test "$(bash "$TR" "$TMP/cont2.bat" | sed -n 's/^NFQWS_OPT="\(.*\)"$/\1/p')" = "--filter-tcp=443"

finish
