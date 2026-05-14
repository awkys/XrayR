#!/bin/bash
# XrayR 自动对接脚本 (SSPanel / Metron)
# 目标: 稳定对接 VLESS(含 Reality) / Trojan / Shadowsocks

set -e

API_HOST="${1:-}"
API_KEY="${2:-}"
NODE_ID="${3:-}"

API_HOST_FINAL=""
NODE_INFO=""
UNI_CONFIG=""

SERVER_STR=""
SORT=""
NODE_HOST=""
NODE_PORT=""
NODE_NETWORK=""
NODE_SECURITY=""
SERVER_PARAMS_RAW=""

FLOW_PARAM=""
PBK=""
SID=""
PRI_KEY=""
SNI=""
DEST=""

NODE_TYPE="V2ray"
ENABLE_VLESS="false"
ENABLE_XTLS="false"
ENABLE_REALITY="false"
VLESS_FLOW=""

XRAYR_REPO_URL="${XRAYR_REPO_URL:-https://github.com/awkys/XrayR.git}"
XRAYR_SOURCE_DIR="${XRAYR_SOURCE_DIR:-/usr/local/src/XrayR}"
XRAYR_INSTALL_DIR="${XRAYR_INSTALL_DIR:-/usr/local/XrayR}"
XRAYR_BIN="${XRAYR_INSTALL_DIR}/XrayR"
XRAYR_SERVICE_FILE="${XRAYR_SERVICE_FILE:-/etc/systemd/system/XrayR.service}"
XRAYR_CONFIG_FILE="${XRAYR_CONFIG_FILE:-/etc/XrayR/config.yml}"
XRAYR_SKIP_GIT_SYNC="${XRAYR_SKIP_GIT_SYNC:-0}"
XRAYR_FORCE_INSTALL="${XRAYR_FORCE_INSTALL:-0}"
XRAYR_GITHUB_REPO="${XRAYR_GITHUB_REPO:-}"
XRAYR_RELEASE_TAG="${XRAYR_RELEASE_TAG:-latest}"
XRAYR_RELEASE_ASSET="${XRAYR_RELEASE_ASSET:-XrayR-linux-64.zip}"
XRAYR_INSTALL_SCRIPT_URL="${XRAYR_INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/awkys/XrayR/master/install.sh}"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "请使用 root 运行此脚本。"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

detect_pkg_manager() {
    if command_exists apt-get; then
        echo "apt"
    elif command_exists dnf; then
        echo "dnf"
    elif command_exists yum; then
        echo "yum"
    else
        echo ""
    fi
}

ensure_xrayr_build_dependencies() {
    local mgr=""

    if command_exists git && command_exists go; then
        return 0
    fi

    mgr=$(detect_pkg_manager)
    [ -n "$mgr" ] || fail "未找到可用包管理器(apt/dnf/yum)，无法安装 XrayR 依赖。"

    log "安装 XrayR 编译依赖: git/go ..."
    case "$mgr" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y ca-certificates git curl wget tar gzip
            if ! command_exists go; then
                apt-get install -y golang-go || apt-get install -y golang
            fi
            ;;
        dnf)
            dnf install -y ca-certificates git curl wget tar gzip golang
            ;;
        yum)
            yum install -y ca-certificates git curl wget tar gzip golang
            ;;
    esac

    command_exists git || fail "git 安装失败。"
    command_exists go || fail "go 安装失败。"
}

sync_xrayr_runtime_files() {
    local src_main="${XRAYR_SOURCE_DIR}/main"
    local asset=""

    mkdir -p /etc/XrayR

    for asset in dns.json route.json custom_inbound.json custom_outbound.json geoip.dat geosite.dat; do
        if [ -f "${src_main}/${asset}" ]; then
            cp -f "${src_main}/${asset}" "/etc/XrayR/${asset}"
        fi
    done

    if [ ! -f "$XRAYR_CONFIG_FILE" ] && [ -f "${src_main}/config.yml.example" ]; then
        cp -f "${src_main}/config.yml.example" "$XRAYR_CONFIG_FILE"
    fi
}

