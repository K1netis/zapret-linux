#!/usr/bin/env bash
# apply-strategy.sh — выбор стратегии, подстановка меток, запись рабочих файлов
# и перезапуск службы zapret-linux.
#
#   apply-strategy.sh general
#   apply-strategy.sh general_alt11
#   apply-strategy.sh --print-args general
#
# С --print-args ничего не записывается и служба не перезапускается: скрипт
# только печатает на stdout аргументы nfqws (по одному в строке, без --qnum и
# --dpi-desync-fwmark). Сообщения в этом режиме идут в stderr. Нужен тесту
# стратегий (zapret test), которому требуется запускать nfqws сразу на нескольких
# очередях. Активный список IP должен уже существовать (стратегию применяли).
#
# Какие метки подставляются:
#   @BIN@ / @LISTS@                      — абсолютные пути установки
#   @IPSET@                              — активный список IP (режим none/loaded/any, по умолчанию none)
#   @GAMEFILTER_TCP@ / @GAMEFILTER_UDP@  — диапазон игровых портов; в списке
#                                          портов firewall он появляется только
#                                          если игровой фильтр включён для этого
#                                          протокола, иначе удаляется
set -euo pipefail
export LC_ALL=C

OPT_DIR="${OPT_DIR:-/opt/zapret-linux}"
ETC_DIR="${ETC_DIR:-/etc/zapret-linux}"
BIN_DIR="$OPT_DIR/bin"
LISTS_DIR="$OPT_DIR/lists"
STRAT_DIR="$OPT_DIR/strategies"
NFQWS_BIN="${NFQWS_BIN:-$OPT_DIR/nfqws}"
QNUM="${QNUM:-200}"
FWMARK="${FWMARK:-0x40000000}"
# Порт-заглушка для выключенного игрового фильтра: firewall его не направляет
# в очередь, поэтому профиль с ним не срабатывает никогда. Так же поступает
# Flowseal в Windows-версии.
GAMEFILTER_OFF_PORT="${GAMEFILTER_OFF_PORT:-1}"
SERVICE="${SERVICE:-zapret-linux}"

die() { echo "apply-strategy: $*" >&2; exit 1; }

# Разрешаем запуск прямо из каталога с исходниками — удобно для проверки.
if [ ! -d "$STRAT_DIR" ] && [ -d "$(dirname "$0")/strategies" ]; then
  here="$(cd "$(dirname "$0")" && pwd)"
  OPT_DIR="$here"; STRAT_DIR="$here/strategies"
  BIN_DIR="$here/bin"; LISTS_DIR="$here/lists"
fi

PRINT_ARGS=0
if [ "${1:-}" = "--print-args" ]; then
  PRINT_ARGS=1; shift
  # stdout занят аргументами (дескриптор 3), всё остальное уходит в stderr
  exec 3>&1 1>&2
fi

STRAT="${1:-}"; [ -n "$STRAT" ] || die "использование: apply-strategy.sh [--print-args] <имя>"
# Имя стратегии становится частью пути — только безопасные символы.
case "$STRAT" in
  *[!A-Za-z0-9._-]*) die "недопустимое имя стратегии '$STRAT' (разрешены латиница, цифры, . _ -)" ;;
esac
CONF="$STRAT_DIR/$STRAT.conf"
[ -f "$CONF" ] || die "нет стратегии: $CONF"

