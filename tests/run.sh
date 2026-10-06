#!/usr/bin/env bash
# Запуск тестов: все — bash tests/run.sh, один — bash tests/run.sh sync
# Тесты работают без root и без сети: curl, id и systemctl подменяются
# макетами из tests/mock, настоящая служба и /opt, /etc не затрагиваются.
set -u
dir="$(cd "$(dirname "$0")" && pwd)"
pattern="${1:-}"
failed=""; total=0
for t in "$dir"/test_*.sh; do
  name="$(basename "$t" .sh)"; name="${name#test_}"
  [ -n "$pattern" ] && [ "$name" != "$pattern" ] && continue
  total=$((total+1))
  printf '\n\033[1;36m=== %s ===\033[0m' "$name"
  bash "$t" || failed="$failed $name"
done
[ "$total" -gt 0 ] || { echo "нет теста с именем '$pattern'"; exit 2; }
echo
if [ -n "$failed" ]; then
  printf '\033[1;31mПРОВАЛЕНЫ:%s\033[0m\n' "$failed"; exit 1
fi
printf '\033[1;32mВсе наборы пройдены (%d)\033[0m\n' "$total"
