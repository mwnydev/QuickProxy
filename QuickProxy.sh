#!/usr/bin/env bash
# =============================================================
# VLESS-Reality / Hysteria2 一键安装脚本 —— 适用于 Debian 10/11/12+、Alpine 3.21+
#   协议：VLESS+Reality（Xray 或 sing-box）、Hysteria2（sing-box）、两者同时部署
#   功能：开启 BBR、自动生成密钥/证书、输出分享链接
#
# 直接运行，按菜单提示操作即可：
#   bash vless-reality.sh
#
# 进阶（预先指定后将跳过对应提问，适合自动化）：
#   PROTO=reality|hy2|both   CORE=xray|singbox
#   PORT=xxxx (Reality/TCP)  HY2_PORT=xxxx (Hysteria2/UDP)  SNI=www.microsoft.com
#   SB_SOURCE=github|apt     SB_VERSION=1.12.0   （Alpine 仅支持 github）
# 子命令：install | info | restart | uninstall
#
# Alpine 默认没有 bash：用 sh 运行本文件时会自动 apk add bash 后切换到 bash；
# 若通过管道运行，请先执行：apk add bash curl
# =============================================================

# 以下几行需兼容 POSIX sh（Alpine 的 ash），在切换到 bash 之前不能使用 bash 语法
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1 && command -v apk >/dev/null 2>&1; then
        echo "[INFO] 未检测到 bash，正在安装（apk add bash）..."
        apk add --no-cache bash >/dev/null || { echo "[ERROR] 安装 bash 失败，请手动执行：apk add bash" >&2; exit 1; }
    fi
    command -v bash >/dev/null 2>&1 || { echo "[ERROR] 本脚本需要 bash" >&2; exit 1; }
    if [ -f "$0" ]; then exec bash "$0" "$@"; fi
    echo "[ERROR] 请使用 bash 运行本脚本（Alpine 请先执行：apk add bash）" >&2
    exit 1
fi

set -euo pipefail

INFO_FILE="/root/vless-reality-info.txt"
XRAY_CONF="${XRAY_CONF:-/usr/local/etc/xray/config.json}"
SB_DIR="${SB_DIR:-/etc/sing-box}"
SB_CONF="${SB_CONF:-${SB_DIR}/config.json}"
LOCK_FILE="${LOCK_FILE:-/run/vless-reality.lock}"

PROTO="${PROTO:-}"; PROTO="${PROTO,,}"
CORE="${CORE:-}"
PORT="${PORT:-}"
HY2_PORT="${HY2_PORT:-}"
SNI="${SNI:-}"
HY2_MODE="${HY2_MODE:-}"; HY2_MODE="${HY2_MODE,,}"   # self | acme
SB_SOURCE="${SB_SOURCE:-}"; SB_SOURCE="${SB_SOURCE,,}"  # github | apt
SB_VERSION="${SB_VERSION:-}"
HY2_DOMAIN="${HY2_DOMAIN:-}"
HY2_EMAIL="${HY2_EMAIL:-}"
HY2_SNI="www.bing.com"          # 自签证书使用的名称

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# 是否有可交互的终端（curl | bash 时也可通过 /dev/tty 交互）
is_interactive() { (exec </dev/tty) 2>/dev/null; }

# ask "提示语" "默认值" -> 结果放在 ANSWER
ask() {
    local v=""
    if is_interactive; then
        read -rp "$1" v </dev/tty || v=""
    fi
    ANSWER="${v:-$2}"
}

# ---------- 输入校验 ----------
valid_host()  { local re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'; [[ "$1" =~ $re ]]; }
valid_email() { [[ -z "$1" ]] && return 0; local re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; [[ "$1" =~ $re ]]; }

# ask_valid 变量名 提示语 默认值 校验函数 出错说明
ask_valid() {
    local var="$1" prompt="$2" def="$3" fn="$4" msg="$5" cur
    cur="${!var}"
    while true; do
        if [[ -z "$cur" ]]; then
            ask "$prompt" "$def"
            cur="$ANSWER"
        fi
        if "$fn" "$cur"; then break; fi
        warn "${msg}：${cur}"
        is_interactive || err "非交互模式下参数无效，请检查环境变量"
        cur=""
    done
    printf -v "$var" '%s' "$cur"
}

check_enums() {
    case "$HY2_MODE"  in ""|self|acme) ;; *) err "HY2_MODE 只能是 self 或 acme，收到：$HY2_MODE" ;; esac
    case "$SB_SOURCE" in ""|github|apt) ;; *) err "SB_SOURCE 只能是 github 或 apt，收到：$SB_SOURCE" ;; esac
}

# ---------- 系统 / 服务管理抽象：systemd（Debian）与 OpenRC（Alpine） ----------
if command -v systemctl >/dev/null 2>&1; then
    INIT_SYS="systemd"
elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"
else
    INIT_SYS=""
fi
if [[ -f /etc/alpine-release ]]; then
    OS_FAMILY="alpine"
else
    OS_FAMILY="debian"
fi

is_musl() { compgen -G '/lib/ld-musl-*.so.1' >/dev/null; }

svc_log_file() { echo "/var/log/${1}.log"; }   # OpenRC 下由本脚本写入的服务日志