# Файл стратегии создаётся из чужого текста, поэтому он НЕ исполняется, а
# разбирается построчно: берётся последняя строка КЛЮЧ=значение, снимаются
# внешние кавычки, а всё, что может сработать в shell, отвергается.
# $1 — ключ, $2 — имя переменной для результата; код 1, если ключа нет.
conf_get() {
  local line v q=""
  line="$(grep -E "^$1=" "$CONF" | tail -n1)" || true
  [ -n "$line" ] || return 1
  v="${line#*=}"; v="${v%$'\r'}"
  if [ "${#v}" -ge 2 ]; then
    case "$v" in
      \"*\") q='"'; v="${v:1:${#v}-2}" ;;
      \'*\') q="'"; v="${v:1:${#v}-2}" ;;
    esac
  fi
  case "$v" in
    *'$'*|*'`'*|*'\'*) die "стратегия $STRAT.conf содержит недопустимые символы — переведите её заново: zapret sync" ;;
  esac
  if [ -n "$q" ]; then
    case "$v" in
      *"$q"*) die "стратегия $STRAT.conf содержит недопустимые символы — переведите её заново: zapret sync" ;;
    esac
  fi
  printf -v "$2" '%s' "$v"
}

STRATEGY_NAME=""; PORTS_TCP=""; PORTS_UDP=""; NFQWS_OPT=""
conf_get STRATEGY_NAME STRATEGY_NAME || true
conf_get PORTS_TCP PORTS_TCP || true
conf_get PORTS_UDP PORTS_UDP || true
conf_get NFQWS_OPT NFQWS_OPT || die "в стратегии $STRAT.conf нет NFQWS_OPT — переведите её заново: zapret sync"
[ -n "$STRATEGY_NAME" ] || STRATEGY_NAME="$STRAT"

# Режим игрового фильтра: off | tcp | udp | all (по умолчанию off)
GF_MODE="off"
[ -f "$ETC_DIR/gamefilter" ] && GF_MODE="$(cat "$ETC_DIR/gamefilter")"
case "$GF_MODE" in
  off|tcp|udp|all) ;;
  *)
    echo "apply-strategy: предупреждение: неизвестный режим игрового фильтра в $ETC_DIR/gamefilter — используется off" >&2
    GF_MODE="off" ;;
esac

# Проверка списка портов: числа и диапазоны через запятую, 1..65535.
valid_ports() {
  local list="$1" item a b
  [ -n "$list" ] || return 1
  case "$list" in *[!0-9,-]*) return 1 ;; esac
  local IFS=','
  for item in $list; do
    [ -n "$item" ] || return 1
    case "$item" in
      *-*-*) return 1 ;;
      *-*)   a="${item%-*}"; b="${item#*-}" ;;
      *)     a="$item"; b="$item" ;;
    esac
    [ -n "$a" ] && [ -n "$b" ] || return 1
    if [ "$a" -lt 1 ] || [ "$b" -gt 65535 ] || [ "$a" -gt "$b" ]; then return 1; fi
  done
}

clean_ports() { sed -E 's/,+/,/g; s/^,//; s/,$//'; }

# Порты игрового фильтра настраиваются (Flowseal 1.10.3), по умолчанию 1024-65535.
GF_TCP_PORTS="1024-65535"; GF_UDP_PORTS="1024-65535"
if [ -f "$ETC_DIR/gamefilter-ports" ]; then
  v="$(sed -n 's/^TCP=//p' "$ETC_DIR/gamefilter-ports" | head -n1)"
  if [ -n "$v" ]; then
    if valid_ports "$v"; then GF_TCP_PORTS="$v"
    else echo "apply-strategy: предупреждение: некорректные TCP-порты игрового фильтра в $ETC_DIR/gamefilter-ports — используются 1024-65535" >&2; fi
  fi
  v="$(sed -n 's/^UDP=//p' "$ETC_DIR/gamefilter-ports" | head -n1)"
  if [ -n "$v" ]; then
    if valid_ports "$v"; then GF_UDP_PORTS="$v"
    else echo "apply-strategy: предупреждение: некорректные UDP-порты игрового фильтра в $ETC_DIR/gamefilter-ports — используются 1024-65535" >&2; fi
  fi
fi

# gf_* — порты для firewall (пусто = не направлять в очередь),
# opt_* — значение для профиля nfqws (заглушка, если фильтр выключен).
case "$GF_MODE" in
  tcp)  gf_tcp="$GF_TCP_PORTS"; gf_udp="" ;;
  udp)  gf_tcp="";              gf_udp="$GF_UDP_PORTS" ;;
  all)  gf_tcp="$GF_TCP_PORTS"; gf_udp="$GF_UDP_PORTS" ;;
  *)    gf_tcp="";              gf_udp="" ;;
esac
opt_tcp="${gf_tcp:-$GAMEFILTER_OFF_PORT}"
opt_udp="${gf_udp:-$GAMEFILTER_OFF_PORT}"

ports_tcp="$(printf '%s' "$PORTS_TCP" | sed "s|@GAMEFILTER_TCP@|$gf_tcp|g" | clean_ports)"
ports_udp="$(printf '%s' "$PORTS_UDP" | sed "s|@GAMEFILTER_UDP@|$gf_udp|g" | clean_ports)"

