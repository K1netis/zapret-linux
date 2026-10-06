#!/usr/bin/env bash
# selftest.sh (zapret test): проверка каждой стратегии в отдельной очереди и
# отдельном диапазоне исходящих портов. Без root и сети: nft, nfqws и curl
# подменены макетами, apply-strategy.sh — заглушкой --print-args.
. "$(dirname "$0")/lib.sh"

MB="$TMP/mb"; NQ="$TMP/nq"; SD="$TMP/stub"; OPT="$TMP/opt"; ETC="$TMP/etc"; TD="$TMP/tmpd"
mkdir -p "$MB" "$NQ" "$SD" "$OPT/strategies" "$ETC" "$TD"

# ---- макеты ---------------------------------------------------------------
cat > "$MB/nft" <<'M'
#!/usr/bin/env bash
echo "$*" >> "$MOCK_NFT_LOG"
ORIG1="${1:-}"
# nft -f <файл> | nft -f - : в лог попадает содержимое набора правил
while [ $# -gt 0 ]; do
  if [ "$1" = "-f" ]; then
    if [ "${2:-}" = "-" ]; then cat >> "$MOCK_NFT_LOG"; else cat "$2" >> "$MOCK_NFT_LOG"; fi
    break
  fi
  shift
done
[ "${ORIG1:-}" = list ] && exit 1
exit 0
M
cat > "$MB/nfqws" <<'M'
#!/usr/bin/env bash
# Пишет аргументы и PID в файл очереди; со стратегией --bad-option падает.
q=""
for a in "$@"; do case "$a" in --qnum=*) q="${a#--qnum=}" ;; esac; done
printf '%s\n' "$@" > "$MOCK_NFQWS_DIR/$q.args"
echo $$ > "$MOCK_NFQWS_DIR/$q.pid"
for a in "$@"; do
  if [ "$a" = "--bad-option" ]; then
    echo "nfqws: unrecognized option '--bad-option'" >&2
    exit 1
  fi
done
exec sleep 120 </dev/null >/dev/null 2>&1
M
cat > "$MB/apply-stub" <<'M'
#!/usr/bin/env bash
[ "${1:-}" = "--print-args" ] || exit 2
f="$STUB_DIR/${2:-}.args"
[ -f "$f" ] || { echo "нет стратегии ${2:-}" >&2; exit 1; }
cat "$f"
M
# curl: результат берётся из сценария $MOCK_SCEN, строки «стратегия хост проверка результат»
# (стратегия — номер или base, остальное — * для любого). Номер стратегии
# определяется по исходящему порту: (порт-20000)/100.
cat > "$MB/curl" <<'M'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-V" ]; then
  echo "curl 8.0.0 (mock)"; echo "Protocols: http https"
  if [ -n "${MOCK_CURL_H3:-}" ]; then echo "Features: SSL HTTP3"; else echo "Features: SSL"; fi
  exit 0
fi
lp=""; url=""; fmt=""; chk=http11
while [ $# -gt 0 ]; do
  case "$1" in
    --local-port) lp="$2"; shift 2 ;;
    --local-port=*) lp="${1#*=}"; shift ;;
    -w|--write-out) fmt="$2"; shift 2 ;;
    -o|--output|--connect-timeout|--max-time|-m|--range|-r|--tls-max|-H|-A|--resolve|--noproxy|--interface|-x|--proxy) 
      [ "$1" = --range ] || [ "$1" = -r ] && chk=big
      shift 2 ;;
    --http3-only|--http3) chk=h3; shift ;;
    --tlsv1.2) [ "$chk" = big ] || chk=tls12; shift ;;
    --tlsv1.3) [ "$chk" = big ] || chk=tls13; shift ;;
    --http1.1) shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
host="${url#*://}"; host="${host%%/*}"; host="${host%%:*}"
a="${lp%%-*}"
if [ -z "$a" ]; then idx=none
elif [ "$a" -ge 29900 ] 2>/dev/null; then idx=base
else idx=$(( (a - 20000) / 100 )); fi
echo "$lp $host $chk" >> "$MOCK_CURL_LOG"
[ -n "${MOCK_CURL_SLEEP:-}" ] && sleep "$MOCK_CURL_SLEEP"
res="ok:0.100"
if [ -f "${MOCK_SCEN:-}" ]; then
  while read -r si sh sc sr; do
    [ -n "$si" ] || continue
    [ "$si" = '*' ] || [ "$si" = "$idx" ] || continue
    [ "$sh" = '*' ] || [ "$sh" = "$host" ] || continue
    [ "$sc" = '*' ] || [ "$sc" = "$chk" ] || continue
    res="$sr"; break
  done < "$MOCK_SCEN"
