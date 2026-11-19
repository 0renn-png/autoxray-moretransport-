#!/bin/bash

# Цвета для вывода
GRN='\033[1;32m'
RED='\033[1;31m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m' # No Color

# >>> AX-LIB-BEGIN
# ============================================================================
#  autoXRAY multi v2: служебные функции (бэкапы, откат, состояние, диагностика)
# ============================================================================
AX_ROOT="${AX_TEST_ROOT:-}"                     # префикс путей, нужен только для тестов
AX_HOME="$AX_ROOT/usr/local/etc/xray/autoxray"
AX_STATE="$AX_HOME/state.env"
AX_LINKS="$AX_HOME/links.txt"
AX_BACKUPS="$AX_HOME/backups"
AX_XRAY_CFG="$AX_ROOT/usr/local/etc/xray/config.json"
AX_XRAY_NEW="$AX_ROOT/usr/local/etc/xray/config.new.json"   # Xray требует расширение .json
AX_NGINX_DEF="$AX_ROOT/etc/nginx/conf.d/default.conf"
AX_NGINX_CONF="$AX_ROOT/etc/nginx/nginx.conf"
AX_STREAM_DIR="$AX_ROOT/etc/nginx/autoxray-stream.d"
AX_CERT_DIR="$AX_ROOT/var/lib/xray/cert"
AX_LIBDIR="$AX_ROOT/usr/local/lib/autoxray"
AX_KEEP=20
AX_PRE_BACKUP=""

ax_log()  { echo -e "${GRN}$*${NC}"; }
ax_warn() { echo -e "${YEL}$*${NC}"; }
ax_err()  { echo -e "${RED}$*${NC}" >&2; }

# --- состояние (ключи сохраняются между запусками) --------------------------
AX_STATE_VARS=(DOMAIN WEB_PATH path_subpage path_xhttp xray_uuid_vrv xray_shortIds_vrv
    socksUser socksPasw xray_dest_vrv xray_dest_vrv2 xray_privateKey_vrv xray_publicKey_vrv
    path_xhttp_r path_ws path_grpc path_xp path_xe vlessenc_dec vlessenc_enc
    FRONT FW_TCP FW_UDP)

ax_state_load() { [ -f "$AX_STATE" ] || return 1; . "$AX_STATE"; }

ax_state_save() {
    local v tmp="$AX_STATE.tmp"
    mkdir -p "$AX_HOME"
    ( umask 077
      for v in "${AX_STATE_VARS[@]}"; do
          [ -n "${!v+x}" ] && printf '%s=%q\n' "$v" "${!v}"
      done > "$tmp" )
    chmod 600 "$tmp"
    mv -f "$tmp" "$AX_STATE"
}

# --- резервные копии ---------------------------------------------------------
ax_backup_create() {
    local ts dir f
    ts=$(date +%Y%m%d-%H%M%S); dir="$AX_BACKUPS/$ts"
    while [ -e "$dir" ]; do dir="$AX_BACKUPS/$ts-$RANDOM"; done
    mkdir -p "$dir"
    [ -f "$AX_XRAY_CFG" ]   && cp -p "$AX_XRAY_CFG"   "$dir/xray-config.json"
    [ -f "$AX_NGINX_DEF" ]  && cp -p "$AX_NGINX_DEF"  "$dir/nginx-default.conf"
    [ -f "$AX_NGINX_CONF" ] && cp -p "$AX_NGINX_CONF" "$dir/nginx.conf"
    if ls "$AX_STREAM_DIR"/*.conf >/dev/null 2>&1; then
        mkdir -p "$dir/stream"; cp -p "$AX_STREAM_DIR"/*.conf "$dir/stream/"
    fi
    [ -f "$AX_STATE" ] && cp -p "$AX_STATE" "$dir/state.env"
    [ -f "$AX_LINKS" ] && cp -p "$AX_LINKS" "$dir/links.txt"
    if [ -n "${WEB_PATH:-}" ] && [ -n "${path_subpage:-}" ]; then
        for f in "$WEB_PATH/$path_subpage".json "$WEB_PATH/$path_subpage".html "$WEB_PATH/$path_subpage".txt; do
            [ -f "$f" ] && { mkdir -p "$dir/www"; cp -p "$f" "$dir/www/"; }
        done
    fi
    echo "${1:-manual}" > "$dir/REASON"
    chmod -R go-rwx "$AX_BACKUPS"          # в копиях лежат ключи
    ls -1d "$AX_BACKUPS"/*/ 2>/dev/null | sort -r | tail -n +$((AX_KEEP + 1)) | xargs -r rm -rf
    AX_LAST_BACKUP="$dir"
}

ax_backup_path() { ls -1d "$AX_BACKUPS"/*/ 2>/dev/null | sort -r | sed -n "${1}p" | sed 's:/$::'; }

ax_backup_list() {
    local i=0 d
    for d in $(ls -1d "$AX_BACKUPS"/*/ 2>/dev/null | sort -r); do
        i=$((i + 1))
        printf '%2d) %s  [%s]\n' "$i" "$(basename "$d")" "$(cat "$d/REASON" 2>/dev/null)"
    done
    [ "$i" -gt 0 ] || echo "Резервных копий нет."
}

