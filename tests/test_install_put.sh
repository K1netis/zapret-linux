#!/usr/bin/env bash
# install.sh: атомарная замена файлов (функции put и put_dir берутся из
# самого install.sh, чтобы проверялся настоящий код, а не копия).
. "$(dirname "$0")/lib.sh"
section "Функции из install.sh"
sed -n '/^put() {/,/^}/p; /^put_dir() {/,/^}/p' "$ROOT/install.sh" > "$TMP/put.sh"
check "функции put и put_dir найдены в install.sh" has_re "$TMP/put.sh" "^put_dir\(\) \{"
. "$TMP/put.sh"
D="$TMP/d"; mkdir -p "$D"

section "Замена работающего бинарника"
cp "$(command -v sleep)" "$D/nfqws"; cp "$(command -v sleep)" "$D/nfqws_new"; echo x >> "$D/nfqws_new"
"$D/nfqws" 3 & pid=$!; sleep 0.3
put "$D/nfqws_new" "$D/nfqws"; code=$?
check "замена проходит (нет «Текстовый файл занят»)" test "$code" -eq 0
check "на диске новый файл"                     same "$D/nfqws_new" "$D/nfqws"
check "работающий процесс не прерван"           kill -0 "$pid"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

section "Неизменённый файл не трогается"
echo same > "$D/a"; echo same > "$D/b"
ino="$(stat -c %i "$D/b")"; put "$D/a" "$D/b"
check "inode прежний"                           test "$ino" = "$(stat -c %i "$D/b")"

section "Скрипт, заменяющий сам себя"
# аналог update.sh, который запускает установщик, а тот заменяет update.sh
{ echo "# добавленная строка сдвигает текст"; for i in $(seq 1 40); do echo "echo \"новая строка $i\""; done; } > "$D/new.sh"
cat > "$D/self.sh" <<S
echo "начало"
if true; then
  . "$TMP/put.sh"; put "$D/new.sh" "$D/self.sh"
fi
echo "старый скрипт дошёл до конца"
S
bash "$D/self.sh" > "$TMP/out" 2>&1
check "старый текст дочитан до конца"           has "$TMP/out" "дошёл до конца"
check_not "нет обрывков нового текста"          has "$TMP/out" "новая строка"

section "put_dir"
mkdir -p "$D/src/sub" "$D/dst"; echo 1 > "$D/src/f1"; echo 2 > "$D/src/.gitkeep"; echo 3 > "$D/src/sub/x"
put_dir "$D/src" "$D/dst"
check "копирует файлы"                           test -f "$D/dst/f1"
check "копирует скрытые файлы"                   test -f "$D/dst/.gitkeep"
check "не копирует подкаталоги"                  test ! -e "$D/dst/sub"
check_not "не оставляет временных файлов"        ls "$D/dst/"*.new.* 

finish