fi
# once:<результат> — провал только при первом обращении к паре порты+хост+проверка
case "$res" in
  once:*)
    key="$(printf '%s_%s_%s' "$lp" "$host" "$chk" | tr -c 'A-Za-z0-9.\n-' '_')"
    mkdir -p "$MOCK_CURL_STATE"
    if [ -e "$MOCK_CURL_STATE/$key" ]; then res="ok:0.100"; else : > "$MOCK_CURL_STATE/$key"; res="${res#once:}"; fi ;;
esac
code=0; http=200; t=0.100; size=1234
case "$res" in
  noport)  code=45; http=000; size=0 ;;
  ok:*)    t="${res#ok:}" ;;
  t16k)    code=28; http=200; size=16000 ;;
  timeout) code=28; http=000; size=0 ;;
  cert)    code=60; http=000; size=0 ;;
  dns)     code=6;  http=000; size=0 ;;
  refused) code=7;  http=000; size=0 ;;
  tls)     code=35; http=000; size=0 ;;
  reset)   code=56; http=000; size=0 ;;
  *)       code=99; http=000; size=0 ;;
esac
if [ "$code" -ne 0 ] && [ "$res" != t16k ]; then t=0; fi
if [ -n "$fmt" ]; then
  out="$fmt"
  conn="$(awk -v t="$t" 'BEGIN{printf "%.3f", t/2}')"
  out="${out//%\{http_code\}/$http}"
  out="${out//%\{time_connect\}/$conn}"
  out="${out//%\{time_appconnect\}/$t}"
  out="${out//%\{time_total\}/$t}"
  out="${out//%\{size_download\}/$size}"
  out="${out//%\{exitcode\}/$code}"
  printf '%b' "$out"