# Возвращает файлы из копии на место. Чего в копии нет, то не трогаем,
# кроме конфига Xray и stream-конфигов: их отсутствие значит "раньше не было".
ax_restore_from() {
    local src="$1" f
    [ -d "$src" ] || return 1
    if [ -f "$src/xray-config.json" ]; then cp -p "$src/xray-config.json" "$AX_XRAY_CFG"
    else rm -f "$AX_XRAY_CFG"; fi
    [ -f "$src/nginx-default.conf" ] && cp -p "$src/nginx-default.conf" "$AX_NGINX_DEF"
    [ -f "$src/nginx.conf" ]         && cp -p "$src/nginx.conf" "$AX_NGINX_CONF"
    mkdir -p "$AX_STREAM_DIR"; rm -f "$AX_STREAM_DIR"/*.conf
    if [ -d "$src/stream" ]; then cp -p "$src/stream"/*.conf "$AX_STREAM_DIR/" 2>/dev/null; fi
    [ -f "$src/state.env" ] && cp -p "$src/state.env" "$AX_STATE"
    [ -f "$src/links.txt" ] && cp -p "$src/links.txt" "$AX_LINKS"
    if [ -d "$src/www" ] && [ -n "${WEB_PATH:-}" ]; then
        for f in "$src/www"/*; do [ -f "$f" ] && cp -p "$f" "$WEB_PATH/"; done
    fi
    return 0
}

ax_services_reload() {
    systemctl stop xray 2>/dev/null
    if nginx -t >/dev/null 2>&1; then systemctl restart nginx; else return 1; fi
    [ -f "$AX_XRAY_CFG" ] && systemctl restart xray
    sleep 2
    systemctl is-active --quiet nginx && { [ ! -f "$AX_XRAY_CFG" ] || systemctl is-active --quiet xray; }
}

ax_backup_restore() {
    local n="$1" src pre
    [[ "$n" =~ ^[0-9]+$ ]] || { ax_err "Укажите номер копии (см. autoxray backup list)"; return 1; }
    src=$(ax_backup_path "$n")
    [ -d "$src" ] || { ax_err "Копии №$n нет"; return 1; }
    ax_state_load 2>/dev/null
    ax_backup_create "перед откатом к $(basename "$src")"; pre="$AX_LAST_BACKUP"
    ax_restore_from "$src"
    if [ -f "$AX_XRAY_CFG" ] && ! xray run -test -c "$AX_XRAY_CFG" >/dev/null 2>&1; then
        ax_err "❌ Конфиг из копии не проходит проверку Xray, возвращаю как было"
        ax_restore_from "$pre"; ax_services_reload; return 1
    fi
    if ! ax_services_reload; then
        ax_err "❌ Сервисы не поднялись после отката, возвращаю как было"
        ax_restore_from "$pre"; ax_services_reload; return 1
    fi
    ax_log "✅ Откат к копии $(basename "$src") выполнен (прежнее состояние сохранено как $(basename "$pre"))"
}

# Откат установки при ошибке: возвращаем то, что было до запуска скрипта.
ax_rollback_install() {
    ax_err "❌ $1"
    ax_err "Откатываю изменения к состоянию до запуска скрипта..."
    rm -f "$AX_XRAY_NEW"
    if [ -n "$AX_PRE_BACKUP" ] && ax_restore_from "$AX_PRE_BACKUP"; then
        ax_services_reload || true
        ax_warn "Прежние файлы возвращены (копия: $AX_PRE_BACKUP)"
    fi
    exit 1
}

# --- установка: проверки, флаг, Reality-цели ---------------------------------
ax_preflight() {
    local line proc busy="" ans
    for p in 80 443; do
        while read -r line; do
            proc=$(echo "$line" | grep -o 'users:(("[^"]*"' | head -1 | sed 's/users:(("//;s/"//')
            [ -z "$proc" ] && continue
            [[ "$proc" =~ ^(nginx|xray)$ ]] || busy+="  порт $p занят процессом: $proc"$'\n'
        done < <(ss -H -ltnp "sport = :$p" 2>/dev/null)
    done
    if [ -n "$busy" ]; then
        ax_warn "⚠️ Найдены посторонние службы на нужных портах:"
        echo -n "$busy"
        read -p "Продолжить установку? (y/N): " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { ax_err "Установка прервана."; exit 1; }
    fi
    if [ -f "$AX_XRAY_CFG" ] && [ ! -f "$AX_STATE" ]; then
        ax_warn "⚠️ Найден конфиг Xray, созданный не этим скриптом. Он будет заменён (копия сохранится в $AX_BACKUPS)."
    fi
}

ax_get_flag() {
    local cc flag="" i n url
    for url in https://ipinfo.io/country https://ipapi.co/country/; do
        cc=$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' | tr 'a-z' 'A-Z')
        [[ "$cc" =~ ^[A-Z]{2}$ ]] && break
        cc=""
    done
    [ -n "$cc" ] || { printf '\xF0\x9F\x87\xAA\xF0\x9F\x87\xBA'; return; }     # 🇪🇺
    for i in 0 1; do
        n=$(( $(printf '%d' "'${cc:i:1}") - 65 ))
        flag+=$(printf '\xF0\x9F\x87'"\\x$(printf '%02x' $((0xA6 + n)))")
    done
    printf '%s' "$flag"
}

# Выбирает маскировочный сайт для Reality: нужен TLS 1.3 и HTTP/2.
# Аргументы: домены, которые брать нельзя (наш домен, уже выбранные).
ax_pick_reality_target() {
    local cand=(www.bing.com github.com tradingview.com www.theregister.com www.computerworld.com www.techadvisor.com www.caradisiac.com www.manomano.fr)
    local pool d r ex skip first=""
    mapfile -t pool < <(printf '%s\n' "${cand[@]}" | shuf)
    for d in "${pool[@]}"; do
        skip=false
        for ex in "$@"; do [ "$d" = "$ex" ] && skip=true; done
        $skip && continue
        [ -z "$first" ] && first="$d"
        r=$(curl -s -o /dev/null --max-time 6 --http2 --tlsv1.3 -w '%{http_version}' "https://$d/" 2>/dev/null)
        if [ "$r" = "2" ]; then echo "$d"; return 0; fi
    done
    echo -e "${YEL}⚠️ Ни один сайт из списка не подтвердил TLS 1.3 + HTTP/2, беру $first без проверки${NC}" >&2
    echo "$first"
}

ax_nginx_has_stream() {
    local v; v=$(nginx -V 2>&1)
    [[ "$v" == *"--with-stream"* && "$v" != *"--with-stream=dynamic"* && "$v" == *"--with-stream_ssl_preread_module"* ]]
}

# --- SNI-разводка порта 443 через nginx stream ---------------------------------
ax_stream_write() {
    local dir="$AX_STREAM_DIR"
    mkdir -p "$dir"
    if ! grep -q "autoxray-stream.d" "$AX_NGINX_CONF" 2>/dev/null; then
        printf '\n# autoXRAY: SNI-разводка порта 443\ninclude /etc/nginx/autoxray-stream.d/*.conf;\n' >> "$AX_NGINX_CONF"
    fi
    rm -f "$dir"/*.conf
    [ "$FRONT" = true ] || return 0
    {
        echo "stream {"
        echo "    map \$ssl_preread_server_name \$autoxray_upstream {"
        echo "        hostnames;"
        [ "$USE_REALITY_VISION" = true ] && echo "        $xray_dest_vrv  reality_vision;"
        [ "$USE_REALITY_XHTTP" = true ]  && echo "        $xray_dest_vrv2  reality_xhttp;"
        echo "        default  xray_tls;"
        echo "    }"
        echo "    upstream xray_tls { server 127.0.0.1:${xray_tls_port}; }"
        [ "$USE_REALITY_VISION" = true ] && echo "    upstream reality_vision { server 127.0.0.1:${port_rv}; }"
        [ "$USE_REALITY_XHTTP" = true ]  && echo "    upstream reality_xhttp { server 127.0.0.1:${port_rx}; }"
        echo "    server {"
        echo "        listen 443;"
        echo "        ssl_preread on;"
        echo "        proxy_pass \$autoxray_upstream;"
        echo "        proxy_connect_timeout 10s;"
        echo "        proxy_timeout 1h;"
        echo "    }"
        echo "}"
    } > "$dir/autoxray.conf"
}

# Включение нового конфига: проверка уже пройдена, здесь замена и запуск с откатом.
ax_activate() {
    mv -f "$AX_XRAY_NEW" "$AX_XRAY_CFG"
    # в конфиге ключи и пароли: читают только root и группа xraycert
    chgrp xraycert "$AX_XRAY_CFG" 2>/dev/null || ax_rollback_install "не удалось назначить группе xraycert доступ к конфигу"
    chmod 640 "$AX_XRAY_CFG"
    systemctl stop xray 2>/dev/null
    ax_stream_write

    # В конфиге Xray указан /var/log/xray/error.log. Подготовим каталог и файл
    # для пользователя службы заранее: иначе Xray может падать с permission denied
    # ещё до чтения сертификата.
    getent passwd xray >/dev/null 2>&1 || ax_rollback_install "пользователь службы xray не найден"
    mkdir -p /var/log/xray || ax_rollback_install "не удалось создать /var/log/xray"
    touch /var/log/xray/error.log || ax_rollback_install "не удалось создать /var/log/xray/error.log"
    chown xray:xray /var/log/xray /var/log/xray/error.log || ax_rollback_install "не удалось назначить владельца логов Xray"
    chmod 750 /var/log/xray
    chmod 640 /var/log/xray/error.log

    if ! nginx -t >"$AX_HOME/nginx-test.log" 2>&1; then
        cat "$AX_HOME/nginx-test.log" >&2
        ax_rollback_install "nginx не принял конфигурацию"
    fi
    systemctl restart nginx || ax_rollback_install "nginx не запустился"
    systemctl restart xray; sleep 2
    if ! systemctl is-active --quiet xray; then
        ax_warn "Последние сообщения Xray перед откатом:"
        journalctl -u xray -n 30 --no-pager 2>/dev/null >&2 || true
        ax_rollback_install "Xray не запустился с новым конфигом; права сертификата автоматически не ослаблялись"
    fi
    ss -H -ltn 'sport = :443' 2>/dev/null | grep -q . || ax_rollback_install "порт 443 никто не слушает"
}

# --- файрвол: только добавляем разрешения, ничего не включаем ------------------
ax_firewall() {
    local mode="${1:-status}" p tcp udp active=false missing=0
    tcp="${FW_TCP:-80 443}"; udp="${FW_UDP:-443}"
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active" && active=true
    if [ "$active" != true ]; then
        [ "$mode" = status ] || [ "$mode" = open ] && \
        ax_warn "ufw не включён, локальный файрвол ничего не блокирует. Проверьте файрвол в панели хостера: TCP: $tcp  UDP: $udp"
        return 0
    fi
    for p in $tcp; do
        if ufw status | grep -Eq "^$p(/tcp)?[[:space:]]+ALLOW"; then [ "$mode" = status ] && echo "  TCP $p: открыт"
        elif [ "$mode" = open ]; then ufw allow "$p"/tcp >/dev/null && echo "  TCP $p: открыл"
        else echo "  TCP $p: ЗАКРЫТ"; missing=1; fi
    done
    for p in $udp; do
        if ufw status | grep -Eq "^$p(/udp)?[[:space:]]+ALLOW"; then [ "$mode" = status ] && echo "  UDP $p: открыт"
        elif [ "$mode" = open ]; then ufw allow "$p"/udp >/dev/null && echo "  UDP $p: открыл"
        else echo "  UDP $p: ЗАКРЫТ"; missing=1; fi
    done
    [ "$missing" = 1 ] && ax_warn "Откройте недостающие порты командой: autoxray firewall open"
    return 0
}

# --- диагностика ---------------------------------------------------------------
ax_status() {
    local s ver ok bad
    ok="${GRN}работает${NC}"; bad="${RED}НЕ РАБОТАЕТ${NC}"
    echo -e "Домен: ${CYAN}${DOMAIN:-?}${NC}"
    echo -e "Порт 443: $([ "$FRONT" = true ] && echo 'nginx stream, разводка по SNI' || echo 'напрямую Xray')"
    for s in xray nginx; do
        systemctl is-active --quiet "$s" && echo -e "$s: $ok" || echo -e "$s: $bad"
    done
    ver=$(xray version 2>/dev/null | awk 'NR==1{print $2}'); echo "Версия Xray: ${ver:-?}"
    echo "Слушают порты (TCP/UDP):"
    ss -H -ltnu 2>/dev/null | awk '{print $1" "$5}' | grep -E ':443$' | sort -u | sed 's/^/  /'
    if [ -f "$AX_CERT_DIR/fullchain.pem" ]; then
        echo "Сертификат: $(openssl x509 -in "$AX_CERT_DIR/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2)"
    fi
    echo "Синхронизация времени: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo ?)"
    echo "Watchdog: $(systemctl is-active autoxray-watchdog.timer 2>/dev/null)"
    echo "Протоколов в подписке: $(grep -c '://' "$AX_LINKS" 2>/dev/null || echo 0)"
    echo "Резервных копий: $(ls -1d "$AX_BACKUPS"/*/ 2>/dev/null | wc -l)"
}

ax_links() {
    [ -f "$AX_LINKS" ] || { ax_err "Ссылок нет, установка ещё не выполнялась"; return 1; }
    cat "$AX_LINKS"
    echo -e "${YEL}Подписка JSON:${NC}      https://$DOMAIN/$path_subpage.json"
    echo -e "${YEL}Подписка base64:${NC}    https://$DOMAIN/$path_subpage.txt"
    echo -e "${YEL}Страница с QR:${NC}      https://$DOMAIN/$path_subpage.html"
}