svc_exists() {
    if [[ "$INIT_SYS" == "openrc" ]]; then [[ -f "/etc/init.d/$1" ]]
    else systemctl cat "${1}.service" >/dev/null 2>&1; fi
}
svc_active() {
    if [[ "$INIT_SYS" == "openrc" ]]; then rc-service "$1" status >/dev/null 2>&1
    else systemctl is-active --quiet "$1" 2>/dev/null; fi
}
svc_enabled() {
    if [[ "$INIT_SYS" == "openrc" ]]; then
        rc-update show default 2>/dev/null | awk '{print $1}' | grep -qx "$1"
    else systemctl is-enabled --quiet "$1" 2>/dev/null; fi
}
svc_enable() {
    if [[ "$INIT_SYS" == "openrc" ]]; then rc-update add "$1" default >/dev/null 2>&1
    else systemctl enable "$1" >/dev/null 2>&1; fi
}
svc_disable() {
    if [[ "$INIT_SYS" == "openrc" ]]; then rc-update del "$1" default >/dev/null 2>&1
    else systemctl disable "$1" >/dev/null 2>&1; fi
}
svc_stop() {
    if [[ "$INIT_SYS" == "openrc" ]]; then rc-service "$1" stop >/dev/null 2>&1
    else systemctl stop "$1" >/dev/null 2>&1; fi
}
svc_restart() {
    if [[ "$INIT_SYS" == "openrc" ]]; then rc-service "$1" restart
    else systemctl restart "$1"; fi
}
svc_reload_units() { if [[ "$INIT_SYS" == "systemd" ]]; then systemctl daemon-reload; fi; }
svc_status() {
    if [[ "$INIT_SYS" == "openrc" ]]; then
        rc-service "$1" status || true
        tail -n 5 "$(svc_log_file "$1")" 2>/dev/null || true
    else systemctl --no-pager -n 5 status "$1" || true; fi
}
# svc_logs 服务名 [行数]
svc_logs() {
    if [[ "$INIT_SYS" == "openrc" ]]; then tail -n "${2:-20}" "$(svc_log_file "$1")" 2>/dev/null || true
    else journalctl -u "$1" --no-pager -n "${2:-20}" 2>/dev/null || true; fi
}
# 给用户看的查看日志命令
svc_log_cmd() {
    if [[ "$INIT_SYS" == "openrc" ]]; then echo "tail -f $(svc_log_file "$1")"
    else echo "journalctl -u $1 -f"; fi
}
# 服务的运行用户（为空视为 root）
svc_user() {
    if [[ "$INIT_SYS" == "openrc" ]]; then
        sed -n 's/^command_user="\{0,1\}\([^:"]*\).*/\1/p' "/etc/init.d/$1" 2>/dev/null | head -n1 || true
    else systemctl show -p User --value "$1" 2>/dev/null || true; fi
}

# 按服务运行用户收紧配置文件权限（含私钥/密码）
secure_file() {
    local f="$1" svc="$2" u g
    [[ -e "$f" ]] || return 0
    u=$(svc_user "$svc")
    if [[ -z "$u" || "$u" == "root" ]]; then
        chmod 600 "$f"
    elif id "$u" >/dev/null 2>&1; then
        g=$(id -gn "$u")
        chown "root:${g}" "$f" 2>/dev/null || true
        chmod 640 "$f"
    else
        chmod 644 "$f"   # 动态用户等无法预知的情况，保证服务可读
    fi
}

# ---------- 并发锁：防止两个脚本实例同时改动配置和服务 ----------
acquire_lock() {
    if command -v flock >/dev/null; then
        exec 9>"$LOCK_FILE" || err "无法创建锁文件 $LOCK_FILE"
        flock -n 9 || err "另一个本脚本实例正在运行（锁：${LOCK_FILE}），请等待其结束后再试"
    else
        mkdir "${LOCK_FILE}.d" 2>/dev/null || err "另一个本脚本实例正在运行（锁：${LOCK_FILE}.d）；若确认没有，请删除该目录后重试"
        LOCK_DIR_HELD=1
    fi
}

# ---------- 事务：安装失败时自动回滚到安装前的状态 ----------
TXN_ACTIVE=0
TXN_DIR=""
TXN_FILES=()

begin_txn() {
    TXN_DIR=$(mktemp -d)
    TXN_FILES=("$XRAY_CONF" "$SB_CONF" "${SB_DIR}/hy2.key" "${SB_DIR}/hy2.crt" "$INFO_FILE")
    local i f svc
    for i in "${!TXN_FILES[@]}"; do
        f="${TXN_FILES[$i]}"
        if [[ -e "$f" ]]; then cp -a "$f" "${TXN_DIR}/${i}"; else touch "${TXN_DIR}/${i}.absent"; fi
    done
    for svc in xray sing-box; do
        if svc_exists "$svc"; then
            if svc_active "$svc"; then touch "${TXN_DIR}/${svc}.active"; fi
            if svc_enabled "$svc"; then touch "${TXN_DIR}/${svc}.enabled"; fi
        fi
    done
    TXN_ACTIVE=1
}

commit_txn() { TXN_ACTIVE=0; }

rollback_txn() {
    set +e
    echo
    warn "安装失败，正在回滚到安装前的状态..."
    local i f svc restored=0
    for svc in xray sing-box; do
        if svc_exists "$svc"; then svc_stop "$svc"; fi
    done
    for i in "${!TXN_FILES[@]}"; do
        f="${TXN_FILES[$i]}"
        if [[ -e "${TXN_DIR}/${i}" ]]; then
            mkdir -p "$(dirname "$f")"; cp -a "${TXN_DIR}/${i}" "$f"
        elif [[ -e "${TXN_DIR}/${i}.absent" ]]; then
            rm -f "$f"
        fi
    done
    svc_reload_units >/dev/null 2>&1
    for svc in xray sing-box; do
        svc_exists "$svc" || continue
        if [[ -e "${TXN_DIR}/${svc}.enabled" ]]; then
            svc_enable "$svc"
        else
            svc_disable "$svc"
        fi
        if [[ -e "${TXN_DIR}/${svc}.active" ]]; then
            svc_restart "$svc" >/dev/null 2>&1
            restored=1
            command sleep 2
            if svc_active "$svc"; then
                info "已恢复原来的 ${svc} 节点 ✔（原节点信息不变）"
            else
                warn "尝试恢复 ${svc} 失败，请查看日志：$(svc_log_cmd "$svc")"
            fi
        fi
    done
    if (( ! restored )); then info "回滚完成（安装前没有正在运行的节点）"; fi
    warn "注意：ufw 放行规则与已下载的内核程序不会回滚"
}

on_exit() {
    local rc=$?
    if (( TXN_ACTIVE == 1 )) && (( rc != 0 )); then
        TXN_ACTIVE=0
        rollback_txn
    fi
    if [[ -n "$TXN_DIR" ]]; then rm -rf "$TXN_DIR"; fi
    if [[ "${LOCK_DIR_HELD:-0}" == 1 ]]; then rmdir "${LOCK_FILE}.d" 2>/dev/null; fi
    exit "$rc"
}