download_xrayr_from_github_release() {
    local repo="$1"
    local tag="$2"
    local asset="$3"
    local base_url=""
    local download_url=""
    local tmp_dir=""
    local archive=""
    local extract_dir=""
    local candidate=""

    [ -n "$repo" ] || return 1
    if ! command_exists curl && ! command_exists wget; then
        log "未检测到 curl/wget，跳过 GitHub Release 预编译包安装。"
        return 1
    fi
    if ! command_exists unzip; then
        log "未检测到 unzip，跳过 GitHub Release 预编译包安装。"
        return 1
    fi

    if [ "$tag" = "latest" ]; then
        base_url="https://github.com/${repo}/releases/latest/download"
    else
        base_url="https://github.com/${repo}/releases/download/${tag}"
    fi
    download_url="${base_url}/${asset}"

    tmp_dir=$(mktemp -d)
    archive="${tmp_dir}/${asset}"
    extract_dir="${tmp_dir}/extract"
    mkdir -p "$extract_dir"

    log "尝试下载预编译 XrayR: ${download_url}"
    if command_exists curl; then
        if ! curl -fL --connect-timeout 15 --retry 2 --retry-delay 1 -o "$archive" "$download_url"; then
            rm -rf "$tmp_dir"
            return 1
        fi
    else
        if ! wget -q -O "$archive" "$download_url"; then
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    if ! unzip -q "$archive" -d "$extract_dir"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    candidate=$(find "$extract_dir" -type f -name XrayR -perm -u+x 2>/dev/null | head -n 1)
    if [ -z "$candidate" ]; then
        candidate=$(find "$extract_dir" -type f -name XrayR 2>/dev/null | head -n 1)
    fi
    [ -n "$candidate" ] || {
        rm -rf "$tmp_dir"
        return 1
    }

    mkdir -p "$XRAYR_INSTALL_DIR" /usr/local/bin /etc/XrayR
    cp -f "$candidate" "$XRAYR_BIN"
    chmod +x "$XRAYR_BIN"
    ln -sf "$XRAYR_BIN" /usr/local/bin/XrayR
    ln -sf "$XRAYR_BIN" /usr/local/bin/xrayr

    for candidate in README.md LICENSE config.yml dns.json route.json custom_inbound.json custom_outbound.json geoip.dat geosite.dat rulelist; do
        if [ -f "${extract_dir}/${candidate}" ]; then
            if [ "$candidate" = "config.yml" ]; then
                [ -f "$XRAYR_CONFIG_FILE" ] || cp -f "${extract_dir}/${candidate}" "$XRAYR_CONFIG_FILE"
            else
                cp -f "${extract_dir}/${candidate}" "/etc/XrayR/${candidate}"
            fi
        fi
    done

    rm -rf "$tmp_dir"
    log "已通过 GitHub Release 安装预编译 XrayR。"
    return 0
}

install_xrayr_from_install_script() {
    local installer=""

    if ! command_exists curl && ! command_exists wget; then
        log "未检测到 curl/wget，跳过 install.sh 安装。"
        return 1
    fi

    installer="$(mktemp)"
    log "尝试下载安装脚本: ${XRAYR_INSTALL_SCRIPT_URL}"
    if command_exists curl; then
        if ! curl -fL --connect-timeout 15 --retry 2 --retry-delay 1 -o "$installer" "$XRAYR_INSTALL_SCRIPT_URL"; then
            rm -f "$installer"
            return 1
        fi
    else
        if ! wget -q -O "$installer" "$XRAYR_INSTALL_SCRIPT_URL"; then
            rm -f "$installer"
            return 1
        fi
    fi

    XRAYR_REPO="${XRAYR_GITHUB_REPO:-awkys/XrayR}" \
    XRAYR_TAG="$XRAYR_RELEASE_TAG" \
    XRAYR_ASSET="$XRAYR_RELEASE_ASSET" \
    bash "$installer"
    rm -f "$installer"
}

