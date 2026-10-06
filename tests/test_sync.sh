#!/usr/bin/env bash
# sync-flowseal.sh: загрузка от Flowseal, очистка устаревшего, устойчивость к сбоям.
. "$(dirname "$0")/lib.sh"
UP="$TMP/up"; INST="$TMP/inst"; ETC="$TMP/etc"
mkdir -p "$UP/lists" "$UP/bin" "$INST" "$ETC"
# sync пишет в каталог рядом с собой — запускаем копию, а не файл из репозитория
cp "$ROOT/sync-flowseal.sh" "$INST/"; cp -r "$ROOT/tools" "$INST/"

sync_run() { MOCK_UPSTREAM="$UP" ETC_DIR="$ETC" mocked bash "$INST/sync-flowseal.sh" > "$TMP/out" 2>&1; }
snapshot() { (cd "$INST" && find strategies lists bin -type f | sort | xargs md5sum) > "$1" 2>/dev/null; }

# Репозиторий Flowseal «до»: три стратегии, три списка, три фейка, служебный скрипт
make_bat "$UP/general.bat"        tls_clienthello_www_google_com.bin
make_bat "$UP/general (ALT9).bat" quic_initial_dbankcloud_ru.bin
make_bat "$UP/general (OLD).bat"  quic_initial_4pda.to.bin
echo "@echo off" > "$UP/service.bat"
for l in list-general ipset-all ipset-exclude; do echo x.com > "$UP/lists/$l.txt"; done
printf '10.0.0.0/8\n172.16.0.0/12\n' > "$UP/lists/ipset-all.txt.backup"
for b in tls_clienthello_www_google_com quic_initial_dbankcloud_ru quic_initial_4pda.to; do
  echo "$b" > "$UP/bin/$b.bin"
done

section "Первая синхронизация"
sync_run; code=$?
check "успешно"                              test "$code" -eq 0
check "стратегии переведены"                 test -f "$INST/strategies/general.conf" -a -f "$INST/strategies/general_alt9.conf"
check "service.bat пропущен"                 test ! -e "$INST/strategies/service.conf"
check "списки и фейки скачаны"               test -f "$INST/lists/ipset-all.txt" -a -f "$INST/bin/quic_initial_4pda.to.bin"

check "ipset-all.txt.backup скачан в lists/"  same "$UP/lists/ipset-all.txt.backup" "$INST/lists/ipset-all.txt.backup"

section "Повтор без изменений"
sync_run
check "сообщает, что изменений нет"          has "$TMP/out" "изменений нет"

section "Обновление у Flowseal: удаления и переименования"
rm "$UP/lists/ipset-all.txt.backup" "$UP/general (OLD).bat" "$UP/bin/quic_initial_dbankcloud_ru.bin" "$UP/bin/quic_initial_4pda.to.bin" "$UP/lists/ipset-exclude.txt"
make_bat "$UP/general (ALT9).bat"  quic_initial_4pda_to.bin
make_bat "$UP/general (ALT13).bat" tls_clienthello_www_sferum_ru.bin
echo new > "$UP/bin/quic_initial_4pda_to.bin"; echo new > "$UP/bin/tls_clienthello_www_sferum_ru.bin"
printf 'STRATEGY_FILE="general_old"\n' > "$ETC/active.env"          # пользователь сидит на удаляемой
printf 'STRATEGY_NAME="my"\nPORTS_TCP="443"\nPORTS_UDP=""\nNFQWS_OPT="--filter-tcp=443"\n' > "$INST/strategies/my_custom.conf"
echo "мой.сайт" > "$INST/lists/list-general-user.txt"
echo mine > "$INST/bin/my_fake.bin"; echo "tls my_fake.bin" > "$ETC/fakes.conf"
sync_run
check "новая стратегия добавлена"            test -f "$INST/strategies/general_alt13.conf"
check "ALT9 обновлена"                       has "$INST/strategies/general_alt9.conf" "quic_initial_4pda_to.bin"
check "активная удалённая стратегия оставлена" test -f "$INST/strategies/general_old.conf"
check "о ней выдано предупреждение"          has "$TMP/out" "сейчас активна"
check "фейк активной стратегии оставлен"     test -f "$INST/bin/quic_initial_4pda.to.bin"
check "неиспользуемый фейк удалён"           test ! -e "$INST/bin/quic_initial_dbankcloud_ru.bin"
check "неиспользуемый список удалён"         test ! -e "$INST/lists/ipset-exclude.txt"
check "своя стратегия не тронута"            test -f "$INST/strategies/my_custom.conf"
check "*-user.txt не тронут"                 has "$INST/lists/list-general-user.txt" "мой.сайт"
check "фейк из подмены не тронут"            test -f "$INST/bin/my_fake.bin"
check "ipset-all.txt не удалён"              test -f "$INST/lists/ipset-all.txt"
check "ipset-all.txt.backup не удалён (его нет у Flowseal)" test -f "$INST/lists/ipset-all.txt.backup"

