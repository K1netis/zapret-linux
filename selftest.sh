#!/usr/bin/env bash
# selftest.sh — проверка всех стратегий сразу и рейтинг от лучшей к худшей.
#
#   sudo ./selftest.sh                 все стратегии из strategies/
#   sudo ./selftest.sh general alt2    только перечисленные
#
# Как это работает. Для каждой стратегии i запускается свой nfqws на очереди
# QBASE+i (по умолчанию 210+i). Рабочая служба не останавливается и не
# меняется: отдельная таблица nftables inet zapret_linux_test с хуком
# postrouting (приоритет mangle - 1, то есть раньше рабочей) отправляет в
# очередь стратегии i только пакеты с исходящими портами PBASE+i*100 ...
# PBASE+i*100+99 (первые 6 пакетов соединения). curl привязывается к этому
# диапазону через --local-port, поэтому каждое соединение обрабатывает ровно
# одна стратегия. Пакет, вернувшийся из nfqws, помечается 0x20000000 — по этой
# метке рабочие правила службы его пропускают и не обрабатывают второй раз.
# Базовая линия «без обхода» — порты 29900-29999 без правил.
#
# Для каждой стратегии и каждой цели из targets.txt выполняются проверки
# tls12, tls13, http11, big (первые 64 КБ: ловит обрыв соединения на 16-20 КБ)
# и h3 (QUIC, если curl его умеет). Задания перемешиваются и выполняются
# пулом из PARALLEL процессов. Порядок рейтинга: больше пройденных проверок,
# затем быстрее (медиана времени установки TLS, корзины по 50 мс), затем
# проще (меньше «сложность»), затем имя.
set -uo pipefail

export LC_NUMERIC=C
OPT_DIR="${OPT_DIR:-/opt/zapret-linux}"
ETC_DIR="${ETC_DIR:-/etc/zapret-linux}"
NFQWS_BIN="${NFQWS_BIN:-$OPT_DIR/nfqws}"
TARGETS_FILE="${TARGETS_FILE:-$OPT_DIR/targets.txt}"
TIMEOUT="${TIMEOUT:-5}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-3}"
PARALLEL="${PARALLEL:-32}"
QBASE="${QBASE:-210}"
PBASE="${PBASE:-20000}"
REPORT="${REPORT:-$ETC_DIR/test-report.txt}"
APPLY="${APPLY:-$OPT_DIR/apply-strategy.sh}"
TABLE_NAME="zapret_linux_test"
MAX_STRATEGIES=99
BASE_NAME="без обхода"

if [ -t 1 ]; then
  C_OK=$'\033[1;32m'; C_BAD=$'\033[1;31m'; C_WARN=$'\033[1;33m'; C_HDR=$'\033[1;36m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_BAD=""; C_WARN=""; C_HDR=""; C_OFF=""
fi
hdr() { printf '\n%s== %s ==%s\n' "$C_HDR" "$1" "$C_OFF"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

TMP=""
TABLE_CREATED=0
POOL_PID=""
PIDS=()
CLEANED=0

cleanup() {
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  local p
  if [ -n "$POOL_PID" ]; then
    kill "$POOL_PID" 2>/dev/null
  fi
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  sleep 0.2
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] || continue
    kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
    wait "$p" 2>/dev/null
  done
  if [ "$TABLE_CREATED" = 1 ]; then
    nft delete table inet "$TABLE_NAME" >/dev/null 2>&1
  fi
  [ -n "$TMP" ] && rm -rf "$TMP"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 1) Окружение ----------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "нужны права root: sudo zapret test"
for v in TIMEOUT CONNECT_TIMEOUT PARALLEL QBASE PBASE; do
  case "${!v}" in ''|*[!0-9]*) die "$v должно быть числом, а не '${!v}'" ;; esac
done
[ "$PARALLEL" -ge 1 ] || die "PARALLEL должно быть не меньше 1"
command -v nft >/dev/null 2>&1 || die "нужен nft (nftables)"
command -v curl >/dev/null 2>&1 || die "нужен curl"
[ -x "$NFQWS_BIN" ] || die "не найден исполняемый nfqws: $NFQWS_BIN"
[ -r "$TARGETS_FILE" ] || die "не найден список целей: $TARGETS_FILE"
[ -x "$APPLY" ] || die "не найден apply-strategy.sh: $APPLY"