install_xrayr_service() {
    command_exists systemctl || fail "系统未安装 systemd(systemctl)，无法管理 XrayR 服务。"

    cat > "$XRAYR_SERVICE_FILE" <<EOF
[Unit]
Description=XrayR Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
ExecStart=${XRAYR_BIN} --config ${XRAYR_CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable XrayR >/dev/null 2>&1 || true
}

install_xrayr_from_source() {
    log "开始从备份仓库安装 XrayR: ${XRAYR_REPO_URL}"

    ensure_xrayr_build_dependencies

    if [ "$XRAYR_SKIP_GIT_SYNC" != "1" ]; then
        mkdir -p "$(dirname "$XRAYR_SOURCE_DIR")"
        if [ -d "${XRAYR_SOURCE_DIR}/.git" ]; then
            log "更新现有源码目录: ${XRAYR_SOURCE_DIR}"
            git -C "$XRAYR_SOURCE_DIR" remote set-url origin "$XRAYR_REPO_URL" || true
            git -C "$XRAYR_SOURCE_DIR" fetch --depth=1 origin
            git -C "$XRAYR_SOURCE_DIR" checkout -f FETCH_HEAD
        else
            rm -rf "$XRAYR_SOURCE_DIR"
            git clone --depth=1 "$XRAYR_REPO_URL" "$XRAYR_SOURCE_DIR"
        fi
    elif [ ! -d "$XRAYR_SOURCE_DIR" ]; then
        fail "XRAYR_SKIP_GIT_SYNC=1 但源码目录不存在: $XRAYR_SOURCE_DIR"
    fi

    if [ ! -x "${XRAYR_SOURCE_DIR}/XrayR" ]; then
        log "编译 XrayR 二进制 ..."
        (
            cd "$XRAYR_SOURCE_DIR"
            CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -buildid=" -o XrayR ./main
        )
    else
        log "检测到已编译二进制，跳过编译: ${XRAYR_SOURCE_DIR}/XrayR"
    fi

    mkdir -p "$XRAYR_INSTALL_DIR" /usr/local/bin
    cp -f "${XRAYR_SOURCE_DIR}/XrayR" "$XRAYR_BIN"
    chmod +x "$XRAYR_BIN"
    ln -sf "$XRAYR_BIN" /usr/local/bin/XrayR
    ln -sf "$XRAYR_BIN" /usr/local/bin/xrayr

    sync_xrayr_runtime_files
    install_xrayr_service
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

contains_ret_ok() {
    local payload="$1"
    [[ "$payload" == *"\"ret\":1"* ]]
}

json_field() {
    local json="$1"
    local field="$2"

    JSON_INPUT="$json" JSON_FIELD="$field" python3 - <<'PY'
import json
import os
import sys

raw = os.environ.get("JSON_INPUT", "")
field = os.environ.get("JSON_FIELD", "")

try:
    obj = json.loads(raw)
except Exception:
    raise SystemExit(1)

if not isinstance(obj, dict):
    raise SystemExit(1)

val = obj.get(field)
if val is None and isinstance(obj.get("data"), dict):
    val = obj["data"].get(field)

if val is None:
    raise SystemExit(1)

if isinstance(val, (dict, list)):
    print(json.dumps(val, ensure_ascii=False))
else:
    print(val)
PY
}

fetch_node_info() {
    local host="$1"
    local key="$2"
    local node_id="$3"
    local payload=""

    payload=$(curl -sS -k --get "${host}/mod_mu/nodes/${node_id}/info" --data-urlencode "key=${key}" || true)
    printf '%s' "$payload"
}

fetch_uniproxy_config() {
    local host="$1"
    local key="$2"
    local node_id="$3"
    local payload=""

    payload=$(curl -sS -k --get "${host}/api/v1/server/UniProxy/config" --data-urlencode "token=${key}" --data-urlencode "node_id=${node_id}" || true)
    if [[ -n "$payload" && "$payload" == *"\"server_port\":"* ]]; then
        printf '%s' "$payload"
        return 0
    fi

    payload=$(curl -sS -k --get "${host}/uniproxy/config" --data-urlencode "key=${key}" --data-urlencode "node_id=${node_id}" || true)
    if [[ -n "$payload" && "$payload" == *"\"server_port\":"* ]]; then
        printf '%s' "$payload"
        return 0
    fi

    return 1
}

fill_reality_from_uniproxy() {
    local payload="$1"
    local result=""

    result=$(UP_PAYLOAD="$payload" python3 - <<'PY' || true
import json
import os
import sys

raw = os.environ.get("UP_PAYLOAD", "")
if not raw:
    raise SystemExit(1)

try:
    obj = json.loads(raw)
except Exception:
    raise SystemExit(1)

if not isinstance(obj, dict):
    raise SystemExit(1)

data = obj.get("data", {})
if not isinstance(data, dict):
    data = {}

def pick(key, default=""):
    if key in obj:
        return obj.get(key)
    return data.get(key, default)

network = pick("network", "")
tls_settings = pick("tls_settings", {})
if isinstance(tls_settings, list):
    tls_settings = {}
if not isinstance(tls_settings, dict):
    tls_settings = {}

private_key = tls_settings.get("private_key", "")
server_name = tls_settings.get("server_name", "")
dest = tls_settings.get("dest", "")
short_ids = tls_settings.get("short_ids", [])
sid = ""
if isinstance(short_ids, list) and short_ids:
    first = short_ids[0]
    if isinstance(first, str):
        sid = first

print(f"network={network}")
print(f"private_key={private_key}")
print(f"server_name={server_name}")
print(f"dest={dest}")
print(f"sid={sid}")
PY
)

    [ -n "$result" ] || return 0
    while IFS='=' read -r key value; do
        case "$key" in
            network) [ -z "$NODE_NETWORK" ] && NODE_NETWORK="$value" ;;
            private_key) [ -z "$PRI_KEY" ] && PRI_KEY="$value" ;;
            server_name) [ -z "$SNI" ] && SNI="$value" ;;
            dest) [ -z "$DEST" ] && DEST="$value" ;;
            sid) [ -z "$SID" ] && SID="$value" ;;
        esac
    done <<< "$result" || true
}

