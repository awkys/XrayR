#!/usr/bin/env bash
# Install XrayR from the public backup repository asset.

set -euo pipefail

XRAYR_REPO="${XRAYR_REPO:-awkys/XrayR}"
XRAYR_TAG="${XRAYR_TAG:-latest}"
XRAYR_ASSET="${XRAYR_ASSET:-}"
XRAYR_INSTALL_DIR="${XRAYR_INSTALL_DIR:-/usr/local/XrayR}"
XRAYR_CONFIG_DIR="${XRAYR_CONFIG_DIR:-/etc/XrayR}"
XRAYR_BIN="${XRAYR_INSTALL_DIR}/XrayR"
XRAYR_SERVICE_FILE="${XRAYR_SERVICE_FILE:-/etc/systemd/system/XrayR.service}"
XRAYR_MIN_FREE_KB="${XRAYR_MIN_FREE_KB:-300000}"
TMP_DIR=""

cleanup() {
    if [ -n "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

fail() {
    log "ERROR: $*"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

existing_path() {
    local path="$1"

    while [ ! -e "$path" ] && [ "$path" != "/" ]; do
        path="$(dirname "$path")"
    done

    printf '%s' "$path"
}

check_free_space() {
    local path="$1"
    local label="$2"
    local free_kb=""

    path="$(existing_path "$path")"
    free_kb="$(df -Pk "$path" | awk 'NR == 2 {print $4}')"
    if [ -z "$free_kb" ]; then
        return 0
    fi

    if [ "$free_kb" -lt "$XRAYR_MIN_FREE_KB" ]; then
        fail "Not enough free disk space on ${label} (${path}). Need at least ${XRAYR_MIN_FREE_KB} KB, available ${free_kb} KB."
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "Please run as root."
    fi
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)
            echo "XrayR-linux-64.zip"
            ;;
        aarch64|arm64)
            echo "XrayR-linux-arm64-v8a.zip"
            ;;
        *)
            fail "Unsupported architecture: ${arch}. Set XRAYR_ASSET manually if you have a matching release asset."
            ;;
    esac
}

install_packages() {
    local packages="curl wget unzip ca-certificates"

    if command_exists apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y $packages
    elif command_exists dnf; then
        dnf install -y $packages
    elif command_exists yum; then
        yum install -y $packages
    else
        command_exists curl || command_exists wget || fail "curl or wget is required."
        command_exists unzip || fail "unzip is required."
    fi
}

download_file() {
    local url="$1"
    local out="$2"

    if command_exists curl; then
        curl -fsSL --connect-timeout 20 --retry 2 --retry-delay 1 -o "$out" "$url"
    else
        wget -q -O "$out" "$url"
    fi
}

download_release_asset() {
    local archive="$1"
    local asset="$2"
    local url=""
    local raw_url="https://raw.githubusercontent.com/${XRAYR_REPO}/master/${asset}"

    if [ "$XRAYR_TAG" = "latest" ]; then
        log "Downloading raw backup file: ${raw_url}"
        if download_file "$raw_url" "$archive"; then
            return 0
        fi
        log "Raw backup file not found, trying GitHub release asset."
    fi

    if [ "$XRAYR_TAG" = "latest" ]; then
        url="https://github.com/${XRAYR_REPO}/releases/latest/download/${asset}"
    else
        url="https://github.com/${XRAYR_REPO}/releases/download/${XRAYR_TAG}/${asset}"
    fi

    log "Downloading ${url}"
    if download_file "$url" "$archive"; then
        return 0
    fi

    log "Release asset not found, trying raw backup file: ${raw_url}"
    download_file "$raw_url" "$archive"
}

install_service() {
    command_exists systemctl || fail "systemctl is required."

    cat > "$XRAYR_SERVICE_FILE" <<EOF
[Unit]
Description=XrayR Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
ExecStart=${XRAYR_BIN} --config ${XRAYR_CONFIG_DIR}/config.yml
Restart=on-failure
RestartSec=3
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable XrayR >/dev/null 2>&1 || true
}

install_xrayr() {
    local tmp_dir=""
    local archive=""
    local extract_dir=""
    local binary=""
    local asset="$XRAYR_ASSET"
    local file=""

    [ -n "$asset" ] || asset="$(detect_arch)"

    check_free_space "${TMPDIR:-/tmp}" "temporary directory"
    check_free_space "$XRAYR_INSTALL_DIR" "install directory"
    check_free_space "$XRAYR_CONFIG_DIR" "config directory"

    TMP_DIR="$(mktemp -d)"
    tmp_dir="$TMP_DIR"
    extract_dir="${tmp_dir}/extract"
    archive="${tmp_dir}/${asset}"
    mkdir -p "$extract_dir"

    download_release_asset "$archive" "$asset"
    if ! unzip -oq "$archive" -d "$extract_dir" </dev/null; then
        fail "Failed to extract ${asset}. Please check disk space with: df -h"
    fi

    binary="$(find "$extract_dir" -type f -name XrayR | head -n 1)"
    [ -n "$binary" ] || fail "XrayR binary not found in ${asset}."

    mkdir -p "$XRAYR_INSTALL_DIR" "$XRAYR_CONFIG_DIR" /usr/local/bin
    cp -f "$binary" "$XRAYR_BIN"
    chmod +x "$XRAYR_BIN"
    ln -sf "$XRAYR_BIN" /usr/local/bin/XrayR
    ln -sf "$XRAYR_BIN" /usr/local/bin/xrayr

    for file in dns.json route.json custom_inbound.json custom_outbound.json geoip.dat geosite.dat rulelist; do
        if [ -e "${extract_dir}/${file}" ]; then
            cp -Rf "${extract_dir}/${file}" "${XRAYR_CONFIG_DIR}/${file}"
        fi
    done

    if [ ! -f "${XRAYR_CONFIG_DIR}/config.yml" ] && [ -f "${extract_dir}/config.yml" ]; then
        cp -f "${extract_dir}/config.yml" "${XRAYR_CONFIG_DIR}/config.yml"
    fi

    install_service
    "$XRAYR_BIN" version >/dev/null 2>&1 || fail "Installed XrayR binary cannot run."
}

main() {
    require_root
    install_packages
    install_xrayr
    log "XrayR installed successfully."
}

main "$@"