# Поднимает локальный клиент для каждого протокола из подписки и ходит через него на example.com
ax_selftest() {
    local json="$WEB_PATH/$path_subpage.json" tmp n i name port pid code t pass=0 fail=0
    [ -f "$json" ] || { ax_err "Файл подписки не найден: $json"; return 1; }
    tmp=$(mktemp -d); n=$(jq length "$json")
    echo "Проверяю протоколов: $n (запрос к https://example.com через каждый)"
    for i in $(seq 0 $((n - 1))); do
        name=$(jq -r --argjson i "$i" '.[$i].remarks' "$json")
        port=$(jq -r --argjson i "$i" '[.[$i].inbounds[] | select(.protocol=="socks") | .port][0]' "$json")
        jq --argjson i "$i" '.[$i]' "$json" > "$tmp/c$i.json"
        xray run -c "$tmp/c$i.json" >"$tmp/c$i.log" 2>&1 & pid=$!
        for t in 1 2 3 4 5 6 7 8 9 10; do
            (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.5
        done
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 --socks5-hostname "127.0.0.1:$port" https://example.com/ 2>/dev/null)
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        if [[ "$code" =~ ^[23] ]]; then echo -e "  ${GRN}OK  ${NC} $name"; pass=$((pass + 1))
        else echo -e "  ${RED}FAIL${NC} $name (HTTP $code)"; fail=$((fail + 1)); fi
    done
    rm -rf "$tmp"
    echo "Итого: OK $pass, FAIL $fail"
    [ "$fail" -eq 0 ]
}

ax_check_updates() {
    local cur latest
    cur=$(xray version 2>/dev/null | awk 'NR==1{print $2}')
    latest=$(curl -sIL --max-time 10 -o /dev/null -w '%{url_effective}' https://github.com/XTLS/Xray-core/releases/latest 2>/dev/null | sed -n 's|.*/tag/v||p')
    echo "Xray установлен: ${cur:-?}"
    echo "Xray последний:  ${latest:-не удалось узнать}"
    if [ -n "$latest" ] && [ "$cur" != "$latest" ]; then
        ax_warn "Есть новая версия. Обновление: перед ним сделайте autoxray backup create, после него autoxray selftest"
        echo '  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install'
    fi
    local g="$AX_ROOT/usr/local/share/xray/geosite.dat"
    [ -f "$g" ] && echo "geosite.dat обновлён: $(date -r "$g" +%F)"
}

ax_usage() {
    cat <<USAGE
autoxray: служебные команды
  autoxray status             состояние сервисов, портов и сертификата
  autoxray links              показать ссылки и адреса подписок
  autoxray selftest           проверить каждый протокол реальным запросом
  autoxray backup list        список резервных копий
  autoxray backup create      сделать копию сейчас
  autoxray backup restore N   откатиться к копии номер N
  autoxray firewall [open]    статус портов в ufw (open: открыть недостающие)
  autoxray check-updates      проверить версию Xray
Установка / переустановка: bash autoXRAY2-multi.sh ваш-домен.com
USAGE
}

# --- установка вспомогательных файлов (watchdog, logrotate, команда autoxray) --
# Команда autoxray собирается из функций, а не копирует $0. Поэтому она
# устанавливается и при запуске через bash <(curl ...), где $0=/dev/fd/....
ax_install_helpers() {
    local helper_tmp fn
    mkdir -p "$AX_LIBDIR" "$AX_ROOT/usr/local/bin" || {
        ax_warn "Не удалось создать каталоги для команды autoxray"
        return 1
    }

    for fn in ax_state_load ax_backup_create ax_backup_path ax_backup_list \
              ax_restore_from ax_services_reload ax_backup_restore ax_firewall \
              ax_status ax_links ax_selftest ax_check_updates ax_usage; do
        declare -F "$fn" >/dev/null || {
            ax_warn "Не найдена функция $fn; служебная команда autoxray не собрана"
            return 1
        }
    done

    helper_tmp="$AX_LIBDIR/autoxray.sh.tmp.$$"
    if ! {
        cat <<'AXHELPER_HEADER'
#!/bin/bash
GRN='\033[1;32m'
RED='\033[1;31m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'
AX_ROOT="${AX_TEST_ROOT:-}"
AX_HOME="$AX_ROOT/usr/local/etc/xray/autoxray"
AX_STATE="$AX_HOME/state.env"
AX_LINKS="$AX_HOME/links.txt"
AX_BACKUPS="$AX_HOME/backups"
AX_XRAY_CFG="$AX_ROOT/usr/local/etc/xray/config.json"
AX_NGINX_DEF="$AX_ROOT/etc/nginx/conf.d/default.conf"
AX_NGINX_CONF="$AX_ROOT/etc/nginx/nginx.conf"
AX_STREAM_DIR="$AX_ROOT/etc/nginx/autoxray-stream.d"
AX_CERT_DIR="$AX_ROOT/var/lib/xray/cert"
AX_LIBDIR="$AX_ROOT/usr/local/lib/autoxray"
AX_KEEP=20
ax_log()  { echo -e "${GRN}$*${NC}"; }
ax_warn() { echo -e "${YEL}$*${NC}"; }
ax_err()  { echo -e "${RED}$*${NC}" >&2; }
AXHELPER_HEADER
        for fn in ax_state_load ax_backup_create ax_backup_path ax_backup_list \
                  ax_restore_from ax_services_reload ax_backup_restore ax_firewall \
                  ax_status ax_links ax_selftest ax_check_updates ax_usage; do
            declare -f "$fn"
        done
        cat <<'AXHELPER_MAIN'
case "${1:-}" in
    ""|help|--help|-h)
        ax_usage
        exit 0
        ;;
    status|links|selftest|backup|firewall|check-updates)
        [[ $EUID -eq 0 ]] || { ax_err "Нужны root права"; exit 1; }
        ax_cmd="$1"; shift
        ax_state_load || { [ "$ax_cmd" = check-updates ] || { ax_err "Состояние не найдено: сначала выполните установку"; exit 1; }; }
        case "$ax_cmd" in
            status)         ax_status ;;
            links)          ax_links ;;
            selftest)       ax_selftest ;;
            firewall)       ax_firewall "${1:-status}" ;;
            check-updates)  ax_check_updates ;;
            backup)
                case "${1:-list}" in
                    list)    ax_backup_list ;;
                    create)  ax_backup_create "${2:-вручную}"; ax_log "Копия создана: $AX_LAST_BACKUP" ;;
                    restore) ax_backup_restore "${2:-}" ;;
                    *)       ax_usage; exit 1 ;;
                esac
                ;;
        esac
        exit $?
        ;;
    *)
        ax_err "Неизвестная команда: $1"
        ax_usage
        exit 2
        ;;
esac
AXHELPER_MAIN
    } > "$helper_tmp"; then
        rm -f "$helper_tmp"
        ax_warn "Не удалось собрать служебную команду autoxray"
        return 1
    fi

    chmod 755 "$helper_tmp" && mv -f "$helper_tmp" "$AX_LIBDIR/autoxray.sh" && \
        ln -sfn "$AX_LIBDIR/autoxray.sh" "$AX_ROOT/usr/local/bin/autoxray" || {
            rm -f "$helper_tmp"
            ax_warn "Не удалось установить ссылку /usr/local/bin/autoxray"
            return 1
        }
    ax_log "✅ Команда autoxray установлена"

    cat > "$AX_LIBDIR/watchdog.sh" <<'WDEOF'
#!/bin/bash
# autoXRAY watchdog: перезапускает Xray/nginx, если они упали или 443 никто не слушает
STAMP=/run/autoxray-watchdog.last
now=$(date +%s)
last=$(cat "$STAMP" 2>/dev/null || echo 0)
[ $((now - last)) -lt 120 ] && exit 0
bad=""
for s in xray nginx; do systemctl is-active --quiet "$s" || bad+="$s "; done
ss -H -ltn 'sport = :443' | grep -q . || bad+="port443 "
[ -z "$bad" ] && exit 0
logger -t autoxray-watchdog "проблема: $bad, перезапускаю nginx и xray"
echo "$now" > "$STAMP"
systemctl restart nginx
systemctl restart xray
WDEOF
    chmod 755 "$AX_LIBDIR/watchdog.sh"

    cat > "$AX_ROOT/etc/systemd/system/autoxray-watchdog.service" <<UNIT
[Unit]
Description=autoXRAY watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/lib/autoxray/watchdog.sh
UNIT
    cat > "$AX_ROOT/etc/systemd/system/autoxray-watchdog.timer" <<UNIT
[Unit]
Description=autoXRAY watchdog timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
UNIT
    mkdir -p "$AX_ROOT/etc/logrotate.d"
    cat > "$AX_ROOT/etc/logrotate.d/autoxray" <<LR
/var/log/xray/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
LR
    systemctl daemon-reload 2>/dev/null
    systemctl enable --now autoxray-watchdog.timer >/dev/null 2>&1 && ax_log "✅ Watchdog включён (проверка раз в минуту)"
}
# >>> AX-LIB-END

# --- служебные команды: autoxray status|links|selftest|backup|firewall|... ----
case "${1:-}" in
    ""|help|--help|-h)
        ax_usage
        exit 0
        ;;
    status|links|selftest|backup|firewall|check-updates)
        [[ $EUID -eq 0 ]] || { ax_err "Нужны root права"; exit 1; }
        ax_cmd="$1"; shift
        ax_state_load || { [ "$ax_cmd" = check-updates ] || { ax_err "Состояние не найдено: сначала выполните установку"; exit 1; }; }
        case "$ax_cmd" in
            status)         ax_status ;;
            links)          ax_links ;;
            selftest)       ax_selftest ;;
            firewall)       ax_firewall "${1:-status}" ;;
            check-updates)  ax_check_updates ;;
            backup)
                case "${1:-list}" in
                    list)    ax_backup_list ;;
                    create)  ax_backup_create "${2:-вручную}"; ax_log "Копия создана: $AX_LAST_BACKUP" ;;
                    restore) ax_backup_restore "${2:-}" ;;
                    *)       ax_usage; exit 1 ;;
                esac ;;
        esac
        exit $?
        ;;
esac

echo -e "${GRN}Версия: 164 (multi-protocol v2, без Shadowsocks) ${NC}"
sleep 1

[[ $EUID -eq 0 ]] || { echo -e "${RED}❌ Скрипту нужны root права!${NC}"; exit 1; }

# Компактная проверка ОС (Debian / Ubuntu)
. /etc/os-release 2>/dev/null
[[ "$ID" =~ ^(debian|ubuntu)$ ]] || { echo -e "${RED}❌ Ошибка: поддерживаются только Debian и Ubuntu!${NC}"; exit 1; }
[[ "$ID" == "ubuntu" ]] && echo -e "${YEL}⚠️ Внимание: запуск на Ubuntu. Рекомендованная система: Debian 12/13.${NC}"

DOMAIN=$1

# Аргумент, не являющийся командой управления, должен быть доменным именем.
# Это не даёт случайной опечатке запустить установку с некорректным доменом.
if [[ ! "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
    ax_err "Укажите корректный домен для установки. Пример: bash autoXRAY2-multi.sh example.com"
    ax_usage
    exit 2
fi

# --- проверки перед установкой, сохранённое состояние, резервная копия ---
ax_preflight
FLAG="${FLAG:-$(ax_get_flag)}"
echo -e "Флаг в названиях конфигов: ${FLAG}"
WEB_PATH="/var/www/$DOMAIN"
NEW_DOMAIN="$DOMAIN"
if [ -f "$AX_STATE" ]; then
    ax_state_load
    ax_backup_create "перед установкой"
    AX_PRE_BACKUP="$AX_LAST_BACKUP"
    if [ "$DOMAIN" = "$NEW_DOMAIN" ]; then
        read -p "$(echo -e "${YEL}Найдена прошлая установка. Сохранить прежние ключи и ссылки (клиенты не отвалятся)? (Y/n): ${NC}")" keep_state
        if [[ "$keep_state" =~ ^[Nn]$ ]]; then AX_FORGET=true; fi
    else
        ax_warn "Домен изменился ($DOMAIN -> $NEW_DOMAIN), ключи будут созданы заново"
        AX_FORGET=true
    fi
    if [ "$AX_FORGET" = true ]; then
        for v in "${AX_STATE_VARS[@]}"; do unset "$v"; done
    else
        echo -e "${GRN}Использую сохранённые ключи, подписка останется прежней${NC}"
    fi
else
    ax_backup_create "перед установкой"
    AX_PRE_BACKUP="$AX_LAST_BACKUP"
fi
DOMAIN="$NEW_DOMAIN"
WEB_PATH="/var/www/$DOMAIN"

KEYRING_PKG=$([ "$ID" = "ubuntu" ] && echo "ubuntu-keyring" || echo "debian-archive-keyring")

echo -e "${YEL}Подготовка официального репозитория Nginx для $ID ($VERSION_CODENAME)...${NC}"
apt-get update && apt-get install -y curl gnupg2 ca-certificates lsb-release $KEYRING_PKG jq dnsutils openssl wget tar socat cron gettext-base

# Добавление ключа и репозитория nginx.org
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/$ID $VERSION_CODENAME nginx" \
    | tee /etc/apt/sources.list.d/nginx.list >/dev/null

echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
    | tee /etc/apt/preferences.d/99nginx >/dev/null

apt-get update
apt-get install -y nginx
systemctl enable --now nginx
systemctl enable --now cron

LOCAL_IP=$(hostname -I | awk '{print $1}')
DNS_IP=$(dig +short "$DOMAIN" | grep '^[0-9]' | head -n 1)

if [ "$LOCAL_IP" != "$DNS_IP" ]; then
    echo -e "${RED}❌ Внимание: IP-адрес ($LOCAL_IP) не совпадает с A-записью $DOMAIN ($DNS_IP).${NC}"
    echo -e "${YEL}Правильно укажите одну A-запись для вашего домена в ДНС - $LOCAL_IP ${NC}"
    
	read -p "Продолжить на ваш страх и риск? (y/N):" choice

	if [[ ! "$choice" =~ ^[Yy]$ ]]; then
		echo -e "${RED}Выполнение скрипта прервано.${NC}"
		exit 1
	fi
    echo -e "${YEL}Продолжение выполнения скрипта...${NC}"
fi

# === ВОПРОСЫ ПОЛЬЗОВАТЕЛЮ ===
read -p "$(echo -e "\n${YEL}Устанавливать Web Proxy для Telegram? (y/n, по умолчанию n): ${NC}")" choice_mtp
choice_mtp=${choice_mtp:-n}
if [[ "$choice_mtp" =~ ^[Yy]$ ]]; then
    INSTALL_MTP=true
    NGINX_web_proxy='    # web proxy
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }'
else
    INSTALL_MTP=false
    NGINX_web_proxy='    location / {
        try_files $uri $uri/ =404;
    }'
