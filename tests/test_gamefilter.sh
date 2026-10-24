#!/usr/bin/env bash
# gamefilter.sh: режимы и настраиваемые порты игрового фильтра.
. "$(dirname "$0")/lib.sh"
OPT="$TMP/opt"; ETC="$TMP/etc"; mkdir -p "$ETC"
make_opt "$OPT"
apply test >/dev/null 2>&1
gf() { OPT_DIR="$OPT" ETC_DIR="$ETC" mocked bash "$ROOT/gamefilter.sh" "$@"; }
# gamefilter.sh ищет apply-strategy.sh в OPT_DIR — кладём ссылку на настоящий
ln -sf "$ROOT/apply-strategy.sh" "$OPT/apply-strategy.sh"

section "Проверка портов"
for bad in "abc" "70000" "0" "100-50" "1024-" "-80" "1024--2000" "80, 443" "80,,443" ""; do
  check_not "отклоняется '$bad'" gf ports tcp "$bad"
done
for good in "443" "1024-65535" "1024-1934,1936-65535" "80,443,1000-2000"; do
  check "принимается '$good'" gf ports tcp "$good"
done

section "Сохранение и сброс"
gf ports tcp 1024-1934,1936-65535 >/dev/null 2>&1
check "порты записаны"            has "$ETC/gamefilter-ports" "TCP=1024-1934,1936-65535"
gf ports udp 2000-3000 >/dev/null 2>&1
check "TCP не затёрт при смене UDP" has "$ETC/gamefilter-ports" "TCP=1024-1934,1936-65535"
gf ports reset >/dev/null 2>&1
check "сброс возвращает 1024-65535" has "$ETC/gamefilter-ports" "TCP=1024-65535"

section "Режимы"
gf all >/dev/null 2>&1
check "режим сохранён"             has "$ETC/gamefilter" "all"
. "$ETC/active.env"
check "стратегия переприменена"    test "$GAMEFILTER_MODE" = all
check_not "неизвестный режим — ошибка" gf turbo

section "Предупреждение: игровой фильтр при IPSet none"
W="не действует ни на один адрес"
gfw() { # режим-ipset (- = нет файла) аргументы gamefilter.sh...; stderr в $TMP/w.err, stdout в $TMP/w.out
  local ips="$1"; shift
  rm -f "$ETC/ipsetfilter"; [ "$ips" = - ] || echo "$ips" > "$ETC/ipsetfilter"
  gf "$@" >"$TMP/w.out" 2>"$TMP/w.err"
}
for m in tcp udp all; do
  gfw none "$m"; rc=$?
  check "$m + IPSet none: предупреждение в stderr"  has "$TMP/w.err" "$W"
  check "$m + IPSet none: совет sudo zapret ipset loaded" has "$TMP/w.err" "sudo zapret ipset loaded"
  check "$m + IPSet none: режим сохранён"           has "$ETC/gamefilter" "$m"
  check "$m + IPSet none: код возврата 0, стратегия применена" test "$rc" -eq 0
  check "$m + IPSet none: переприменение идёт"      has "$TMP/w.out" "переприменяю"
  check_not "$m + IPSet none: предупреждение не в stdout" has "$TMP/w.out" "$W"
done
gfw - udp
check "udp, файла ipsetfilter нет: предупреждение" has "$TMP/w.err" "$W"
check "udp, файла ipsetfilter нет: режим сохранён" has "$ETC/gamefilter" "udp"
gfw none off
check_not "off + IPSet none: предупреждения нет"   has "$TMP/w.err" "$W"
check "off: режим сохранён"                        has "$ETC/gamefilter" "off"
for ips in loaded any; do
  gfw "$ips" all
  check_not "all + IPSet $ips: предупреждения нет" has "$TMP/w.err" "$W"
done

section "status при IPSet none"
gfw none udp
rm -f "$ETC/ipsetfilter"; echo none > "$ETC/ipsetfilter"
gf status >"$TMP/s.out" 2>"$TMP/s.err"
check "status, udp + IPSet none: предупреждение в stdout" has "$TMP/s.out" "$W"
check "status: совет sudo zapret ipset loaded"     has "$TMP/s.out" "sudo zapret ipset loaded"
echo loaded > "$ETC/ipsetfilter"
gf status >"$TMP/s.out" 2>"$TMP/s.err"
check_not "status, udp + IPSet loaded: предупреждения нет" has "$TMP/s.out" "$W"
gfw none off
echo none > "$ETC/ipsetfilter"
gf status >"$TMP/s.out" 2>"$TMP/s.err"
check_not "status, off + IPSet none: предупреждения нет" has "$TMP/s.out" "$W"
rm -f "$ETC/ipsetfilter"
gfw none all >/dev/null 2>&1; rm -f "$ETC/ipsetfilter"
gf status >"$TMP/s.out" 2>"$TMP/s.err"
check "status, файла ipsetfilter нет: предупреждение" has "$TMP/s.out" "$W"

finish
