#!/usr/bin/env bash
# lib/fw.sh: правила очереди. nft подменяется макетом, который пишет аргументы.
. "$(dirname "$0")/lib.sh"
NB="$TMP/nftbin"; mkdir -p "$NB"
cat > "$NB/nft" <<'M'
#!/usr/bin/env bash
echo "$*" >> "$MOCK_NFT_LOG"
[ "${1:-}" = list ] && exit 1
exit 0
M
chmod +x "$NB/nft"
fw() { PATH="$NB:$PATH" MOCK_NFT_LOG="$TMP/nft.log" ZAPRET_ENV="$TMP/no.env" bash "$ROOT/lib/fw.sh" "$@"; }

section "fw.sh up: правила очереди"
: > "$TMP/nft.log"
PORTS_TCP="80,443,2053" PORTS_UDP="443,50000-50100" fw up >/dev/null 2>&1; code=$?
check "код 0"                                      test "$code" -eq 0
grep 'queue num' "$TMP/nft.log" > "$TMP/rules"
check "создано 5 правил очереди"                   test "$(wc -l < "$TMP/rules")" -eq 5
check_not "каждое правило пропускает пакеты с меткой 0x20000000 (проверка: нет правил без неё)" \
  bash -c "grep -vF 'meta mark and 0x20000000 == 0' '$TMP/rules' | grep -q ."
check_not "каждое правило сохраняет условие 0x40000000" \
  bash -c "grep -vF 'meta mark and 0x40000000 != 0x40000000' '$TMP/rules' | grep -q ."
check "таблица inet zapret_linux создана"          has "$TMP/nft.log" "add table inet zapret_linux"

section "fw.sh up: некорректный порт"
: > "$TMP/nft.log"
PORTS_TCP="80,44a3" PORTS_UDP="" fw up >/dev/null 2>"$TMP/err"; code=$?
check "отказ с ненулевым кодом"                    test "$code" -ne 0
check "назван некорректный порт"                   has "$TMP/err" "44a3"
check_not "правило с таким портом не создано"      has "$TMP/nft.log" "44a3"
PORTS_TCP="80-" PORTS_UDP="" fw up >/dev/null 2>&1; code=$?
check "порт '80-': отказ"                          test "$code" -ne 0

finish
