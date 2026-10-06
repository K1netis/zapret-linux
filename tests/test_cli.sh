#!/usr/bin/env bash
# zapret-cli: команды, которые передают аргументы дальше.
. "$(dirname "$0")/lib.sh"
OPT="$TMP/opt"; ETC="$TMP/etc"; mkdir -p "$OPT" "$ETC"
cat > "$OPT/selftest.sh" <<'M'
#!/usr/bin/env bash
f="$(dirname "$0")/selftest.args"; : > "$f"; for a in "$@"; do printf '%s\n' "$a" >> "$f"; done
M
chmod +x "$OPT/selftest.sh"

section "zapret test"
OPT_DIR="$OPT" ETC_DIR="$ETC" mocked bash "$ROOT/zapret-cli" test alfa "br avo" >/dev/null 2>&1; code=$?
check "selftest.sh запущен, код 0"                 test "$code" -eq 0
printf 'alfa\nbr avo\n' > "$TMP/want"
check "аргументы переданы без изменений"           same "$TMP/want" "$OPT/selftest.args"
rm -f "$OPT/selftest.args"
OPT_DIR="$OPT" ETC_DIR="$ETC" mocked bash "$ROOT/zapret-cli" test >/dev/null 2>&1
check "без аргументов: selftest.sh запускается пустым" test -e "$OPT/selftest.args" -a ! -s "$OPT/selftest.args"

finish