section "Изменение ipset-all.txt.backup у Flowseal"
printf '10.0.0.0/8\n192.0.2.0/24\n' > "$UP/lists/ipset-all.txt.backup"
sync_run
check "обновлённый .backup доехал"           same "$UP/lists/ipset-all.txt.backup" "$INST/lists/ipset-all.txt.backup"
sync_run
check "повтор: изменений нет"                has "$TMP/out" "изменений нет"
rm "$UP/lists/ipset-all.txt.backup"; sync_run
check "после исчезновения у Flowseal файл остался" test -f "$INST/lists/ipset-all.txt.backup"

section "После переключения стратегии"
printf 'STRATEGY_FILE="general_alt9"\n' > "$ETC/active.env"
sync_run
check "устаревшая стратегия удалена"         test ! -e "$INST/strategies/general_old.conf"
check "и её фейк тоже"                       test ! -e "$INST/bin/quic_initial_4pda.to.bin"

section "Сбой GitHub API"
snapshot "$TMP/before"; touch "$UP/.fail_api"
sync_run; code=$?; rm "$UP/.fail_api"; snapshot "$TMP/after"
check "завершается с ошибкой"                test "$code" -ne 0
check "рабочие файлы не изменены"            same "$TMP/before" "$TMP/after"

section "Сбой API только для каталога lists"
# Список стратегий получен, а каталог lists — нет. Если принять пустой ответ за
# «у Flowseal больше нет списков», очистка удалила бы все списки.
echo z.com > "$UP/lists/list-exclude.txt"; sync_run
snapshot "$TMP/before"; touch "$UP/.fail_api_lists"
sync_run; code=$?; rm "$UP/.fail_api_lists"; snapshot "$TMP/after"
check "завершается с ошибкой"                test "$code" -ne 0
check "списки не удалены"                    same "$TMP/before" "$TMP/after"

section "Обрыв загрузки на середине"
echo y.com >> "$UP/lists/list-general.txt"
snapshot "$TMP/before"; touch "$UP/.fail_raw"
sync_run; code=$?; rm "$UP/.fail_raw"; snapshot "$TMP/after"
check "завершается с ошибкой"                test "$code" -ne 0
check "частичных изменений нет"              same "$TMP/before" "$TMP/after"
sync_run
check "после восстановления изменение доехало" has "$INST/lists/list-general.txt" "y.com"

section "Незнакомый макрос у Flowseal"
cp "$INST/strategies/general_alt9.conf" "$TMP/alt9"
sed -i 's/%GameFilterUDP%/%BrandNewFilter%/g' "$UP/general (ALT9).bat"
sed -i 's/--dpi-desync=multisplit/--dpi-desync=multisplit --dpi-desync-repeats=8/' "$UP/general.bat"
sync_run; code=$?
check "синхронизация не прерывается"         test "$code" -eq 0
check "рабочая версия стратегии сохранена"   same "$TMP/alt9" "$INST/strategies/general_alt9.conf"
check "остальные стратегии обновлены"        has "$INST/strategies/general.conf" "repeats=8"
check "пользователь предупреждён"            has "$TMP/out" "не переведены"

