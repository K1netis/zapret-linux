#!/usr/bin/env bash
# install.sh: выбор бинарника nfqws и режим IPSet по умолчанию. Install.sh целиком
# не запускается (пишет в /etc/systemd и /usr/local/bin), поэтому берутся его
# настоящие фрагменты: блок выбора nfqws и строка с режимом ipsetfilter.
. "$(dirname "$0")/lib.sh"

section "Фрагменты из install.sh"
sed -n '/^NFQWS=""/,/^\[ -x "\$NFQWS" \] || die/p' "$ROOT/install.sh" > "$TMP/pick.sh"
check "блок выбора nfqws найден"                  has_re "$TMP/pick.sh" 'uname -m'
check "блок заканчивается проверкой бинарника"    has_re "$TMP/pick.sh" '^\[ -x "\$NFQWS" \] \|\| die'
grep -E '^\[ -f "\$ETC_DIR/ipsetfilter" \]' "$ROOT/install.sh" > "$TMP/ipsline.sh"
check "строка создания ipsetfilter найдена (одна)" test "$(wc -l < "$TMP/ipsline.sh")" -eq 1

# Запуск блока: $1 — архитектура (uname -m); результат: «NFQWS|вызвана ли сборка»
pick() (
  ENGINE_DIR="$TMP/eng"; OPT_DIR="$TMP/optI"
  say() { :; }; die() { echo "DIE:$*"; exit 1; }
  uname() { echo "$FAKE_ARCH"; }
  make() { echo build >> "$TMP/make_log"; exe "$TMP/eng/nfq/nfqws"; }
  FAKE_ARCH="$1"
  . "$TMP/pick.sh" >/dev/null 2>&1
  echo "${NFQWS:-}"
)
exe() { mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\n' > "$1"; chmod +x "$1"; }
reset() { rm -rf "$TMP/eng" "$TMP/optI" "$TMP/make_log"; mkdir -p "$TMP/eng/nfq" "$TMP/optI"; }

section "Выбор nfqws"
reset; exe "$TMP/eng/nfq/nfqws"; exe "$TMP/optI/nfqws"; exe "$TMP/eng/binaries/linux-x86_64/nfqws"
check "собранный движок важнее остальных"         test "$(pick x86_64)" = "$TMP/eng/nfq/nfqws"
reset; exe "$TMP/optI/nfqws"; exe "$TMP/eng/binaries/linux-x86_64/nfqws"
check "установленный важнее binaries/"            test "$(pick x86_64)" = "$TMP/optI/nfqws"
reset; exe "$TMP/eng/binaries/linux-x86_64/nfqws"; exe "$TMP/eng/binaries/linux-arm64/nfqws"
check "x86_64: берётся linux-x86_64"              test "$(pick x86_64)" = "$TMP/eng/binaries/linux-x86_64/nfqws"
check "готовый бинарник: сборка не запускалась"   test ! -e "$TMP/make_log"
reset; exe "$TMP/eng/binaries/linux-x86_64/nfqws"; exe "$TMP/eng/binaries/linux-arm64/nfqws"
check "aarch64: берётся linux-arm64"              test "$(pick aarch64)" = "$TMP/eng/binaries/linux-arm64/nfqws"
reset; exe "$TMP/eng/binaries/linux-arm64/nfqws"; exe "$TMP/eng/binaries/linux-arm/nfqws"; exe "$TMP/eng/binaries/linux-x86/nfqws"
check "armv7l: берётся linux-arm, а не arm64"     test "$(pick armv7l)" = "$TMP/eng/binaries/linux-arm/nfqws"
check "i686: берётся linux-x86, а не x86_64"      test "$(pick i686)" = "$TMP/eng/binaries/linux-x86/nfqws"

section "Чужая архитектура не выбирается"
reset; exe "$TMP/eng/binaries/linux-arm64/nfqws"; exe "$TMP/eng/binaries/linux-arm/nfqws"
r="$(pick x86_64)"
check "x86_64 при наличии только arm: не arm"     test "$r" != "$TMP/eng/binaries/linux-arm64/nfqws" -a "$r" != "$TMP/eng/binaries/linux-arm/nfqws"
check "вместо этого запущена сборка"              test -s "$TMP/make_log"
reset; exe "$TMP/eng/binaries/linux-x86_64/nfqws"
r="$(pick aarch64)"
check "aarch64 при наличии только x86_64: не x86_64" test "$r" != "$TMP/eng/binaries/linux-x86_64/nfqws"
check "вместо этого запущена сборка"              test -s "$TMP/make_log"
reset; exe "$TMP/eng/binaries/linux-x86_64/nfqws"
r="$(pick riscv64)"
check "неизвестная архитектура: готовый бинарник не берётся" test "$r" != "$TMP/eng/binaries/linux-x86_64/nfqws"
reset
check "нет ничего: после сборки путь nfq/nfqws"   test "$(pick x86_64)" = "$TMP/eng/nfq/nfqws"
check "нет ничего: сборка запущена"               test -s "$TMP/make_log"

section "Режим IPSet по умолчанию"
E="$TMP/etcI"; mkdir -p "$E"
( ETC_DIR="$E"; . "$TMP/ipsline.sh" )
check "новая установка: none"                     test "$(cat "$E/ipsetfilter")" = none
echo any > "$E/ipsetfilter"
( ETC_DIR="$E"; . "$TMP/ipsline.sh" )
check "существующий режим не перезаписывается"    test "$(cat "$E/ipsetfilter")" = any

finish