fi

echo -e "\n${YEL}Выберите TLS fingerprint для маскировки трафика:${NC}"
echo "1) chrome    3) safari   5) android   7) 360"
echo "2) firefox   4) ios      6) edge      8) qq"
read -p "Введите номер [1-8] (по умолчанию 2 - firefox): " fp_choice

case $fp_choice in
    1) fpBro="chrome" ;;
    2) fpBro="firefox" ;;
    3) fpBro="safari" ;;
    4) fpBro="ios" ;;
    5) fpBro="android" ;;
    6) fpBro="edge" ;;
    7) fpBro="360" ;;
    8) fpBro="qq" ;;
    *) fpBro="firefox" ;;
esac

# === РОССИЙСКИЕ САЙТЫ И IP ЧЕРЕЗ ЭТОТ СЕРВЕР ===
echo -e "\n${YEL}Российские сайты и IP через этот сервер:${NC}"
echo "1) блокировать (.ru/.su, Яндекс, VK, российские IP) - по умолчанию"
echo "2) пропускать (сервисы проверки IP всё равно блокируются)"
read -p "Номер [1-2]: " ru_choice
[ "$ru_choice" = "2" ] && RU_POLICY=allow || RU_POLICY=block

# === ДОПОЛНИТЕЛЬНЫЕ ПРОТОКОЛЫ ===
ax_nginx_has_stream && STREAM_OK=true || STREAM_OK=false
if [ "$STREAM_OK" = true ]; then
    default_protos="1 2 3 4 5 6"
    rv_note="443, разводка по SNI через nginx stream"
    rx_note="443, разводка по SNI через nginx stream"
else
    default_protos="3 4 5 6"
    rv_note="TCP 8443: в этой сборке nginx нет stream, порт 443 недоступен"
    rx_note="TCP 2053: в этой сборке nginx нет stream, порт 443 недоступен"
fi
echo -e "\n${YEL}Дополнительные протоколы (VISION, Hysteria2 и XHTTP ставятся всегда):${NC}"
echo "1) VLESS RAW REALITY Vision       ($rv_note)"
echo "2) VLESS XHTTP REALITY            ($rx_note)"
echo "3) VLESS WebSocket TLS            (443 через nginx, работает и через CDN; устаревает в Xray)"
echo "4) VLESS gRPC TLS                 (443 через nginx; устаревает в Xray)"
echo "5) VLESS XHTTP packet-up TLS      (443 через nginx, подходит для CDN)"
echo "6) VLESS XHTTP + VLESS Encryption (443 через nginx, постквантовое шифрование внутри)"
read -p "Номера через пробел/запятую, all - все, 0 - ничего (Enter = $default_protos): " proto_choice
proto_choice=${proto_choice:-"$default_protos"}
proto_choice=${proto_choice//,/ }
has_proto() { [[ "$proto_choice" == "all" ]] || [[ " $proto_choice " == *" $1 "* ]]; }
has_proto 1 && USE_REALITY_VISION=true || USE_REALITY_VISION=false
has_proto 2 && USE_REALITY_XHTTP=true  || USE_REALITY_XHTTP=false
has_proto 3 && USE_WS=true             || USE_WS=false
has_proto 4 && USE_GRPC=true           || USE_GRPC=false
has_proto 5 && USE_XPACKET=true        || USE_XPACKET=false
has_proto 6 && USE_VLESSENC=true       || USE_VLESSENC=false
port_rv=8443
port_rx=2053

# Режим порта 443: если выбран Reality и nginx умеет stream, 443 принимает nginx
# и разводит по SNI: наш домен -> Xray TLS, сайты-маскировки -> Reality inbound'ы
FRONT=false
if { [ "$USE_REALITY_VISION" = true ] || [ "$USE_REALITY_XHTTP" = true ]; } && [ "$STREAM_OK" = true ]; then
    FRONT=true
fi
if [ "$FRONT" = true ]; then
    xray_tls_port=4443; xray_tls_listen=127.0.0.1; reality_listen=127.0.0.1
    pub_rv=443;         pub_rx=443
else
    xray_tls_port=443;  xray_tls_listen=0.0.0.0;   reality_listen=0.0.0.0
    pub_rv=$port_rv;    pub_rx=$port_rx
fi
FW_TCP="80 443"; FW_UDP="443"
if [ "$FRONT" != true ]; then
    [ "$USE_REALITY_VISION" = true ] && FW_TCP+=" $port_rv"
    [ "$USE_REALITY_XHTTP" = true ]  && FW_TCP+=" $port_rx"
fi
# ============================

# Включаем BBR, MTU Probing и расширенные TCP-буферы ядра
cat <<EOF > /etc/sysctl.d/999-autoXRAY.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
sysctl --system >/dev/null 2>&1
echo -e "${GRN}BBR, TCP буферы и MTU Probing активированы${NC}"

cat <<EOF > /etc/security/limits.d/99-autoXRAY.conf
*       soft    nofile  1048576
*       hard    nofile  1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
EOF
ulimit -n 65535
echo -e "${GRN}Лимиты применены. Текущий ulimit -n: $(ulimit -n) ${NC}"

# Синхронизация времени: TLS и Reality ломаются при расхождении часов
if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true >/dev/null 2>&1 || { apt-get install -y systemd-timesyncd >/dev/null 2>&1; timedatectl set-ntp true >/dev/null 2>&1; }
    echo -e "${GRN}Синхронизация времени (NTP) включена. Сейчас: $(timedatectl show -p NTPSynchronized --value 2>/dev/null)${NC}"
fi

# Создание директории сайта
WEB_PATH="/var/www/$DOMAIN"
mkdir -p "$WEB_PATH"

# Генерируем сайт маскировку
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xVRVx/autoXRAY/main/test/gen_page3.sh)" -- "$WEB_PATH"

# Установка Xray
bash -c "$(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install --version v26.11.9

# ==========================================
# Блок ACME.SH (Установка и выпуск сертификата)
# ==========================================
CONFIG_PATH="/etc/nginx/conf.d/default.conf"
mkdir -p /var/www/html

cat <<EOF > "$CONFIG_PATH"
server {
	listen 80 default_server;
	server_name _;

	location /.well-known/acme-challenge/ {
		root /var/www/html;
		allow all;
	}

	location / {
		return 301 https://\$host\$request_uri;
	}
}
EOF
systemctl reload nginx

mkdir -p /var/lib/xray/cert/
# Закрытый ключ читает только root и группа xraycert (в неё входит служба Xray)
getent group xraycert >/dev/null || groupadd --system xraycert
chown root:xraycert /var/lib/xray/cert
chmod 750 /var/lib/xray/cert
mkdir -p /etc/systemd/system/xray.service.d
printf '[Service]\nSupplementaryGroups=xraycert\n' > /etc/systemd/system/xray.service.d/20-autoxray-cert.conf
systemctl daemon-reload

ACME_BIN="$HOME/.acme.sh/acme.sh"

if [ ! -f "$ACME_BIN" ]; then
    echo -e "${YEL}Установка acme.sh...${NC}"

    # 1. Основной вариант: через GitHub raw
    curl -fsSL --connect-timeout 10 https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh | sh -s -- --install-online -m mail@$DOMAIN

    # 2. Фоллбек: через get.acme.sh
    if [ ! -f "$ACME_BIN" ]; then
        echo -e "${YEL}Попытка через get.acme.sh...${NC}"
        curl -fsSL --connect-timeout 10 https://get.acme.sh | sh -s email=mail@$DOMAIN
    fi
fi

if [ ! -f "$ACME_BIN" ]; then
    echo -e "${RED}❌ Не удалось установить acme.sh!${NC}"
    exit 1
fi

# Если сертификата физически нет в xray — выпускаем и устанавливаем
if [ ! -s /var/lib/xray/cert/fullchain.pem ]; then
    $ACME_BIN --register-account -m mail@$DOMAIN --server zerossl

    echo -e "\n${YEL}Выпуск сертификата (сначала ZeroSSL, затем Let's Encrypt)...${NC}"
    $ACME_BIN --issue -d "$DOMAIN" -w /var/www/html --server zerossl --keylength ec-256 || \
    $ACME_BIN --issue -d "$DOMAIN" -w /var/www/html --server letsencrypt --keylength ec-256

    $ACME_BIN --install-cert -d "$DOMAIN" --ecc \
      --fullchain-file /var/lib/xray/cert/fullchain.pem \
      --key-file /var/lib/xray/cert/privkey.pem \
      --reloadcmd "chown root:xraycert /var/lib/xray/cert/privkey.pem /var/lib/xray/cert/fullchain.pem; chmod 640 /var/lib/xray/cert/privkey.pem; chmod 644 /var/lib/xray/cert/fullchain.pem; systemctl reload nginx; systemctl restart xray"
fi

# Жесткая проверка: файл появился и он не пустой?
if [ ! -s /var/lib/xray/cert/fullchain.pem ]; then
    echo -e "\n${RED}========================================"
    echo    "❌ ОШИБКА: Сертификат не получен! Проверьте DNS-записи (A и AAAA)."
    echo    "========================================${NC}"
    exit 1
fi

chown root:xraycert /var/lib/xray/cert/privkey.pem /var/lib/xray/cert/fullchain.pem
chmod 640 /var/lib/xray/cert/privkey.pem
chmod 644 /var/lib/xray/cert/fullchain.pem
echo -e "${GRN}✅ Сертификат успешно настроен и применен!${NC}"
# ========================================== #

path_xhttp=${path_xhttp:-$(openssl rand -base64 15 | tr -dc 'a-z0-9' | head -c 6)}
path_subpage=${path_subpage:-$(openssl rand -base64 15 | tr -dc 'A-Za-z0-9' | head -c 20)}