parse_server_string() {
    local server="$1"
    local -a fields
    local extra=""

    IFS=';' read -r -a fields <<< "$server" || true

    NODE_HOST=$(trim "${fields[0]:-}")
    NODE_PORT=$(trim "${fields[1]:-}")
    NODE_NETWORK=$(trim "${fields[3]:-tcp}")
    NODE_SECURITY=$(trim "${fields[4]:-tls}")

    if [ "${#fields[@]}" -ge 6 ]; then
        SERVER_PARAMS_RAW=$(trim "${fields[5]}")
        if [ "${#fields[@]}" -gt 6 ]; then
            extra="${fields[*]:6}"
            extra="${extra// /;}"
            SERVER_PARAMS_RAW="${SERVER_PARAMS_RAW};${extra}"
        fi
    else
        SERVER_PARAMS_RAW=""
    fi

    FLOW_PARAM=""
    PBK=""
    SID=""
    PRI_KEY=""
    SNI=""
    DEST=""

    local part key value
    IFS='|' read -r -a parts <<< "$SERVER_PARAMS_RAW" || true
    for part in "${parts[@]}"; do
        part=$(trim "$part")
        [ -z "$part" ] && continue
        [[ "$part" == *=* ]] || continue

        key=$(trim "${part%%=*}")
        value=$(trim "${part#*=}")

        case "$key" in
            flow) FLOW_PARAM="$value" ;;
            pbk) PBK="$value" ;;
            sid) SID="$value" ;;
            private_key) PRI_KEY="$value" ;;
            sni) SNI="$value" ;;
            dest) DEST="$value" ;;
        esac
    done
}

restart_xrayr() {
    systemctl restart XrayR 2>/dev/null && return 0
    systemctl restart xrayr 2>/dev/null && return 0
    if command_exists XrayR; then
        XrayR restart && return 0
    fi
    return 1
}