# 2) Список стратегий ---------------------------------------------------------
names=()
if [ "$#" -gt 0 ]; then
  names=("$@")
else
  for f in "$OPT_DIR"/strategies/*.conf; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    names+=("${b%.conf}")
  done
fi
[ "${#names[@]}" -gt 0 ] || die "не найдено ни одной стратегии (каталог $OPT_DIR/strategies пуст?)"
[ "${#names[@]}" -le "$MAX_STRATEGIES" ] || die "стратегий больше $MAX_STRATEGIES — проверьте меньше за один раз"

TMP="$(mktemp -d)" || die "не удалось создать временный каталог"
mkdir -p "$TMP/res"

START_TIME="$(date +%s)"

# S_* — стратегии, которые применились (индекс i задаёт очередь и порты);
# BAD_* — не применились или не запустились.
S_NAME=(); BAD_NAME=(); BAD_WHY=()
for name in "${names[@]}"; do
  case "$name" in -*|'') BAD_NAME+=("$name"); BAD_WHY+=("недопустимое имя"); continue ;; esac
  i="${#S_NAME[@]}"
  err="$("$APPLY" --print-args "$name" 2>&1 >"$TMP/args.$i")"
  rc=$?
  if [ "$rc" != 0 ]; then
    BAD_NAME+=("$name"); BAD_WHY+=("не применяется: $(printf '%s\n' "$err" | head -n 1)")
  elif [ ! -s "$TMP/args.$i" ]; then
    BAD_NAME+=("$name"); BAD_WHY+=("не применяется: пустой список аргументов")
  else
    S_NAME+=("$name")
  fi
done
[ "${#S_NAME[@]}" -gt 0 ] || {
  for i in "${!BAD_NAME[@]}"; do echo "  ${BAD_NAME[$i]}: ${BAD_WHY[$i]}" >&2; done
  die "ни одна стратегия не применяется"
}
NS="${#S_NAME[@]}"

# 3) Таблица nftables ---------------------------------------------------------
if nft list table inet "$TABLE_NAME" >/dev/null 2>&1; then
  nft delete table inet "$TABLE_NAME" >/dev/null 2>&1   # остаток прошлого запуска
fi
RULES="$TMP/rules.nft"
{
  echo "add table inet $TABLE_NAME"
  echo "add chain inet $TABLE_NAME post { type filter hook postrouting priority mangle - 1; policy accept; }"
  for ((i = 0; i < NS; i++)); do
    a=$((PBASE + i * 100)); b=$((a + 99)); q=$((QBASE + i))
    for proto in tcp udp; do
      echo "add rule inet $TABLE_NAME post meta l4proto $proto $proto sport $a-$b ct original packets 1-6 meta mark and 0x40000000 != 0x40000000 meta mark set meta mark or 0x20000000 counter queue num $q bypass"
    done
  done
  # без обхода: только метка, без очереди — иначе эти пакеты обработала бы
  # рабочая служба, и «без обхода» на деле проверяло бы текущую стратегию
  a=$((PBASE + 9900)); b=$((a + 99))
  for proto in tcp udp; do
    echo "add rule inet $TABLE_NAME post meta l4proto $proto $proto sport $a-$b meta mark set meta mark or 0x20000000 counter"
  done
} > "$RULES"
TABLE_CREATED=1
nft -f "$RULES" || die "не удалось создать таблицу nftables $TABLE_NAME (нет поддержки nft queue в ядре?)"

# 4) Запуск nfqws на каждую стратегию -----------------------------------------
for ((i = 0; i < NS; i++)); do
  mapfile -t args < "$TMP/args.$i"
  "$NFQWS_BIN" --qnum="$((QBASE + i))" --dpi-desync-fwmark=0x40000000 "${args[@]}" \
    >"$TMP/nfqws.$i.log" 2>&1 &
  PIDS[$i]=$!
done

sleep 1
# если ядро показывает привязанные очереди — ждём, пока nfqws их займут
QFILE=/proc/net/netfilter/nfnetlink_queue
if [ -r "$QFILE" ]; then
  for _ in $(seq 1 40); do
    miss=0
    for ((i = 0; i < NS; i++)); do
      kill -0 "${PIDS[$i]}" 2>/dev/null || continue
      awk -v q="$((QBASE + i))" '$1 == q {f = 1} END {exit !f}' "$QFILE" || miss=1
    done
    [ "$miss" = 0 ] && break
    sleep 0.1
  done
fi

STARTED=()
for ((i = 0; i < NS; i++)); do
  if kill -0 "${PIDS[$i]}" 2>/dev/null; then
    STARTED[$i]=1
  else
    STARTED[$i]=0
    last="$(grep -v '^[[:space:]]*$' "$TMP/nfqws.$i.log" 2>/dev/null | tail -n 1)"
    BAD_NAME+=("${S_NAME[$i]}"); BAD_WHY+=("nfqws не запустился${last:+: $last}")
  fi
done

# 5) Цели и задания -----------------------------------------------------------
T_NAME=(); T_URL=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]] || continue
  case "${BASH_REMATCH[2]}" in
    https://*|http://*) T_NAME+=("${BASH_REMATCH[1]}"); T_URL+=("${BASH_REMATCH[2]}") ;;
  esac
done < "$TARGETS_FILE"
NT="${#T_NAME[@]}"
[ "$NT" -gt 0 ] || die "в $TARGETS_FILE нет ни одной цели"

CHECKS=(tls12 tls13 http11 big)
H3=0
if curl -V 2>/dev/null | grep -E '^Features:' | grep -qwE 'HTTP3'; then
  CHECKS+=(h3); H3=1
fi
NC="${#CHECKS[@]}"

check_opts() { # проверка -> массив CO
  case "$1" in
    tls12)  CO=(-I --tlsv1.2 --tls-max 1.2) ;;
    tls13)  CO=(-I --tlsv1.3 --tls-max 1.3) ;;
    http11) CO=(-I --http1.1) ;;
    big)    CO=(--range 0-65535) ;;
    h3)     CO=(-I --http3-only) ;;
    *)      CO=() ;;
  esac
}

run_job() { # номер стратегия(-1 = без обхода) цель проверка
  local n="$1" s="$2" t="$3" c="$4" a b out
  if [ "$s" -lt 0 ]; then a=$((PBASE + 9900)); else a=$((PBASE + s * 100)); fi
  b=$((a + 99))
  check_opts "$c"
  out="$(curl -s -o /dev/null --noproxy '*' --connect-timeout "$CONNECT_TIMEOUT" -m "$TIMEOUT" \
        --local-port "$a-$b" -w '%{http_code} %{time_appconnect} %{time_total} %{size_download}' \
        "${CO[@]}" "${T_URL[$t]}" 2>/dev/null)"
  local rc=$?
  [ -n "$out" ] || out="000 0 0 0"
  printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$t" "$c" "$rc" "$out" > "$TMP/res/$n"
}

JOBS="$TMP/jobs"
: > "$JOBS"
n=0
for ((s = -1; s < NS; s++)); do
  if [ "$s" -ge 0 ] && [ "${STARTED[$s]}" != 1 ]; then continue; fi
  for ((t = 0; t < NT; t++)); do
    for c in "${CHECKS[@]}"; do
      n=$((n + 1))
      printf '%s\t%s\t%s\t%s\n' "$n" "$s" "$t" "$c" >> "$JOBS"
    done
  done
done
NJOBS="$n"

if command -v shuf >/dev/null 2>&1; then shuf "$JOBS" > "$JOBS.mix"; else sort -R "$JOBS" > "$JOBS.mix"; fi

echo "Проверяю: стратегий ${#S_NAME[@]}, целей $NT, проверок на стратегию $NC (всего заданий $NJOBS), параллельно $PARALLEL ..."

# пул заданий в отдельном процессе: так wait -n не путает задания с nfqws
(
  trap 'kill $(jobs -p) 2>/dev/null; exit 143' TERM
  running=0
  while IFS=$'\t' read -r jn js jt jc; do
    if [ "$running" -ge "$PARALLEL" ]; then
      wait -n
      running=$((running - 1))
    fi
    run_job "$jn" "$js" "$jt" "$jc" &
    running=$((running + 1))
  done < "$JOBS.mix"
  wait
) &
POOL_PID=$!
wait "$POOL_PID"
POOL_PID=""

# Повтор: один-два провала у стратегии — скорее случайность сети, чем
# блокировка; такие проверки выполняются ещё раз. Стратегии с большим числом
# провалов не повторяются: время проверки не растёт.
failed_of() { # стратегия -> номера проваленных заданий (кроме «нет порта»)
  local f s rc
  for f in "$TMP"/res/*; do
    IFS=$'\t' read -r s _ _ rc _ < "$f"
    [ "$s" = "$1" ] && [ "$rc" != 0 ] && [ "$rc" != 45 ] && echo "${f##*/}"
  done
}
: > "$JOBS.retry"
for ((s = 0; s < NS; s++)); do
  [ "${STARTED[$s]}" = 1 ] || continue
  mapfile -t fl < <(failed_of "$s")
  if [ "${#fl[@]}" -ge 1 ] && [ "${#fl[@]}" -le 2 ]; then
    for k in "${fl[@]}"; do awk -F'\t' -v k="$k" '$1 == k' "$JOBS" >> "$JOBS.retry"; done
  fi