# Режим IPSet (как у Flowseal): none | loaded | any, по умолчанию none.
#   none   — заглушка 203.0.113.113/32: под профили с ipset не попадает ничего
#            (пустой список nfqws считает отсутствующим и применяет профиль
#            ко всем адресам, поэтому пустой ipset-active.txt не пишется никогда);
#   loaded — полный список Flowseal (lists/ipset-all.txt.backup);
#   any    — любые адреса.
IPSET_STUB="203.0.113.113/32"
IPSET_MODE="none"
[ -f "$ETC_DIR/ipsetfilter" ] && IPSET_MODE="$(tr -d '[:space:]' < "$ETC_DIR/ipsetfilter")"

# Есть ли в файле что-то, кроме пустых строк, комментариев и заглушки.
ipset_has_content() {
  [ -s "$1" ] || return 1
  tr -d '\r' < "$1" | grep -vE '^[[:space:]]*(#|$)' | grep -qvxF "$IPSET_STUB"
}

IPSET_ACTIVE="$ETC_DIR/ipset-active.txt"
if [ "$PRINT_ARGS" = 1 ] && [ ! -f "$IPSET_ACTIVE" ]; then
  die "нет $IPSET_ACTIVE — сначала примените стратегию: sudo zapret use $STRAT"
fi
ips_src=""; ips_text=""; ips_migrate=0; ips_warn=""
case "$IPSET_MODE" in
  none|any|loaded) ;;
  *)
    ips_warn="предупреждение: неизвестный режим IPSet в $ETC_DIR/ipsetfilter — используется none"
    IPSET_MODE="none" ;;
esac
# Переход с версий, где loaded из-за ошибки работал как none: без метки явного
# выбора (её ставит только ipsetfilter.sh) режим переключается на none.
if [ "$IPSET_MODE" = loaded ] && [ ! -f "$ETC_DIR/ipsetfilter-chosen" ]; then
  ips_migrate=1
  IPSET_MODE="none"
fi
case "$IPSET_MODE" in
  any)
    # под профили с ipset попадают любые адреса
    ips_text="$(printf '0.0.0.0/0\n::/0')" ;;
  loaded)
    if [ -s "$LISTS_DIR/ipset-all.txt.backup" ] && grep -q '[^[:space:]]' "$LISTS_DIR/ipset-all.txt.backup"; then
      ips_src="$LISTS_DIR/ipset-all.txt.backup"
    elif ipset_has_content "$LISTS_DIR/ipset-all.txt"; then
      ips_src="$LISTS_DIR/ipset-all.txt"
    else
      ips_warn="предупреждение: полный список IP не загружен — выполните: sudo zapret sync; пока действует заглушка (как в режиме none)"
      ips_text="$IPSET_STUB"
    fi ;;
  *)
    ips_text="$IPSET_STUB" ;;
esac
[ -z "$ips_warn" ] || echo "apply-strategy: $ips_warn" >&2

opt="$(printf '%s' "$NFQWS_OPT" \
  | sed "s|@GAMEFILTER_TCP@|$opt_tcp|g; s|@GAMEFILTER_UDP@|$opt_udp|g" \
  | sed "s|@IPSET@|$IPSET_ACTIVE|g" \
  | sed "s|@BIN@|$BIN_DIR|g; s|@LISTS@|$LISTS_DIR|g")"

# Стратегии, переведённые до версии 1.1.5, содержат «=^!» (экранирование
# cmd.exe попало в параметр): winws получал «!», nfqws — нет. Исправляем на ходу.
opt="$(printf '%s' "$opt" | sed 's|=^!|=!|g')"

# Fake replacement (аналог "Replace active fakes" из Flowseal 1.10.0):
# строки вида "<тип> <файл.bin>" в fakes.conf переопределяют
# --dpi-desync-fake-<тип>=<любой путь> на выбранный файл из bin/.
FAKES_MAP="$ETC_DIR/fakes.conf"
fakes_applied=""
if [ -s "$FAKES_MAP" ]; then
  while read -r ftype ffile; do
    case "$ftype" in ''|\#*) continue ;; esac
    [ -n "$ffile" ] || continue
    if ! [[ "$ftype" =~ ^[a-z][a-z-]*$ ]] || ! [[ "$ffile" =~ ^[A-Za-z0-9._-]+\.bin$ ]]; then
      echo "apply-strategy: предупреждение: некорректная строка в fakes.conf ('$ftype $ffile') — пропущена" >&2
      continue
    fi
    if [ ! -f "$BIN_DIR/$ffile" ]; then
      echo "apply-strategy: предупреждение: фейк $ffile не найден, подмена '$ftype' пропущена" >&2
      continue
    fi
    opt="$(printf '%s' "$opt" | sed -E "s|--dpi-desync-fake-$ftype=[^ ]+|--dpi-desync-fake-$ftype=$BIN_DIR/$ffile|g")"
    fakes_applied="$fakes_applied $ftype"
  done < "$FAKES_MAP"
