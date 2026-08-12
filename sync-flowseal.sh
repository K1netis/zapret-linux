#!/usr/bin/env bash
# sync-flowseal.sh — загрузка актуальных стратегий, списков и фейков из
# репозитория Flowseal с переводом каждой стратегии в strategies/*.conf.
#
# Это и есть способ следить за обновлениями Flowseal: запускайте после выхода
# новой версии. Содержимое репозитория перечисляется через GitHub API, поэтому
# новые стратегии подхватываются сами — список файлов нигде не зашит.
#
#   ./sync-flowseal.sh                 # взять из ветки main
#   REF=1.10.1 ./sync-flowseal.sh      # взять конкретный релиз
#
# Требуется curl. Перевод выполняет tools/bat2nfqws.sh.
set -euo pipefail

REPO="${REPO:-Flowseal/zapret-discord-youtube}"
REF="${REF:-main}"   # в main обычно свежее, чем в последнем теге
HERE="$(cd "$(dirname "$0")" && pwd)"
TRANSLATE="$HERE/tools/bat2nfqws.sh"
SRC_DIR="$HERE/flowseal-src"
STRAT_DIR="$HERE/strategies"
LISTS_DIR="$HERE/lists"
BIN_DIR="$HERE/bin"

command -v curl >/dev/null 2>&1 || { echo "sync: требуется curl" >&2; exit 1; }
[ -f "$TRANSLATE" ] || { echo "sync: не найден $TRANSLATE" >&2; exit 1; }
mkdir -p "$SRC_DIR" "$STRAT_DIR" "$LISTS_DIR" "$BIN_DIR"

api() { curl -fsSL -H "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/$REPO/contents/$1?ref=$REF"; }

# ссылки на скачивание файлов каталога, по одной в строке
raw_urls() { api "$1" | grep -oE 'https://raw\.githubusercontent\.com/[^"]+'; }

# раскодирование %XX и + — этого хватает для пробелов и скобок в именах
urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

slug() { # "general (FAKE TLS AUTO ALT3).bat" -> general_fake_tls_auto_alt3
  basename "$1" .bat | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//'
}

echo "sync: репозиторий=$REPO ветка/тег=$REF"

# 1) Стратегии ---------------------------------------------------------------
echo "sync: стратегии"
n=0
while IFS= read -r url; do
  case "$url" in *.bat) ;; *) continue ;; esac
  fname="$(urldecode "$(basename "$url")")"
  case "$fname" in service*.bat) continue ;; esac      # служебный скрипт меню пропускаем
  case "$fname" in general*.bat) ;; *) continue ;; esac
  curl -fsSL "$url" -o "$SRC_DIR/$fname"
  conf="$STRAT_DIR/$(slug "$fname").conf"
  bash "$TRANSLATE" "$SRC_DIR/$fname" > "$conf"
  echo "  + $(basename "$conf")"
  n=$((n+1))
done < <(raw_urls "")
echo "sync: переведено стратегий: $n"

# 2) Списки доменов и адресов; файлы *-user.txt не трогаем — они пользователя -
echo "sync: списки"
while IFS= read -r url; do
  case "$url" in *.txt) ;; *) continue ;; esac
  fname="$(urldecode "$(basename "$url")")"
  case "$fname" in *-user.txt) continue ;; esac
  curl -fsSL "$url" -o "$LISTS_DIR/$fname"
  echo "  + lists/$fname"
done < <(raw_urls lists)

# 3) Фейки -------------------------------------------------------------------
echo "sync: фейки"
while IFS= read -r url; do
  case "$url" in *.bin) ;; *) continue ;; esac
  fname="$(urldecode "$(basename "$url")")"
  curl -fsSL "$url" -o "$BIN_DIR/$fname"
  echo "  + bin/$fname"
done < <(raw_urls bin)

echo "sync: готово. Проверьте изменения (git diff strategies/) и закоммитьте."