done
if [ -s "$JOBS.retry" ]; then
  echo "Повторяю единичные провалы: $(wc -l < "$JOBS.retry") ..."
  (
    trap 'kill $(jobs -p) 2>/dev/null; exit 143' TERM
    while IFS=$'\t' read -r jn js jt jc; do run_job "$jn" "$js" "$jt" "$jc" & done < "$JOBS.retry"
    wait
  ) &
  POOL_PID=$!
  wait "$POOL_PID"
  POOL_PID=""
fi


# 6) Классы ошибок ------------------------------------------------------------
ALL="$TMP/all.tsv"
: > "$ALL"
for ((k = 1; k <= NJOBS; k++)); do
  [ -f "$TMP/res/$k" ] || continue
  IFS=$'\t' read -r rs rt rc_ rrc rest < "$TMP/res/$k"
  read -r code tconn ttotal size <<< "$rest"
  : "${code:=000}" "${tconn:=0}" "${ttotal:=0}" "${size:=0}"
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  status=fail
  case "$rrc" in
    0)  case "$code" in 000|''|*[!0-9]*) cls="прочее: нет HTTP-кода" ;; *) status=ok; cls="OK" ;; esac ;;
    6)  cls="DNS не отвечает" ;;
    7)  cls="отказ в соединении" ;;
    28) if [ "$size" -gt 0 ]; then cls="обрыв на $(((size + 512) / 1024)) КБ"; else cls="таймаут"; fi ;;
    35) cls="ошибка TLS" ;;
    52|56) cls="сброс соединения" ;;
    51|60) cls="сертификат (подмена DNS?)" ;;
    45) cls="нет порта"; status=skip ;;
    *)  cls="ошибка curl $rrc" ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$rs" "${T_NAME[$rt]}" "$rc_" "$rrc" "$code" "$tconn" "$ttotal" "$size" "$status" "$cls" >> "$ALL"