show_xrayr_log() {
    if command_exists XrayR; then
        if XrayR log; then
            return 0
        fi
    fi
    journalctl -u XrayR -n 80 --no-pager || true
    journalctl -u xrayr -n 80 --no-pager || true
}

stop_xrayr_service() {
    systemctl stop XrayR 2>/dev/null || true
    systemctl stop xrayr 2>/dev/null || true
}

xrayr_bin_path() {
    if [ -x "$XRAYR_BIN" ]; then
        printf '%s' "$XRAYR_BIN"
        return 0
    fi

    if [ -x "/usr/local/XrayR/XrayR" ]; then
        printf '%s' "/usr/local/XrayR/XrayR"
        return 0
    fi

    if command_exists XrayR; then
        command -v XrayR
        return 0
    fi

    return 1
}

xrayr_supports_reality() {
    local bin=""
    local version=""

    bin=$(xrayr_bin_path || true)
    [ -n "$bin" ] || return 1

    version=$("$bin" version 2>&1 | head -n 1 || true)
    if ! echo "$version" | grep -Eq 'XrayR|[0-9]+\.[0-9]+\.[0-9]+'; then
        version=$("$bin" --version 2>&1 | head -n 1 || true)
    fi
    log "当前 XrayR 版本: ${version:-unknown}"

    # XrayR 0.8.0 / xray-core 1.5.5 会忽略 REALITYConfigs，必须换到 0.9.x。
    echo "$version" | grep -Eq '(^|[^0-9])0\.9\.'
}

ensure_xrayr_installed() {
    if command_exists XrayR || [ -x "$XRAYR_BIN" ] || [ -x "/usr/local/XrayR/XrayR" ]; then
        if [ "$XRAYR_FORCE_INSTALL" != "1" ]; then
            if [ "$ENABLE_REALITY" != "true" ] || xrayr_supports_reality; then
                if [ -x "$XRAYR_BIN" ] && ! command_exists XrayR; then
                    ln -sf "$XRAYR_BIN" /usr/local/bin/XrayR || true
                    ln -sf "$XRAYR_BIN" /usr/local/bin/xrayr || true
                fi
                install_xrayr_service || true
                return 0
            fi
        fi

        log "检测到现有 XrayR 不满足 Reality 节点要求，准备覆盖安装支持 Reality 的版本。"
        stop_xrayr_service
    fi

    if install_xrayr_from_install_script; then
        command_exists XrayR || [ -x "$XRAYR_BIN" ] || fail "install.sh 安装后 XrayR 仍不可用。"
        if [ "$ENABLE_REALITY" = "true" ] && ! xrayr_supports_reality; then
            fail "install.sh 安装后仍未检测到支持 Reality 的 XrayR 0.9.x，请检查磁盘空间和下载包。"
        fi
        return 0
    fi
    log "install.sh 安装失败，尝试备用安装方式。"

    if [ -n "$XRAYR_GITHUB_REPO" ]; then
        if download_xrayr_from_github_release "$XRAYR_GITHUB_REPO" "$XRAYR_RELEASE_TAG" "$XRAYR_RELEASE_ASSET"; then
            install_xrayr_service
            command_exists XrayR || [ -x "$XRAYR_BIN" ] || fail "XrayR 预编译包安装后仍不可用。"
            if [ "$ENABLE_REALITY" = "true" ] && ! xrayr_supports_reality; then
                fail "预编译包安装后仍未检测到支持 Reality 的 XrayR 0.9.x。"
            fi
            return 0
        fi
        log "预编译包安装失败，回退到源码编译安装。"
    fi

    if [ "$ENABLE_REALITY" = "true" ]; then
        fail "Reality 节点必须使用支持 Reality 的预编译 XrayR 0.9.x；当前预编译安装失败，已阻止回退到旧源码编译。"
    fi

    install_xrayr_from_source
    command_exists XrayR || [ -x "$XRAYR_BIN" ] || fail "XrayR 安装失败。"
}