fi
exit "$code"
M
chmod +x "$MB"/*

# ---- окружение ------------------------------------------------------------
cat > "$TMP/targets.txt" <<'M'
# проверочный список
DiscordMain = "https://discord.com"
YouTubeWeb  = "https://www.youtube.com"
CloudflareDNS = "PING:1.1.1.1"
M

# strat <имя> <аргументы...> — заглушка --print-args и файл стратегии
strat() {
  local n="$1"; shift
  printf '%s\n' "$@" > "$SD/$n.args"
  printf 'STRATEGY_NAME="%s"\nNFQWS_OPT="%s"\n' "$n" "$*" > "$OPT/strategies/$n.conf"
}

reset_state() {
  rm -rf "$NQ" "$TD" "$TMP/cstate"; mkdir -p "$NQ" "$TD"
  : > "$TMP/nft.log"; : > "$TMP/curl.log"; : > "$TMP/sc.log"; rm -f "$TMP/report.txt"
}

# run_st <файл вывода> <имена стратегий...>
run_st() {
  local out="$1"; shift
  env PATH="$MB:$MOCK:$PATH" TMPDIR="$TD" OPT_DIR="$OPT" ETC_DIR="$ETC" \
    NFQWS_BIN="$MB/nfqws" TARGETS_FILE="${TARGETS_FILE_T:-$TMP/targets.txt}" TIMEOUT=5 CONNECT_TIMEOUT=3 \
    PARALLEL=8 QBASE=210 PBASE=20000 REPORT="$TMP/report.txt" APPLY="$MB/apply-stub" \
    STUB_DIR="$SD" MOCK_SCEN="$TMP/scen" MOCK_NFT_LOG="$TMP/nft.log" \
    MOCK_NFQWS_DIR="$NQ" MOCK_CURL_LOG="$TMP/curl.log" MOCK_SYSTEMCTL_LOG="$TMP/sc.log" \
    MOCK_CURL_H3="${MOCK_CURL_H3:-}" MOCK_CURL_SLEEP="${MOCK_CURL_SLEEP:-}" MOCK_CURL_STATE="$TMP/cstate" \
    timeout 90 bash "$ROOT/selftest.sh" "$@" > "$out.raw" 2>&1
  local code=$?
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$out.raw" > "$out"
  return $code
}

alive() {
  local p="$1" st
  [ -d "/proc/$p" ] || return 1
  st="$(sed -n 's/^State:[[:space:]]*\(.\).*/\1/p' "/proc/$p/status" 2>/dev/null)"
  [ -n "$st" ] && [ "$st" != Z ]
}
all_dead() {
  local f p i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    local live=0
    for f in "$NQ"/*.pid; do
      [ -e "$f" ] || continue
      p="$(cat "$f")"; alive "$p" && live=1
    done
    [ "$live" -eq 0 ] && return 0
    sleep 0.3
  done
  return 1
}

# Порядок имён в таблице рейтинга (от строки «Рейтинг» до пустой строки).
rank_order() {
  local out="$1" n l; shift
  sed -n '/Рейтинг/,/^$/p' "$out" > "$out.rating"
  for n in "$@"; do
    l="$(grep -nw -- "$n" "$out.rating" | head -n1 | cut -d: -f1)"
    echo "${l:-0} $n"
  done | sort -n | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//'
}

INJ="$TMP/pwned"
strat s-alfa    --filter-tcp=443 --dpi-desync=multisplit --new --filter-udp=443 --dpi-desync=multisplit
strat s-bravo   --filter-tcp=443 --dpi-desync=fake --dpi-desync-repeats=3
strat s-charlie --filter-tcp=443 --dpi-desync=multisplit
strat s-delta   --filter-tcp=443 --dpi-desync=fake "--x=a\$(touch $INJ)" "--hostlist=/tmp/a b/(1).txt" '--y=`touch '"$INJ"'`'
strat s-echo    --filter-tcp=443 --dpi-desync=fake --dpi-desync-repeats=6 --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6
strat s-foxtrot --filter-tcp=443 --bad-option
NAMES="s-alfa s-bravo s-charlie s-delta s-echo s-foxtrot"

cat > "$TMP/scen" <<'M'
0 * * ok:0.300
1 * * ok:0.100
2 * tls12 cert
2 * * ok:0.010
3 * * ok:0.110
4 * * ok:0.120
base discord.com * ok:0.050
base * * dns
M
printf 'STRATEGY_NAME="s-bravo (cur)"\nSTRATEGY_FILE="s-bravo"\n' > "$ETC/active.env"

section "Запуск: правила nft и очереди"
reset_state
run_st "$TMP/out1" $NAMES; code=$?
cp "$TMP/nft.log" "$TMP/nft.log.main"
[ -n "${ST_KEEP:-}" ] && cp "$TMP/curl.log" "$ST_KEEP.curl"
[ -n "${ST_KEEP:-}" ] && cp "$TMP/out1" "$ST_KEEP"
check "завершается с кодом 0"                      test "$code" -eq 0
check "создана таблица inet zapret_linux_test"     has "$TMP/nft.log" "inet zapret_linux_test"
check "приоритет mangle - 1"                       has_re "$TMP/nft.log" 'priority mangle - 1'
check_not "рабочая таблица inet zapret_linux не трогается" grep -qE 'table inet zapret_linux( |$)' "$TMP/nft.log"
i=0
for n in $NAMES; do
  q=$((210+i)); a=$((20000+i*100)); b=$((a+99))
  grep -F "queue num $q" "$TMP/nft.log" > "$TMP/r.$i"
  check "$n: правило tcp с портами $a-$b"          grep -qE "tcp.*$a-$b" "$TMP/r.$i"
  check "$n: правило udp с портами $a-$b"          grep -qE "udp.*$a-$b" "$TMP/r.$i"
  check "$n: метка 0x20000000 ставится"            has "$TMP/r.$i" "meta mark set meta mark or 0x20000000"
  i=$((i+1))
done

section "Запуск: nfqws на каждую стратегию"
i=0
for n in $NAMES; do
  q=$((210+i))
  f="$NQ/$q.args"
  check "$n: nfqws запущен в очереди $q"           test -f "$f"
  check "$n: --qnum=$q"                            has "$f" "--qnum=$q"
  check "$n: --dpi-desync-fwmark=0x40000000"       has "$f" "--dpi-desync-fwmark=0x40000000"
  grep -v -e '^--qnum=' -e '^--dpi-desync-fwmark=' "$f" > "$TMP/got.$i" 2>/dev/null
  check "$n: ровно её аргументы"                   same "$SD/$n.args" "$TMP/got.$i"
  i=$((i+1))
done
check "спецсимволы в аргументах не исполнены"      test ! -e "$INJ"
check "аргумент с пробелом передан целым"          has "$NQ/213.args" "--hostlist=/tmp/a b/(1).txt"

section "Рейтинг"
check "порядок: меньше сложность при равной скорости, быстрее выше, провалы ниже" \
  test "$(rank_order "$TMP/out1" s-delta s-bravo s-echo s-alfa s-charlie)" = "s-delta s-bravo s-echo s-alfa s-charlie"
check "строка «Лучшая: s-delta»"                   grep -qE 'Лучшая.*s-delta' "$TMP/out1"
check "команда sudo zapret use s-delta"            has "$TMP/out1" "sudo zapret use s-delta"
check "текущая стратегия s-bravo помечена"         bash -c "grep -E 's-bravo' '$TMP/out1' | grep -qE '\\* *s-bravo|[Тт]екущ'"
check_not "у остальных нет пометки «текущая»"      bash -c "grep -E 's-(alfa|echo|delta|charlie)' '$TMP/out1' | grep -qE '\\* *s-(alfa|echo|delta|charlie)|[Тт]екущ'"
check "базовая линия: DiscordMain открывается без zapret" \
  bash -c "grep -E '[Оо]ткрываются.*без zapret' '$TMP/out1' | grep -q DiscordMain"
check_not "базовая линия: YouTubeWeb не открывается без zapret" \
  bash -c "grep -E '[Оо]ткрываются.*без zapret' '$TMP/out1' | grep -q YouTubeWeb"
check "порты базовой линии 29900-29999 использованы" has_re "$TMP/curl.log" '^299[0-9][0-9]'
check "curl всегда с --local-port"                 bash -c "test -s '$TMP/curl.log' && ! grep -q '^ ' '$TMP/curl.log'"
check "отчёт REPORT создан"                        test -s "$TMP/report.txt"
check "в отчёте есть рейтинг (имена стратегий)"    grep -q 's-delta' "$TMP/report.txt"

section "Не запустившиеся"
check "есть раздел «не запустились»"               grep -qiE 'не запустил' "$TMP/out1"
check "s-foxtrot назван после него"                bash -c "sed -n '/[Нн]е запустил/,\$p' '$TMP/out1' | grep -q s-foxtrot"
check "названа причина (вывод nfqws)"              bash -c "sed -n '/[Нн]е запустил/,\$p' '$TMP/out1' | grep -q 'bad-option'"
check_not "s-foxtrot не получил запросов curl"     grep -qE '^200[5-9][0-9] ' "$TMP/curl.log"
check_not "s-foxtrot не в рейтинге выбран лучшим"  grep -qE 'Лучшая.*s-foxtrot' "$TMP/out1"

section "Очистка и рабочая служба"
check "все процессы nfqws завершены"               all_dead
check "таблица inet zapret_linux_test удалена"     has "$TMP/nft.log" "delete table inet zapret_linux_test"
check "временные каталоги удалены"                 test -z "$(ls -A "$TD")"
check_not "служба не останавливалась и не перезапускалась" grep -qE 'stop|restart' "$TMP/sc.log"

section "Классы ошибок"
strat g-one --filter-tcp=443 --dpi-desync=fake
strat g-two --filter-tcp=443 --dpi-desync=fake
strat g-three --filter-tcp=443 --dpi-desync=fake
strat g-four --filter-tcp=443 --dpi-desync=fake
cat > "$TMP/scen" <<'M'
0 * tls12 cert
1 * tls12 dns
2 * big t16k
3 * http11 refused
M
reset_state
run_st "$TMP/out2" g-one g-two g-three g-four; code=$?
check "завершается с кодом 0"                      test "$code" -eq 0
check "60: сертификат"                             grep -qi 'сертификат' "$TMP/out2"
check "6: DNS"                                     grep -q 'DNS' "$TMP/out2"
check "28 и 16000 байт: обрыв на 16 КБ"            grep -qE 'обрыв[^0-9]*1[56]' "$TMP/out2"
check "7: отказ в соединении"                      grep -qiE 'отказ' "$TMP/out2"

section "Без обхода: правила базовой линии"
grep -E '29900-29999' "$TMP/nft.log.main" > "$TMP/base.rules" 2>/dev/null
check "есть правила для портов 29900-29999 (tcp и udp)" test "$(grep -cE '(tcp|udp).*29900-29999' "$TMP/base.rules")" -ge 2
check "правила ставят метку 0x20000000"            bash -c "grep -c 'meta mark set meta mark or 0x20000000' '$TMP/base.rules' | grep -qv '^0'"
check_not "в правилах базовой линии нет queue"     grep -q 'queue' "$TMP/base.rules"

section "Повтор единичных провалов"
strat r-a --filter-tcp=443 --dpi-desync=fake
strat r-b --filter-tcp=443 --dpi-desync=fake
strat r-c --filter-tcp=443 --dpi-desync=fake
cat > "$TMP/scen" <<'M'
0 discord.com tls12 once:reset
1 * tls12 reset
1 * tls13 reset
1 * http11 reset
2 * big noport
M
reset_state
run_st "$TMP/out3" r-a r-b r-c; code=$?
check "завершается с кодом 0"                      test "$code" -eq 0
[ -n "${ST_KEEP:-}" ] && cp "$TMP/out3" "$ST_KEEP.3" && cp "$TMP/curl.log" "$ST_KEEP.3curl"
check "в выводе «Повторяю единичные провалы»"      has "$TMP/out3" "Повторяю единичные провалы"
check "один провал: задание выполнено дважды"      test "$(grep -c '^20000-20099 discord.com tls12$' "$TMP/curl.log")" -eq 2
check "один провал: остальные задания по одному разу" test "$(grep '^20000-' "$TMP/curl.log" | grep -vc 'discord.com tls12$')" -eq 7
check "результат повтора заменил первый: у r-a 8/8" bash -c "sed -n '/Рейтинг/,/^\$/p' '$TMP/out3' | grep -w r-a | grep -q '8/8'"
check "3 и больше провалов: каждое задание ровно один раз" \
  bash -c "grep '^20100-' '$TMP/curl.log' | sort | uniq -c | awk '\$1 != 1 {bad=1} END {exit bad || NR != 8}'"
check "код 45 не повторяется"                      bash -c "grep '^20200-' '$TMP/curl.log' | sort | uniq -c | awk '\$1 != 1 {bad=1} END {exit bad || NR != 8}'"

section "Скорость от лучшей в группе"
strat v-a --filter-tcp=443 --dpi-desync=fake --dpi-desync-repeats=60
strat v-b --filter-tcp=443 --dpi-desync=fake --dpi-desync-repeats=10
strat v-c --filter-tcp=443 --dpi-desync=multisplit
cat > "$TMP/scen" <<'M'
0 * * ok:0.049
1 * * ok:0.051
2 * * ok:0.120
M
reset_state
run_st "$TMP/out4" v-a v-b v-c; code=$?
check "завершается с кодом 0"                      test "$code" -eq 0
check "49 мс/сложность 60 ниже 51 мс/сложность 10, оба выше 120 мс" \
  test "$(rank_order "$TMP/out4" v-a v-b v-c)" = "v-b v-a v-c"
check "лучшая — v-b"                               grep -qE 'Лучшая.*v-b' "$TMP/out4"

section "Итог по целям: не открылась, частично, только QUIC"
cat > "$TMP/targets5.txt" <<'M'
DiscordMain = "https://discord.com"
YouTubeWeb  = "https://www.youtube.com"
DeadSite    = "https://dead.example"
QuicOnly    = "https://quic.example"
M
strat h-a --filter-tcp=443 --dpi-desync=fake
strat h-b --filter-tcp=443 --dpi-desync=fake
strat h-c --filter-tcp=443 --dpi-desync=fake
cat > "$TMP/scen" <<'M'
* dead.example * timeout
* quic.example tls12 timeout
* quic.example tls13 timeout
* quic.example http11 timeout
* quic.example big timeout
1 www.youtube.com * timeout
0 www.youtube.com tls12 reset
* discord.com h3 timeout
M
reset_state
TARGETS_FILE_T="$TMP/targets5.txt" MOCK_CURL_H3=1 run_st "$TMP/out5" h-a h-b h-c; code=$?
check "завершается с кодом 0"                      test "$code" -eq 0
[ -n "${ST_KEEP:-}" ] && cp "$TMP/out5" "$ST_KEEP.5"
check "проверка h3 выполнялась"                    has_re "$TMP/curl.log" 'discord.com h3$'
check "лучшая — h-c"                               grep -qE 'Лучшая.*h-c' "$TMP/out5"
grep '^  не открылись' "$TMP/out5" > "$TMP/l.nf"
grep '^  открылись по TCP, но не по QUIC' "$TMP/out5" > "$TMP/l.q"
check "есть строка «не открылись» с DeadSite"      has "$TMP/l.nf" DeadSite
check_not "цель с провалом только h3 не в строке «не открылись»" has "$TMP/l.nf" DiscordMain
check "цель с провалом только h3: «по TCP, но не по QUIC»" has "$TMP/l.q" DiscordMain
check_not "в «не по QUIC» нет целей с провалом TCP" has "$TMP/l.q" DeadSite
grep 'Ни с одной стратегией не открылись' "$TMP/out5" > "$TMP/l.no"
check "«Ни с одной…»: DeadSite"                    has "$TMP/l.no" DeadSite
check "«Ни с одной…»: h3 не считается (QuicOnly)"  has "$TMP/l.no" QuicOnly
check_not "«Ни с одной…»: нет DiscordMain"         has "$TMP/l.no" DiscordMain
check_not "«Ни с одной…»: нет YouTubeWeb (открылся у h-c)" has "$TMP/l.no" YouTubeWeb

section "Главные проблемы: порядок «провал, частично, только QUIC»"
strat p-a --filter-tcp=443 --dpi-desync=fake
strat p-b --filter-tcp=443 --dpi-desync=fake
cat > "$TMP/scen" <<'M'
* discord.com h3 timeout
1 www.youtube.com * timeout
0 www.youtube.com tls12 reset
M
reset_state
MOCK_CURL_H3=1 run_st "$TMP/out6" p-a p-b; code=$?
check "завершается с кодом 0"                      test "$code" -eq 0
sed -n '/Рейтинг/,/^$/p' "$TMP/out6" > "$TMP/rt6"
check "p-a: «частично (3/4 по TCP, …)»"            bash -c "grep -w p-a '$TMP/rt6' | grep -q 'YouTubeWeb: частично (3/4 по TCP, '"
check "p-a: «DiscordMain: только QUIC»"            bash -c "grep -w p-a '$TMP/rt6' | grep -q 'DiscordMain: только QUIC (таймаут)'"
check "p-a: частично раньше только QUIC (хотя Discord первый в списке)" \
  bash -c "grep -w p-a '$TMP/rt6' | grep -qE 'частично.*только QUIC'"
check "p-b: провал раньше только QUIC"             bash -c "grep -w p-b '$TMP/rt6' | grep -qE 'YouTubeWeb: таймаут.*DiscordMain: только QUIC'"

section "Прерывание"
cat > "$TMP/intr.py" <<'P'
import os, signal, subprocess, sys, time, glob
sig = getattr(signal, sys.argv[1])
nq = os.environ["MOCK_NFQWS_DIR"]
p = subprocess.Popen(["bash", sys.argv[2]] + sys.argv[3:], stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
t = time.time()
while time.time() - t < 20 and len(glob.glob(nq + "/*.pid")) < 2:
    time.sleep(0.1)
time.sleep(0.5)
p.send_signal(sig)
try:
    p.wait(timeout=20)
except subprocess.TimeoutExpired:
    p.kill(); sys.exit(99)
sys.exit(0)
P
for sg in SIGINT SIGTERM; do
  cat > "$TMP/scen" <<'M'
* * * ok:0.100
M
  reset_state
  env PATH="$MB:$MOCK:$PATH" TMPDIR="$TD" OPT_DIR="$OPT" ETC_DIR="$ETC" \
    NFQWS_BIN="$MB/nfqws" TARGETS_FILE="$TMP/targets.txt" TIMEOUT=5 CONNECT_TIMEOUT=3 \
    PARALLEL=8 QBASE=210 PBASE=20000 REPORT="$TMP/report.txt" APPLY="$MB/apply-stub" \
    STUB_DIR="$SD" MOCK_SCEN="$TMP/scen" MOCK_NFT_LOG="$TMP/nft.log" \
    MOCK_NFQWS_DIR="$NQ" MOCK_CURL_LOG="$TMP/curl.log" MOCK_SYSTEMCTL_LOG="$TMP/sc.log" \
    MOCK_CURL_SLEEP=4 MOCK_CURL_STATE="$TMP/cstate" \
    python3 -I "$TMP/intr.py" "$sg" "$ROOT/selftest.sh" g-one g-two g-three; code=$?
  check "$sg: selftest завершился сам"             test "$code" -eq 0
  check "$sg: nfqws успел запуститься"             test "$(ls "$NQ"/*.pid 2>/dev/null | wc -l)" -ge 2
  check "$sg: все процессы nfqws завершены"        all_dead
  check "$sg: таблица тестов удалена"              has "$TMP/nft.log" "delete table inet zapret_linux_test"
  check "$sg: временные каталоги удалены"          test -z "$(ls -A "$TD")"
  check_not "$sg: служба не трогалась"             grep -qE 'stop|restart' "$TMP/sc.log"
done
# дочерние sleep макета curl и nfqws не оставляем
for f in "$NQ"/*.pid; do [ -e "$f" ] && kill "$(cat "$f")" 2>/dev/null; done; true

finish