done
# столбцы: 1 стратегия, 2 цель, 3 проверка, 4 код curl, 5 HTTP, 6 appconnect,
#          7 total, 8 размер, 9 статус (ok/fail/skip), 10 класс

# 7) Сложность и рейтинг ------------------------------------------------------
complexity() { # файл аргументов -> число
  awk '
    function close_profile() { total += rep * fk; rep = 1; fk = 0 }
    BEGIN { rep = 1; fk = 0; total = 0 }
    $0 == "--new" { close_profile(); next }
    index($0, "--dpi-desync-repeats=") == 1 {
      v = substr($0, 22); if (v ~ /^[0-9]+$/) rep = v + 0; next }
    index($0, "--dpi-desync=") == 1 {
      m = split(substr($0, 14), parts, ","); fk = 0
      for (j = 1; j <= m; j++) if (parts[j] ~ /fake/) fk++
      next }
    END { close_profile(); print total }
  ' "$1"
}

# Итог по целям одной стратегии: строка «цель<TAB>вид<TAB>причина» на каждую
# цель с проблемами. Вид: fail — не открылась ни одним способом по TCP;
# part — часть проверок TCP не прошла; quic — по TCP всё открылось, не прошёл
# только QUIC (браузер в этом случае сам переходит на TCP). Порядок: fail,
# part, quic — сначала то, что действительно не работает.
target_issues() { # стратегия
  awk -F'\t' -v s="$1" -v OFS='\t' '
    $1 != s || $9 == "skip" { next }
    !($2 in seen) { seen[$2] = 1; order[++n] = $2 }
    $3 == "h3" { h3[$2] = $9; if ($9 == "fail") h3c[$2] = $10; next }
    { tt[$2]++; if ($9 == "ok") to[$2]++; else if (!($2 in tc)) tc[$2] = $10 }
    END {
      for (r = 1; r <= 3; r++) for (k = 1; k <= n; k++) {
        t = order[k]; v = ""
        if (tt[t] > 0 && to[t] + 0 == 0) { v = "fail"; c = tc[t] }
        else if (to[t] + 0 < tt[t]) { v = "part"; c = (to[t] + 0) "/" tt[t] " по TCP, " tc[t] }
        else if (h3[t] == "fail") { v = "quic"; c = h3c[t] }
        if ((r == 1 && v == "fail") || (r == 2 && v == "part") || (r == 3 && v == "quic")) print t, v, c
      }
    }' "$ALL"
}
issue_text() { # вид причина -> текст
  case "$1" in
    fail) printf '%s' "$2" ;;
    part) printf 'частично (%s)' "$2" ;;
    quic) printf 'только QUIC (%s)' "$2" ;;
  esac
}

