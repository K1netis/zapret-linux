#!/usr/bin/env bash
# update.sh: самообновление проекта с сохранением настроек.
. "$(dirname "$0")/lib.sh"
OPT="$TMP/opt"; ETC="$TMP/etc"
ARC_VER=1.1.4; ARC_DIR=zapret-linux-main      # версия в архиве и имя верхнего каталога
mkdir -p "$OPT" "$ETC" "$TMP/tmpdir"
cp "$ROOT/update.sh" "$OPT/update.sh"
echo "1.1.3" > "$OPT/VERSION"
printf 'UPDATE_REPO=K1netis/zapret-linux\nUPDATE_BRANCH=main\n' > "$OPT/repo.conf"
printf '#!/bin/sh\nexit 0\n' > "$OPT/apply-strategy.sh"; chmod +x "$OPT/apply-strategy.sh"
printf 'STRATEGY_FILE="general_alt9"\n' > "$ETC/active.env"
echo udp > "$ETC/gamefilter"; echo any > "$ETC/ipsetfilter"

# Установщик «новой версии» перезаписывает update.sh НА МЕСТЕ и более длинным
# текстом — худший случай: так bash, исполняющий update.sh, мог бы продолжить
# читать из середины нового файла.
{ echo "# строка, добавленная в новой версии, сдвигает весь текст файла"; cat "$ROOT/update.sh"; } > "$TMP/new_update.sh"
make_installer() { # $1 — код выхода установщика; ARC_VER ("" — архив без VERSION), ARC_DIR
  local d="$TMP/src/$ARC_DIR"
  rm -rf "$TMP/src"; mkdir -p "$d"
  cat > "$d/install.sh" <<S
echo "SYNC=\${SYNC:-} DEFAULT_STRATEGY=\${DEFAULT_STRATEGY:-}" > "$TMP/install_env"
cat "$TMP/new_update.sh" > "\$OPT_DIR/update.sh"
exit $1
S
  [ -z "$ARC_VER" ] || echo "$ARC_VER" > "$d/VERSION"
  tar -czf "$TMP/src.tar.gz" -C "$TMP/src" "$ARC_DIR"
}
upd() {
  OPT_DIR="$OPT" ETC_DIR="$ETC" TMPDIR="$TMP/tmpdir" MOCK_TARBALL="$TMP/src.tar.gz" \
    mocked bash "$OPT/update.sh" "$@" > "$TMP/out" 2>&1
}
garbage() { has_re "$TMP/out" "не найдена|not found|unexpected EOF|неожиданный конец|syntax error|синтаксическая"; }

section "Обновление на новую версию"
make_installer 0
MOCK_REMOTE_VERSION=1.1.4 upd; code=$?
check "завершается успешно"                     test "$code" -eq 0
check_not "нет ошибок от подменённого update.sh" garbage
check "сообщает о переходе версий"              has "$TMP/out" "1.1.3 -> 1.1.4"
check "установщику передана сохранённая стратегия" has "$TMP/install_env" "DEFAULT_STRATEGY=general_alt9"
check "установщик не синхронизирует Flowseal"   has "$TMP/install_env" "SYNC=0"
check "игровой фильтр сохранён"                 has "$ETC/gamefilter" "udp"
check "режим IPSet сохранён"                    has "$ETC/ipsetfilter" "any"
check "временные файлы убраны"                  test -z "$(ls -A "$TMP/tmpdir")"

check "в итоговом сообщении версия из архива"   has "$TMP/out" "1.1.3 -> 1.1.4"

section "Версия актуальна"
cp "$ROOT/update.sh" "$OPT/update.sh"; rm -f "$TMP/install_env"
MOCK_REMOTE_VERSION=1.1.3 upd; code=$?
check "завершается успешно"                     test "$code" -eq 0
check "сообщает об актуальности"                has "$TMP/out" "актуальная"
check "установщик не запускался"                test ! -e "$TMP/install_env"
check "временные файлы убраны"                  test -z "$(ls -A "$TMP/tmpdir")"

section "Только проверка (--check)"
MOCK_REMOTE_VERSION=1.10.0 upd --check
check "видит обновление 1.1.3 -> 1.10.0"        has "$TMP/out" "доступно обновление"
check "установщик не запускался"                test ! -e "$TMP/install_env"

section "Архив с другим именем верхнего каталога"
ARC_DIR=myfork-main; ARC_VER=1.1.4; make_installer 0
cp "$ROOT/update.sh" "$OPT/update.sh"; rm -f "$TMP/install_env"
MOCK_REMOTE_VERSION=1.1.4 upd; code=$?
check "каталог myfork-main: успех"              test "$code" -eq 0
check "установщик запущен"                      test -e "$TMP/install_env"
check "временные файлы убраны"                  test -z "$(ls -A "$TMP/tmpdir")"
ARC_DIR=zapret-linux-main

section "Архив без VERSION"
ARC_VER=""; make_installer 0
cp "$ROOT/update.sh" "$OPT/update.sh"; rm -f "$TMP/install_env"
MOCK_REMOTE_VERSION=1.1.4 upd; code=$?
check "отказ (код не 0)"                        test "$code" -ne 0
check "установщик не запускался"                test ! -e "$TMP/install_env"
check "временные файлы убраны"                  test -z "$(ls -A "$TMP/tmpdir")"

section "Архив не новее установленной версии (кэш)"
ARC_VER=1.1.3; make_installer 0
cp "$ROOT/update.sh" "$OPT/update.sh"; rm -f "$TMP/install_env"
MOCK_REMOTE_VERSION=1.10.0 upd; code=$?
check "код 0"                                   test "$code" -eq 0
check "сообщение «повторите через 5 минут»"     has "$TMP/out" "через 5 минут"
check "установщик не запускался"                test ! -e "$TMP/install_env"
check "временные файлы убраны"                  test -z "$(ls -A "$TMP/tmpdir")"
MOCK_REMOTE_VERSION=1.10.0 upd --force; code=$?
check "--force: успех"                          test "$code" -eq 0
check "--force: установщик запущен"             test -e "$TMP/install_env"

section "Версия в архиве отличается от объявленной"
ARC_VER=1.1.5; make_installer 0
cp "$ROOT/update.sh" "$OPT/update.sh"; rm -f "$TMP/install_env"
MOCK_REMOTE_VERSION=1.1.4 upd; code=$?
check "успех"                                   test "$code" -eq 0
check "в сообщении версия из архива"            has "$TMP/out" "1.1.3 -> 1.1.5"
check_not "объявленная версия не показана итогом" has "$TMP/out" "1.1.3 -> 1.1.4"

section "Нет файла режима IPSet"
ARC_VER=1.1.4; make_installer 0
cp "$ROOT/update.sh" "$OPT/update.sh"; rm -f "$ETC/ipsetfilter"
MOCK_REMOTE_VERSION=1.1.4 upd; code=$?
check "успех"                                   test "$code" -eq 0
check "в текущем состоянии ipset=none"          has "$TMP/out" "ipset=none"
check_not "loaded по умолчанию не показывается" has "$TMP/out" "ipset=loaded"

section "Сбои"
ARC_VER=1.1.4; make_installer 0
MOCK_REMOTE_VERSION="" upd; code=$?
check "нет связи с репозиторием — ошибка"       test "$code" -ne 0
make_installer 1
MOCK_REMOTE_VERSION=1.1.4 upd; code=$?
check "сбой установщика — ошибка"               test "$code" -ne 0
check "сообщение предлагает повторить"          has "$TMP/out" "повторите"
check "временные файлы убраны"                  test -z "$(ls -A "$TMP/tmpdir")"

finish
