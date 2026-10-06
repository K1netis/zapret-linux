#!/usr/bin/env bash
# sync-flowseal.sh — загрузка актуальных стратегий, списков и фейков из
# репозитория Flowseal с переводом каждой стратегии в strategies/*.conf.
#
# Это и есть способ следить за обновлениями Flowseal: запускайте после выхода
# новой версии. Содержимое репозитория перечисляется через GitHub API, поэтому
# новые стратегии подхватываются сами — список файлов нигде не зашит.
#
#   ./sync-flowseal.sh                 # взять из ветки main
#   REF=1.10.3 ./sync-flowseal.sh      # взять конкретный релиз
#
# Порядок работы рассчитан на то, чтобы сбой не портил рабочую установку:
#   1. получаем списки файлов всех трёх каталогов — без них ничего не трогаем;
#   2. скачиваем всё во временную папку и переводим стратегии там же;
#   3. только после этого подменяем рабочие файлы;
#   4. удаляем то, чего больше нет у Flowseal, кроме того, что ещё используется.
#
# Требуется curl. Перевод выполняет tools/bat2nfqws.sh.
set -uo pipefail

REPO="${REPO:-Flowseal/zapret-discord-youtube}"
REF="${REF:-main}"   # в main обычно свежее, чем в последнем теге
HERE="$(cd "$(dirname "$0")" && pwd)"
ETC_DIR="${ETC_DIR:-/etc/zapret-linux}"
TRANSLATE="$HERE/tools/bat2nfqws.sh"
SRC_DIR="$HERE/flowseal-src"
STRAT_DIR="$HERE/strategies"
LISTS_DIR="$HERE/lists"
BIN_DIR="$HERE/bin"
API_BASE="${API_BASE:-https://api.github.com/repos}"

die()  { echo "sync: ОШИБКА — $*" >&2; echo "sync: рабочие файлы не изменены." >&2; exit 1; }
warn() { echo "sync: внимание — $*" >&2; }

command -v curl >/dev/null 2>&1 || die "требуется curl"
[ -f "$TRANSLATE" ] || die "не найден $TRANSLATE"
mkdir -p "$SRC_DIR" "$STRAT_DIR" "$LISTS_DIR" "$BIN_DIR"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bat" "$STAGE/strategies" "$STAGE/lists" "$STAGE/bin"

# Список ссылок на файлы каталога. Ошибка API (нет сети, лимит запросов
# GitHub — 60 в час без авторизации) возвращается кодом, а не пустым выводом.
listing() {
  local json
  json="$(curl -fsSL --max-time 30 -H "Accept: application/vnd.github+json" \
          "$API_BASE/$REPO/contents/$1?ref=$REF")" || return 1
  # у каталогов download_url равен null — под шаблон с кавычками они не попадают
  printf '%s\n' "$json" | grep -oE '"download_url": *"[^"]+"' \
    | sed -E 's/^"download_url": *"//; s/"$//' || true
}

# раскодирование %XX и + — этого хватает для пробелов и скобок в именах
urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

slug() { # "general (FAKE TLS AUTO ALT3).bat" -> general_fake_tls_auto_alt3
  basename "$1" .bat | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//'
}

# Имя файла из ответа API идёт в пути под root: «../», «/», кавычки, $ и
# управляющие символы недопустимы (раскодирование %2F иначе дало бы обход пути).
safe_fname() {
  case "$1" in
    ''|.*|*/*|*\\*|*'$'*|*'`'*|*'"'*|*"'"*) return 1 ;;
  esac
  case "$1" in *[[:cntrl:]]*) return 1 ;; esac
  return 0
}
warn_fname() { warn "подозрительное имя файла, пропущено: $(printf '%s' "$1" | tr '[:cntrl:]' '?')"; }

fetch() { curl -fsSL --max-time 60 "$1" -o "$2"; }

echo "sync: репозиторий=$REPO ветка/тег=$REF"

# 1) Списки файлов --------------------------------------------------------------
root_urls="$(listing "")"     || die "не удалось получить содержимое репозитория (нет сети или исчерпан лимит запросов GitHub — повторите через час)"
lists_urls="$(listing lists)" || die "не удалось получить содержимое каталога lists"
bin_urls="$(listing bin)"     || die "не удалось получить содержимое каталога bin"

bat_urls="$(printf '%s\n' "$root_urls" | grep -E '/general[^/]*\.bat$' || true)"
[ -n "$bat_urls" ] || die "в репозитории не найдено ни одной стратегии general*.bat"

# 2) Загрузка и перевод во временной папке ---------------------------------------
echo "sync: загрузка"
up_strat=""; up_lists=""; up_bin=""   # имена файлов, которые есть у Flowseal
failed=""                             # стратегии, которые не удалось перевести

while IFS= read -r url; do
  [ -n "$url" ] || continue
  fname="$(urldecode "$(basename "$url")")"
  safe_fname "$fname" || { warn_fname "$fname"; continue; }
  fetch "$url" "$STAGE/bat/$fname" || die "не удалось скачать $fname"
  [ -s "$STAGE/bat/$fname" ]       || die "скачан пустой файл $fname"
  name="$(slug "$fname")"
  up_strat="$up_strat $name"
  if ! bash "$TRANSLATE" "$STAGE/bat/$fname" > "$STAGE/strategies/$name.conf" 2> "$STAGE/err"; then
    rm -f "$STAGE/strategies/$name.conf"
    failed="$failed $name"
    if [ -f "$STRAT_DIR/$name.conf" ]; then
      warn "не удалось перевести $fname, оставлена прежняя версия:"
    else
      warn "не удалось перевести $fname, стратегия пропущена:"
    fi
    sed 's/^/    /' "$STAGE/err" >&2
  fi
done <<< "$bat_urls"

while IFS= read -r url; do
  # кроме *.txt нужен полный список IP для режима ipset loaded: у Flowseal
  # он лежит под именем ipset-all.txt.backup
  case "$url" in *.txt|*/ipset-all.txt.backup) ;; *) continue ;; esac
  fname="$(urldecode "$(basename "$url")")"
  safe_fname "$fname" || { warn_fname "$fname"; continue; }
  case "$fname" in *.txt|ipset-all.txt.backup) ;; *) continue ;; esac
  case "$fname" in *-user.txt) continue ;; esac     # списки пользователя не трогаем
  fetch "$url" "$STAGE/lists/$fname" || die "не удалось скачать lists/$fname"
  [ "$fname" = ipset-all.txt.backup ] && continue   # очистка *.txt его не касается
  up_lists="$up_lists $fname"
