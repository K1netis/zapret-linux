#!/usr/bin/env bash
# apply-strategy.sh — выбор стратегии, подстановка меток, запись рабочих файлов
# и перезапуск службы zapret-linux.
#
#   apply-strategy.sh general
#   apply-strategy.sh general_alt11
#
# Какие метки подставляются:
#   @BIN@ / @LISTS@                      — абсолютные пути установки
#   @IPSET@                              — активный список IP (режим none/loaded/any)
#   @GAMEFILTER_TCP@ / @GAMEFILTER_UDP@  — диапазон игровых портов; в списке
#                                          портов firewall он появляется только
#                                          если игровой фильтр включён для этого
#                                          протокола, иначе удаляется
set -euo pipefail

OPT_DIR="${OPT_DIR:-/opt/zapret-linux}"
ETC_DIR="${ETC_DIR:-/etc/zapret-linux}"
BIN_DIR="$OPT_DIR/bin"
LISTS_DIR="$OPT_DIR/lists"
STRAT_DIR="$OPT_DIR/strategies"
NFQWS_BIN="${NFQWS_BIN:-$OPT_DIR/nfqws}"
QNUM="${QNUM:-200}"
FWMARK="${FWMARK:-0x40000000}"
GAMEFILTER_PORTS="${GAMEFILTER_PORTS:-1024-65535}"
SERVICE="${SERVICE:-zapret-linux}"

die() { echo "apply-strategy: $*" >&2; exit 1; }

# Разрешаем запуск прямо из каталога с исходниками — удобно для проверки.
if [ ! -d "$STRAT_DIR" ] && [ -d "$(dirname "$0")/strategies" ]; then
  here="$(cd "$(dirname "$0")" && pwd)"
  OPT_DIR="$here"; STRAT_DIR="$here/strategies"
  BIN_DIR="$here/bin"; LISTS_DIR="$here/lists"
fi

STRAT="${1:-}"; [ -n "$STRAT" ] || die "usage: apply-strategy.sh <name>"
CONF="$STRAT_DIR/$STRAT.conf"
[ -f "$CONF" ] || die "no strategy: $CONF"

# Режим игрового фильтра: off | tcp | udp | all (по умолчанию off)
GF_MODE="off"
[ -f "$ETC_DIR/gamefilter" ] && GF_MODE="$(cat "$ETC_DIR/gamefilter")"

# shellcheck disable=SC1090
. "$CONF"   # -> STRATEGY_NAME, PORTS_TCP, PORTS_UDP, NFQWS_OPT

clean_ports() { sed -E 's/,+/,/g; s/^,//; s/,$//'; }

case "$GF_MODE" in
  tcp)  gf_tcp="$GAMEFILTER_PORTS"; gf_udp="" ;;
  udp)  gf_tcp="";                  gf_udp="$GAMEFILTER_PORTS" ;;
  all)  gf_tcp="$GAMEFILTER_PORTS"; gf_udp="$GAMEFILTER_PORTS" ;;
  *)    gf_tcp="";                  gf_udp="" ;;
esac

ports_tcp="$(printf '%s' "$PORTS_TCP" | sed "s|@GAMEFILTER_TCP@|$gf_tcp|g" | clean_ports)"
ports_udp="$(printf '%s' "$PORTS_UDP" | sed "s|@GAMEFILTER_UDP@|$gf_udp|g" | clean_ports)"

# Режим IPSet: none | loaded | any (по умолчанию loaded, как у Flowseal)
IPSET_MODE="loaded"
[ -f "$ETC_DIR/ipsetfilter" ] && IPSET_MODE="$(cat "$ETC_DIR/ipsetfilter")"

mkdir -p "$ETC_DIR"
IPSET_ACTIVE="$ETC_DIR/ipset-active.txt"
case "$IPSET_MODE" in
  any)
    # под профили с ipset попадают любые адреса
    printf '0.0.0.0/0\n::/0\n' > "$IPSET_ACTIVE" ;;
  none)
    # пустой список — под профили с ipset не попадает ничего
    : > "$IPSET_ACTIVE" ;;
  *)
    IPSET_MODE=loaded
    if [ -f "$LISTS_DIR/ipset-all.txt" ]; then
      cp -f "$LISTS_DIR/ipset-all.txt" "$IPSET_ACTIVE"
    else
      : > "$IPSET_ACTIVE"
      echo "apply-strategy: warning: $LISTS_DIR/ipset-all.txt missing — ipset is empty" >&2
    fi ;;
esac

