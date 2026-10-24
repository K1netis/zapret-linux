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
  say() { :; }; die() { echo "$*" > "$TMP/die_log"; exit 1; }
  uname() { echo "$FAKE_ARCH"; }
  # Что «установлено» на машине, определяет только HAVE (по умолчанию make и cc):
  # настоящие PATH, dnf, pacman, apt-get и cc машины на результат не влияют.
  command() {
    if [ "${1:-}" = -v ]; then case " ${HAVE-make cc} " in *" $2 "*) return 0 ;; *) return 1 ;; esac; fi
    builtin command "$@"
  }
  make() { echo build >> "$TMP/make_log"; [ -z "${MAKE_FAIL:-}" ] || return 1; exe "$TMP/eng/nfq/nfqws"; }
  FAKE_ARCH="$1"
  . "$TMP/pick.sh" >/dev/null 2>&1
  echo "${NFQWS:-}"
)
exe() { mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\n' > "$1"; chmod +x "$1"; }
reset() { rm -rf "$TMP/eng" "$TMP/optI" "$TMP/make_log" "$TMP/die_log"; mkdir -p "$TMP/eng/nfq" "$TMP/optI"; }

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

section "Сборка nfqws: зависимости и подсказка"
# nfqws нет нигде — доходит до сборки. HAVE — «установленные» команды.
build() { reset; HAVE="$1" MAKE_FAIL="${2:-}" pick x86_64 >/dev/null; }
build "make cc"
check "всё есть: сборка запущена"                 test -s "$TMP/make_log"
check "всё есть: ошибки нет"                      test ! -e "$TMP/die_log"
build "cc"
check "нет make: отказ"                           has "$TMP/die_log" "для сборки nfqws нужны компилятор и make"
check "нет make: сборка не запускалась"           test ! -e "$TMP/make_log"
build "make"
check "нет cc: отказ"                             has "$TMP/die_log" "для сборки nfqws нужны компилятор и make"
check "нет cc: сборка не запускалась"             test ! -e "$TMP/make_log"
build ""
check "нет ни make, ни cc: отказ без сборки"      test -s "$TMP/die_log" -a ! -e "$TMP/make_log"
build "cc dnf"
check "dnf без make: отказ"                       has "$TMP/die_log" "нужны компилятор и make"

build "make cc dnf" 1
check "make упал: сообщение о сборке"             has "$TMP/die_log" "сборка nfqws не удалась"
check "make упал: подсказка с зависимостями"      has "$TMP/die_log" "zlib-devel"
check "make упал: nfqws не выбран"                test ! -x "$TMP/eng/nfq/nfqws"

build "make cc dnf pacman apt-get" 1
check "dnf: подсказка с zlib-devel"               has "$TMP/die_log" "zlib-devel"
check "dnf: подсказка с libnetfilter_queue-devel" has "$TMP/die_log" "libnetfilter_queue-devel"
check_not "dnf: без пакетов apt"                  has "$TMP/die_log" "zlib1g-dev"
check_not "dnf: без пакетов pacman"               has "$TMP/die_log" "base-devel"
build "make cc pacman apt-get" 1
check "pacman: подсказка с base-devel"            has "$TMP/die_log" "base-devel"
check_not "pacman: без zlib1g-dev"                has "$TMP/die_log" "zlib1g-dev"
check_not "pacman: без zlib-devel"                has "$TMP/die_log" "zlib-devel"
build "make cc apt-get" 1
check "apt-get: подсказка с zlib1g-dev"           has "$TMP/die_log" "zlib1g-dev"
check_not "apt-get: без base-devel"               has "$TMP/die_log" "base-devel"
build "make cc" 1
check "нет менеджера пакетов: общий текст"        has "$TMP/die_log" "пакеты разработки zlib"
check_not "общий текст без команд установки"      has "$TMP/die_log" "sudo "
build "cc dnf"
check "нет make при dnf: подсказка dnf в отказе"  has "$TMP/die_log" "libnetfilter_queue-devel"
build "cc"
check "нет make и менеджера: общий текст"         has "$TMP/die_log" "пакеты разработки zlib"

section "Метки SELinux после установки (restorecon)"
sed -n '/^if command -v restorecon/,/^fi/p' "$ROOT/install.sh" > "$TMP/rc.sh"
check "блок restorecon найден в install.sh"       has_re "$TMP/rc.sh" '^fi'
RCB="$TMP/rcbin"; mkdir -p "$RCB"
rc_run() ( # $1 — код возврата макета restorecon, пустой — команды нет
  rm -f "$TMP/rc_log"
  if [ -n "$1" ]; then
    printf '#!/bin/sh\necho "$*" >> "%s"\nexit %s\n' "$TMP/rc_log" "$1" > "$RCB/restorecon"
    chmod +x "$RCB/restorecon"
  else rm -f "$RCB/restorecon"; fi
  OPT_DIR="/opt/zl x"; ETC_DIR="/etc/zl"
  # PATH — только макет и /usr/bin:/bin без настоящего restorecon
  [ -n "$1" ] || { command() { if [ "${1:-}" = -v ] && [ "$2" = restorecon ]; then return 1; fi; builtin command "$@"; }; }
  set -e
  . "$TMP/rc.sh"
)
PATH="$RCB:$PATH" rc_run 0; code=$?
check "restorecon есть: блок завершился успешно"  test "$code" -eq 0
check "вызван с -RF и тремя путями"               test "$(cat "$TMP/rc_log")" = "-RF /opt/zl x /etc/zl /etc/systemd/system/zapret-linux.service"
PATH="$RCB:$PATH" rc_run 1; code=$?
check "restorecon вернул ошибку: установка не падает (set -e)" test "$code" -eq 0
check "при ошибке он всё же вызывался"            test -s "$TMP/rc_log"
PATH="$RCB:$PATH" rc_run ""; code=$?
check "restorecon нет: блок не падает (set -e)"   test "$code" -eq 0
check "restorecon нет: ничего не вызвано"         test ! -e "$TMP/rc_log"

section "Режим IPSet по умолчанию"
E="$TMP/etcI"; mkdir -p "$E"
( ETC_DIR="$E"; . "$TMP/ipsline.sh" )
check "новая установка: none"                     test "$(cat "$E/ipsetfilter")" = none
echo any > "$E/ipsetfilter"
( ETC_DIR="$E"; . "$TMP/ipsline.sh" )
check "существующий режим не перезаписывается"    test "$(cat "$E/ipsetfilter")" = any

finish