check_env() {
    [[ $EUID -eq 0 ]] || err "请使用 root 用户运行（或 sudo -i 后再执行）"
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "${ID:-}" == "alpine" ]]; then
            local amaj amin
            amaj=${VERSION_ID:-0}; amaj=${amaj%%.*}; amin=${VERSION_ID:-0.0}; amin=${amin#*.}; amin=${amin%%.*}
            if [[ "$amaj" =~ ^[0-9]+$ && "$amin" =~ ^[0-9]+$ ]] && (( amaj < 3 || (amaj == 3 && amin < 21) )); then
                warn "检测到 Alpine ${VERSION_ID}，本脚本针对 Alpine 3.21+ 测试，旧版本可能无法正常工作"
            fi
        elif [[ "${ID:-}" != "debian" && "${ID_LIKE:-}" != *debian* ]]; then
            warn "检测到非 Debian/Alpine 系统（${PRETTY_NAME:-unknown}），脚本可能无法正常工作"
        fi
    fi
    case "$INIT_SYS" in
        systemd) ;;
        openrc)
            if [[ ! -e /run/openrc/softlevel ]]; then
                warn "OpenRC 尚未启动（常见于容器），服务可能无法启动；可先执行：openrc default"
            fi
            ;;
        *) err "未检测到 systemd 或 OpenRC" ;;
    esac
}

# ---------------------- 选择协议 / 内核 ----------------------
choose_proto() {
    if [[ -z "$PROTO" ]]; then
        echo
        echo "请选择要部署的协议："
        echo "  1) VLESS + Reality              （默认，可选 Xray 或 sing-box 内核）"
        echo "  2) Hysteria2                    （仅 sing-box 内核，UDP/QUIC）"
        echo "  3) VLESS + Reality + Hysteria2  （同时部署，sing-box 内核）"
        ask "请选择 [1-3，回车默认 1]: " 1
        case "$ANSWER" in
            2) PROTO="hy2" ;;
            3) PROTO="both" ;;
            *) PROTO="reality" ;;
        esac
    fi
    case "$PROTO" in reality|hy2|both) ;; *) err "未知协议：$PROTO（可选 reality / hy2 / both）" ;; esac
}

choose_core() {
    if [[ "$PROTO" != "reality" ]]; then
        if [[ "${CORE,,}" == "xray" ]]; then
            warn "Hysteria2 需要 sing-box 内核，已忽略 CORE=xray"
        fi
        CORE="singbox"
    elif [[ -z "$CORE" ]]; then
        echo
        echo "请选择代理内核："
        echo "  1) Xray-core   （默认）"
        echo "  2) sing-box"
        ask "请选择 [1-2，回车默认 1]: " 1
        case "$ANSWER" in 2) CORE="singbox" ;; *) CORE="xray" ;; esac
    fi
    case "${CORE,,}" in
        xray)                 CORE="xray";    SERVICE="xray" ;;
        singbox|sing-box|sb)  CORE="singbox"; SERVICE="sing-box" ;;
        *) err "未知内核：$CORE（可选 xray 或 singbox）" ;;
    esac
    info "协议：${PROTO}；内核：${CORE}"
}

install_deps() {
    info "安装依赖..."
    if [[ "$OS_FAMILY" == "alpine" ]]; then
        apk update
        apk add curl openssl ca-certificates unzip tar iproute2 iproute2-ss coreutils
        return
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl openssl ca-certificates unzip gnupg iproute2
}

# ---------------------- 端口工具 ----------------------
# port_busy tcp|udp 端口 —— 被 xray/sing-box 以外的程序占用则返回 0
port_busy() {
    local flag="t" out; [[ "$1" == "udp" ]] && flag="u"
    out=$(ss -ln${flag}p 2>/dev/null | grep -E ":${2}\\s" || true)
    [[ -n "$out" ]] && grep -qvE 'xray|sing-box' <<<"$out"
}

rand_port() {
    local p="" i
    for i in $(seq 1 30); do
        p=$(shuf -i 10000-60000 -n 1)
        port_busy "$1" "$p" || { echo "$p"; return; }
    done
    echo "$p"
}

