#!/usr/bin/env bash
# Безопасность (1.1.4): ничего из недоверенных данных (стратегии Flowseal,
# имена файлов, содержимое /etc/zapret-linux, аргументы команд) не должно
# исполняться или выходить за пределы своих каталогов.
. "$(dirname "$0")/lib.sh"
TR="$ROOT/tools/bat2nfqws.sh"

# ---------------------------------------------------------------- транслятор
section "Транслятор: недопустимые символы в параметрах"
mkdir -p "$TMP/t"
# Параметр, содержащий $1, внедряется в путь фейка: --dpi-desync-fake-tls="%BIN%x$1.bin"
tr_bad() {
  local d="$1" s="$2"
  make_bat "$TMP/t/bad.bat" "x${s}y.bin"
  bash "$TR" "$TMP/t/bad.bat" > "$TMP/t/bad.out" 2> "$TMP/t/bad.err"; local code=$?
  check "$d: код 4"           test "$code" -eq 4
  check "$d: stdout пуст"     test ! -s "$TMP/t/bad.out"
}
tr_bad 'подстановка dollar-скобки'     '$(touch m)'
tr_bad 'обратные кавычки'       '`touch m`'
tr_bad 'символ |'               '|'
tr_bad 'символ &'               '&'
tr_bad 'символ ;'               ';'
tr_bad 'символ >'               '>'
tr_bad 'символ <'               '<'
tr_bad "одинарная кавычка"      "'"
tr_bad 'символ *'               '*'

section "Транслятор: списки портов"
# make_bat -> подменяем значение --wf-tcp / --wf-udp
tr_bad_ports() {
  local d="$1" flag="$2" val="$3"
  make_bat "$TMP/t/p.bat" a.bin
  local esc="${val//&/\\&}"
  if [ "$flag" = tcp ]; then
    sed -i "s#--wf-tcp=80,443,2053,%GameFilterTCP%#--wf-tcp=$esc#" "$TMP/t/p.bat"
  else
    sed -i "s#--wf-udp=443,50000-50100,%GameFilterUDP%#--wf-udp=$esc#" "$TMP/t/p.bat"
  fi
  bash "$TR" "$TMP/t/p.bat" > "$TMP/t/p.out" 2> "$TMP/t/p.err"; local code=$?
  check "$d: код 4"        test "$code" -eq 4
  check "$d: stdout пуст"  test ! -s "$TMP/t/p.out"
}
tr_bad_ports 'TCP: точка с запятой'  tcp '80;reboot'
tr_bad_ports 'TCP: $(...)'           tcp '80$(id)'
tr_bad_ports 'UDP: конвейер'         udp '443|x'
tr_bad_ports 'UDP: амперсанд'        udp '443\&x'
make_bat "$TMP/t/ok.bat" a.bin
bash "$TR" "$TMP/t/ok.bat" > "$TMP/t/ok.out" 2>/dev/null; code=$?
check "обычные порты с метками проходят" test "$code" -eq 0

section "Транслятор: макрос проверяется раньше символов"
make_bat "$TMP/t/m.bat" 'x$(touch m).bin'
sed -i 's/%GameFilterUDP%/%BrandNewFilter%/g' "$TMP/t/m.bat"
bash "$TR" "$TMP/t/m.bat" > "$TMP/t/m.out" 2> "$TMP/t/m.err"; code=$?
check 'незнакомый макрос вместе с $(...) — код 3' test "$code" -eq 3

section "Транслятор: допустимые + ! ^ :"
make_bat "$TMP/t/allow.bat" 'a.bin --dpi-desync-split-pos=2,sniext+1 --x=a!b:c^d'
bash "$TR" "$TMP/t/allow.bat" > "$TMP/t/allow.conf" 2> "$TMP/t/allow.err"; code=$?
check "параметры с + ! ^ : проходят"      test "$code" -eq 0
check "split-pos=2,sniext+1 сохранён"     has "$TMP/t/allow.conf" "--dpi-desync-split-pos=2,sniext+1"