section "Вредоносная стратегия у Flowseal"
MK="$TMP/mk_sync"
make_bat "$UP/general (EVIL).bat" x.bin
echo x > "$UP/bin/x.bin"
sync_run
cp "$INST/strategies/general_evil.conf" "$TMP/evil_good"
make_bat "$UP/general (EVIL).bat" 'x$(touch '"$MK"').bin'
sync_run; code=$?
check "синхронизация завершается успешно"      test "$code" -eq 0
check "прежняя рабочая версия сохранена"       same "$TMP/evil_good" "$INST/strategies/general_evil.conf"
check "пользователь предупреждён"              has "$TMP/out" "оставлена прежняя версия"
check "маркер не создан при синхронизации"     test ! -e "$MK"
make_bat "$UP/general (EVIL2).bat" 'y`touch '"$MK"'`.bin'
sync_run; code=$?
check "обратные кавычки: синхронизация успешна" test "$code" -eq 0
check "обратные кавычки: стратегия не записана" test ! -e "$INST/strategies/general_evil2.conf"
for c in "$INST"/strategies/*.conf; do ( . "$c" ) >/dev/null 2>&1; done
check "подключение любого .conf не создаёт маркер" test ! -e "$MK"
rm -f "$UP/general (EVIL2).bat" "$UP/general (EVIL).bat" "$INST/strategies/general_evil.conf"

section "Подозрительные имена файлов"
# имена, которые после раскодирования уходят из каталога или начинаются с точки;
# временный каталог sync — внутри $TMP, чтобы увидеть выход за его пределы
mkdir -p "$TMP/tmpd"
echo hidden > "$UP/bin/.hidden.bin"
echo hidden > "$UP/lists/.hidden.txt"
cp "$UP/general.bat" "$UP/.payload"
tmp_sync() { MOCK_UPSTREAM="$UP" ETC_DIR="$ETC" TMPDIR="$TMP/tmpd" mocked bash "$INST/sync-flowseal.sh" > "$TMP/out" 2>&1; }
# 1) подозрительное имя стратегии
printf '%s\n' 'http://mock/raw/general%2F..%2F..%2Fx.bat' > "$UP/.extra_urls"
tmp_sync; code=$?
check "стратегия с / в имени: синхронизация успешна"   test "$code" -eq 0
check "стратегия с / в имени: выдано «подозрительное имя файла»" has "$TMP/out" "подозрительное имя файла"
rm -f "$UP/.extra_urls"
# 2) подозрительные имена списков и фейков
tmp_sync; code=$?
check "обычные файлы синхронизируются без предупреждений"  test "$code" -eq 0
check_not "предупреждения об именах нет"               has "$TMP/out" "подозрительное имя файла"
printf '%s\n' 'http://mock/raw/bin/.hidden.bin' 'http://mock/raw/bin/..%2F..%2Fpwn.bin' > "$UP/bin/.extra_urls"
printf '%s\n' 'http://mock/raw/lists/..%2F..%2Fevil.txt' 'http://mock/raw/lists/%2Ehidden.txt' > "$UP/lists/.extra_urls"
tmp_sync; code=$?
check "список/фейк с / или точкой в имени: синхронизация успешна" test "$code" -eq 0
check "выдано «подозрительное имя файла»"      has "$TMP/out" "подозрительное имя файла"
check "за пределы временного каталога ничего не записано" test -z "$(find "$TMP/tmpd" -mindepth 1 -maxdepth 1)"
check "ничего не записано выше каталога sync"  test ! -e "$TMP/pwn.bin" -a ! -e "$TMP/evil.txt" -a ! -e "$INST/../pwn.bin" -a ! -e "$INST/../evil.txt"
check "скрытые файлы не попали в bin/ и lists/" test ! -e "$INST/bin/.hidden.bin" -a ! -e "$INST/lists/.hidden.txt"
check "нет файлов pwn.bin и evil.txt в установке" test -z "$(find "$INST" -name pwn.bin -o -name evil.txt)"
check "обычные файлы синхронизируются дальше"  test -f "$INST/bin/x.bin" -a -f "$INST/lists/list-general.txt"
rm -f "$UP/.payload" "$UP/.extra_urls" "$UP/bin/.extra_urls" "$UP/lists/.extra_urls" "$UP/bin/.hidden.bin" "$UP/lists/.hidden.txt"

finish