# ask_port 变量名 显示名 tcp|udp
ask_port() {
    local var="$1" label="$2" proto="$3" cur def
    cur="${!var}"
    while true; do
        if [[ -z "$cur" ]]; then
            def=$(rand_port "$proto")
            ask "${label}端口 [默认随机 ${def}，也可自己输入，回车确认]: " "$def"
            cur="$ANSWER"
        fi
        if [[ ! "$cur" =~ ^[1-9][0-9]{0,4}$ ]] || (( 10#$cur > 65535 )); then
            warn "端口无效：$cur（需为 1-65535 的整数，不能有前导 0 或空格）"
        elif port_busy "$proto" "$cur"; then
            warn "${proto} 端口 ${cur} 已被其他程序占用"
        else
            break
        fi
        is_interactive || err "非交互模式下 ${label}端口不可用，请通过环境变量指定其他端口"
        cur=""
    done
    printf -v "$var" '%s' "$cur"
}

# 解析域名的第一个 IPv4 地址（兼容 glibc 与 musl/busybox）
resolve_ipv4() {
    local ip=""
    ip=$(getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}' || true)
    if [[ -z "$ip" ]]; then
        ip=$(getent hosts "$1" 2>/dev/null | awk '$1 ~ /^[0-9]+(\.[0-9]+){3}$/ {print $1; exit}' || true)
    fi
    if [[ -z "$ip" ]] && command -v nslookup >/dev/null; then
        ip=$(nslookup "$1" 2>/dev/null | awk '/^Name:/ {f=1; next} f && /^Address/ {sub(/^Address( [0-9]+)?: */, ""); if ($1 ~ /^[0-9]+(\.[0-9]+){3}$/) {print $1; exit}}' || true)
    fi
    echo "$ip"
}

# ---------------------- 交互式参数 ----------------------
prompt_settings() {
    echo
    if [[ "$PROTO" != "hy2" ]]; then
        ask_port PORT "Reality(TCP) " tcp
        ask_valid SNI "Reality 伪装域名 SNI [默认 www.microsoft.com，回车确认]: " "www.microsoft.com" \
            valid_host "域名格式无效（需形如 www.example.com，不含端口/空格/中文）"
        local tls_out
        tls_out=$(echo | timeout 8 openssl s_client -connect "${SNI}:443" -servername "$SNI" -tls1_3 2>/dev/null || true)
        if ! grep -q "TLSv1.3" <<<"$tls_out"; then
            warn "未能确认 ${SNI} 支持 TLS 1.3（也可能是网络原因），建议用 www.microsoft.com / www.apple.com 等"
        fi
    fi

    if [[ "$PROTO" != "reality" ]]; then
        echo
        ask_port HY2_PORT "Hysteria2(UDP) " udp
        if [[ -z "$HY2_MODE" ]]; then
            echo
            echo "Hysteria2 证书方式："
            echo "  1) 自签证书（默认，无需域名；客户端需「跳过证书验证」或使用证书指纹）"
            echo "  2) 域名 + 自动申请证书（ACME，需域名已解析到本机，并放行 80/tcp）"
            ask "请选择 [1-2，回车默认 1]: " 1
            if [[ "$ANSWER" == "2" ]]; then HY2_MODE="acme"; else HY2_MODE="self"; fi
        fi
        if [[ "$HY2_MODE" == "acme" ]]; then
            ask_valid HY2_DOMAIN "你的域名（如 hy2.example.com）: " "" valid_host "域名格式无效"
            ask_valid HY2_EMAIL "证书通知邮箱（可留空）: " "" valid_email "邮箱格式无效"
            if [[ "$PROTO" == "both" && "$PORT" == "80" ]]; then
                err "Reality 端口不能设为 80：域名证书申请需要占用 80/tcp"
            fi
            if port_busy tcp 80 && port_busy tcp 443; then
                warn "80/tcp 与 443/tcp 均被其他程序占用，域名证书申请很可能失败"
            fi
            get_ip
            local resolved
            resolved=$(resolve_ipv4 "$HY2_DOMAIN")
            if [[ -z "$resolved" ]]; then
                warn "域名 ${HY2_DOMAIN} 暂未解析，证书申请会失败，请先添加 A 记录指向 ${SERVER_IP}"
            elif [[ "$resolved" != "$SERVER_IP" ]]; then
                warn "域名解析到 ${resolved}，与本机 IP ${SERVER_IP} 不一致（若开了 CDN 代理请关闭）"
            fi
        fi
    fi

    if [[ "$CORE" == "singbox" && "$OS_FAMILY" == "alpine" && "$SB_SOURCE" == "apt" ]]; then
        warn "Alpine 不支持 APT 源，改为从 GitHub 安装 sing-box"
        SB_SOURCE="github"
    fi
    if [[ "$CORE" == "singbox" && -z "$SB_SOURCE" && "$OS_FAMILY" == "alpine" ]]; then
        echo
        echo "sing-box 安装来源："
        echo "  1) GitHub 最新正式版（默认）"
        echo "  2) GitHub 指定版本"
        ask "请选择 [1-2，回车默认 1]: " 1
        SB_SOURCE="github"
        if [[ "$ANSWER" == "2" ]]; then
            ask "输入版本号（如 1.12.0）: " ""
            [[ -n "$ANSWER" ]] || err "版本号不能为空"
            SB_VERSION="$ANSWER"
        fi
    fi
    if [[ "$CORE" == "singbox" && -z "$SB_SOURCE" ]]; then
        echo
        echo "sing-box 安装来源："
        echo "  1) GitHub 最新正式版（默认）"
        echo "  2) GitHub 指定版本"
        echo "  3) 官方 APT 源"
        ask "请选择 [1-3，回车默认 1]: " 1
        case "$ANSWER" in
            2)
                SB_SOURCE="github"
                ask "输入版本号（如 1.12.0）: " ""
                [[ -n "$ANSWER" ]] || err "版本号不能为空"
                SB_VERSION="$ANSWER"
                ;;
            3) SB_SOURCE="apt" ;;
            *) SB_SOURCE="github" ;;
        esac
    fi

    echo
    echo "================ 安装确认 ================"
    echo " 协议     : ${PROTO}"
    echo " 内核     : ${CORE}"
    if [[ "$PROTO" != "hy2" ]]; then echo " Reality  : ${PORT}/tcp，SNI=${SNI}"; fi
    if [[ "$PROTO" != "reality" ]]; then
        if [[ "$HY2_MODE" == "acme" ]]; then
            echo " Hysteria2: ${HY2_PORT}/udp，域名证书 ${HY2_DOMAIN}"
        else
            echo " Hysteria2: ${HY2_PORT}/udp，自签证书"
        fi
    fi
    if [[ "$CORE" == "singbox" ]]; then echo " 安装来源 : ${SB_SOURCE:-github} ${SB_VERSION:+(v${SB_VERSION#v})}"; fi
    echo "=========================================="
    ask "确认开始安装？[Y/n]: " "Y"
    [[ "$ANSWER" =~ ^[Yy]$ ]] || { info "已取消"; exit 0; }
}