CURRENT=""
if [ -f "$ETC_DIR/active.env" ]; then
  CURRENT="$( . "$ETC_DIR/active.env" 2>/dev/null; echo "${STRATEGY_FILE:-}" )"
fi

RANK_RAW="$TMP/rank.raw"
: > "$RANK_RAW"
for ((i = 0; i < NS; i++)); do
  [ "${STARTED[$i]}" = 1 ] || continue
  read -r pass total < <(awk -F'\t' -v s="$i" '$1 == s && $9 != "skip" {t++; if ($9 == "ok") p++} END {print p + 0, t + 0}' "$ALL")
  med="$(awk -F'\t' -v s="$i" '$1 == s && $9 == "ok" && $3 != "h3" && $6 > 0 {printf "%d\n", $6 * 1000 + 0.5}' "$ALL" \
        | sort -n | awk '{a[NR] = $1} END {if (NR == 0) print -1; else if (NR % 2) print a[(NR + 1) / 2]; else print int((a[NR / 2] + a[NR / 2 + 1]) / 2)}')"
  if [ "$med" -lt 0 ]; then bucket=999999; else bucket="$med"; fi   # корзина — ниже
  cx="$(complexity "$TMP/args.$i")"
  probs=""; c=0
  while IFS=$'\t' read -r it iv ic; do
    c=$((c + 1))
    [ "$c" -le 2 ] && probs="${probs:+$probs; }$it: $(issue_text "$iv" "$ic")"
  done < <(target_issues "$i")
  [ "$c" -gt 2 ] && probs="$probs (+$((c - 2)))"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pass" "$bucket" "$cx" "${S_NAME[$i]}" "$i" "$med" "$total" "$probs" >> "$RANK_RAW"
done
# Скорость сравнивается от лучшей среди стратегий с тем же числом пройденных
# проверок: кто в пределах 50 мс от неё — считаются равными, дальше решает
# простота. Так нет случайной границы между, например, 49 и 50 мс.
awk -F'\t' -v OFS='\t' '
  NR == FNR { if ($2 < 999999 && (!($1 in best) || $2 < best[$1])) best[$1] = $2; next }
  { if ($2 < 999999) $2 = int(($2 - best[$1]) / 50); print }
