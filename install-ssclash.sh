#!/bin/sh
# ================================================================
#  SSClash Auto-Installer for OpenWrt
#  Поддерживаемые версии: 21.x / 23.05.x / 24.10.x / 25.12.x
#  Архитектуры: arm64, armhf, mipsel_24kc, mips_24kc, amd64
#  https://github.com/Lysifer/SSClashR
# ================================================================

SSCLASH_API="https://api.github.com/repos/Lysifer/SSClashR/releases/latest"
MIHOMO_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
MIHOMO_BASE="https://github.com/MetaCubeX/mihomo/releases"
CLASH_BIN="/opt/clash/bin/clash"

# SSCLASH_VER и URL пакетов заполняются в fetch_ssclash_release()
SSCLASH_VER=""
SSCLASH_APK_URL=""
SSCLASH_IPK_URL=""
SSCLASH_SHA256_URL=""
PKG_UPDATED=0   # станет 1, если ensure_curl() уже обновил индекс

# ── цвета ───────────────────────────────────────────────────────
# printf '\033[Xm' корректно интерпретируется в любом POSIX sh
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    R=$(printf '\033[0;31m') G=$(printf '\033[0;32m') Y=$(printf '\033[1;33m')
    C=$(printf '\033[0;36m') B=$(printf '\033[1m')    N=$(printf '\033[0m')
else
    R='' G='' Y='' C='' B='' N=''
fi
log()  { printf "%s[+]%s %s\n" "$G" "$N" "$*"; }
info() { printf "%s[i]%s %s\n" "$C" "$N" "$*"; }
warn() { printf "%s[!]%s %s\n" "$Y" "$N" "$*"; }
die()  { printf "%s[✗] %s%s\n" "$R" "$*" "$N" >&2; exit 1; }
sep()  { printf "%s%s%s\n"     "$C" "────────────────────────────────────────" "$N"; }

CURL_OPTS="-fL --retry 3 --connect-timeout 15 --max-time 180"

download_file() {
    url="$1"
    output="$2"

    rm -f "$output"
    curl $CURL_OPTS "$url" -o "$output"
}

verify_sha256_file() {
    file="$1"
    sums_url="$2"

    [ -s "$file" ] || die "Загруженный файл пустой: $file"

    if ! command -v sha256sum >/dev/null 2>&1; then
        warn "sha256sum недоступен — пропускаю проверку SHA256"
        return 0
    fi

    if [ -z "$sums_url" ]; then
        warn "В релизе нет sha256sums.txt — пропускаю проверку SHA256"
        return 0
    fi

    sums_file="/tmp/ssclash-sha256sums.txt"
    download_file "$sums_url" "$sums_file" || die "Не удалось загрузить sha256sums.txt"

    expected=$(grep -F "  ${file##*/}" "$sums_file" | head -1 | awk '{print $1}')
    [ -n "$expected" ] || expected=$(grep -F " *${file##*/}" "$sums_file" | head -1 | awk '{print $1}')
    [ -n "$expected" ] || die "В sha256sums.txt нет записи для ${file##*/}"

    actual=$(sha256sum "$file" | awk '{print $1}')
    [ "$actual" = "$expected" ] || die "SHA256 не совпал для ${file##*/}"

    rm -f "$sums_file"
    log "SHA256 проверен: ${file##*/}"
}

# ================================================================
#  0. Гарантируем наличие curl
#     Вызывается после detect_openwrt (нужен PKG_MGR),
#     но до любых сетевых запросов
# ================================================================
ensure_curl() {
    if command -v curl >/dev/null 2>&1; then
        info "curl: уже установлен ($(curl --version | head -1 | cut -d' ' -f1-2))"
        return 0
    fi

    warn "curl не найден — устанавливаю..."
    if [ "$PKG_MGR" = "apk" ]; then
        apk update  || die "apk update завершился с ошибкой"
        apk add curl || die "Не удалось установить curl"
    else
        opkg update  || die "opkg update завершился с ошибкой"
        opkg install curl || die "Не удалось установить curl"
    fi

    command -v curl >/dev/null 2>&1 || die "curl всё равно недоступен после установки"
    log "curl установлен"

    # Флаг: индекс пакетов уже обновлён — pkg_update() повторно не нужен
    PKG_UPDATED=1
}