append_config() {
    local config_file="/etc/XrayR/config.yml"
    local tmp_file=""

    mkdir -p /etc/XrayR

    if [ -f "$config_file" ] && grep -q '127.0.0.1:667' "$config_file"; then
        log "检测到默认示例配置，重置 /etc/XrayR/config.yml"
        cat > "$config_file" <<'EOF'
Log:
  Level: info
Nodes:
EOF
    fi

    if [ ! -f "$config_file" ]; then
        cat > "$config_file" <<'EOF'
Log:
  Level: info
Nodes:
EOF
    fi

    cp "$config_file" "/etc/XrayR/config.yml.bak_$(date +%s)"

    if grep -Eq "^[[:space:]]+NodeID:[[:space:]]*$NODE_ID([[:space:]]|$)" "$config_file"; then
        log "检测到 NodeID=$NODE_ID 的旧配置，先移除后重写。"
        tmp_file=$(mktemp)
        awk -v node_id="$NODE_ID" '
            function flush_block() {
                if (block == "") {
                    return
                }
                if (!skip_block) {
                    printf "%s", block
                }
                block = ""
                skip_block = 0
            }
            {
                if ($0 ~ /^  -[[:space:]]*$/) {
                    flush_block()
                    block = $0 ORS
                    next
                }

                if (block != "") {
                    block = block $0 ORS
                    if ($0 ~ ("^[[:space:]]+NodeID:[[:space:]]*" node_id "([[:space:]]|$)")) {
                        skip_block = 1
                    }
                    next
                }

                print $0
            }
            END {
                flush_block()
            }
        ' "$config_file" > "$tmp_file"
        mv "$tmp_file" "$config_file"
    fi

    if grep -Eq "^[[:space:]]*# Port:[[:space:]]*$NODE_PORT([[:space:]]|$)" "$config_file"; then
        fail "端口 $NODE_PORT 已被其他节点占用，请清理旧节点后重试。"
    fi

    {
        cat <<EOF
  -
    # Port: $NODE_PORT
    PanelType: "SSpanel"
    ApiConfig:
      ApiHost: "$API_HOST_FINAL"
      ApiKey: "$API_KEY"
      NodeID: $NODE_ID
      NodeType: $NODE_TYPE
      EnableVless: $ENABLE_VLESS
      EnableXTLS: $ENABLE_XTLS
      VlessFlow: "$VLESS_FLOW"
    ControllerConfig:
      ListenIP: 0.0.0.0
      UpdatePeriodic: 60
      EnableREALITY: $ENABLE_REALITY
EOF

        if [ "$ENABLE_REALITY" = "true" ]; then
            cat <<EOF
      REALITYConfigs:
        Show: true
        Dest: "$DEST"
        ProxyProtocolVer: 0
        ServerNames:
          - "$SNI"
        PrivateKey: "$PRI_KEY"
        ShortIds:
          - "$SID"
EOF
        fi

        cat <<'EOF'
      CertConfig:
        CertMode: none
EOF
    } >> "$config_file"
}