' "$RANK_RAW" "$RANK_RAW" > "$RANK_RAW.b"
LC_ALL=C sort -t $'\t' -k1,1nr -k2,2n -k3,3n -k4,4 "$RANK_RAW.b" > "$TMP/rank.sorted"

END_TIME="$(date +%s)"
ELAPSED=$((END_TIME - START_TIME))

# printf считает ширину в байтах, а кириллица занимает по два — дополняем сами
pad() { local w="$1" t="$2"; printf '%s' "$t"; while [ "${#t}" -lt "$w" ]; do t="$t "; printf ' '; done; }

RANK_TXT="$TMP/rank.txt"
{
  printf '%s %s %s %s %s %s\n' "$(pad 4 "№")" "$(pad 30 "стратегия")" "$(pad 9 "пройдено")" \
    "$(pad 7 "время")" "$(pad 6 "слож.")" "главные проблемы"
  place=0
  while IFS=$'\t' read -r pass bucket cx name idx med total probs; do
    place=$((place + 1))
    mark=" "; cur=""
    if [ "$name" = "$CURRENT" ]; then mark="*"; cur="  <- текущая"; fi
    if [ "$med" -lt 0 ]; then ms="-"; else ms="$med мс"; fi
    printf '%-4s %s%-29s %-9s %s %-6s %s\n' "$place" "$mark" "$name" "$pass/$total" "$(pad 7 "$ms")" "$cx" "$probs$cur"
  done < "$TMP/rank.sorted"
} > "$RANK_TXT"

# 8) Вывод --------------------------------------------------------------------
HEAD_TXT="$TMP/head.txt"
{
  echo "Проверено стратегий: ${#S_NAME[@]}; целей: $NT; проверок на стратегию: $NC; время работы: $ELAPSED с"
  [ "$H3" = 1 ] || echo "curl без поддержки HTTP/3: QUIC не проверялся (в браузере YouTube ходит по QUIC)."
} > "$HEAD_TXT"

BASE_TXT="$TMP/base.txt"
{
  open=""; blocked=""; part=""
  for ((t = 0; t < NT; t++)); do
    read -r bo bt < <(awk -F'\t' -v s=-1 -v t="${T_NAME[$t]}" '$1 == s && $2 == t && $9 != "skip" {n++; if ($9 == "ok") o++} END {print o + 0, n + 0}' "$ALL")
    if [ "$bt" -eq 0 ]; then continue
    elif [ "$bo" -eq "$bt" ]; then open="${open:+$open, }${T_NAME[$t]}"
    elif [ "$bo" -eq 0 ]; then blocked="${blocked:+$blocked, }${T_NAME[$t]}"
    else part="${part:+$part, }${T_NAME[$t]} ($bo/$bt)"
    fi
  done
  echo "цели, которые открываются и без zapret (мало говорят о стратегиях): ${open:-нет}"
  [ -z "$part" ] || echo "цели, которые открываются без zapret частично: $part"
  echo "цели, заблокированные без zapret: ${blocked:-нет}"
} > "$BASE_TXT"