# В строке параметров nfqws игровые порты подставляются всегда: дойдёт ли до
# этих профилей трафик, решают правила firewall выше.
opt="$(printf '%s' "$NFQWS_OPT" \
  | sed "s|@GAMEFILTER_TCP@|$GAMEFILTER_PORTS|g; s|@GAMEFILTER_UDP@|$GAMEFILTER_PORTS|g" \
  | sed "s|@IPSET@|$IPSET_ACTIVE|g" \
  | sed "s|@BIN@|$BIN_DIR|g; s|@LISTS@|$LISTS_DIR|g")"

# Fake replacement (аналог "Replace active fakes" из Flowseal 1.10.0):
# строки вида "<тип> <файл.bin>" в fakes.conf переопределяют
# --dpi-desync-fake-<тип>=<любой путь> на выбранный файл из bin/.
FAKES_MAP="$ETC_DIR/fakes.conf"
fakes_applied=""
if [ -s "$FAKES_MAP" ]; then
  while read -r ftype ffile; do
    case "$ftype" in ''|\#*) continue ;; esac
    [ -n "$ffile" ] || continue
    if [ ! -f "$BIN_DIR/$ffile" ]; then
      echo "apply-strategy: warning: фейк $ffile не найден, подмена '$ftype' пропущена" >&2
      continue
    fi
    opt="$(printf '%s' "$opt" | sed -E "s|--dpi-desync-fake-$ftype=[^ ]+|--dpi-desync-fake-$ftype=$BIN_DIR/$ffile|g")"
    fakes_applied="$fakes_applied $ftype"
  done < "$FAKES_MAP"
fi

# Flowseal создаёт файлы *-user.txt при первом запуске. Делаем так же, иначе
# nfqws завершится с ошибкой «cannot access hostlist/ipset file».
for f in $(printf '%s\n' "$opt" | grep -oE "$LISTS_DIR/[A-Za-z0-9_.-]+-user\.txt" | sort -u); do
  if [ ! -f "$f" ]; then
    : > "$f"
    echo "apply-strategy: создан пустой $(basename "$f")"
  fi
done

# Не перезапускаем службу, если у стратегии не хватает файлов: nfqws сразу
# завершится, а systemd уйдёт в бесконечный цикл перезапусков.
missing_files=""
for f in $(printf '%s\n' "$opt" \
    | grep -oE -- '--(hostlist|hostlist-exclude|ipset|ipset-exclude|dpi-desync-fake-[a-z-]+|dpi-desync-split-seqovl-pattern)=[^ ]+' \
    | sed 's/^[^=]*=//' | sort -u); do
  case "$f" in /*) ;; *) continue ;; esac      # значения вида 0x00 — не файлы
  [ -f "$f" ] || missing_files="$missing_files
  $f"
done
if [ -n "$missing_files" ]; then
  echo "apply-strategy: ОШИБКА — стратегия '$STRATEGY_NAME' ссылается на отсутствующие файлы:$missing_files" >&2
  echo "  Выполните: bash sync-flowseal.sh" >&2
  exit 1
fi

# Всё в кавычках: имена стратегий содержат пробелы и скобки — "general (ALT11)".
# systemd EnvironmentFile и наши скрипты читают этот файл как shell-фрагмент.
cat > "$ETC_DIR/active.env" <<EOF
# generated by apply-strategy.sh — do not edit
STRATEGY_NAME="$STRATEGY_NAME"
STRATEGY_FILE="$STRAT"
GAMEFILTER_MODE="$GF_MODE"
IPSET_MODE="$IPSET_MODE"
IPSET_ACTIVE="$IPSET_ACTIVE"
PORTS_TCP="$ports_tcp"
PORTS_UDP="$ports_udp"
QNUM="$QNUM"
FWMARK="$FWMARK"
NFQWS_BIN="$NFQWS_BIN"
EOF

cat > "$ETC_DIR/nfqws.cmd" <<EOF
#!/bin/sh
# generated by apply-strategy.sh — do not edit
exec "$NFQWS_BIN" $opt --qnum=$QNUM --dpi-desync-fwmark=$FWMARK
EOF
chmod +x "$ETC_DIR/nfqws.cmd"

echo "apply-strategy: '$STRATEGY_NAME' (gamefilter=$GF_MODE, ipset=$IPSET_MODE)"
[ -n "$fakes_applied" ] && echo "  подмена фейков:$fakes_applied"
echo "  tcp ports: $ports_tcp"
echo "  udp ports: $ports_udp"

if command -v systemctl >/dev/null 2>&1 && \
   systemctl list-unit-files "$SERVICE.service" >/dev/null 2>&1; then
  systemctl restart "$SERVICE" && echo "  служба перезапущена."
else
  echo "  (служба не установлена — запустите install.sh либо nfqws вручную: $ETC_DIR/nfqws.cmd)"
fi