AUTH_VARIANTS=(
    "ERR_INVALID_CREDENTIALS|The username or password you entered is incorrect."
    "ERR_INVALID_CREDENTIALS|The identity or security key you provided is invalid."
    "ERR_BAD_PASSWORD|Incorrect password. Please verify your credentials and retry."
    "ERR_KEY_MISMATCH|The security key provided does not match the account identity."
    "ERR_CREDENTIAL_REJECTED|Credential verification rejected by the authentication authority."
    "ERR_PASSWORD_MISMATCH|The password provided does not match the registered key."
    "ERR_INCORRECT_KEY|Incorrect security credentials provided for this principal."
    "ERR_USER_NOT_FOUND|Principal identity not found in directory services."
    "ERR_IDENTITY_NOT_FOUND|No account found matching the provided identity."
    "ERR_PRINCIPAL_MISSING|User principal does not exist in this organizational realm."
    "ERR_ACCOUNT_NOT_FOUND|Account identifier not recognized by the identity provider."
    "ERR_UNKNOWN_USER|Unrecognized user identity. Please verify your login."
    "ERR_LOOKUP_FAILED|User lookup failed: Specified identity does not exist."
    "ERR_AUTH_FAILED|Authentication failed: The provided credentials do not match."
    "ERR_DIRECTORY_MISMATCH|Credentials could not be verified against the corporate directory."
    "ERR_RECORDS_MISMATCH|The security credentials entered do not match our records."
)