SUMMARY="$TMP/summary.txt"
{
  if [ -s "$TMP/rank.sorted" ]; then
    IFS=$'\t' read -r bpass bbucket bcx bname bidx bmed btotal bprobs < <(head -n 1 "$TMP/rank.sorted")
    if [ "$bpass" -eq 0 ]; then
      echo "${C_BAD}Ни одна стратегия не открыла ни одной цели.${C_OFF} Проверьте сеть и DNS; возможно, нужна другая стратегия или игровой фильтр."
    else
      if [ "$bname" = "$CURRENT" ]; then
        echo "${C_OK}Лучшая: $bname — это текущая стратегия, менять ничего не нужно.${C_OFF}"
      else
        echo "${C_OK}Лучшая: $bname — применить: sudo zapret use $bname${C_OFF}"
      fi
      if [ "$bpass" -lt "$btotal" ]; then
        echo "У неё пройдено $bpass из $btotal."
        nf=""; np=""; nq=""
        while IFS=$'\t' read -r it iv ic; do
          case "$iv" in
            fail) nf="${nf:+$nf, }$it ($ic)" ;;
            part) np="${np:+$np, }$it ($(issue_text "$iv" "$ic"))" ;;
            quic) nq="${nq:+$nq, }$it" ;;
          esac
        done < <(target_issues "$bidx")
        [ -z "$nf" ] || echo "  не открылись: $nf"
        [ -z "$np" ] || echo "  открылись не всеми способами: $np"
        [ -z "$nq" ] || echo "  открылись по TCP, но не по QUIC: $nq — браузер в этом случае сам переходит на TCP, сайт работает"
      fi
    fi
  fi
  nowhere=""
  for ((t = 0; t < NT; t++)); do
    any="$(awk -F'\t' -v t="${T_NAME[$t]}" '$1 >= 0 && $2 == t && $3 != "h3" && $9 == "ok" {f = 1} END {print f + 0}' "$ALL")"
    [ "$any" = 1 ] || nowhere="${nowhere:+$nowhere, }${T_NAME[$t]}"
  done
  if [ -n "$nowhere" ]; then
    echo "Ни с одной стратегией не открылись: $nowhere — дело, скорее всего, не в стратегии (блокировка по адресу или сам адрес недоступен)."
  fi
  nbad="$(awk -F'\t' '$9 == "fail" && ($4 == 51 || $4 == 60 || $4 == 6) {n++} END {print n + 0}' "$ALL")"
  nall="$(awk -F'\t' '$9 != "skip" {n++} END {print n + 0}' "$ALL")"
  if [ "$nbad" -ge 3 ] && [ $((nbad * 10)) -ge "$nall" ]; then
    echo "${C_WARN}Много ошибок сертификата или DNS ($nbad из $nall): похоже, провайдер подменяет DNS-ответы."
    echo "Настройте DNS поверх HTTPS или TLS (DoH/DoT) в системе — иначе стратегии не помогут.${C_OFF}"
  fi
  gf="$(cat "$ETC_DIR/gamefilter" 2>/dev/null || echo off)"
  if [ "$gf" = off ]; then
    echo "Игровой фильтр выключен: голос Discord (UDP) может не работать. Попробуйте: sudo zapret game udp (или all)"
  fi
} > "$SUMMARY"

BAD_TXT="$TMP/bad.txt"
: > "$BAD_TXT"
for i in "${!BAD_NAME[@]}"; do
  printf '  %s: %s\n' "${BAD_NAME[$i]}" "${BAD_WHY[$i]}" >> "$BAD_TXT"
done

hdr "Итоги проверки"
cat "$HEAD_TXT"
hdr "Без обхода"
cat "$BASE_TXT"
hdr "Рейтинг стратегий (* — текущая)"
cat "$RANK_TXT"
if [ -s "$BAD_TXT" ]; then
  hdr "Не запустились / не применяются"
  cat "$BAD_TXT"
fi
echo
cat "$SUMMARY"

# полный отчёт: без цветов
mkdir -p "$(dirname "$REPORT")" 2>/dev/null
if {
  echo "zapret test — $(date '+%Y-%m-%d %H:%M:%S')"
  cat "$HEAD_TXT"
  echo; echo "== Без обхода =="; cat "$BASE_TXT"
  echo; echo "== Рейтинг (* — текущая) =="; cat "$RANK_TXT"
  if [ -s "$BAD_TXT" ]; then echo; echo "== Не запустились / не применяются =="; cat "$BAD_TXT"; fi
  echo; echo "== Итог =="; sed 's/\x1b\[[0-9;]*m//g' "$SUMMARY"
  echo; echo "== Все результаты (стратегия, цель, проверка, класс, HTTP, appconnect, total, байт) =="
  while IFS=$'\t' read -r rs rtn rcheck rcurl rcode rconn rtot rsize rstat rcls; do
    if [ "$rs" -lt 0 ]; then sn="$BASE_NAME"; else sn="${S_NAME[$rs]}"; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sn" "$rtn" "$rcheck" "$rcls" "$rcode" "$rconn" "$rtot" "$rsize"
  done < "$ALL"
} > "$REPORT" 2>/dev/null; then
  echo
  echo "Полный отчёт: $REPORT"
else
  echo "Не удалось записать отчёт в $REPORT" >&2
fi
exit 0