# ---------------------- BBR ----------------------
enable_bbr() {
    info "配置 BBR..."
    local kver major minor
    kver=$(uname -r | cut -d- -f1)
    major=${kver%%.*}; minor=${kver#*.}; minor=${minor%%.*}
    if (( major < 4 || (major == 4 && minor < 9) )); then
        warn "内核版本 $kver 低于 4.9，不支持 BBR，请先升级内核。已跳过。"
    else
        modprobe tcp_bbr 2>/dev/null || true
        sed -i '/^net.core.default_qdisc/d;/^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
        cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    fi

    # Hysteria2 基于 QUIC，适当调大 UDP 缓冲区
    if [[ "$PROTO" != "reality" ]]; then
        cat > /etc/sysctl.d/99-udp-buffer.conf <<'EOF'
net.core.rmem_max=7500000
net.core.wmem_max=7500000
EOF
    fi
    if ! sysctl --system >/dev/null 2>&1; then
        # busybox sysctl 不支持 --system，逐个加载
        local f
        for f in /etc/sysctl.d/99-bbr.conf /etc/sysctl.d/99-udp-buffer.conf; do
            if [[ -f "$f" ]]; then sysctl -p "$f" >/dev/null 2>&1 || true; fi
        done
    fi
    if [[ "$INIT_SYS" == "openrc" && -f /etc/init.d/sysctl ]]; then
        rc-update add sysctl boot >/dev/null 2>&1 || true   # 保证重启后 /etc/sysctl.d 仍被加载
    fi

    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$cc" == "bbr" ]]; then
        info "BBR 已开启 ✔（拥塞控制：$cc，队列：$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 未知)）"
    else
        warn "BBR 开启失败，当前算法：$cc（部分 OpenVZ/LXC 虚拟化不支持）"
    fi
}

# ---------------------- 安装内核 ----------------------
run_xray_installer() {
    local tmp rc=0
    tmp=$(mktemp)
    if ! curl -fsSL -o "$tmp" https://github.com/XTLS/Xray-install/raw/main/install-release.sh; then
        rm -f "$tmp"; return 1
    fi
    bash "$tmp" "$@" || rc=$?
    rm -f "$tmp"
    return "$rc"
}

# OpenRC 启动脚本：write_openrc_service 服务名 程序 参数 工作目录
write_openrc_service() {
    local name="$1" cmd="$2" args="$3" dir="$4" log
    log=$(svc_log_file "$name")
    mkdir -p /etc/init.d
    cat > "/etc/init.d/${name}" <<EOF
#!/sbin/openrc-run
# 由 QuickProxy 脚本生成
name="${name}"
description="${name} service"
supervisor="supervise-daemon"
command="${cmd}"
command_args="${args}"
directory="${dir}"
output_log="${log}"
error_log="${log}"
respawn_delay=10
respawn_max=0
rc_ulimit="-n 1048576"
extra_started_commands="reload"

depend() {
    after net dns firewall
    use net
}

reload() {
    ebegin "Reloading \${name}"
    supervise-daemon "\${RC_SVCNAME}" --signal HUP
    eend \$?
}
EOF
    chmod 755 "/etc/init.d/${name}"
    touch "$log"; chmod 600 "$log"
}

# Alpine：官方 Xray-install 脚本依赖 systemd，这里直接下载发布包并写 OpenRC 服务
install_xray_alpine() {
    local arch tmp zip sum want f
    case "$(uname -m)" in
        x86_64|amd64)  arch="64" ;;
        aarch64|arm64) arch="arm64-v8a" ;;
        armv7l|armv7)  arch="arm32-v7a" ;;
        i386|i686)     arch="32" ;;
        *) err "不支持的 CPU 架构：$(uname -m)" ;;
    esac
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
    tmp=$(mktemp -d); zip="${tmp}/xray.zip"
    info "下载 Xray (${arch})..."
    if ! curl -fL --retry 3 -o "$zip" "$url" || ! curl -fsSL --retry 3 -o "${zip}.dgst" "${url}.dgst"; then
        rm -rf "$tmp"; err "Xray 下载失败（服务器可能无法访问 GitHub）"
    fi
    want=$(awk -F'= *' 'toupper($1) ~ /SHA2-?256/ {print $2; exit}' "${zip}.dgst" | tr -d '[:space:]')
    sum=$(sha256sum "$zip" | awk '{print $1}')
    [[ -n "$want" && "$want" == "$sum" ]] || { rm -rf "$tmp"; err "Xray 安装包 SHA256 校验失败"; }
    unzip -oq "$zip" -d "$tmp" || { rm -rf "$tmp"; err "解压失败，下载文件可能已损坏"; }
    if svc_exists xray && svc_active xray; then svc_stop xray; fi
    install -m 755 "${tmp}/xray" /usr/local/bin/xray
    mkdir -p /usr/local/share/xray "$(dirname "$XRAY_CONF")"
    for f in geoip.dat geosite.dat; do
        if [[ -f "${tmp}/${f}" ]]; then install -m 644 "${tmp}/${f}" "/usr/local/share/xray/${f}"; fi
    done
    rm -rf "$tmp"
    write_openrc_service xray /usr/local/bin/xray "run -config ${XRAY_CONF}" /usr/local/etc/xray
}

uninstall_xray_alpine() {
    svc_stop xray || true
    svc_disable xray || true
    rm -f /usr/local/bin/xray /etc/init.d/xray "$(svc_log_file xray)"
    rm -rf /usr/local/share/xray /usr/local/etc/xray
}

install_xray() {
    if [[ "$OS_FAMILY" == "alpine" || "$INIT_SYS" == "openrc" ]]; then
        info "安装 Xray（GitHub 发布包 + OpenRC 服务）..."
        install_xray_alpine
    else
        info "安装 Xray（官方安装脚本）..."
        run_xray_installer install || err "Xray 安装失败（服务器可能无法访问 GitHub，或安装脚本报错）"
    fi
    command -v xray >/dev/null || err "Xray 安装失败"
    info "Xray 版本：$(xray version | head -n1)"
}

install_singbox_apt() {
    info "安装 sing-box（官方 APT 源）..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    chmod a+r /etc/apt/keyrings/sagernet.asc
    cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
    apt-get update -y
    apt-get install -y sing-box
}

install_singbox_github() {
    local arch ver tag url tmp
    case "$(uname -m)" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv7)  arch="armv7" ;;
        *) err "不支持的 CPU 架构：$(uname -m)" ;;
    esac

    if [[ -n "${SB_VERSION:-}" ]]; then
        ver="${SB_VERSION#v}"
    else
        # 通过 releases/latest 的跳转获取最新正式版（不受 API 限流影响）
        tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
              https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null || true)
        tag="${tag##*/tag/}"
        ver="${tag#v}"
    fi
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$ ]] \
        || err "获取 sing-box 版本号失败：'${ver}'（可能无法访问 GitHub；可稍后重试，或改用 APT 源）"

    local base="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}"
    tmp=$(mktemp -d)
    url="${base}.tar.gz"
    # musl 系统（Alpine）：1.13+ 的通用包依赖 glibc，优先使用 -musl 包；旧版本没有 -musl 包，但通用包为静态编译
    if is_musl && curl -fsSLI -o /dev/null "${base}-musl.tar.gz" 2>/dev/null; then
        url="${base}-musl.tar.gz"
        info "下载 sing-box v${ver} (${arch}, musl)..."
    else
        info "下载 sing-box v${ver} (${arch})..."
    fi
    curl -fL --retry 3 -o "${tmp}/sb.tar.gz" "$url" || { rm -rf "$tmp"; err "下载失败：$url"; }
    tar -xzf "${tmp}/sb.tar.gz" -C "$tmp" || { rm -rf "$tmp"; err "解压失败，下载文件可能已损坏"; }
    local bin
    bin=$(find "$tmp" -type f -name sing-box | head -n1 || true)
    [[ -n "$bin" ]] || { rm -rf "$tmp"; err "压缩包内未找到 sing-box 可执行文件"; }
    chmod +x "$bin"
    "$bin" version >/dev/null 2>&1 || { rm -rf "$tmp"; err "下载的 sing-box 无法在本系统运行（${url##*/}），请换用其他版本（SB_VERSION）"; }
    install -m 755 "$bin" /usr/local/bin/sing-box
    rm -rf "$tmp"

    mkdir -p "$SB_DIR" /var/lib/sing-box
    if [[ "$INIT_SYS" == "openrc" ]]; then
        write_openrc_service sing-box /usr/local/bin/sing-box \
            "-D /var/lib/sing-box -c ${SB_CONF} run" /var/lib/sing-box
        return 0
    fi
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
WorkingDirectory=/var/lib/sing-box
ExecStart=/usr/local/bin/sing-box -D /var/lib/sing-box -c ${SB_CONF} run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

