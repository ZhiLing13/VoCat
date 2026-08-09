#!/bin/sh
# Install or update VoCat on OpenWrt/procd systems.
#
# Examples:
#   sh install-vocat-openwrt.sh
#   VOCAT_ADMIN_PASSWORD='ChangeMe_2026' sh install-vocat-openwrt.sh 0.0.12
#   VOCAT_LOCAL_SOURCE=/mnt/sda1/vocat sh install-vocat-openwrt.sh 0.0.12
#
# Optional environment variables:
#   VOCAT_VERSION            Release version without the leading "v" (default: 0.0.12)
#   VOCAT_PORT               HTTP port (default: 7576)
#   VOCAT_ADMIN_USERNAME     Initial administrator name (default: admin)
#   VOCAT_ADMIN_PASSWORD     Initial administrator password; generated when omitted
#   VOCAT_RELEASE_BASE       Alternate release URL base, without the trailing slash
#   VOCAT_LOCAL_SOURCE       Directory containing vocat-linux-<arch> and SHA256SUMS
#   VOCAT_INSECURE_TLS=1     Disable TLS verification for downloads (not recommended)
#   VOCAT_OVERWRITE_CONFIG=1 Replace /etc/vocat/env on an existing installation

set -eu

REPO="MengMengCode/VoCat"
VERSION="${1:-${VOCAT_VERSION:-0.0.12}}"
VERSION="${VERSION#v}"
PORT="${VOCAT_PORT:-7576}"
ADMIN_USERNAME="${VOCAT_ADMIN_USERNAME:-admin}"
PREFIX="/opt/vocat"
BIN_DIR="$PREFIX/bin"
DATA_DIR="$PREFIX/data"
BIN_PATH="$BIN_DIR/vocat"
CONFIG_DIR="/etc/vocat"
CONFIG_FILE="$CONFIG_DIR/env"
INIT_SCRIPT="/etc/init.d/vocat"
TMP_DIR="/tmp/vocat-install.$$"

fail() {
    echo "VoCat installation failed: $*" >&2
    exit 1
}

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

require_root() {
    [ "$(id -u)" -eq 0 ] || fail "run this script as root"
}

detect_arch() {
    case "$(uname -m)" in
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armv7) echo "armv7" ;;
        x86_64|amd64) echo "amd64" ;;
        i386|i486|i586|i686) echo "386" ;;
        *) fail "unsupported architecture: $(uname -m)" ;;
    esac
}

download_with_curl() {
    source_url="$1"
    destination="$2"

    if [ -n "${VOCAT_PROXY:-}" ]; then
        if [ "${VOCAT_INSECURE_TLS:-0}" = "1" ]; then
            curl -k -fL --retry 2 --connect-timeout 15 --max-time 300 \
                --proxy "$VOCAT_PROXY" -o "$destination" "$source_url"
        else
            curl -fL --retry 2 --connect-timeout 15 --max-time 300 \
                --proxy "$VOCAT_PROXY" -o "$destination" "$source_url"
        fi
    elif [ "${VOCAT_INSECURE_TLS:-0}" = "1" ]; then
        curl -k -fL --retry 2 --connect-timeout 15 --max-time 300 \
            -o "$destination" "$source_url"
    else
        curl -fL --retry 2 --connect-timeout 15 --max-time 300 \
            -o "$destination" "$source_url"
    fi
}

download_file() {
    source_url="$1"
    destination="$2"

    if command -v curl >/dev/null 2>&1; then
        download_with_curl "$source_url" "$destination"
        return
    fi

    if command -v wget >/dev/null 2>&1; then
        if [ "${VOCAT_INSECURE_TLS:-0}" = "1" ]; then
            wget --no-check-certificate -O "$destination" "$source_url"
        else
            wget -O "$destination" "$source_url"
        fi
        return
    fi

    fail "curl or wget is required"
}

generate_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
}

validate_env_value() {
    case "$1" in
        *[[:space:]]*) fail "configuration values cannot contain whitespace" ;;
    esac
}

