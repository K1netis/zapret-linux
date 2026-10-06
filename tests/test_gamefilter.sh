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

finish
