# Общие функции для тестов. Подключается из каждого tests/test_*.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK="$ROOT/tests/mock"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

T_PASS=0; T_FAIL=0

ok()   { T_PASS=$((T_PASS+1)); printf '  \033[32mOK\033[0m    %s\n' "$1"; }
fail() {
  T_FAIL=$((T_FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"
  [ -n "${2:-}" ] && printf '        %s\n' "$2"
  return 0
}

# check "описание" команда... — команда должна завершиться успешно
check()     { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi; }
# check_not "описание" команда... — команда должна завершиться с ошибкой
check_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else ok "$d"; fi; }

has()     { grep -qF -- "$2" "$1"; }        # файл содержит строку
has_re()  { grep -qE -- "$2" "$1"; }        # файл содержит регулярное выражение
same()    { cmp -s "$1" "$2"; }             # файлы совпадают побайтно

# Запуск с подменёнными curl, id и systemctl из tests/mock.
mocked() { PATH="$MOCK:$PATH" "$@"; }

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

finish() {
  printf '  итог: пройдено %d, провалено %d\n' "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -eq 0 ]
}

# Стратегия в формате Flowseal: winws.exe, перенос строк через ^, CRLF.
# $1 — путь, $2 — имя файла-фейка для TCP-профиля.
make_bat() {
  {
    printf '@echo off\r\n'
    printf 'set "BIN=%%~dp0bin\\"\r\n'
    printf 'set "LISTS=%%~dp0lists\\"\r\n'
    printf 'start "zapret: %%~n0" /min "%%BIN%%winws.exe" --wf-tcp=80,443,2053,%%GameFilterTCP%% --wf-udp=443,50000-50100,%%GameFilterUDP%% ^\r\n'
    printf -- '--filter-tcp=443 --hostlist="%%LISTS%%list-general.txt" --hostlist="%%LISTS%%list-general-user.txt" --dpi-desync=fake --dpi-desync-fake-tls="%%BIN%%%s" --new ^\r\n' "$2"
    printf -- '--filter-tcp=%%GameFilterTCP%% --ipset="%%LISTS%%ipset-all.txt" --dpi-desync=multisplit --new ^\r\n'
    printf -- '--filter-udp=%%GameFilterUDP%% --ipset="%%LISTS%%ipset-all.txt" --ipset-exclude="%%LISTS%%ipset-exclude-user.txt" --dpi-desync=fake\r\n'
  } > "$1"
}

# Каталог установки для тестов: $1 — куда. Стратегия test из make_bat,
# все файлы, на которые она ссылается, кроме пользовательских списков.
make_opt() {
  local o="$1"
  mkdir -p "$o/strategies" "$o/lists" "$o/bin"
  make_bat "$TMP/_t.bat" tls_clienthello_www_google_com.bin
  bash "$ROOT/tools/bat2nfqws.sh" "$TMP/_t.bat" > "$o/strategies/test.conf"
  sed -i 's/^STRATEGY_NAME=.*/STRATEGY_NAME="general (TEST)"/' "$o/strategies/test.conf"
  echo "example.com" > "$o/lists/list-general.txt"
  printf '1.2.3.0/24\n5.6.7.8\n' > "$o/lists/ipset-all.txt"
  echo fake > "$o/bin/tls_clienthello_www_google_com.bin"
}

# Применить стратегию в песочнице. Окружение: OPT, ETC.
apply() { OPT_DIR="$OPT" ETC_DIR="$ETC" mocked bash "$ROOT/apply-strategy.sh" "$@"; }