done <<< "$lists_urls"

while IFS= read -r url; do
  case "$url" in *.bin) ;; *) continue ;; esac
  fname="$(urldecode "$(basename "$url")")"
  safe_fname "$fname" || { warn_fname "$fname"; continue; }
  fetch "$url" "$STAGE/bin/$fname" || die "не удалось скачать bin/$fname"
  up_bin="$up_bin $fname"
done <<< "$bin_urls"

# 3) Подмена рабочих файлов ------------------------------------------------------
added=0; updated=0; unchanged=0; removed=0

place() { # временный файл -> рабочий, с подсчётом и выводом изменений
  local src="$1" dst="$2" label="$3"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    unchanged=$((unchanged+1))
  elif [ -f "$dst" ]; then
    mv -f "$src" "$dst"; updated=$((updated+1)); echo "  ~ $label"
  else
    mv -f "$src" "$dst"; added=$((added+1));     echo "  + $label"
  fi
}

echo "sync: изменения"
for f in "$STAGE"/strategies/*.conf; do [ -e "$f" ] && place "$f" "$STRAT_DIR/$(basename "$f")" "strategies/$(basename "$f")"; done
for f in "$STAGE"/lists/*.txt;       do [ -e "$f" ] && place "$f" "$LISTS_DIR/$(basename "$f")"  "lists/$(basename "$f")"; done
for f in "$STAGE"/lists/ipset-all.txt.backup; do [ -e "$f" ] && place "$f" "$LISTS_DIR/$(basename "$f")" "lists/$(basename "$f")"; done
for f in "$STAGE"/bin/*.bin;         do [ -e "$f" ] && place "$f" "$BIN_DIR/$(basename "$f")"    "bin/$(basename "$f")"; done

# исходные .bat храним рядом для справки — заменяем каталог целиком
rm -f "$SRC_DIR"/*.bat
cp -f "$STAGE"/bat/*.bat "$SRC_DIR"/ 2>/dev/null || true

# 4) Удаление устаревшего --------------------------------------------------------
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

active=""
if [ -f "$ETC_DIR/active.env" ]; then
  active="$( . "$ETC_DIR/active.env" 2>/dev/null; echo "${STRATEGY_FILE:-}" )"
fi

# Стратегии: удаляем только созданные транслятором (свои .conf пользователя
# не трогаем) и никогда — активную.
for f in "$STRAT_DIR"/*.conf; do
  [ -e "$f" ] || continue
  name="$(basename "$f" .conf)"
  in_list "$name" "$up_strat" && continue
  grep -qE '^# (Файл создан автоматически|Auto-generated from)' "$f" || continue
  if [ "$name" = "$active" ]; then
    warn "стратегия $name удалена у Flowseal, но сейчас активна — оставлена."
    warn "  переключитесь на другую: zapret list, затем zapret use <имя>"
    continue
  fi
  rm -f "$f"; removed=$((removed+1)); echo "  - strategies/$name.conf"
done

# Файлы, на которые ещё ссылаются оставшиеся стратегии или подмена фейков,
# не удаляем, даже если у Flowseal их уже нет.
referenced=" $(grep -ohE '@(BIN|LISTS)@/[^ "]+' "$STRAT_DIR"/*.conf 2>/dev/null \
              | sed 's|.*/||' | sort -u | tr '\n' ' ')"
if [ -f "$ETC_DIR/fakes.conf" ]; then
  referenced="$referenced $(awk 'NF>=2 && $1 !~ /^#/ {print $2}' "$ETC_DIR/fakes.conf" | tr '\n' ' ')"
fi
referenced="$referenced ipset-all.txt "   # подключается через метку @IPSET@

for f in "$LISTS_DIR"/*.txt; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  case "$name" in *-user.txt) continue ;; esac
  in_list "$name" "$up_lists"   && continue
  in_list "$name" "$referenced" && continue
  rm -f "$f"; removed=$((removed+1)); echo "  - lists/$name"
done

for f in "$BIN_DIR"/*.bin; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  in_list "$name" "$up_bin"     && continue
  in_list "$name" "$referenced" && continue
  rm -f "$f"; removed=$((removed+1)); echo "  - bin/$name"
done

# Итог -----------------------------------------------------------------------------
total="$(ls -1 "$STRAT_DIR"/*.conf 2>/dev/null | wc -l)"
[ $((added+updated+removed)) -eq 0 ] && echo "  (изменений нет)"
echo "sync: готово — добавлено $added, обновлено $updated, удалено $removed, без изменений $unchanged."
echo "sync: стратегий доступно: $total"
if [ -n "$failed" ]; then
  warn "не переведены:$failed — у Flowseal появилось что-то новое, нужна доработка транслятора."
fi
exit 0