install_singbox() {
    if [[ "${SB_SOURCE:-github}" == "apt" && "$OS_FAMILY" != "alpine" ]]; then
        install_singbox_apt
    else
        install_singbox_github
    fi
    command -v sing-box >/dev/null || err "sing-box 安装失败"
    info "sing-box 版本：$(sing-box version | head -n1)"
}

# ---------------------- 生成参数 ----------------------
gen_hy2_cert() {
    mkdir -p "$SB_DIR"
    openssl ecparam -genkey -name prime256v1 -out "${SB_DIR}/hy2.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${SB_DIR}/hy2.key" -out "${SB_DIR}/hy2.crt" \
        -subj "/CN=${HY2_SNI}" 2>/dev/null
    chmod 644 "${SB_DIR}/hy2.crt"
    secure_file "${SB_DIR}/hy2.key" sing-box
    HY2_PIN=$(openssl x509 -in "${SB_DIR}/hy2.crt" -noout -fingerprint -sha256 | cut -d= -f2)
}

gen_params() {
    if [[ "$PROTO" != "hy2" ]]; then
        SHORT_ID=$(openssl rand -hex 8)
        local out=""
        if [[ "$CORE" == "xray" ]]; then
            UUID=$(xray uuid 2>/dev/null || true)
            out=$(xray x25519 2>/dev/null || true)
            # 兼容新旧版本：旧版 Private key/Public key；新版 PrivateKey / Password (PublicKey)
            PRIVATE_KEY=$(echo "$out" | grep -iE 'private' | head -n1 | awk -F': *' '{print $2}' | tr -d '[:space:]' || true)
            PUBLIC_KEY=$(echo "$out" | grep -iE 'public|password' | head -n1 | awk -F': *' '{print $2}' | tr -d '[:space:]' || true)
        else
            UUID=$(sing-box generate uuid 2>/dev/null || true)
            out=$(sing-box generate reality-keypair 2>/dev/null || true)
            PRIVATE_KEY=$(echo "$out" | grep -i 'PrivateKey' | head -n1 | awk -F': *' '{print $2}' | tr -d '[:space:]' || true)
            PUBLIC_KEY=$(echo "$out" | grep -i 'PublicKey' | head -n1 | awk -F': *' '{print $2}' | tr -d '[:space:]' || true)
        fi
        [[ -n "${UUID:-}" ]] || err "UUID 生成失败"
        [[ -n "${PRIVATE_KEY:-}" && -n "${PUBLIC_KEY:-}" ]] || err "Reality 密钥生成失败，内核输出为：${out:-<空>}"
    fi

    if [[ "$PROTO" != "reality" ]]; then
        HY2_PASS=$(openssl rand -base64 18 | tr -d '=+/\n')
        [[ "$HY2_MODE" == "acme" ]] || gen_hy2_cert
    fi
}

# ---------------------- 写配置 ----------------------
write_config_xray() {
    mkdir -p "$(dirname "$XRAY_CONF")"
    local tmp="${XRAY_CONF%.json}.new.json"
    cat > "$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
    secure_file "$tmp" xray
    if ! xray run -test -config "$tmp" >/dev/null; then
        rm -f "$tmp"; err "Xray 配置校验失败（原配置未改动）"
    fi
    mv -f "$tmp" "$XRAY_CONF"
}

sb_reality_inbound() {
    cat <<EOF
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        { "uuid": "${UUID}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${SNI}", "server_port": 443 },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    }
EOF
}

# sing-box 是否 >= 1.14（新版 ACME 使用 certificate_providers）
sb_is_new_acme() {
    local v maj min
    v=$(sing-box version 2>/dev/null | head -n1 | awk '{print $3}')
    maj=${v%%.*}; min=${v#*.}; min=${min%%.*}
    [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] || return 1
    (( maj > 1 || (maj == 1 && min >= 14) ))
}

sb_hy2_inbound() {
    local tls
    if [[ "$HY2_MODE" == "acme" ]]; then
        if sb_is_new_acme; then
            tls=$(cat <<EOF
      "tls": {
        "enabled": true,
        "server_name": "${HY2_DOMAIN}",
        "alpn": ["h3"],
        "certificate_provider": "acme"
      }
EOF
)
        else
            local email_line=""
            [[ -n "$HY2_EMAIL" ]] && email_line="\"email\": \"${HY2_EMAIL}\","
            tls=$(cat <<EOF
      "tls": {
        "enabled": true,
        "server_name": "${HY2_DOMAIN}",
        "alpn": ["h3"],
        "acme": {
          "domain": ["${HY2_DOMAIN}"],
          ${email_line}
          "data_directory": "/var/lib/sing-box/acme"
        }
      }
EOF
)
        fi
    else
        tls=$(cat <<EOF
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${SB_DIR}/hy2.crt",
        "key_path": "${SB_DIR}/hy2.key"
      }
EOF
)
    fi
    cat <<EOF
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        { "name": "user", "password": "${HY2_PASS}" }
      ],
${tls}
    }
EOF
}