RAND_AUTH=${AUTH_VARIANTS[$RANDOM % ${#AUTH_VARIANTS[@]}]}
AUTH_CODE=$(echo "$RAND_AUTH" | cut -d'|' -f1)
AUTH_MSG=$(echo "$RAND_AUTH" | cut -d'|' -f2)

# Дополнительные location для nginx (WebSocket / gRPC)
path_ws=${path_ws:-$(openssl rand -hex 4)}
path_grpc=${path_grpc:-$(openssl rand -hex 4)}
path_xp=${path_xp:-$(openssl rand -hex 4)}
path_xe=${path_xe:-$(openssl rand -hex 4)}
NGINX_EXTRA=""
if [ "$USE_WS" = true ]; then
NGINX_EXTRA+="
    # VLESS WebSocket
    location /${path_ws} {
        proxy_pass http://127.0.0.1:8401;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
"
fi
if [ "$USE_GRPC" = true ]; then
NGINX_EXTRA+="
    # VLESS gRPC
    location ^~ /${path_grpc}/ {
        client_max_body_size 0;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_set_header Host \$host;
        grpc_pass grpc://127.0.0.1:8402;
    }
"
fi

for xh in "xp:$USE_XPACKET:8403" "xe:$USE_VLESSENC:8404"; do
    IFS=: read -r xh_name xh_use xh_port <<< "$xh"
    if [ "$xh_use" = true ]; then
        xh_path_var="path_$xh_name"
        NGINX_EXTRA+="
    # VLESS XHTTP ($xh_name)
    location /${!xh_path_var} {
        proxy_pass http://127.0.0.1:$xh_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
"
    fi
done

# Конфиг Nginx с ОЗУ-буферами для высокой скорости отдачи
cat <<EOF > "$CONFIG_PATH"
http2 on;
server_tokens off;

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    server_name $DOMAIN;
    listen unix:/dev/shm/nginx.sock proxy_protocol;

    set_real_ip_from unix:;
    real_ip_header proxy_protocol;

    server_tokens off;
    access_log off;
    error_log /var/log/nginx/error.log crit;

    root /var/www/$DOMAIN;
    index index.html;

    location = /${path_subpage}.html {
        try_files \$uri =404;
    }

    location = /${path_subpage}.json {
        add_header profile-title "base64:YXV0b1hSQVk=";
        add_header routing "happ://routing/onadd/eyJOYW1lIjoiYXV0b1hSQVkiLCJHbG9iYWxQcm94eSI6InRydWUiLCJSb3V0ZU9yZGVyIjoiYmxvY2stcHJveHktZGlyZWN0IiwiUmVtb3RlRE5TVHlwZSI6IkRvSCIsIlJlbW90ZUROU0RvbWFpbiI6Imh0dHBzOi8vZG5zLmdvb2dsZS9kbnMtcXVlcnkiLCJSZW1vdGVETlNJUCI6IjguOC40LjQiLCJEb21lc3RpY0ROU1R5cGUiOiJEb0giLCJEb21lc3RpY0ROU0RvbWFpbiI6Imh0dHBzOi8vY29tbW9uLmRvdC5kbnMueWFuZGV4Lm5ldC9kbnMtcXVlcnkiLCJEb21lc3RpY0ROU0lQIjoiNzcuODguOC44IiwiR2VvaXB1cmwiOiJodHRwczovL2Nkbi5qc2RlbGl2ci5uZXQvZ2gvTG95YWxzb2xkaWVyL3YycmF5LXJ1bGVzLWRhdEByZWxlYXNlL2dlb2lwLmRhdCIsIkdlb3NpdGV1cmwiOiJodHRwczovL2Nkbi5qc2RlbGl2ci5uZXQvZ2gvTG95YWxzb2xkaWVyL3YycmF5LXJ1bGVzLWRhdEByZWxlYXNlL2dlb3NpdGUuZGF0IiwiTGFzdFVwZGF0ZWQiOiIxNzc1MjA2MTA4IiwiRG5zSG9zdHMiOnt9LCJEaXJlY3RTaXRlcyI6WyJnZW9zaXRlOmNhdGVnb3J5LXJ1IiwiZ2Vvc2l0ZTpwcml2YXRlIl0sIkRpcmVjdElwIjpbImdlb2lwOnByaXZhdGUiLCJnZW9pcDpydSJdLCJQcm94eVNpdGVzIjpbXSwiUHJveHlJcCI6W10sIkJsb2NrU2l0ZXMiOlsiZ2Vvc2l0ZTpjYXRlZ29yeS1hZHMiXSwiQmxvY2tJcCI6W10sIkRvbWFpblN0cmF0ZWd5IjoiSVBJZk5vbk1hdGNoIiwiRmFrZUROUyI6ImZhbHNlIiwiVXNlQ2h1bmtGaWxlcyI6ImZhbHNlIn0";
        add_header socks-auth-mode auto;
        add_header http-auth-mode auto;
        add_header routing-enable 0;
        try_files \$uri =404;
    }

    location = /${path_subpage}.txt {
        default_type text/plain;
        add_header profile-title "base64:YXV0b1hSQVk=";
        try_files \$uri =404;
    }

    # XHTTP endpoint (режим stream-up через gRPC-модуль Nginx с буферами 512k)
    location /${path_xhttp} {
        client_max_body_size 0;
        client_body_buffer_size 512k;
        grpc_buffer_size 64k;

        client_body_timeout 120s;
        grpc_read_timeout 180s;
        grpc_send_timeout 180s;
        grpc_socket_keepalive on;

        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$remote_addr;

        grpc_pass grpc://127.0.0.1:3333;
    }

    # Для сайта
    location /api/v1/authenticate {
        limit_except POST {
            deny all;
        }

        default_type application/json;

        add_header Set-Cookie "X-Auth-Token=\$request_id; Path=/; HttpOnly; Secure; SameSite=Lax" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;

        return 401 '{"success":false,"code":"$AUTH_CODE","message":"$AUTH_MSG","request_id":"\$request_id"}';
    }
$NGINX_EXTRA
$NGINX_web_proxy

    location ~ /\.ht {
        deny all;
    }
}

server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

if ! nginx -t >/dev/null 2>&1; then nginx -t; ax_rollback_install "nginx не принял новую конфигурацию"; fi
systemctl restart nginx
echo -e "${GRN}✅ Конфигурация nginx обновлена.${NC}"

SCRIPT_DIR=/usr/local/etc/xray

# Генерируем ключи и переменные
xray_uuid_vrv=${xray_uuid_vrv:-$(xray uuid)}
xray_shortIds_vrv=${xray_shortIds_vrv:-$(openssl rand -hex 8)}

socksUser=${socksUser:-$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 6)}
socksPasw=${socksPasw:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 16)}

# === Ключи и inbound'ы дополнительных протоколов ===
if [ "$USE_REALITY_VISION" = true ] || [ "$USE_REALITY_XHTTP" = true ]; then
    echo -e "${YEL}Проверяю сайты для маскировки Reality (нужны TLS 1.3 и HTTP/2)...${NC}"
    [ -z "$xray_dest_vrv" ]  && xray_dest_vrv=$(ax_pick_reality_target "$DOMAIN")
    [ -z "$xray_dest_vrv2" ] && xray_dest_vrv2=$(ax_pick_reality_target "$DOMAIN" "$xray_dest_vrv")
    if [ "$xray_dest_vrv2" = "$xray_dest_vrv" ]; then xray_dest_vrv2=$(ax_pick_reality_target "$DOMAIN" "$xray_dest_vrv"); fi
    echo "Reality: $xray_dest_vrv и $xray_dest_vrv2"
fi
if [ -z "$xray_privateKey_vrv" ] || [ -z "$xray_publicKey_vrv" ]; then
    key_output=$(xray x25519)
    xray_privateKey_vrv=$(echo "$key_output" | awk -F': ' '/PrivateKey/ {print $2}')
    xray_publicKey_vrv=$(echo "$key_output" | awk -F': ' '/Password|PublicKey/ {print $2}')
fi
path_xhttp_r=${path_xhttp_r:-$(openssl rand -hex 4)}

EXTRA_INBOUNDS=""
EXTRA_TCP_PORTS=()
EXTRA_UDP_PORTS=()

if [ "$USE_REALITY_VISION" = true ]; then
EXTRA_INBOUNDS+=$(cat <<EOF
,
    {
      "tag": "vsRAWrealityVISION",
      "port": ${port_rv},
      "listen": "${reality_listen}",
      "protocol": "vless",
      "settings": {
        "clients": [ { "flow": "xtls-rprx-vision", "id": "${xray_uuid_vrv}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${xray_dest_vrv}:443",
          "xver": 0,
          "serverNames": [ "${xray_dest_vrv}" ],
          "privateKey": "${xray_privateKey_vrv}",
          "shortIds": [ "${xray_shortIds_vrv}" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
EOF
)
EXTRA_TCP_PORTS+=("$port_rv")
fi

if [ "$USE_REALITY_XHTTP" = true ]; then
EXTRA_INBOUNDS+=$(cat <<EOF
,
    {
      "tag": "vsXHTTPreality",
      "port": ${port_rx},
      "listen": "${reality_listen}",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${xray_uuid_vrv}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "mode": "auto", "path": "/${path_xhttp_r}" },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${xray_dest_vrv2}:443",
          "xver": 0,
          "serverNames": [ "${xray_dest_vrv2}" ],
          "privateKey": "${xray_privateKey_vrv}",
          "shortIds": [ "${xray_shortIds_vrv}" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
EOF
)
EXTRA_TCP_PORTS+=("$port_rx")
fi

if [ "$USE_WS" = true ]; then
EXTRA_INBOUNDS+=$(cat <<EOF
,
    {
      "tag": "vsWStls",
      "port": 8401,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${xray_uuid_vrv}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/${path_ws}" },
        "security": "none"
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
EOF
)
fi

if [ "$USE_GRPC" = true ]; then
EXTRA_INBOUNDS+=$(cat <<EOF
,
    {
      "tag": "vsGRPCtls",
      "port": 8402,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${xray_uuid_vrv}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": { "serviceName": "${path_grpc}" },
        "security": "none"
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
EOF
)
fi

if [ "$USE_XPACKET" = true ]; then
EXTRA_INBOUNDS+=$(cat <<EOF
,
    {
      "tag": "vsXHTTPpacketup",
      "port": 8403,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${xray_uuid_vrv}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "mode": "auto", "path": "/${path_xp}" },
        "security": "none"
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
EOF
)
fi

if [ "$USE_VLESSENC" = true ]; then
if [ -z "$vlessenc_dec" ] || [ -z "$vlessenc_enc" ]; then
    vlessenc_out=$(xray vlessenc)
    vlessenc_dec=$(echo "$vlessenc_out" | grep '"decryption"' | head -1 | cut -d'"' -f4)
    vlessenc_enc=$(echo "$vlessenc_out" | grep '"encryption"' | head -1 | cut -d'"' -f4)
fi
EXTRA_INBOUNDS+=$(cat <<EOF
,
    {
      "tag": "vsXHTTPvlessenc",
      "port": 8404,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${xray_uuid_vrv}" } ],
        "decryption": "${vlessenc_dec}"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "mode": "auto", "path": "/${path_xe}" },
        "security": "none"
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
EOF
)
fi

# Экспортируем переменные для envsubst
export xray_uuid_vrv xray_shortIds_vrv DOMAIN path_subpage path_xhttp WEB_PATH socksUser socksPasw fpBro
ax_state_save
export xray_tls_port xray_tls_listen reality_listen pub_rv pub_rx
export xray_dest_vrv xray_dest_vrv2 xray_privateKey_vrv xray_publicKey_vrv path_xhttp_r path_ws path_grpc path_xp path_xe vlessenc_enc port_rv port_rx EXTRA_INBOUNDS

# Создаем JSON конфигурацию сервера Xray
cat << 'EOF' | envsubst > "$SCRIPT_DIR/config.new.json"
{
  "log": {
    "dnsLog": false,
    "access": "none",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      "https+local://8.8.4.4/dns-query",
      "https+local://8.8.8.8/dns-query",
      "https+local://1.1.1.1/dns-query",
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "vsRAWtlsVISION",
      "port": ${xray_tls_port},
      "listen": "${xray_tls_listen}",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "flow": "xtls-rprx-vision",
            "id": "${xray_uuid_vrv}"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": "/dev/shm/nginx.sock",
            "xver": 2
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/var/lib/xray/cert/fullchain.pem",
              "keyFile": "/var/lib/xray/cert/privkey.pem"
            }
          ],
          "minVersion": "1.2",
          "cipherSuites": "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256", 
          "alpn": [
            "h2", "http/1.1"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "tag": "Hysteria2",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "clients": [
          {
            "auth": "${xray_shortIds_vrv}"
          }
        ]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$DOMAIN",
          "alpn": [
            "h3"
          ],
          "certificates": [
            {
              "usage": "encipherment",
              "certificateFile": "/var/lib/xray/cert/fullchain.pem",
              "keyFile": "/var/lib/xray/cert/privkey.pem"
            }
          ]
        },
        "hysteriaSettings": {
          "version": 2
        },
        "finalmask": {
          "quicParams": {
            "congestion": "bbr"
          }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "tag": "vsXHTTPtls",
      "port": 3333,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${xray_uuid_vrv}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "mode": "stream-up",
          "path": "/${path_xhttp}"
        },
        "security": "none",
        "sockopt": {
          "acceptProxyProtocol": false,
          "trustedXForwardedFor": [ "X-Real-IP" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "tag": "socks5",
      "port": 10443,
      "listen": "127.0.0.1",
      "protocol": "mixed",
      "settings": {
        "ip": "127.0.0.1",
        "udp": true,
        "auth": "password",
        "accounts": [
          {
            "user": "${socksUser}",
            "pass": "${socksPasw}"
          }
        ]
      }
    }${EXTRA_INBOUNDS}
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {},
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "ForceIPv4"
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    },
	{
	  "tag": "warp",
	  "protocol": "socks",
	  "settings": {
		"servers": [
		  {
			"address": "127.0.0.1",
			"port": 40000
		  }
		]
	  },
	  "targetStrategy": "ForceIPv4v6"
	}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      },
      {
        "port": "25, 135, 137-139, 445",
        "outboundTag": "block"
      },
      {
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      },
      {
        "domain": [
          "geosite:category-ads",
          "geosite:private"
        ],
        "outboundTag": "block"
      },
      {
        "domain": [
          "domain:habr.com",
          "geosite:canva"
        ],
        "outboundTag": "direct"
      },
      {
        "domain": [
          "domain:ifconfig.me",
          "domain:checkip.amazonaws.com",
          "domain:ipify.org",
          "domain:2ip.io",
          "geosite:category-ip-geo-detect",
          "domain:vk.com",
          "domain:vk.company",
          "domain:mradx.net",
          "domain:userapi.com",
          "domain:vk-cdn.net",
          "domain:vkuservideo.net",
          "domain:vkuservideo.com",
          "domain:ru",
          "domain:su",
          "domain:xn--p1ai",
          "geosite:yandex",
          "geosite:vk",
          "geosite:category-ru"
        ],
        "outboundTag": "block"
      },
      {
        "ip": [
          "geoip:ru"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

# Российские сайты и IP: по желанию пропускаем (сервисы проверки IP остаются заблокированными)
if [ "$RU_POLICY" = allow ]; then
    jq '.routing.rules |= (map(select(((.ip // []) | index("geoip:ru")) | not))
        | map(if (.outboundTag == "block" and ((.domain // []) | index("domain:ru")))
              then .domain -= ["domain:vk.com","domain:vk.company","domain:mradx.net","domain:userapi.com","domain:vk-cdn.net","domain:vkuservideo.net","domain:vkuservideo.com","domain:ru","domain:su","domain:xn--p1ai","geosite:yandex","geosite:vk","geosite:category-ru"]
              else . end))' "$SCRIPT_DIR/config.new.json" > "$SCRIPT_DIR/config.new2.json" \
        && mv -f "$SCRIPT_DIR/config.new2.json" "$SCRIPT_DIR/config.new.json"
fi

# Проверяем новый конфиг до замены рабочего
echo -e "${YEL}Проверяю новый конфиг Xray...${NC}"
if ! xray run -test -c "$SCRIPT_DIR/config.new.json" >"$AX_HOME/xray-test.log" 2>&1; then
    tail -n 20 "$AX_HOME/xray-test.log"
    ax_rollback_install "новый конфиг Xray не прошёл проверку, рабочий конфиг не изменён"
fi
echo -e "${GRN}✅ Конфиг Xray корректен${NC}"

# Создаем JSON конфигурацию клиента
print_config() {
  local PROXY_OUTBOUND="$1"
  local REMARK="$2"

  cat << TPL
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      {
        "address": "https+local://77.88.8.8/dns-query",
        "domains": [
          "geosite:category-ru",
          "geosite:yandex",
          "geosite:vk",
          "domain:ru",
          "domain:su",
          "domain:xn--p1ai"
        ],
        "skipFallback": true
      },
      "https://8.8.4.4/dns-query",
      "https://8.8.8.8/dns-query",
      "https://1.1.1.1/dns-query"
    ],
    "queryStrategy": "UseIPv4"
  },
  "routing": {
    "domainMatcher": "hybrid",
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "domain": [
          "geosite:category-ads"
        ],
        "outboundTag": "block"
      },
      {
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "direct"
      },
      {
        "domain": [
          "domain:habr.com",
          "domain:apkmirror.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "domain": [
          "geosite:private",
          "domain:ifconfig.me",
          "domain:checkip.amazonaws.com",
          "domain:ipify.org",
          "domain:2ip.io",
          "domain:ru",
          "domain:su",
          "domain:xn--p1ai",
          "geosite:category-ip-geo-detect",
          "geosite:apple",
          "geosite:apple-pki",
          "geosite:f-droid",
          "geosite:yandex",
          "geosite:vk",
          "geosite:category-ru"
        ],
        "outboundTag": "direct"
      },
      {
        "ip": [
          "geoip:ru",
          "geoip:private"
        ],
        "outboundTag": "direct"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "protocol": "socks",
      "listen": "127.0.0.1",
      "port": 10808,
      "settings": {
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "tag": "socks-sb",
      "protocol": "mixed",
      "listen": "127.0.0.1",
      "port": 2080,
      "settings": {
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "tag": "http-in",
      "protocol": "http",
      "listen": "127.0.0.1",
      "port": 10809,
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    $PROXY_OUTBOUND,
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "remarks": "$REMARK"
}
TPL
}

# --- Config 1: VLESS XHTTP TLS (Оптимальный для личного сервера: Stealth + High Upload + Буфер 20)
OUT_XHTTP='{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$DOMAIN",
      "port": 443,
      "users": [{ "id": "${xray_uuid_vrv}", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "xhttp",
    "xhttpSettings": {
      "mode": "stream-up",
      "path": "/${path_xhttp}",
      "extra": {
        "noGRPCHeader": true,
        "xPaddingBytes": "150-400",
        "scMaxEachPostBytes": 500000,
        "scMinPostsIntervalMs": "5-15",
        "scMaxBufferedPosts": 20,
        "scStreamUpServerSecs": "90-180",
        "xmux": {
          "maxConcurrency": "2-4",
          "cMaxReuseTimes": "800-1500",
          "hMaxReusableSecs": "900-1200"
        }
      }
    },
    "security": "tls",
    "tlsSettings": {
      "serverName": "$DOMAIN",
      "alpn": [
        "h2"
      ],
      "fingerprint": "$fpBro"
    }
  }
}'

# --- Config 2: VLESS RAW TLS VISION (Port 443 TCP)
OUT_VISION='{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$DOMAIN",
      "port": 443,
      "users": [{ "id": "${xray_uuid_vrv}", "flow": "xtls-rprx-vision", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "raw",
    "security": "tls",
    "tlsSettings": {
      "serverName": "$DOMAIN",
      "fingerprint": "$fpBro"
    }
  }
}'

# --- Config 3: HYSTERIA2 (Port 443 UDP)
HYSTERIA2='{
"tag": "proxy",
"protocol": "hysteria",
"settings": {
	"address": "$DOMAIN",
	"port": 443,
	"version": 2
},
"streamSettings": {
	"network": "hysteria",
	"security": "tls",
	"tlsSettings": {
		"serverName": "$DOMAIN",
		"alpn": [
			"h3"
		],
		"fingerprint": "$fpBro"
	},
	"hysteriaSettings": {
		"version": 2,
		"auth": "${xray_shortIds_vrv}"
	},
	"finalmask": {
		"quicParams": {
			"congestion": "bbr"
		}
	}
}
}'

# --- Дополнительные клиентские конфиги ---
EXTRA_CLIENT_OUTS=()

if [ "$USE_REALITY_VISION" = true ]; then
EXTRA_CLIENT_OUTS+=("${FLAG} VLESS RAW REALITY VISION|"'{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$DOMAIN",
      "port": ${pub_rv},
      "users": [{ "id": "${xray_uuid_vrv}", "flow": "xtls-rprx-vision", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "serverName": "${xray_dest_vrv}",
      "fingerprint": "$fpBro",
      "publicKey": "${xray_publicKey_vrv}",
      "shortId": "${xray_shortIds_vrv}",
      "spiderX": "/"
    }
  }
}')
fi

if [ "$USE_REALITY_XHTTP" = true ]; then
EXTRA_CLIENT_OUTS+=("${FLAG} VLESS XHTTP REALITY|"'{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$DOMAIN",
      "port": ${pub_rx},
      "users": [{ "id": "${xray_uuid_vrv}", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "xhttp",
    "xhttpSettings": { "mode": "auto", "path": "/${path_xhttp_r}" },
    "security": "reality",
    "realitySettings": {
      "serverName": "${xray_dest_vrv2}",
      "fingerprint": "$fpBro",
      "publicKey": "${xray_publicKey_vrv}",
      "shortId": "${xray_shortIds_vrv}",
      "spiderX": "/"
    }
  }
}')
fi

if [ "$USE_WS" = true ]; then
EXTRA_CLIENT_OUTS+=("${FLAG} VLESS WS TLS|"'{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$DOMAIN",
      "port": 443,
      "users": [{ "id": "${xray_uuid_vrv}", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "ws",
    "wsSettings": { "path": "/${path_ws}", "host": "$DOMAIN" },
    "security": "tls",
    "tlsSettings": { "serverName": "$DOMAIN", "alpn": [ "http/1.1" ], "fingerprint": "$fpBro" }
  }
}')
fi

if [ "$USE_GRPC" = true ]; then
EXTRA_CLIENT_OUTS+=("${FLAG} VLESS gRPC TLS|"'{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$DOMAIN",
      "port": 443,
      "users": [{ "id": "${xray_uuid_vrv}", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "grpc",
    "grpcSettings": { "serviceName": "${path_grpc}" },
    "security": "tls",
    "tlsSettings": { "serverName": "$DOMAIN", "alpn": [ "h2" ], "fingerprint": "$fpBro" }
  }
}')
fi

if [ "$USE_XPACKET" = true ]; then
EXTRA_CLIENT_OUTS+=("${FLAG} VLESS XHTTP packet-up TLS|"'{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$DOMAIN",
      "port": 443,
      "users": [{ "id": "${xray_uuid_vrv}", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "xhttp",
    "xhttpSettings": { "mode": "packet-up", "path": "/${path_xp}" },
    "security": "tls",
    "tlsSettings": { "serverName": "$DOMAIN", "alpn": [ "h2" ], "fingerprint": "$fpBro" }
  }
}')
fi

if [ "$USE_VLESSENC" = true ]; then
EXTRA_CLIENT_OUTS+=("${FLAG} VLESS XHTTP + VLESS ENCRYPTION|"'{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$DOMAIN",
      "port": 443,
      "users": [{ "id": "${xray_uuid_vrv}", "encryption": "${vlessenc_enc}" }]
    }]
  },
  "streamSettings": {
    "network": "xhttp",
    "xhttpSettings": { "mode": "packet-up", "path": "/${path_xe}" },
    "security": "tls",
    "tlsSettings": { "serverName": "$DOMAIN", "alpn": [ "h2" ], "fingerprint": "$fpBro" }
  }
}')
fi

# Порядок в клиентском конфиге: XHTTP -> RAW VISION -> HYSTERIA2
(
  echo "["
  print_config "$OUT_XHTTP"     "${FLAG} VLESS XHTTP TLS stream-up"
  echo ","
  print_config "$OUT_VISION"    "${FLAG} VLESS RAW TLS VISION"
  echo ","
  print_config "$HYSTERIA2"      "${FLAG} HYSTERIA2"
  for extra in "${EXTRA_CLIENT_OUTS[@]}"; do
    echo ","
    print_config "${extra#*|}" "${extra%%|*}"
  done
  echo "]"
) | envsubst > "$WEB_PATH/$path_subpage.json"

# Файрвол: только добавляем разрешения, если ufw уже включён
ax_firewall open

# Запуск: замена конфига, разводка 443, перезапуск с автоматическим откатом при ошибке
ax_activate
echo -e "${GRN}✅ Xray и nginx перезапущены${NC}"

# Формирование ссылок
subPageLink="https://$DOMAIN/$path_subpage.json"

linkTLS2="vless://${xray_uuid_vrv}@$DOMAIN:443?security=tls&alpn=h2&type=xhttp&mode=stream-up&path=%2F${path_xhttp}&extra=%7B%22noGRPCHeader%22%3Atrue%2C%22xPaddingBytes%22%3A%22150-400%22%2C%22scMaxEachPostBytes%22%3A500000%2C%22scMinPostsIntervalMs%22%3A%225-15%22%2C%22scMaxBufferedPosts%22%3A20%2C%22scStreamUpServerSecs%22%3A%2290-180%22%2C%22xmux%22%3A%7B%22maxConcurrency%22%3A%222-4%22%2C%22cMaxReuseTimes%22%3A%22800-1500%22%2C%22hMaxReusableSecs%22%3A%22900-1200%22%7D%7D&sni=$DOMAIN&fp=$fpBro#vlessXHTTPtls-stream-up"
linkTLS1="vless://${xray_uuid_vrv}@$DOMAIN:443?security=tls&type=tcp&headerType=&path=&host=&flow=xtls-rprx-vision&sni=$DOMAIN&fp=$fpBro&spx=%2F#vlessRAWtlsVision-autoXRAY"
hy2="hy2://${xray_shortIds_vrv}@$DOMAIN:443/?sni=$DOMAIN&alpn=h3#Hysteria2"

configListLink="https://$DOMAIN/$path_subpage.html"

CONFIGS_ARRAY=(
    "VLESS XHTTP TLS stream-up (для моста)|$linkTLS2"
    "VLESS RAW TLS VISION|$linkTLS1"
    "HYSTERIA2|$hy2"
)
EXTRA_LINKS_TEXT=""
add_link() {
    CONFIGS_ARRAY+=("$1|$2")
    EXTRA_LINKS_TEXT+="${YEL}$1${NC}\n$2\n\n"
}
if [ "$USE_REALITY_VISION" = true ]; then
    add_link "VLESS RAW REALITY VISION (Порт $pub_rv TCP)" "vless://${xray_uuid_vrv}@$DOMAIN:${pub_rv}?security=reality&type=tcp&headerType=&flow=xtls-rprx-vision&sni=${xray_dest_vrv}&fp=$fpBro&pbk=${xray_publicKey_vrv}&sid=${xray_shortIds_vrv}&spx=%2F#vlessRAWrealityVision-autoXRAY"
fi
if [ "$USE_REALITY_XHTTP" = true ]; then
    add_link "VLESS XHTTP REALITY (Порт $pub_rx TCP)" "vless://${xray_uuid_vrv}@$DOMAIN:${pub_rx}?security=reality&type=xhttp&mode=auto&path=%2F${path_xhttp_r}&sni=${xray_dest_vrv2}&fp=$fpBro&pbk=${xray_publicKey_vrv}&sid=${xray_shortIds_vrv}&spx=%2F#vlessXHTTPreality-autoXRAY"
fi
if [ "$USE_WS" = true ]; then
    add_link "VLESS WS TLS (Порт 443 TCP)" "vless://${xray_uuid_vrv}@$DOMAIN:443?security=tls&type=ws&path=%2F${path_ws}&host=$DOMAIN&sni=$DOMAIN&fp=$fpBro&alpn=http%2F1.1#vlessWStls-autoXRAY"
fi
if [ "$USE_GRPC" = true ]; then
    add_link "VLESS gRPC TLS (Порт 443 TCP)" "vless://${xray_uuid_vrv}@$DOMAIN:443?security=tls&type=grpc&serviceName=${path_grpc}&mode=gun&sni=$DOMAIN&fp=$fpBro&alpn=h2#vlessGRPCtls-autoXRAY"
fi
if [ "$USE_XPACKET" = true ]; then
    add_link "VLESS XHTTP packet-up TLS (Порт 443 TCP)" "vless://${xray_uuid_vrv}@$DOMAIN:443?security=tls&type=xhttp&mode=packet-up&path=%2F${path_xp}&sni=$DOMAIN&fp=$fpBro&alpn=h2#vlessXHTTPpacketup-autoXRAY"
fi
if [ "$USE_VLESSENC" = true ]; then
    add_link "VLESS XHTTP + VLESS ENCRYPTION (Порт 443 TCP)" "vless://${xray_uuid_vrv}@$DOMAIN:443?encryption=${vlessenc_enc}&security=tls&type=xhttp&mode=packet-up&path=%2F${path_xe}&sni=$DOMAIN&fp=$fpBro&alpn=h2#vlessXHTTPenc-autoXRAY"
fi
# --- base64-подписка и сохранённый список ссылок (для autoxray links) ---
( umask 077; : > "$AX_LINKS" )
for item in "${CONFIGS_ARRAY[@]}"; do
    printf '%s\n%s\n\n' "${item%%|*}" "${item#*|}" >> "$AX_LINKS"
done
for item in "${CONFIGS_ARRAY[@]}"; do printf '%s\n' "${item#*|}"; done | base64 -w0 > "$WEB_PATH/$path_subpage.txt"
subTxtLink="https://$DOMAIN/$path_subpage.txt"
ALL_LINKS_TEXT=""

if [ "$INSTALL_MTP" = true ]; then
    echo -e "\n\n${GRN}Устанавливаем Telegram Web Proxy ${NC}"
    source <(curl -sL https://raw.githubusercontent.com/xVRVx/autoXRAY/refs/heads/main/test/telegram/web-proxy.sh)
else
    echo -e "\n\n${YEL}Установка Telegram Web Proxy пропущена.${NC}"
    MTProto=""
fi

# --- ЗАПИСЬ HEAD (СТАТИКА, МИНИФИЦИРОВАННЫЕ СТИЛИ И JS) ---
cat > "$WEB_PATH/$path_subpage.html" <<'EOF'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<meta name="robots" content="noindex,nofollow">
<title>autoXRAY configs</title>
<link rel="icon" type="image/svg+xml" href='data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMDBCRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBhdGggZD0iTTIxIDJsLTIgMm0tNy42MSA3LjYxYTUuNSA1LjUgMCAxIDEtNy43NzggNy43NzggNS41IDUuNSAwIDAgMSA3Ljc3Ny03Ljc3N3ptMCAwTDE1LjUgNy41bTAgMGwzIDNMMjIgN2wtMy0zbS0zLjUgMy41TDE5IDQiLz48L3N2Zz4='>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcode/1.5.1/qrcode.min.js"></script>
<style>
body{font-family:monospace;background:#121212;color:#e0e0e0;padding:10px;max-width:900px;margin:0 auto}h2{color:#c3e88d;border-top:2px solid #333;padding-top:20px;margin:15px 0 10px;font-size:18px}.config-row{background:#1e1e1e;border:1px solid #333;border-radius:6px;padding:5px;display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-bottom:8px}.config-label{background:#2c2c2c;color:#82aaff;padding:6px 10px;border-radius:4px;font-weight:700;font-size:13px;white-space:nowrap;min-width:140px;text-align:center}.config-code{flex:1;white-space:nowrap;overflow-x:auto;padding:8px;background:#121212;border-radius:4px;color:#c3e88d;font-size:12px;scrollbar-width:none}.config-code::-webkit-scrollbar{display:none}.btn-action{border:1px solid #555;padding:6px 12px;border-radius:4px;cursor:pointer;font-weight:700;font-size:12px;transition:all .2s;height:32px;display:flex;align-items:center;justify-content:center}.copy-btn{background:#333;color:#e0e0e0;min-width:60px}.copy-btn:hover{background:#c3e88d;color:#121212;border-color:#c3e88d}.qr-btn{background:#333;color:#82aaff;border-color:#82aaff;min-width:40px}.qr-btn:hover{background:#82aaff;color:#121212}.btn-group{display:flex;gap:10px;margin:10px 0 20px}.btn{flex:1;background:#2c2c2c;color:#c3e88d;border:1px solid #c3e88d;padding:10px;text-align:center;border-radius:6px;text-decoration:none;font-weight:700;font-size:14px}.btn:hover{background:#c3e88d;color:#121212}.btn.download{border-color:#82aaff;color:#82aaff}.btn.download:hover{background:#82aaff;color:#121212}.btn.tg{border-color:#2AABEE;color:#2AABEE}.btn.tg:hover{background:#2AABEE;color:#fff}.modal-overlay{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.85);z-index:999;justify-content:center;align-items:center;backdrop-filter:blur(3px)}.modal-content{background:#1e1e1e;padding:20px;border-radius:10px;border:1px solid #82aaff;text-align:center}#qrcode{background:#fff;padding:10px;border-radius:6px;margin-bottom:10px}#qrcode canvas,#qrcode img{display:block;margin:0 auto}.qr-err{color:#c31e1e;font-size:13px;padding:10px;background:#fff;border-radius:4px;font-weight:700}.close-modal-btn{background:#c31e1e;color:#fff;border:none;padding:8px 20px;border-radius:4px;cursor:pointer}@media(max-width:600px){.config-label{width:100%;margin-bottom:2px}.config-code{min-width:100%;order:3}.btn-action{flex:1;order:2}}
</style>
<script>
function copyText(e,t){navigator.clipboard.writeText(document.getElementById(e).innerText.trim()).then(()=>{let o=t.innerText;t.innerText="OK",t.style.cssText="background:#c3e88d;color:#121212",setTimeout(()=>{t.innerText=o,t.style.cssText=""},1500)}).catch(e=>console.error(e))}
function showQR(e){
    let t=document.getElementById(e).innerText.trim(),o=document.getElementById("qrModal"),n=document.getElementById("qrcode");
    n.innerHTML="";
    if(e==='cAll'||t.length>1800){
        n.innerHTML="<div class='qr-err'>❌ Слишком много данных для одного QR-кода.<br>Используйте кнопку Copy.</div>";
        o.style.display="flex";
        return;
    }
    let c=document.createElement("canvas");
    n.appendChild(c);
    QRCode.toCanvas(c,t,{width:256,margin:2,errorCorrectionLevel:'L'},function(err){
        if(err){
            console.error(err);
            n.innerHTML="<div class='qr-err'>❌ Ошибка создания QR.<br>Скопируйте ссылку вручную.</div>";
        }
    });
    o.style.display="flex";
}
function closeModal(){document.getElementById("qrModal").style.display="none"}
window.onclick=function(e){e.target==document.getElementById("qrModal")&&closeModal()};
</script>
</head><body>
EOF

# --- ЗАПИСЬ BODY (ДИНАМИЧЕСКИЕ ДАННЫЕ) ---
cat >> "$WEB_PATH/$path_subpage.html" <<EOF

<h2>📂 Ссылка на подписку (готовый конфиг клиента с роутингом)</h2>
<div class="config-row">
    <div class="config-label">Subscription</div>
    <div class="config-code" id="subLink">$subPageLink</div>
    <button class="btn-action copy-btn" onclick="copyText('subLink', this)">Copy</button>
    <button class="btn-action qr-btn" onclick="showQR('subLink')">QR</button>
</div>


<h2>📱 Приложение HAPP (Windows/Android/iOS/MAC/Linux)</h2>

<div class="btn-group">
    <a href="happ://add/$subPageLink" class="btn">⚡ Add to HAPP</a>
    <a href="https://www.happ.su/main/ru" target="_blank" class="btn download">⬇️ Download App</a>
</div>
<p>Маршрутизацию нужно выключить, она тут встроенная. По умолчанию она выключена - включается, если вы пользовались сторонними сервисами.</p>


<h2>➡️ Конфиги</h2>
EOF

# Цикл генерации строк конфигов (XHTTP -> RAW VISION -> HY2)
idx=1
for item in "${CONFIGS_ARRAY[@]}"; do
    title="${item%%|*}"
    link="${item#*|}"
    
    if [ -z "$ALL_LINKS_TEXT" ]; then ALL_LINKS_TEXT="$link"; else ALL_LINKS_TEXT="$ALL_LINKS_TEXT<br>$link"; fi
    
    cat >> "$WEB_PATH/$path_subpage.html" <<EOF
<div class="config-row">
    <div class="config-label">$title</div>
    <div class="config-code" id="c$idx">$link</div>
    <button class="btn-action copy-btn" onclick="copyText('c$idx', this)">Copy</button>
    <button class="btn-action qr-btn" onclick="showQR('c$idx')">QR</button>
</div>
EOF
    ((idx++))
done

# Добавляем Web Proxy блок (чистые tg:// ссылки)
if [ "$INSTALL_MTP" = true ]; then
cat >> "$WEB_PATH/$path_subpage.html" <<EOF
<div class="config-row">
    <div class="config-label">Telegram Web Proxy</div>
    <div class="config-code" id="mtproto">${MTProto}</div>
    <button class="btn-action copy-btn" onclick="copyText('mtproto', this)">Copy</button>
    <a href="${MTProto}" target="_blank" class="btn-action qr-btn" title="автодобавление прокси в тг" style="text-decoration:none">✈️ Add to TG</a>
</div>
EOF
fi

# Дописываем конец страницы
cat >> "$WEB_PATH/$path_subpage.html" <<EOF
<h2>💠 Все конфиги вместе</h2>
<div class="config-row">
    <div class="config-code" id="cAll" style="max-height:60px;white-space:pre-wrap;word-break:break-all">$ALL_LINKS_TEXT</div>
    <button class="btn-action copy-btn" onclick="copyText('cAll', this)">Copy ALL</button>
</div>

<div><a style="color:white;margin:40px auto 20px;display:block;text-align:center;" href="https://github.com/xVRVx/autoXRAY">https://github.com/xVRVx/autoXRAY</a></div>

<div id="qrModal" class="modal-overlay"><div class="modal-content"><div id="qrcode"></div><button class="close-modal-btn" onclick="closeModal()">Close</button></div></div>
</body></html>
EOF

# --- служебные файлы: состояние, watchdog, logrotate, команда autoxray ---
ax_state_save
if ! ax_install_helpers; then
    ax_warn "⚠️ Основная установка завершена, но команда autoxray не была создана. Проверьте права /usr/local/bin и /usr/local/lib."
fi

# --- ФИНАЛЬНАЯ ПРОВЕРКА ---
echo -e "\n${YEL}=== Финальная проверка статусов ===${NC}"

if [ "$INSTALL_MTP" = true ]; then
    if systemctl is-active --quiet telemt; then echo -e "Telemt: ${GRN}RUNNING${NC}"; else echo -e "Telemt: ${RED}STOPPED/ERROR${NC}"; fi
    if systemctl is-active --quiet tproxy-server; then echo -e "WebProxy: ${GRN}RUNNING${NC}"; else echo -e "WebProxy: ${RED}STOPPED/ERROR${NC}"; fi
fi

if systemctl is-active --quiet nginx; then
    echo -e "Nginx: ${GRN}RUNNING${NC}"
else
    echo -e "Nginx: ${RED}STOPPED/ERROR${NC}"
fi

if systemctl is-active --quiet xray; then
    echo -e "XRAY: ${GRN}RUNNING${NC}"
else
    echo -e "XRAY: ${RED}STOPPED/ERROR${NC}"
fi

echo -e "\n"

if [ "$INSTALL_MTP" = true ]; then
    echo -e "${YEL}Telegram Web Proxy для ТГ:${NC}"
    echo -e "${CYAN}$MTProto${NC}\n"
fi

echo -e "${YEL}VLESS XHTTP TLS stream-up (Порт 443 TCP - для моста) ${NC}
$linkTLS2

${YEL}VLESS RAW TLS VISION (Порт 443 TCP) ${NC}
$linkTLS1

${YEL}HYSTERIA2 (Порт 443 UDP) ${NC}
$hy2

${EXTRA_LINKS_TEXT}${YEL}Ваша json страничка подписки ${NC}
$subPageLink

${YEL}Универсальная подписка (base64) ${NC}
$subTxtLink

${YEL}Ссылка на сохраненные конфиги ${NC}
${GRN}$configListLink ${NC}

Скопируйте подписку в специализированное приложение:
- iOS: Happ или v2RayTun или v2rayN
- Android: Happ или v2RayTun или v2rayNG
- Windows: конфиги Happ или winLoadXRAY или v2rayN
	для vless v2RayTun или Throne

Внутри клиента открыт socks5 на 10808, 2080 и http на 10809.

Служебные команды: autoxray status | links | selftest | backup list | firewall | check-updates

${GRN}Поддержать автора: https://github.com/xVRVx/autoXRAY ${NC}
"