section "Транслятор: опасное имя файла"
mkdir -p "$TMP/w"
EVILNAME='general $(touch m1) `touch m2` b\s "q" '"'z'"
make_bat "$TMP/t/$EVILNAME.bat" a.bin
bash "$TR" "$TMP/t/$EVILNAME.bat" > "$TMP/t/name.conf" 2> "$TMP/t/name.err"; code=$?
check 'имя с $(...) и кавычками переводится (код 0)' test "$code" -eq 0
( cd "$TMP/w" && . "$TMP/t/name.conf" >/dev/null 2>&1; printf '%s' "${STRATEGY_NAME:-}" > "$TMP/t/name.val" )
check "подключение .conf не исполняет имя"           test ! -e "$TMP/w/m1" -a ! -e "$TMP/w/m2"
check_not "в STRATEGY_NAME нет \$"                   grep -qF '$'  "$TMP/t/name.val"
check_not "в STRATEGY_NAME нет обратных кавычек"     grep -qF '`'  "$TMP/t/name.val"
check_not "в STRATEGY_NAME нет обратной косой"       grep -qF '\'  "$TMP/t/name.val"
check_not "в STRATEGY_NAME нет двойных кавычек"      grep -qF '"'  "$TMP/t/name.val"
check_not "в STRATEGY_NAME нет одинарных кавычек"    grep -qF "'"  "$TMP/t/name.val"
check "непустое имя осталось"                        test -s "$TMP/t/name.val"
make_bat "$TMP/t/общий (тест).bat" a.bin
bash "$TR" "$TMP/t/общий (тест).bat" > "$TMP/t/ru.conf" 2>/dev/null
( . "$TMP/t/ru.conf"; printf '%s' "$STRATEGY_NAME" > "$TMP/t/ru.val" )
check "кириллица в имени сохраняется"                test "$(cat "$TMP/t/ru.val")" = "общий (тест)"