fi

# Flowseal создаёт файлы *-user.txt при первом запуске и не оставляет их
# пустыми («Never leave this file empty»): пустой список nfqws считает
# отсутствующим. Делаем так же: пустые и новые файлы заполняем заглушкой.
for f in $(printf '%s\n' "$opt" | grep -oE "$LISTS_DIR/[A-Za-z0-9_.-]+-user\.txt" | sort -u); do
  [ -s "$f" ] && continue
  case "$(basename "$f")" in
    *ipset*) stub="$IPSET_STUB" ;;
    *)       stub="domain.example.abc" ;;
  esac
  if [ -f "$f" ]; then echo "apply-strategy: пустой $(basename "$f") заполнен заглушкой"
  else echo "apply-strategy: создан $(basename "$f") с заглушкой"; fi
  printf '%s\n' "$stub" > "$f"
done

# Не перезапускаем службу, если у стратегии не хватает файлов: nfqws сразу
# завершится, а systemd уйдёт в бесконечный цикл перезапусков. Проверяется
# каждый параметр вида --имя=значение, где значение (после необязательного
# префикса «+число@» или «@») — абсолютный путь. Активный ipset создаётся
# ниже, поэтому его здесь пропускаем.
missing_files=""
for f in $(printf '%s\n' "$opt" \
    | grep -oE -- '--[A-Za-z0-9-]+=[^ ]+' \
    | sed -E 's/^[^=]*=//; s/^(\+[0-9]+)?@//' | sort -u); do
  case "$f" in /*) ;; *) continue ;; esac      # значения вида 0x00 — не файлы
  [ "$f" = "$IPSET_ACTIVE" ] && continue
  [ -f "$f" ] || missing_files="$missing_files
  $f"
done
if [ -n "$missing_files" ]; then
  echo "apply-strategy: ОШИБКА — стратегия '$STRATEGY_NAME' ссылается на отсутствующие файлы:$missing_files" >&2
  echo "  Выполните: bash sync-flowseal.sh" >&2
  exit 1
fi

# Проверка итоговых значений ДО записи рабочих файлов. В nfqws.cmd попадают
# только слова из безопасного набора символов, в active.env — только значения,
# которые не могут сработать при чтении как shell-фрагмента.
bad_chars() { printf '%s' "$1" | tr -d "$2" | tr '\n' '~' | fold -w1 | sort -u | tr -d '\n'; }
case "$opt" in
  *[!A-Za-z0-9\ @=._/,+!:^-]*)
    die "в параметрах стратегии '$STRAT' недопустимые символы: $(bad_chars "$opt" 'A-Za-z0-9 @=._/,+!:^-') — рабочие файлы не изменены" ;;
esac
case "$ports_tcp" in *[!0-9,-]*) die "в списке TCP-портов недопустимые символы: $(bad_chars "$ports_tcp" '0-9,-') — рабочие файлы не изменены" ;; esac
case "$ports_udp" in *[!0-9,-]*) die "в списке UDP-портов недопустимые символы: $(bad_chars "$ports_udp" '0-9,-') — рабочие файлы не изменены" ;; esac
case "$NFQWS_BIN" in ''|*[!A-Za-z0-9._/+@:,=-]*) die "недопустимый путь NFQWS_BIN: $NFQWS_BIN" ;; esac
case "$IPSET_ACTIVE" in *[!A-Za-z0-9._/+@:,=-]*) die "недопустимый путь IPSET_ACTIVE: $IPSET_ACTIVE" ;; esac
case "$QNUM" in ''|*[!0-9]*) die "недопустимый номер очереди QNUM: $QNUM" ;; esac
case "$FWMARK" in ''|*[!0-9A-Fa-fx]*) die "недопустимое значение FWMARK: $FWMARK" ;; esac

# Режим --print-args: проверки пройдены, рабочие файлы не трогаем.
if [ "$PRINT_ARGS" = 1 ]; then
  set -f
  for w in $opt; do printf '%s\n' "$w" >&3; done
  set +f
  exit 0
fi

# Имя стратегии показывается пользователю и пишется в active.env в кавычках.
STRATEGY_NAME="$(printf '%s' "$STRATEGY_NAME" | tr -d '\042\044\140\134\047' | tr -d '[:cntrl:]')"
[ -n "$STRATEGY_NAME" ] || STRATEGY_NAME="$STRAT"

# Каждый аргумент nfqws.cmd — в одинарных кавычках: shell ничего не раскрывает.
qargs=""
set -f
for w in $opt "--qnum=$QNUM" "--dpi-desync-fwmark=$FWMARK"; do
  qargs="$qargs '$w'"
done
set +f

# Файлы пишутся во временные рядом и подменяются целиком (mv), чтобы сбой
# не оставил полуготовую конфигурацию.
tmp_env=""; tmp_cmd=""; tmp_ips=""
trap 'rm -f "$tmp_env" "$tmp_cmd" "$tmp_ips"' EXIT
mkdir -p "$ETC_DIR"
tmp_ips="$(mktemp "$ETC_DIR/.ipset-active.XXXXXX")"
if [ -n "$ips_src" ]; then cp -f "$ips_src" "$tmp_ips"; else printf '%s\n' "$ips_text" > "$tmp_ips"; fi
tmp_env="$(mktemp "$ETC_DIR/.active.env.XXXXXX")"
tmp_cmd="$(mktemp "$ETC_DIR/.nfqws.cmd.XXXXXX")"

# Всё в кавычках: имена стратегий содержат пробелы и скобки — "general (ALT11)".
# systemd EnvironmentFile и наши скрипты читают этот файл как shell-фрагмент.
cat > "$tmp_env" <<EOF
# создано apply-strategy.sh — не редактировать вручную
STRATEGY_NAME="$STRATEGY_NAME"
STRATEGY_FILE="$STRAT"
GAMEFILTER_MODE="$GF_MODE"
GAMEFILTER_TCP_PORTS="$GF_TCP_PORTS"
GAMEFILTER_UDP_PORTS="$GF_UDP_PORTS"
IPSET_MODE="$IPSET_MODE"
IPSET_ACTIVE="$IPSET_ACTIVE"
PORTS_TCP="$ports_tcp"
PORTS_UDP="$ports_udp"
QNUM="$QNUM"
FWMARK="$FWMARK"
NFQWS_BIN="$NFQWS_BIN"
EOF

cat > "$tmp_cmd" <<EOF
#!/bin/sh
# создано apply-strategy.sh — не редактировать вручную
exec '$NFQWS_BIN'$qargs
EOF
chmod 644 "$tmp_env" "$tmp_ips"
chmod 755 "$tmp_cmd"
mv -f "$tmp_ips" "$IPSET_ACTIVE"
mv -f "$tmp_env" "$ETC_DIR/active.env"
mv -f "$tmp_cmd" "$ETC_DIR/nfqws.cmd"
tmp_env=""; tmp_cmd=""; tmp_ips=""

if [ "$ips_migrate" = 1 ]; then
  echo none > "$ETC_DIR/ipsetfilter"
  echo "apply-strategy: в прежних версиях режим IPSet loaded из-за ошибки работал как none, поэтому он переключён на none — поведение не изменилось."
  echo "  Чтобы включить полный список Flowseal: sudo zapret ipset loaded"
fi

echo "apply-strategy: '$STRATEGY_NAME' (gamefilter=$GF_MODE, ipset=$IPSET_MODE)"
[ -n "$fakes_applied" ] && echo "  подмена фейков:$fakes_applied"
echo "  TCP-порты: $ports_tcp"
echo "  UDP-порты: $ports_udp"

if command -v systemctl >/dev/null 2>&1 && \
   systemctl list-unit-files "$SERVICE.service" >/dev/null 2>&1; then
  systemctl restart "$SERVICE" && echo "  служба перезапущена."
else
  echo "  (служба не установлена — запустите install.sh либо nfqws вручную: $ETC_DIR/nfqws.cmd)"
fi