# ================================================================
#  1. Версия OpenWrt и пакетный менеджер
# ================================================================
detect_openwrt() {
    [ -f /etc/openwrt_release ] || die "Не найден /etc/openwrt_release — это OpenWrt?"
    . /etc/openwrt_release

    OW_RELEASE="${DISTRIB_RELEASE:-unknown}"
    OW_MAJOR=$(echo "$OW_RELEASE" | cut -d. -f1)
    OW_MINOR=$(echo "$OW_RELEASE" | cut -d. -f2)

    info "OpenWrt: ${B}${OW_RELEASE}${N}"

    # OpenWrt 25+ использует apk; 21-24 — opkg
    if [ "${OW_MAJOR:-0}" -ge 25 ] 2>/dev/null; then
        PKG_MGR="apk"
    else
        PKG_MGR="opkg"
    fi
    info "Пакетный менеджер: ${B}${PKG_MGR}${N}"

    # Для OpenWrt 21.x нужен iptables-mod-tproxy вместо kmod-nft-tproxy
    if [ "${OW_MAJOR:-0}" -le 21 ] 2>/dev/null; then
        TPROXY_PKG="iptables-mod-tproxy"
    else
        TPROXY_PKG="kmod-nft-tproxy"
    fi
    info "Пакет tproxy: ${B}${TPROXY_PKG}${N}"
}

# ================================================================
#  2. Определение архитектуры → имя файла ядра mihomo
# ================================================================
detect_arch() {
    ARCH_RAW=$(uname -m)

    # Уточняем по DISTRIB_TARGET из /etc/openwrt_release
    . /etc/openwrt_release
    TARGET="${DISTRIB_TARGET:-}"
    ARCH_PKG="${DISTRIB_ARCH:-}"

    info "CPU (uname -m): ${B}${ARCH_RAW}${N}"
    info "OpenWrt target: ${B}${TARGET}${N}"
    info "DISTRIB_ARCH:   ${B}${ARCH_PKG}${N}"

    case "$ARCH_RAW" in
        aarch64)
            MIHOMO_ARCH="arm64"
            ;;
        armv7l|armv6l)
            # armv7 с hardfloat
            MIHOMO_ARCH="armv7"
            ;;
        mips)
            # big-endian MIPS (ar71xx, ath79 — старые роутеры)
            MIHOMO_ARCH="mips-softfloat"
            ;;
        mipsel)
            # little-endian MIPS (MediaTek MT76xx legacy, Realtek)
            MIHOMO_ARCH="mipsle-softfloat"
            ;;
        x86_64)
            MIHOMO_ARCH="amd64-compatible"
            ;;
        i686|i386)
            MIHOMO_ARCH="386"
            ;;
        *)
            warn "Неизвестная архитектура: ${ARCH_RAW}"
            warn "Посмотри доступные ядра: ${MIHOMO_BASE}/latest"
            MIHOMO_ARCH=""
            ;;
    esac

    # Дополнительная проверка по target для ARM:
    # Некоторые armv7 роутеры возвращают uname -m = armv7l, но нужен armv7
    case "$TARGET" in
        *armvirt*|*bcm27xx*|*mvebu*|*sunxi*|*imx*|*bcm53xx*)
            [ "$MIHOMO_ARCH" = "armv7" ] || true
            ;;
    esac

    if [ -n "$MIHOMO_ARCH" ]; then
        info "Ядро mihomo: ${B}mihomo-linux-${MIHOMO_ARCH}${N}"
    fi
}

# ================================================================
#  3. Обновление индекса пакетов
# ================================================================
pkg_update() {
    if [ "$PKG_UPDATED" = "1" ]; then
        info "Индекс пакетов уже обновлён — пропускаю"
        return 0
    fi
    log "Обновление списка пакетов..."
    if [ "$PKG_MGR" = "apk" ]; then
        apk update || die "apk update завершился с ошибкой"
    else
        opkg update || die "opkg update завершился с ошибкой"
    fi
    PKG_UPDATED=1
}