main() {
    require_root

    if [ -z "$API_HOST" ]; then
        read -r -p "请输入面板地址 (例: https://meng.serty.app): " API_HOST
        read -r -p "请输入对接密钥 (muKey): " API_KEY
        read -r -p "请输入节点 ID: " NODE_ID
    fi

    API_HOST=$(trim "${API_HOST%/}")
    API_KEY=$(trim "$API_KEY")
    NODE_ID=$(trim "$NODE_ID")

    [ -n "$API_HOST" ] || fail "面板地址不能为空。"
    [ -n "$API_KEY" ] || fail "API Key 不能为空。"
    [[ "$NODE_ID" =~ ^[0-9]+$ ]] || fail "NodeID 必须是数字。"

    API_HOST_FINAL="$API_HOST"
    if [[ "$API_HOST" == *"127.0.0.1:667"* ]] || [[ "$API_HOST" == *"localhost:667"* ]]; then
        API_HOST_FINAL="http://127.0.0.1:667"
    fi

    log "正在读取面板节点信息: NodeID=$NODE_ID"
    NODE_INFO=$(fetch_node_info "$API_HOST_FINAL" "$API_KEY" "$NODE_ID")
    if ! contains_ret_ok "$NODE_INFO"; then
        NODE_INFO=$(fetch_node_info "$API_HOST" "$API_KEY" "$NODE_ID")
        API_HOST_FINAL="$API_HOST"
    fi

    if ! contains_ret_ok "$NODE_INFO"; then
        fail "无法获取节点信息。请检查面板地址/API Key/NodeID。返回: $(printf '%s' "$NODE_INFO" | tr '\n' ' ' | head -c 280)"
    fi

    SERVER_STR=$(json_field "$NODE_INFO" server || printf '')
    SORT=$(json_field "$NODE_INFO" sort || printf '')
    [ -n "$SERVER_STR" ] || fail "节点信息中未找到 server 字段。返回: $(printf '%s' "$NODE_INFO" | tr '\n' ' ' | head -c 280)"

    parse_server_string "$SERVER_STR"
    NODE_PORT=$(trim "${NODE_PORT:-}")
    [ -n "$NODE_PORT" ] || NODE_PORT="443"

    SORT=$(trim "$SORT")
    [ -n "$SORT" ] || SORT="0"

    case "$SORT" in
        15|16)
            NODE_TYPE="V2ray"
            ENABLE_VLESS="true"
            VLESS_FLOW="$FLOW_PARAM"
            ;;
        14)
            NODE_TYPE="Trojan"
            ENABLE_VLESS="false"
            ;;
        0|1|9|10)
            NODE_TYPE="Shadowsocks"
            ENABLE_VLESS="false"
            ;;
        *)
            NODE_TYPE="V2ray"
            ENABLE_VLESS="false"
            ;;
    esac

    if [ "$ENABLE_VLESS" = "true" ] && [ "$NODE_NETWORK" = "xhttp" ]; then
        fail "检测到该节点 network=xhttp。deploy_xrayr.sh 仅用于 XrayR(VLESS/Reality/Trojan/SS)，xhttp 请改用 deploy_xray_xhttp_metron.sh。"
    fi

    if [ "$ENABLE_VLESS" = "true" ]; then
        if [ -n "$PRI_KEY" ] || [ -n "$PBK" ] || [ -n "$SID" ] || [ -n "$DEST" ]; then
            ENABLE_REALITY="true"
            ENABLE_XTLS="true"
        else
            ENABLE_REALITY="false"
            ENABLE_XTLS="false"
        fi

        if [ -z "$VLESS_FLOW" ] && [ "$ENABLE_REALITY" = "true" ]; then
            VLESS_FLOW="xtls-rprx-vision"
        fi

        if [ "$ENABLE_REALITY" = "true" ]; then
            UNI_CONFIG=$(fetch_uniproxy_config "$API_HOST_FINAL" "$API_KEY" "$NODE_ID" || true)
            [ -n "$UNI_CONFIG" ] && fill_reality_from_uniproxy "$UNI_CONFIG"

            [ -n "$SNI" ] || SNI="$NODE_HOST"
            [ -n "$DEST" ] || DEST="${SNI}:443"

            [ -n "$PRI_KEY" ] || fail "Reality private_key 缺失。请检查面板节点参数或 server 字段长度(建议 VARCHAR(512))。"
            [ -n "$SID" ] || fail "Reality sid/short_id 缺失。请检查面板节点参数。"
        else
            SNI=""
            DEST=""
            SID=""
            PRI_KEY=""
        fi
    fi

    log "节点识别结果: type=$NODE_TYPE sort=$SORT network=${NODE_NETWORK:-unknown} reality=$ENABLE_REALITY port=$NODE_PORT"

    ensure_xrayr_installed
    append_config

    if ! restart_xrayr; then
        show_xrayr_log
        fail "XrayR 重启失败，请查看日志。"
    fi

    log "对接完成。"
    show_xrayr_log
}

main "$@"