# ------------------------------------------------------------------ apply
OPT="$TMP/s/opt"; ETC="$TMP/s/etc"; mkdir -p "$ETC" "$TMP/w2"
make_opt "$OPT"
CMD="$ETC/nfqws.cmd"
mkconf() { # имя значение_NFQWS_OPT [прочие строки]
  { printf 'STRATEGY_NAME="%s"\nPORTS_TCP="443"\nPORTS_UDP=""\n' "$1"
    printf 'NFQWS_OPT="%s"\n' "$2"; shift 2; [ $# -gt 0 ] && printf '%s\n' "$@"; } > "$OPT/strategies/$1.conf" 2>/dev/null
}
conf_file() { # файл имя значение_NFQWS_OPT [строки]
  local f="$1"; shift
  { printf 'STRATEGY_NAME="%s"\nPORTS_TCP="443"\nPORTS_UDP=""\n' "$1"
    printf 'NFQWS_OPT="%s"\n' "$2"; shift 2; [ $# -gt 0 ] && printf '%s\n' "$@"; } > "$f"
}
apply test >/dev/null 2>&1
cp "$CMD" "$TMP/cmd_good"

section "apply: стратегия не исполняется"
M="$TMP/w2/mark"
conf_file "$OPT/strategies/evil.conf" evil '--x=$(touch '"$M"')'
apply evil > "$TMP/out" 2>&1; code=$?
check 'подстановка $(...) в NFQWS_OPT: отказ'          test "$code" -ne 0
check "маркер не создан"                               test ! -e "$M"
check "nfqws.cmd не изменился"                         same "$TMP/cmd_good" "$CMD"
rm -f "$M"
conf_file "$OPT/strategies/evil2.conf" evil2 '--x=`touch '"$M"'`'
apply evil2 > "$TMP/out" 2>&1; code=$?
check "обратные кавычки в NFQWS_OPT: отказ"            test "$code" -ne 0
check "маркер от обратных кавычек не создан"           test ! -e "$M"
# посторонние строки в .conf не должны выполняться
conf_file "$OPT/strategies/evil3.conf" evil3 '--filter-tcp=443' "touch $M" "\$(touch $M)"
apply evil3 > "$TMP/out" 2>&1
check "посторонние команды в .conf не выполняются"     test ! -e "$M"
conf_file "$OPT/strategies/evil4.conf" evil4 '--filter-tcp=443'
sed -i 's/^STRATEGY_NAME=.*/STRATEGY_NAME="a$(touch '"${M//\//\\/}"')b"/' "$OPT/strategies/evil4.conf"
apply evil4 > "$TMP/out" 2>&1
check 'имя стратегии с $(...) не выполняется'          test ! -e "$M"
rm -f "$OPT/strategies/evil"*.conf
rebase() { apply test >/dev/null 2>&1; cp "$CMD" "$TMP/cmd_good"; }

section "apply: опасные символы в параметрах"
rebase
for ch in '|' '>' '&' '<' ';'; do
  conf_file "$OPT/strategies/bad.conf" bad "--filter-tcp=443 --x=a${ch}b"
  apply bad > "$TMP/out" 2>&1; code=$?
  check "символ $ch в NFQWS_OPT: отказ"                test "$code" -ne 0
  check "символ $ch: nfqws.cmd не изменился"           same "$TMP/cmd_good" "$CMD"
done
rm -f "$OPT/strategies/bad.conf"

section "apply: имя стратегии из аргумента"
rebase
conf_file "$OPT/x.conf" outside '--filter-tcp=443'
apply ../x > "$TMP/out" 2>&1; code=$?
check "../x: отказ"                                    test "$code" -ne 0
check "../x: nfqws.cmd не изменился"                   same "$TMP/cmd_good" "$CMD"
mkdir -p "$OPT/strategies/sub"; conf_file "$OPT/strategies/sub/y.conf" y '--filter-tcp=443'
apply sub/y > "$TMP/out" 2>&1; code=$?
check "sub/y (со слэшем): отказ"                       test "$code" -ne 0
check "sub/y: nfqws.cmd не изменился"                  same "$TMP/cmd_good" "$CMD"
apply 'te st' > "$TMP/out" 2>&1; code=$?
check "имя с пробелом: отказ"                          test "$code" -ne 0
rm -rf "$OPT/x.conf" "$OPT/strategies/sub"

section "apply: подмена фейков"
mkdir -p "$TMP/s/etc"; echo secret > "$ETC/passwd"
printf 'tls ../../etc/passwd\n' > "$ETC/fakes.conf"
apply test > "$TMP/out" 2>&1
check "tls ../../etc/passwd пропущена"                 test "$(grep -c 'etc/passwd' "$CMD")" -eq 0
check "фейк из стратегии остался"                      has "$CMD" "'--dpi-desync-fake-tls=$OPT/bin/tls_clienthello_www_google_com.bin'"
rm -f "$ETC/fakes.conf" "$ETC/passwd"

section "apply: данные из /etc/zapret-linux"
printf 'TCP=1;reboot\nUDP=2|x\n' > "$ETC/gamefilter-ports"; echo all > "$ETC/gamefilter"
apply test > "$TMP/out" 2>&1; ( . "$ETC/active.env"; echo "$PORTS_TCP|$PORTS_UDP" > "$TMP/ports" )
check "мусор в gamefilter-ports: в firewall 1024-65535" has "$TMP/ports" "80,443,2053,1024-65535|443,50000-50100,1024-65535"
check "мусор не попал в профиль TCP"                   has "$CMD" "'--filter-tcp=1024-65535'"
check_not "в nfqws.cmd нет мусора"                     has_re "$CMD" "reboot|2\|x"
rm -f "$ETC/gamefilter-ports"
echo bogus > "$ETC/gamefilter"
apply test > "$TMP/out" 2>&1
check "неизвестный режим фильтра: GAMEFILTER_MODE off" has "$ETC/active.env" 'GAMEFILTER_MODE="off"'
rm -f "$ETC/gamefilter"

section "apply: формат nfqws.cmd"
mkdir -p "$TMP/my_bin"
cat > "$TMP/my_bin/nfqws" <<'EOS'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done
EOS
chmod +x "$TMP/my_bin/nfqws"
conf_file "$OPT/strategies/argtest.conf" argtest '--filter-tcp=443 --hostlist=@LISTS@/list-general.txt --dpi-desync=fake,multisplit --dpi-desync-split-pos=2,sniext+1 --new --filter-udp=443'
NFQWS_BIN="$TMP/my_bin/nfqws" apply argtest > "$TMP/out" 2>&1; code=$?
check "стратегия argtest применена"                    test "$code" -eq 0
check "nfqws.cmd проходит sh -n"                       sh -n "$CMD"
tail -n1 "$CMD" > "$TMP/last"
check "последняя строка: exec с аргументами в кавычках" has_re "$TMP/last" "^exec '[^']+'( '[^']+')+$"
check "в конце --qnum и --dpi-desync-fwmark"           has_re "$TMP/last" " '--qnum=200' '--dpi-desync-fwmark=0x40000000'\$"
check "движок указан первым, в кавычках"               has "$TMP/last" "exec '$TMP/my_bin/nfqws' '--filter-tcp=443'"
sh "$CMD" > "$TMP/args" 2>&1
printf '%s\n' --filter-tcp=443 "--hostlist=$OPT/lists/list-general.txt" --dpi-desync=fake,multisplit \
  --dpi-desync-split-pos=2,sniext+1 --new --filter-udp=443 --qnum=200 --dpi-desync-fwmark=0x40000000 > "$TMP/args_exp"
check "выполнение nfqws.cmd даёт ожидаемые аргументы"  same "$TMP/args_exp" "$TMP/args"

section "apply: временные файлы"
E2="$TMP/s/etc2"; mkdir -p "$E2"
OPT_DIR="$OPT" ETC_DIR="$E2" mocked bash "$ROOT/apply-strategy.sh" test >/dev/null 2>&1
ls -A "$E2" | sort > "$TMP/ls_after"
printf 'active.env\nipset-active.txt\nnfqws.cmd\n' > "$TMP/ls_exp"
check "после применения в ETC только рабочие файлы"    same "$TMP/ls_exp" "$TMP/ls_after"
conf_file "$OPT/strategies/bad.conf" bad '--x=a|b'
OPT_DIR="$OPT" ETC_DIR="$E2" mocked bash "$ROOT/apply-strategy.sh" bad >/dev/null 2>&1
ls -A "$E2" | sort > "$TMP/ls_after"
check "после отказа временных файлов нет"              same "$TMP/ls_exp" "$TMP/ls_after"
rm -f "$OPT/strategies/bad.conf" "$OPT/strategies/argtest.conf"

# -------------------------------------------------------------- zapret-cli
section "zapret use"
CO="$TMP/c/opt"; CE="$TMP/c/etc"; mkdir -p "$CE"
make_opt "$CO"; cp "$ROOT/apply-strategy.sh" "$CO/"; chmod +x "$CO/apply-strategy.sh"
conf_file "$CO/x.conf" outside '--filter-tcp=443'
printf 'touch %s\n' "$TMP/w2/climark" >> "$CO/x.conf"
OPT_DIR="$CO" ETC_DIR="$CE" mocked bash "$ROOT/zapret-cli" use ../x > "$TMP/out" 2>&1; code=$?
check "use ../x: отказ"                                test "$code" -ne 0
check "use ../x: ничего не применено"                  test ! -e "$CE/nfqws.cmd" -a ! -e "$TMP/w2/climark"
OPT_DIR="$CO" ETC_DIR="$CE" mocked bash "$ROOT/zapret-cli" use test > "$TMP/out" 2>&1; code=$?
check "use test: обычная стратегия применяется"        test "$code" -eq 0 -a -f "$CE/nfqws.cmd"

# ------------------------------------------------------------------ fakes
section "fakes"
FO="$TMP/f/opt"; FE="$TMP/f/etc"; mkdir -p "$FE"
make_opt "$FO"; cp "$ROOT/apply-strategy.sh" "$FO/"; chmod +x "$FO/apply-strategy.sh"
for b in a b c x; do echo "$b" > "$FO/bin/$b.bin"; done
echo 'STRATEGY_FILE="test"' > "$FE/active.env"
echo secret > "$TMP/etc_passwd_target"; mkdir -p "$TMP/etc"; echo secret > "$TMP/etc/passwd"
fakes() { OPT_DIR="$FO" ETC_DIR="$FE" mocked bash "$ROOT/fakes.sh" "$@"; }
printf 'quic a.bin\nquicx b.bin\n' > "$FE/fakes.conf"; cp "$FE/fakes.conf" "$TMP/fakes_before"
fakes set tls ../../../etc/passwd > "$TMP/out" 2>&1; code=$?
check "set tls ../../../etc/passwd: отказ"             test "$code" -ne 0
check "fakes.conf не изменён после отказа (путь)"      same "$TMP/fakes_before" "$FE/fakes.conf"
fakes set 'tl.' x.bin > "$TMP/out" 2>&1; code=$?
check "set 'tl.' x.bin (тип не по шаблону): отказ"     test "$code" -ne 0
check "fakes.conf не изменён после отказа (тип)"       same "$TMP/fakes_before" "$FE/fakes.conf"
fakes set 'TLS' x.bin > "$TMP/out" 2>&1; code=$?
check "set TLS (заглавные в типе): отказ"              test "$code" -ne 0
fakes unset 'q.ic' > "$TMP/out" 2>&1
check "unset 'q.ic' не удаляет строку quic по регулярке" has "$FE/fakes.conf" "quic a.bin"
fakes unset quic > "$TMP/out" 2>&1
check "unset quic удаляет quic"                        test "$(grep -c '^quic a.bin' "$FE/fakes.conf")" -eq 0
check "unset quic не трогает quicx"                    has "$FE/fakes.conf" "quicx b.bin"
printf 'quic a.bin\nquicx b.bin\n' > "$FE/fakes.conf"
fakes set quic c.bin > "$TMP/out" 2>&1; code=$?
check "set quic c.bin: успех"                          test "$code" -eq 0
check "set заменил только quic"                        has "$FE/fakes.conf" "quic c.bin"
check "set не удалил quicx"                            has "$FE/fakes.conf" "quicx b.bin"
check "старая строка quic a.bin заменена"              test "$(grep -c '^quic a.bin' "$FE/fakes.conf")" -eq 0

# -------------------------------------------------------------- uninstall
section "uninstall.sh: защита от чужого каталога"
SB="$TMP/safebin"; mkdir -p "$SB"
for c in nft pkill pgrep; do printf '#!/bin/sh\nexit 1\n' > "$SB/$c"; chmod +x "$SB/$c"; done
mkdir -p "$TMP/u"
# копия с путями unit-файла и ссылки внутри $TMP — настоящие /etc и /usr не затрагиваются
sed -e "s|^UNIT=.*|UNIT=$TMP/u/unit|" -e "s|^LINK=.*|LINK=$TMP/u/link|" "$ROOT/uninstall.sh" > "$TMP/u/uninstall.sh"
if ! grep -q "^UNIT=$TMP/u/unit" "$TMP/u/uninstall.sh" || ! grep -q "^LINK=$TMP/u/link" "$TMP/u/uninstall.sh"; then
  fail "не удалось изолировать uninstall.sh (изменилась структура) — проверки пропущены"
else
  un() { PATH="$SB:$MOCK:$PATH" OPT_DIR="$1" ETC_DIR="$TMP/u/etc/zapret-linux" bash "$TMP/u/uninstall.sh" --yes; }
  mkdir -p "$TMP/x" "$TMP/xzapret-linux"; echo data > "$TMP/x/file"; echo data > "$TMP/xzapret-linux/file"
  un "$TMP/x" > "$TMP/out" 2>&1; code=$?
  check "OPT_DIR=.../x: отказ"                         test "$code" -ne 0
  check "каталог .../x остался"                        test -f "$TMP/x/file"
  un "$TMP/xzapret-linux" > "$TMP/out" 2>&1; code=$?
  check "OPT_DIR=.../xzapret-linux: отказ"             test "$code" -ne 0
  check "каталог .../xzapret-linux остался"            test -f "$TMP/xzapret-linux/file"
  mkdir -p "$TMP/y/zapret-linux"; echo data > "$TMP/y/zapret-linux/file"
  un "$TMP/y/zapret-linux" > "$TMP/out" 2>&1; code=$?
  check "OPT_DIR=.../zapret-linux: удаляется"          test "$code" -eq 0 -a ! -e "$TMP/y/zapret-linux"
fi

finish
