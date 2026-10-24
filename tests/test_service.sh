#!/usr/bin/env bash
# systemd/zapret-linux.service: скрипты запускаются через интерпретатор (при SELinux
# прямой запуск файлов из /opt и /etc может быть запрещён), пути указаны верно.
. "$(dirname "$0")/lib.sh"
U="$ROOT/systemd/zapret-linux.service"

section "Файл службы"
check "файл службы существует"                    test -s "$U"
check "ExecStartPre через /bin/bash на fw.sh up"  has_re "$U" '^ExecStartPre=/bin/bash /opt/zapret-linux/lib/fw\.sh up$'
check "ExecStart через /bin/sh на nfqws.cmd"      has_re "$U" '^ExecStart=/bin/sh /etc/zapret-linux/nfqws\.cmd$'
check "ExecStopPost через /bin/bash на fw.sh down" has_re "$U" '^ExecStopPost=/bin/bash /opt/zapret-linux/lib/fw\.sh down$'
check_not "нет прямого запуска скриптов (Exec* без интерпретатора)" grep -qE '^Exec[A-Za-z]*=(-|@|\+)?/(opt|etc)/' "$U"
check "каждая строка Exec* начинается с интерпретатора" test -z "$(grep -E '^Exec' "$U" | grep -vE '^Exec[A-Za-z]*=/bin/(ba)?sh ')"
check "fw.sh есть в репозитории"                  test -f "$ROOT/lib/fw.sh"
check "ExecStart указывает на файл, который пишет apply-strategy.sh" grep -q 'nfqws\.cmd' "$ROOT/apply-strategy.sh"
check "EnvironmentFile не изменился"              has "$U" "EnvironmentFile=/etc/zapret-linux/active.env"

finish