# ================================================================
#  4. Установка зависимостей
# ================================================================
install_deps() {
    log "Установка зависимостей: curl ${TPROXY_PKG} kmod-tun coreutils-base64"
    if [ "$PKG_MGR" = "apk" ]; then
        apk add curl "$TPROXY_PKG" kmod-tun coreutils-base64 \
            || die "Ошибка установки зависимостей"
    else
        opkg install curl "$TPROXY_PKG" kmod-tun coreutils-base64 \
            || die "Ошибка установки зависимостей"
    fi
}

# ================================================================
#  5а. Получение последнего релиза SSClash через GitHub API
# ================================================================
fetch_ssclash_release() {
    log "Определяю последнюю версию SSClash..."

    # GitHub API возвращает JSON; парсим grep+sed — без jq (его нет в OpenWrt по умолчанию)
    RELEASE_JSON=$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 "$SSCLASH_API") \
        || die "Не удалось получить данные релиза SSClash"

    [ -z "$RELEASE_JSON" ] && die "GitHub API вернул пустой ответ"

    # Тег вида "v4.5.1"
    SSCLASH_VER=$(printf '%s' "$RELEASE_JSON" \
        | grep '"tag_name"' | head -1 \
        | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/')

    [ -z "$SSCLASH_VER" ] && die "Не удалось распарсить tag_name из ответа GitHub API"
    info "Последняя версия SSClash: ${B}v${SSCLASH_VER}${N}"

    # Из списка assets берём URL для .apk и .ipk
    # browser_download_url идут построчно — берём нужные по расширению
    SSCLASH_APK_URL=$(printf '%s' "$RELEASE_JSON" \
        | grep '"browser_download_url"' \
        | grep '\.apk"' | head -1 \
        | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    SSCLASH_IPK_URL=$(printf '%s' "$RELEASE_JSON" \
        | grep '"browser_download_url"' \
        | grep '\.ipk"' | head -1 \
        | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    SSCLASH_SHA256_URL=$(printf '%s' "$RELEASE_JSON" \
        | grep '"browser_download_url"' \
        | grep 'sha256sums\.txt"' | head -1 \
        | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    if [ "$PKG_MGR" = "apk" ]; then
        [ -z "$SSCLASH_APK_URL" ] && die "Не найден .apk в assets релиза SSClash"
        info "Пакет: ${B}${SSCLASH_APK_URL##*/}${N}"
    else
        [ -z "$SSCLASH_IPK_URL" ] && die "Не найден .ipk в assets релиза SSClash"
        info "Пакет: ${B}${SSCLASH_IPK_URL##*/}${N}"
    fi
}

# ================================================================
#  5б. Установка luci-app-ssclash
# ================================================================
install_ssclash() {
    log "Загрузка luci-app-ssclash v${SSCLASH_VER}..."

    if [ "$PKG_MGR" = "apk" ]; then
        PKG_FILE="/tmp/${SSCLASH_APK_URL##*/}"
        download_file "$SSCLASH_APK_URL" "$PKG_FILE" || die "Ошибка загрузки .apk"
        verify_sha256_file "$PKG_FILE" "$SSCLASH_SHA256_URL"
        log "Установка пакета..."
        apk add --allow-untrusted "$PKG_FILE" || die "Ошибка установки .apk"
    else
        PKG_FILE="/tmp/${SSCLASH_IPK_URL##*/}"
        download_file "$SSCLASH_IPK_URL" "$PKG_FILE" || die "Ошибка загрузки .ipk"
        verify_sha256_file "$PKG_FILE" "$SSCLASH_SHA256_URL"
        log "Установка пакета..."
        opkg install "$PKG_FILE" || die "Ошибка установки .ipk"
    fi

    rm -f "$PKG_FILE"
}

# ================================================================
#  6. Загрузка и установка ядра mihomo
# ================================================================
install_mihomo() {
    if [ -z "$MIHOMO_ARCH" ]; then
        warn "Архитектура не определена автоматически."
        warn "Вручную скачай нужное ядро: ${MIHOMO_BASE}/latest"
        return 0
    fi

    log "Определяю последнюю версию mihomo..."
    MIHOMO_JSON=$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 "$MIHOMO_API") \
        || die "Не удалось получить данные релиза mihomo"

    MIHOMO_VER=$(printf '%s' "$MIHOMO_JSON" \
        | grep '"tag_name"' | head -1 \
        | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    if [ -z "$MIHOMO_VER" ]; then
        die "Не удалось получить версию mihomo. Проверь интернет-соединение."
    fi
    info "Последняя версия mihomo: ${B}${MIHOMO_VER}${N}"

    MIHOMO_URL=$(printf '%s' "$MIHOMO_JSON" \
        | grep '"browser_download_url"' \
        | grep "mihomo-linux-${MIHOMO_ARCH}-${MIHOMO_VER}\.gz\"" | head -1 \
        | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    [ -z "$MIHOMO_URL" ] && die "Не найдено ядро mihomo для архитектуры ${MIHOMO_ARCH}"
    info "URL: ${MIHOMO_URL}"

    log "Загрузка ядра mihomo..."
    download_file "$MIHOMO_URL" /tmp/clash.gz || die "Ошибка загрузки ядра mihomo"

    log "Распаковка в ${CLASH_BIN}..."
    mkdir -p "$(dirname "$CLASH_BIN")"
    gunzip -c /tmp/clash.gz > "$CLASH_BIN" || die "Ошибка распаковки"
    chmod +x "$CLASH_BIN"
    rm -f /tmp/clash.gz

    if [ -f "/opt/clash/bin/meta-backup" ]; then
        log "Удаляю резервную копию ядра mihomo..."
        rm -f /opt/clash/bin/meta-backup
    fi

    log "Ядро установлено: $("$CLASH_BIN" -v 2>/dev/null || echo 'версия недоступна до запуска сервиса')"
}

# ================================================================
#  MAIN
# ================================================================
sep
printf "  ${B}SSClash Auto-Installer${N}\n"
sep

detect_openwrt
ensure_curl      # нужен для всех последующих сетевых запросов
detect_arch
fetch_ssclash_release
sep

pkg_update
sep

install_deps
sep

# Запоминаем, был ли сервис включён до установки/обновления пакета
CLASH_WAS_ENABLED=0
if [ -x /etc/init.d/clash ] && /etc/init.d/clash enabled 2>/dev/null; then
    CLASH_WAS_ENABLED=1
    info "Сервис clash был включён — состояние будет восстановлено после обновления"
fi

install_ssclash

# Если сервис был включён до обновления — восстанавливаем enabled-состояние,
# которое post-install скрипт пакета сбросил в disabled
if [ "$CLASH_WAS_ENABLED" = "1" ] && [ -x /etc/init.d/clash ]; then
    log "Восстанавливаю автозапуск сервиса clash..."
    /etc/init.d/clash enable
fi
sep

# После post-upgrade хука clash мог автоматически стартовать и перехватить трафик
if [ -x /etc/init.d/clash ] && pidof clash >/dev/null 2>&1; then
    warn "Сервис clash запущен — останавливаю перед загрузкой ядра mihomo..."
    /etc/init.d/clash stop
fi

install_mihomo
sep

log "${G}Установка завершена!${N}"
echo ""
info "Следующие шаги:"
echo "  1. Открой LuCI → Services → SSClash"
echo "  2. Вставь свою конфигурацию Clash/Mihomo в редактор"
printf "  3. Нажми %sSave & Apply%s\n" "$B" "$N"
printf "  4. Перезапусти сервис: %s/etc/init.d/clash restart%s\n" "$B" "$N"
echo ""
warn "Если ядро mihomo не определилось автоматически:"
warn "  → ${MIHOMO_BASE}/latest"
sep