write_config_singbox() {
    mkdir -p "$SB_DIR"
    local parts=() joined
    if [[ "$PROTO" != "hy2" ]]; then parts+=("$(sb_reality_inbound)"); fi
    if [[ "$PROTO" != "reality" ]]; then parts+=("$(sb_hy2_inbound)"); fi
    joined=$(IFS=,; echo "${parts[*]}")

    local providers=""
    if [[ "$PROTO" != "reality" && "$HY2_MODE" == "acme" ]] && sb_is_new_acme; then
        local email_line=""
        [[ -n "$HY2_EMAIL" ]] && email_line="\"email\": \"${HY2_EMAIL}\","
        providers=$(cat <<EOF
  "certificate_providers": [
    {
      "type": "acme",
      "tag": "acme",
      "domain": ["${HY2_DOMAIN}"],
      ${email_line}
      "data_directory": "/var/lib/sing-box/acme"
    }
  ],
EOF
)
    fi

    local tmp="${SB_CONF%.json}.new.json"
    cat > "$tmp" <<EOF
{
  "log": { "level": "warn" },
${providers}
  "inbounds": [
${joined}
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
    secure_file "$tmp" sing-box
    if ! sing-box check -c "$tmp"; then
        rm -f "$tmp"; err "sing-box 配置校验失败（原配置未改动）"
    fi
    mv -f "$tmp" "$SB_CONF"
}

write_config() {
    info "写入配置文件..."
    if [[ "$CORE" == "xray" ]]; then write_config_xray; else write_config_singbox; fi
}

# ---------------------- 防火墙 / 服务 ----------------------
open_firewall() {
    local st pol
    if command -v ufw >/dev/null; then
        st=$(ufw status 2>/dev/null || true)
        if grep -q "Status: active" <<<"$st"; then
            if [[ "$PROTO" != "hy2" ]]; then info "ufw 放行 ${PORT}/tcp"; ufw allow "${PORT}/tcp" >/dev/null; fi
            if [[ "$PROTO" != "reality" ]]; then info "ufw 放行 ${HY2_PORT}/udp"; ufw allow "${HY2_PORT}/udp" >/dev/null; fi
            if [[ "$HY2_MODE" == "acme" ]]; then info "ufw 放行 80/tcp（证书申请）"; ufw allow 80/tcp >/dev/null; fi
        fi
    fi
    if command -v iptables >/dev/null; then
        pol=$(iptables -S INPUT 2>/dev/null || true)
        if grep -q -- "-P INPUT DROP" <<<"$pol"; then
            warn "iptables INPUT 默认策略为 DROP，请手动放行所用端口"
        fi
    fi
    local need=""
    if [[ "$PROTO" != "hy2" ]]; then need+="TCP ${PORT} "; fi
    if [[ "$PROTO" != "reality" ]]; then need+="UDP ${HY2_PORT} "; fi
    if [[ "$HY2_MODE" == "acme" ]]; then need+="TCP 80 "; fi
    warn "如果云服务商有安全组/防火墙，请在控制台放行：${need}"
    return 0
}

stop_other_core() {
    local other
    if [[ "$SERVICE" == "xray" ]]; then other="sing-box"; else other="xray"; fi
    if svc_exists "$other"; then
        if svc_active "$other"; then
            warn "检测到 ${other} 正在运行，将停止并禁用它，以免端口冲突"
        fi
        svc_stop "$other" || true
        svc_disable "$other" || true
    fi
    return 0
}

start_service() {
    svc_reload_units
    svc_enable "$SERVICE" || true
    svc_restart "$SERVICE"
    sleep 3
    if ! svc_active "$SERVICE"; then
        svc_logs "$SERVICE" 20
        err "${SERVICE} 启动失败"
    fi
    info "${SERVICE} 已启动并设置开机自启 ✔"
}

listening() {
    local flag="t" out; [[ "$1" == "udp" ]] && flag="u"
    out=$(ss -ln${flag} 2>/dev/null || true)
    grep -qE ":${2}\\s" <<<"$out"
}

wait_listen() { # 协议 端口 最长等待秒数
    local i
    for (( i = 0; i < $3; i++ )); do
        if listening "$1" "$2"; then return 0; fi
        sleep 1
    done
    return 1
}

verify_listening() {
    command -v ss >/dev/null || return 0
    if [[ "$PROTO" != "hy2" ]]; then
        if wait_listen tcp "$PORT" 10; then info "Reality ${PORT}/tcp 监听正常 ✔"
        else
            svc_logs "$SERVICE" 20
            err "服务已启动但 ${PORT}/tcp 未在监听"
        fi
    fi
    if [[ "$PROTO" != "reality" ]]; then
        local wait=10; [[ "$HY2_MODE" == "acme" ]] && wait=30
        if wait_listen udp "$HY2_PORT" "$wait"; then info "Hysteria2 ${HY2_PORT}/udp 监听正常 ✔"
        else
            warn "未检测到 ${HY2_PORT}/udp 监听。"
            if [[ "$HY2_MODE" == "acme" ]]; then
                warn "域名证书可能仍在申请中或申请失败，请查看：$(svc_log_cmd "$SERVICE")（检查域名解析与 80 端口）"
            else
                svc_logs "$SERVICE" 20
                err "服务已启动但 ${HY2_PORT}/udp 未在监听"
            fi
        fi
    fi
    return 0
}

# ---------------------- 输出结果 ----------------------
get_ip() {
    [[ -n "${SERVER_IP:-}" ]] && return 0
    local ip=""
    for url in https://api.ipify.org https://ifconfig.me https://ip.sb; do
        ip=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null || true)
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break || ip=""
    done
    [[ -n "$ip" ]] || { warn "无法自动获取公网 IP，请手动替换链接中的 SERVER_IP"; ip="SERVER_IP"; }
    SERVER_IP="$ip"
}

show_result() {
    get_ip
    {
        echo "==================== 节点信息 ===================="
        echo "内核 (Core) : ${CORE}"
        echo "服务器 IP   : ${SERVER_IP}"

        if [[ "$PROTO" != "hy2" ]]; then
            local link="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality-${CORE}-${SERVER_IP}"
            echo
            echo "---------- VLESS + Reality (TCP) ----------"
            echo "端口     : ${PORT}"
            echo "UUID     : ${UUID}"
            echo "Flow     : xtls-rprx-vision"
            echo "SNI      : ${SNI}"
            echo "指纹     : chrome"
            echo "公钥     : ${PUBLIC_KEY}"
            echo "ShortID  : ${SHORT_ID}"
            echo "分享链接 :"
            echo "${link}"
        fi

        if [[ "$PROTO" != "reality" ]]; then
            local host sni insecure pin=""
            if [[ "$HY2_MODE" == "acme" ]]; then
                host="$HY2_DOMAIN"; sni="$HY2_DOMAIN"; insecure=0
            else
                host="$SERVER_IP";  sni="$HY2_SNI";   insecure=1
                pin="&pinSHA256=${HY2_PIN}"
            fi
            local hlink="hysteria2://${HY2_PASS}@${host}:${HY2_PORT}/?sni=${sni}&insecure=${insecure}${pin}#Hy2-${SERVER_IP}"
            echo
            echo "---------- Hysteria2 (UDP) ----------"
            echo "地址     : ${host}"
            echo "端口     : ${HY2_PORT}"
            echo "密码     : ${HY2_PASS}"
            echo "SNI      : ${sni}"
            if [[ "$HY2_MODE" == "acme" ]]; then
                echo "证书     : 域名正规证书，无需跳过验证"
            else
                echo "证书     : 自签证书，客户端需勾选「跳过证书验证」"
                echo "证书指纹 : ${HY2_PIN}"
            fi
            echo "分享链接 :"
            echo "${hlink}"
        fi
        echo "=================================================="
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"

    echo
    echo -e "${CYAN}$(cat "$INFO_FILE")${NC}"
    echo
    info "信息已保存到 ${INFO_FILE}（随时可用 cat ${INFO_FILE} 查看，或重新运行脚本选择「查看节点信息」）"
    info "客户端：v2rayN / v2rayNG / NekoBox / Shadowrocket / Hiddify / Clash Meta(mihomo)"
    if [[ "$PROTO" != "reality" && "$HY2_MODE" != "acme" ]]; then
        warn "Hysteria2 使用自签证书：若客户端导入链接后连不上，请手动勾选「允许不安全/跳过证书验证」"
    fi
}

# ---------------------- 主流程 ----------------------
do_install() {
    check_env
    acquire_lock
    trap on_exit EXIT
    trap 'exit 130' INT TERM HUP
    check_enums
    choose_proto
    choose_core
    install_deps
    prompt_settings
    enable_bbr
    if [[ "$CORE" == "xray" ]]; then install_xray; else install_singbox; fi
    begin_txn                 # 从这里开始，任何失败都会自动回滚
    gen_params
    write_config
    open_firewall
    stop_other_core
    start_service
    verify_listening
    show_result
    commit_txn
}

do_info() {
    [[ -f "$INFO_FILE" ]] && cat "$INFO_FILE" || err "未找到节点信息文件，可能尚未安装"
}

do_restart() {
    check_env
    acquire_lock
    local found=0 svc
    for svc in xray sing-box; do
        if svc_exists "$svc" && svc_enabled "$svc"; then
            found=1
            svc_restart "$svc" && info "${svc} 已重启"
            svc_status "$svc"
        fi
    done
    if (( ! found )); then warn "未发现已启用的 xray / sing-box 服务"; fi
    return 0
}

do_uninstall() {
    check_env
    acquire_lock
    echo "请选择要卸载的内核："
    echo "  1) Xray-core"
    echo "  2) sing-box"
    echo "  3) 两者都卸载"
    ask "请选择 [1-3，其他退出]: " ""
    local rm_xray=0 rm_sb=0
    case "$ANSWER" in
        1) rm_xray=1 ;;
        2) rm_sb=1 ;;
        3) rm_xray=1; rm_sb=1 ;;
        *) info "已取消"; exit 0 ;;
    esac

    if (( rm_xray )); then
        info "卸载 Xray..."
        if [[ "$OS_FAMILY" == "alpine" || "$INIT_SYS" == "openrc" ]]; then
            uninstall_xray_alpine
        else
            run_xray_installer remove --purge || warn "Xray 卸载脚本执行失败（可能无法访问 GitHub），请手动检查"
        fi
    fi
    if (( rm_sb )); then
        info "卸载 sing-box..."
        svc_stop sing-box || true
        svc_disable sing-box || true
        if command -v apt-get >/dev/null; then apt-get purge -y sing-box 2>/dev/null || true; fi
        rm -f /etc/apt/sources.list.d/sagernet.sources /etc/apt/keyrings/sagernet.asc
        rm -f /usr/local/bin/sing-box /etc/systemd/system/sing-box.service
        if [[ "$INIT_SYS" == "openrc" ]]; then rm -f /etc/init.d/sing-box "$(svc_log_file sing-box)"; fi
        rm -rf /etc/sing-box /var/lib/sing-box
        svc_reload_units
    fi

    # 只删除与被卸载内核对应的节点信息
    if [[ -f "$INFO_FILE" ]]; then
        if (( rm_xray && rm_sb )) \
           || { (( rm_xray )) && grep -q "内核 (Core) : xray" "$INFO_FILE"; } \
           || { (( rm_sb )) && grep -q "内核 (Core) : singbox" "$INFO_FILE"; }; then
            rm -f "$INFO_FILE"
        fi
    fi
    info "已卸载。BBR/UDP 缓冲区设置保留在 /etc/sysctl.d/，防火墙(ufw)规则也未删除，如需清理请手动处理。"
}

main_menu() {
    echo
    echo -e "${CYAN}===== VLESS-Reality / Hysteria2 一键脚本 (Xray / sing-box) =====${NC}"
    echo "  1) 安装 / 重装节点"
    echo "  2) 查看节点信息"
    echo "  3) 重启服务并查看状态"
    echo "  4) 卸载"
    echo "  0) 退出"
    echo
    ask "请输入序号 [0-4]: " "0"
    case "$ANSWER" in
        1) do_install ;;
        2) do_info ;;
        3) do_restart ;;
        4) do_uninstall ;;
        *) exit 0 ;;
    esac
}

# 被 source 时（例如测试）不自动执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-menu}" in
        menu)      main_menu ;;
        install)   do_install ;;
        info)      do_info ;;
        restart)   do_restart ;;
        uninstall) do_uninstall ;;
        *) echo "用法: $0 [install|info|restart|uninstall]（不带参数进入交互菜单）"; exit 1 ;;
    esac
fi