write_config() {
    password="$1"
    validate_env_value "$ADMIN_USERNAME"
    validate_env_value "$password"

    umask 077
    {
        printf '%s\n' "VOCAT_ADDR=0.0.0.0:$PORT"
        printf '%s\n' "VOCAT_DATABASE_PATH=$DATA_DIR/vocat.db"
        printf '%s\n' "VOCAT_ADMIN_USERNAME=$ADMIN_USERNAME"
        printf '%s\n' "VOCAT_ADMIN_PASSWORD=$password"
        printf '%s\n' "VOCAT_SESSION_TTL=24h"
    } > "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
}

write_init_script() {
    {
        printf '%s\n' '#!/bin/sh /etc/rc.common'
        printf '%s\n' 'START=99'
        printf '%s\n' 'USE_PROCD=1'
        printf '%s\n' 'PROG=/opt/vocat/bin/vocat'
        printf '%s\n' 'VOCAT_ENV=/etc/vocat/env'
        printf '%s\n' ''
        printf '%s\n' 'start_service() {'
        printf '%s\n' '    procd_open_instance'
        printf '%s\n' '    procd_set_param command "$PROG" serve'
        printf '%s\n' '    procd_set_param env $(cat "$VOCAT_ENV")'
        printf '%s\n' '    procd_set_param respawn 3600 5 5'
        printf '%s\n' '    procd_set_param stdout 1'
        printf '%s\n' '    procd_set_param stderr 1'
        printf '%s\n' '    procd_close_instance'
        printf '%s\n' '}'
    } > "$INIT_SCRIPT"
    chmod 0755 "$INIT_SCRIPT"
}

require_root
ARCH="$(detect_arch)"
ASSET="vocat-linux-$ARCH"
SUM_FILE="$TMP_DIR/SHA256SUMS"
ASSET_FILE="$TMP_DIR/$ASSET"

mkdir -p "$TMP_DIR" "$BIN_DIR" "$DATA_DIR" "$CONFIG_DIR"

if [ -n "${VOCAT_LOCAL_SOURCE:-}" ]; then
    [ -f "$VOCAT_LOCAL_SOURCE/$ASSET" ] || fail "missing $VOCAT_LOCAL_SOURCE/$ASSET"
    [ -f "$VOCAT_LOCAL_SOURCE/SHA256SUMS" ] || fail "missing $VOCAT_LOCAL_SOURCE/SHA256SUMS"
    cp "$VOCAT_LOCAL_SOURCE/$ASSET" "$ASSET_FILE"
    cp "$VOCAT_LOCAL_SOURCE/SHA256SUMS" "$SUM_FILE"
else
    RELEASE_BASE="${VOCAT_RELEASE_BASE:-https://github.com/$REPO/releases/download/v$VERSION}"
    download_file "$RELEASE_BASE/SHA256SUMS" "$SUM_FILE"
    download_file "$RELEASE_BASE/$ASSET" "$ASSET_FILE"
fi

EXPECTED_SUM="$(awk -v asset="$ASSET" '$2 == asset { print $1 }' "$SUM_FILE")"
[ -n "$EXPECTED_SUM" ] || fail "SHA256SUMS does not contain $ASSET"
ACTUAL_SUM="$(sha256sum "$ASSET_FILE" | awk '{ print $1 }')"
[ "$EXPECTED_SUM" = "$ACTUAL_SUM" ] || fail "SHA-256 verification failed"

chmod 0755 "$ASSET_FILE"
cp "$ASSET_FILE" "$BIN_PATH.new"
chmod 0755 "$BIN_PATH.new"
mv "$BIN_PATH.new" "$BIN_PATH"

INITIAL_PASSWORD=""
if [ ! -f "$CONFIG_FILE" ] || [ "${VOCAT_OVERWRITE_CONFIG:-0}" = "1" ]; then
    INITIAL_PASSWORD="${VOCAT_ADMIN_PASSWORD:-$(generate_password)}"
    write_config "$INITIAL_PASSWORD"
fi

write_init_script
"$INIT_SCRIPT" enable
"$INIT_SCRIPT" restart

echo "VoCat $VERSION installed for $ARCH."
echo "Open: http://$(uci -q get network.lan.ipaddr 2>/dev/null || echo '<router-ip>'):$PORT"
if [ -n "$INITIAL_PASSWORD" ]; then
    echo "Initial administrator username: $ADMIN_USERNAME"
    echo "Initial administrator password: $INITIAL_PASSWORD"
    echo "Change this password after the first login."
else
    echo "Existing configuration preserved: $CONFIG_FILE"
fi
