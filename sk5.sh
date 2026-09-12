#!/usr/bin/env bash
# 若被 sh/dash 调用，自动重新用 bash 执行（dash 不支持 echo -e，会打印 -e 字面量）
if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
fi
# ============================================================
# SOCKS5 代理一键搭建（合并版：多系统 + 纯 IPv6/WARP 修复）
# 支持：Alpine / Debian / Ubuntu，自动识别 IPv4 / 纯 IPv6，兼容 WARP 出站
# 用法：改下面参数，保存为 sk5.sh 后执行： sh sk5.sh
# ============================================================

# 以下参数会在安装时交互式询问；也可用环境变量预先指定（非交互场景）
PORT="${SK5_PORT:-}"
USER="${SK5_USER:-}"
PASS="${SK5_PASS:-}"

set -e

# ---------- 卸载模式 ----------
# 安装：sh sk5.sh
# 卸载：sh sk5.sh uninstall
uninstall_sk5() {
    echo "==> 开始卸载 SOCKS5 代理"

    # 卸载时可能未传入参数：先从环境变量取，再从服务监听探测
    if [ -z "$PORT" ]; then
        PORT=$(ss -tlnp 2>/dev/null | grep -E "danted|sockd|microsocks" | head -1 | awk '{for(i=1;i<=NF;i++){if($i ~ /:[0-9]+$/){sub(/.*:/,"",$i); print $i; exit}}}')
        if [ -z "$PORT" ]; then
            PORT=$(netstat -tlnp 2>/dev/null | grep -E "danted|sockd|microsocks" | head -1 | awk '{for(i=1;i<=NF;i++){if($i ~ /:[0-9]+$/){sub(/.*:/,"",$i); print $i; exit}}}')
        fi
        [ -z "$PORT" ] && PORT=""
        [ -n "$PORT" ] && echo "    未指定端口，检测到当前端口: $PORT"
    fi
    [ -z "$USER" ] && USER="admin"

    if command -v apk >/dev/null 2>&1; then
        rc-service sockd stop 2>/dev/null || true
        rc-update del sockd default 2>/dev/null || true
        rm -f /etc/sockd.conf /etc/danted.conf
        rm -rf /etc/sk5
        deluser "$USER" 2>/dev/null || true
        apk del dante-server dante-server-openrc 2>/dev/null || true

    elif command -v apt-get >/dev/null 2>&1; then
        systemctl stop danted microsocks 2>/dev/null || true
        systemctl disable danted microsocks 2>/dev/null || true
        rm -f /etc/danted.conf /etc/sockd.conf
        rm -f /etc/systemd/system/microsocks.service
        rm -rf /etc/sk5
        systemctl daemon-reload 2>/dev/null || true
        userdel -f "$USER" 2>/dev/null || true

        dpkg-query -W -f='${Status}' dante-server 2>/dev/null | grep -q 'install ok installed' && apt-get remove --purge -y dante-server || true
        dpkg-query -W -f='${Status}' microsocks 2>/dev/null | grep -q 'install ok installed' && apt-get remove --purge -y microsocks || true
        apt-get autoremove -y 2>/dev/null || true
    else
        echo "❌ 未识别的系统"
        exit 1
    fi

    echo ""
    echo "=== 卸载验证 ==="
    if netstat -tulnp 2>/dev/null | grep -q ":${PORT} "; then
        echo "⚠️ 端口 ${PORT} 仍在使用"
        netstat -tulnp 2>/dev/null | grep ":${PORT} " || true
        exit 1
    elif ss -tulnp 2>/dev/null | grep -q ":${PORT} "; then
        echo "⚠️ 端口 ${PORT} 仍在使用"
        ss -tulnp 2>/dev/null | grep ":${PORT} " || true
        exit 1
    else
        echo "✅ SOCKS5 已卸载，端口 ${PORT} 已释放"
    fi
}

# show / 其他参数由文件末尾的正式入口处理，此处只处理卸载
case "${1:-install}" in
    uninstall|remove|del)
        uninstall_sk5
        exit 0
        ;;
esac

# ---------- 交互式采集参数 ----------
# 仅安装时询问；环境变量已指定则跳过。
# 管道方式（curl ... | sh）下 stdin 被脚本本体占用，改从 /dev/tty 读取。
# 生成 16 位随机密码（兼容 busybox 与 GNU coreutils）
gen_pass() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 8
    elif [ -r /dev/urandom ]; then
        od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
    else
        head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# 保存/读取本次安装的凭据（密码无法从系统反查，落盘以便「查看节点链接」显示）
CRED_FILE="/etc/sk5/credentials"

save_cred() {
    mkdir -p /etc/sk5 2>/dev/null || true
    ( umask 077; printf 'PORT=%s\nUSER=%s\nPASS=%s\n' "${PORT:-}" "${USER:-}" "${PASS:-}" > "$CRED_FILE" ) 2>/dev/null || true
    chmod 600 "$CRED_FILE" 2>/dev/null || true
}

load_cred() {
    [ -f "$CRED_FILE" ] || return 1
    . "$CRED_FILE" 2>/dev/null || return 1
    return 0
}

# URL 编码（用于 TG 链接中的用户名/密码）
# 端口是否被占用
_port_taken() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -q ":$p " && return 0
        ss -uln 2>/dev/null | grep -q ":$p " && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -q ":$p " && return 0
        netstat -uln 2>/dev/null | grep -q ":$p " && return 0
    fi
    return 1
}

# 生成随机端口（10000-65535），避开已占用端口
gen_port() {
    local p i=0
    while [ "$i" -lt 60 ]; do
        p=$(( (RANDOM % 55535) + 10000 ))
        if ! _port_taken "$p"; then
            printf '%s' "$p"
            return 0
        fi
        i=$((i + 1))
    done
    printf '%s' "$(( (RANDOM % 55535) + 10000 ))"
}

urlenc() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1" 2>/dev/null && return
    fi
    printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/@/%40/g' -e 's/#/%23/g' -e 's/ /%20/g' -e 's/+/%2B/g'
}

# base64 编码（供小火箭等客户端导入的 socks:// 链接使用，标准格式为 base64(user:pass)）
b64() {
    if command -v base64 >/dev/null 2>&1; then
        printf '%s' "$1" | base64 | tr -d '\n'
    elif command -v openssl >/dev/null 2>&1; then
        printf '%s' "$1" | openssl base64 -A
    fi
}

# 输出各客户端可直接导入的链接
# - tg://socks   ：Telegram 专用
# - socks://base64(user:pass)@host:port ：小火箭 / Shadowrocket、v2rayNG、Nekoray 等通用格式
print_links() {
    local host="$1" port="$2" user="$3" pass="$4"
    local auth_b64
    auth_b64=$(b64 "${user}:${pass}")
    echo "tg://socks?server=${host}&port=${port}&user=$(urlenc "$user")&pass=$(urlenc "$pass")"
    echo "socks://${auth_b64}@${host}:${port}"
}

# 验证 SOCKS5 认证是否真的可用
# danted 走 PAM 校验系统账号，用户不存在或密码不对都会导致认证失败（端口却是通的）。
# 这里做一次本机 SOCKS5 发起请求，能通过认证就算成功。
verify_auth() {
    local host="127.0.0.1"
    [ "$MODE" = "v6" ] && host="::1"

    # 方式一：curl 走 SOCKS5（最接近实际用法）
    if command -v curl >/dev/null 2>&1; then
        if curl -s --max-time 12 --socks5-hostname "${host}:${PORT}" -U "${USER}:${PASS}" https://api.ipify.org >/dev/null 2>&1; then
            return 0
        fi
        # 不能出网但认证通过的情形：区分对待
        _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --socks5-hostname "${host}:${PORT}" -U "${USER}:${PASS}" https://api.ipify.org 2>/dev/null)
        [ "$_code" = "200" ] && return 0
        # 407 表示认证被拒，其他码（如 000）可能是出网问题而非认证
        [ "$_code" != "407" ] && [ "$_code" != "" ] && return 0
    fi

    # 方式二：curl 不可用时，用密码文件比对（能确认用户与密码一致）
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$USER" >/dev/null 2>&1 || return 1
    fi
    return 0
}

ask_params() {
    # 若三个参数都已由环境变量提供，直接返回
    if [ -n "$PORT" ] && [ -n "$USER" ] && [ -n "$PASS" ]; then
        echo "    使用环境变量参数: 端口=$PORT 用户=$USER"
        return 0
    fi

    # 无交互终端（管道方式）：使用默认值兜底
    if [ ! -t 0 ]; then
        [ -z "$PORT" ] && PORT=$(gen_port)
        [ -z "$USER" ] && USER="admin"
        [ -z "$PASS" ] && PASS=$(gen_pass)
        echo "    无交互终端，使用默认参数: 端口=$PORT 用户=$USER"
        return 0
    fi

    # 端口
    if [ -z "$PORT" ]; then
        while :; do
            printf "\n请输入监听端口 (1-65535，直接回车随机): "
            read -r _p || _p=""
            [ -z "$_p" ] && { PORT=$(gen_port); break; }
            case "$_p" in
                *[!0-9]*|'') echo "⚠ 端口必须是数字" ;;
                *) if [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ]; then PORT="$_p"; break; else echo "⚠ 端口超出 1-65535"; fi ;;
            esac
        done
    fi

    # 用户名
    if [ -z "$USER" ]; then
        while :; do
            printf "请输入认证用户名 (直接回车默认 admin): "
            read -r _u || _u=""
            [ -z "$_u" ] && { USER="admin"; break; }
            case "$_u" in
                *[!A-Za-z0-9_.@-]*) echo "⚠ 用户名只能含字母、数字、_ . @ -" ;;
                *) USER="$_u"; break ;;
            esac
        done
    fi

    # 密码
    if [ -z "$PASS" ]; then
        while :; do
            printf "请输入认证密码 (直接回车自动生成 16 位随机密码): "
            read -r _pw || _pw=""
            [ -z "$_pw" ] && { PASS=$(gen_pass); break; }
            case "$_pw" in
                *[!A-Za-z0-9_.@#%+=-]*) echo "⚠ 密码含不支持的字符（可用：字母数字 _ . @ # % + = - ）" ;;
                *) PASS="$_pw"; break ;;
            esac
        done
    fi

    echo ""
    echo "    将使用：端口=$PORT  用户名=$USER"
}

# ================= 安装 =================
install_sk5() {

    ask_params

    # ---------- 网络检测 ----------
    # 取默认出站网卡
    IFACE=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
    [ -z "$IFACE" ] && IFACE=$(ip -6 route 2>/dev/null | awk '/default/ {print $5; exit}')
    [ -z "$IFACE" ] && IFACE=eth0

    # WARP 网卡（先识别，后续 IPv4 检测须排除它，否则纯 IPv6 机上的 WARP IPv4 会被误判为原生 IPv4）
    WARP_IF=""
    for c in WARP warp wgcf wg0 warp0; do
        ip link show "$c" >/dev/null 2>&1 && { WARP_IF="$c"; break; }
    done
    WARP_V4=""
    [ -n "$WARP_IF" ] && WARP_V4=$(ip -4 addr show dev "$WARP_IF" scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)

    # 取原生 IPv4：按网卡逐个过滤，排除回环与 WARP 网卡。
    # 这样多网卡/多 IPv4 也不会误判：只要没有非 WARP 网卡的全局 IPv4，就是纯 IPv6。
    IPV4=""
    for dev in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2}'); do
        [ "$dev" = "lo" ] && continue
        [ -n "$WARP_IF" ] && [ "$dev" = "$WARP_IF" ] && continue
        # 排除虚拟网卡：docker0 / br-* / veth* / virbr* / tun/tap / tailscale / podman / cni，
        # 否则容器环境下 Docker 网桥的 172.17.x.x 会被误判为原生 IPv4。
        case "$dev" in
            docker*|br-*|veth*|virbr*|tun*|tap*|tailscale*|podman*|cni*|flannel*|cali*|kube*) continue ;;
        esac
        addr=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        if [ -n "$addr" ]; then
            IPV4="$addr"
            break
        fi
    done
    # 取 IPv6 地址（排除 WARP 2606:4700 段和 link-local）
    IPV6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -vE '^2606:4700|^fe80' | head -1)

    echo "    网卡=$IFACE  原生IPv4=${IPV4:-无}  IPv6=${IPV6:-无}  WARP=${WARP_IF:-无}(${WARP_V4:-无})"

    # 判定模式：有原生 IPv4 用 v4，否则纯 v6（WARP 的 IPv4 不计入）
    if [ -n "$IPV4" ]; then MODE="v4"; else MODE="v6"; fi
    echo "    对网络模式: $MODE"

    # ---------- 生成 dante 配置主体 ----------
    # 纯 IPv6 模式下同时生成两条 socks pass 规则（→ IPv6 与 → IPv4），
    # 解决旧版脚本只有单条规则导致 IPv4 目标不可达的问题。
    gen_conf() {
        # $1 = 监听行, $2 = external 行(s), $3 = client to, $4 = socks to (v4), $5 = 输出路径, $6 = socks to (v6, 可选)
        {
            echo "logoutput: syslog"
            echo "$1"
            echo "$2"
            echo ""
            echo "socksmethod: username"
            echo "user.privileged: root"
            echo "user.notprivileged: nobody"
            echo ""
            echo "client pass {"
            echo "    from: $3 to: $3"
            echo "    log: error"
            echo "}"
            echo ""
            echo "socks pass {"
            echo "    from: $3 to: $4"
            echo "    command: bind connect udpassociate"
            echo "    log: error"
            echo "}"
            if [ -n "$6" ]; then
                echo ""
                echo "socks pass {"
                echo "    from: $3 to: $6"
                echo "    command: bind connect udpassociate"
                echo "    log: error"
                echo "}"
            fi
        } > "$5"
    }

    # ============================================================
    # Alpine
    # ============================================================
    if command -v apk >/dev/null 2>&1; then
        echo "==> 检测到 Alpine Linux"
        apk update >/dev/null 2>&1
        apk add dante-server >/dev/null 2>&1

        if [ "$MODE" = "v4" ]; then
            CONF_INTERNAL="internal: 0.0.0.0 port = ${PORT}"
            CONF_EXTERNAL="external: ${IPV4}"
            CONF_TO="0.0.0.0/0"
            CONF_V6=""
        else
            CONF_INTERNAL="internal: :: port = ${PORT}"
            if [ -n "$WARP_V4" ]; then
                CONF_EXTERNAL="external: ${IPV6}
    external: ${WARP_V4}"
            else
                CONF_EXTERNAL="external: ${IPV6}"
            fi
            CONF_TO="::/0"
            CONF_V6="::/0"
        fi
        gen_conf "$CONF_INTERNAL" "$CONF_EXTERNAL" "$CONF_TO" "0.0.0.0/0" /etc/sockd.conf "$CONF_V6"

        id "$USER" >/dev/null 2>&1 || adduser -D -H -s /sbin/nologin "$USER"
        echo "${USER}:${PASS}" | chpasswd
        rc-update add sockd default >/dev/null 2>&1 || true
        rc-service sockd restart
        sleep 2
        SERVICE="sockd"
        _AUTH_NOTE=$(verify_auth && echo ok || echo fail)

    # ============================================================
    # Debian / Ubuntu
    # ============================================================
    elif command -v apt-get >/dev/null 2>&1; then
        echo "==> 检测到 Debian/Ubuntu"
        export DEBIAN_FRONTEND=noninteractive
        dpkg --configure -a --force-confold >/dev/null 2>&1 || true
        apt-get update -qq || true

        if apt-cache policy dante-server 2>/dev/null | grep -q Candidate; then
            echo "    使用 dante-server"
            apt-get install -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" dante-server

            if [ "$MODE" = "v4" ]; then
                CONF_INTERNAL="internal: 0.0.0.0 port = ${PORT}"
                CONF_EXTERNAL="external: ${IPV4}"
                CONF_TO="0.0.0.0/0"
                CONF_V6=""
            else
                CONF_INTERNAL="internal: :: port = ${PORT}"
                if [ -n "$WARP_V4" ]; then
                    CONF_EXTERNAL="external: ${IPV6}
    external: ${WARP_V4}"
                else
                    CONF_EXTERNAL="external: ${IPV6}"
                fi
                CONF_TO="::/0"
                CONF_V6="::/0"
            fi
            gen_conf "$CONF_INTERNAL" "$CONF_EXTERNAL" "$CONF_TO" "0.0.0.0/0" /etc/danted.conf "$CONF_V6"

            id "$USER" >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin "$USER"
            echo "${USER}:${PASS}" | chpasswd
            systemctl enable danted >/dev/null 2>&1 || true
            systemctl restart danted
            sleep 2
            SERVICE="danted"
            _AUTH_NOTE=$(verify_auth && echo ok || echo fail)
        else
            echo "    源里无 dante，改用 microsocks"
            apt-get install -y microsocks
            LISTEN_IP="0.0.0.0"
            [ "$MODE" = "v6" ] && LISTEN_IP="::"
            cat > /etc/systemd/system/microsocks.service <<EOF
[Unit]
Description=microsocks SOCKS5 Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/microsocks -i ${LISTEN_IP} -p ${PORT} -u "${USER}" -P "${PASS}"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable microsocks >/dev/null 2>&1 || true
            systemctl restart microsocks
            sleep 2
            SERVICE="microsocks"
            _AUTH_NOTE=$(verify_auth && echo ok || echo fail)
        fi
    else
        echo "❌ 未识别的系统（仅支持 Alpine / Debian / Ubuntu）"
        exit 1
    fi

    # ---------- 验证 ----------
    echo ""
    echo "=== 验证结果 ==="
    echo -e "${GREEN}服务:  $SERVICE${NC}"
    if [ "$_AUTH_NOTE" = "fail" ]; then
        echo "认证:  ❌ 自检未通过（用户 $USER 可能未创建或密码不匹配）"
        echo "       排查：id $USER ; echo '"$USER:新密码"' | chpasswd ; 重启服务"
    else
        echo "认证:  ✅ 自检通过"
    fi
    _svcname="$(_detect_service)"
    if _service_installed; then
        if _service_running; then
            echo -e "${GREEN}在运行${NC}"
        else
            echo -e "${RED}未运行${NC}"
        fi
    else
        echo -e "${RED}未安装${NC}"
        echo -e "${RED}未运行${NC}"
    fi
    netstat -tlnp 2>/dev/null | grep ":${PORT}" || ss -tlnp 2>/dev/null | grep ":${PORT}"

    # 取公网 IP（v4 优先，v6 备用）
    PUBIP=$(curl -s4 --max-time 8 https://api.ipify.org 2>/dev/null || curl -s6 --max-time 8 https://api64.ipify.org 2>/dev/null || echo "<你的公网IP>")

    # 安装过程输出较多，清屏后在顶部突出显示节点信息
    save_cred   # 密码无法从系统反查，落盘供「查看节点链接」使用
    command -v clear >/dev/null 2>&1 && clear 2>/dev/null || printf '\033[2J\033[H'
    _UE=$(urlenc "$USER")
    _PE=$(urlenc "$PASS")

    echo ""
    echo "================ 完成 ================"
    echo "模式:   $MODE"
    echo "地址:   ${PUBIP}"
    echo "端口:   ${PORT}"
    echo "用户名: ${USER}"
    echo "密码:   ${PASS}"
    _B64=$(b64 "${USER}:${PASS}")
    if [ "$MODE" = "v6" ]; then
        echo "TG链接: tg://socks?server=${IPV6}&port=${PORT}&user=${_UE}&pass=${_PE}"
        echo "小火箭:  socks://${_B64}@${IPV6}:${PORT}"
    else
        echo "TG链接: tg://socks?server=${PUBIP}&port=${PORT}&user=${_UE}&pass=${_PE}"
        echo "小火箭:  socks://${_B64}@${PUBIP}:${PORT}"
    fi
    echo "======================================"
}
# ================= 辅助 =================
_detect_port() {
    local p
    p=$(ss -tlnp 2>/dev/null | grep -E "danted|sockd|microsocks" | head -1 | awk '{for(i=1;i<=NF;i++){if($i ~ /:[0-9]+$/){sub(/.*:/,"",$i); print $i; exit}}}')
    if [ -z "$p" ]; then
        p=$(netstat -tlnp 2>/dev/null | grep -E "danted|sockd|microsocks" | head -1 | awk '{for(i=1;i<=NF;i++){if($i ~ /:[0-9]+$/){sub(/.*:/,"",$i); print $i; exit}}}')
    fi
    printf '%s' "$p"
}

_detect_service() {
    if command -v apk >/dev/null 2>&1; then
        printf 'sockd'
    elif [ -f /etc/systemd/system/microsocks.service ]; then
        printf 'microsocks'
    else
        printf 'danted'
    fi
}

restart_service() {
    local svc
    svc="$(_detect_service)"
    if command -v apk >/dev/null 2>&1; then
        rc-service "$svc" restart 2>&1 | tail -1
    else
        systemctl restart "$svc" 2>&1 | tail -1
    fi
}

_service_installed() {
    local svc
    svc="$(_detect_service)"
    if command -v apk >/dev/null 2>&1; then
        [ -f "/etc/init.d/$svc" ]
    else
        [ -f "/etc/systemd/system/$svc.service" ] || [ -f "/lib/systemd/system/$svc.service" ] || [ -f "/usr/lib/systemd/system/$svc.service" ] || command -v "$svc" >/dev/null 2>&1
    fi
}

_service_running() {
    local svc
    svc="$(_detect_service)"
    if command -v apk >/dev/null 2>&1; then
        rc-service "$svc" status >/dev/null 2>&1
    else
        systemctl is-active --quiet "$svc" 2>/dev/null
    fi
}

show_info() {
    local port svc user pass ipv4 ipv6 pubip mode _host _ue _pe
    port="$(_detect_port)"
    svc="$(_detect_service)"

    if [ -z "$port" ]; then
        echo -e "${RED}❌ 未检测到 SOCKS5 服务，请先安装${NC}"
        return 1
    fi

    # 从本次运行参数或落盘凭据里取用户名/密码（密码无法从系统反查）
    load_cred 2>/dev/null || true
    local _cport="${PORT:-}" _cuser="${USER:-}" _cpass="${PASS:-}"

    user=""
    if [ -f /etc/systemd/system/microsocks.service ]; then
        user=$(grep -oE '\-u "?[A-Za-z0-9_.@-]+' /etc/systemd/system/microsocks.service 2>/dev/null | sed 's/-u "\?//' | head -1)
        [ -z "$pass" ] && pass=$(grep -oE '\-P "?[^"[:space:]]+' /etc/systemd/system/microsocks.service 2>/dev/null | sed 's/-P "\?//' | head -1)
    fi
    [ -z "$user" ] && user="${_cuser:-${USER:-admin}}"
    pass="${_cpass:-${PASS:-}}"
    [ -z "$pass" ] && [ -f /etc/sk5/credentials ] && pass=$(awk -F= '/^PASS=/{print substr($0,6)}' /etc/sk5/credentials 2>/dev/null)
    [ -z "$user" ] && [ -f /etc/sk5/credentials ] && user=$(awk -F= '/^USER=/{print substr($0,6)}' /etc/sk5/credentials 2>/dev/null)
    [ -z "$user" ] && user="admin"

    ipv4=""
    for dev in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2}'); do
        case "$dev" in lo|docker*|br-*|veth*|virbr*|tun*|tap*|tailscale*|podman*|cni*|flannel*|cali*|kube*|WARP|warp|wgcf*|wg0) continue ;; esac
        a=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        [ -n "$a" ] && { ipv4="$a"; break; }
    done
    ipv6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -vE '^2606:4700|^fe80' | head -1)

    if [ -n "$ipv4" ]; then mode="IPv4"; else mode="IPv6-only"; fi

    echo -e "${YELLOW}正在检测...${NC}"
    pubip=$(curl -s4 --max-time 8 https://api.ipify.org 2>/dev/null || curl -s6 --max-time 8 https://api64.ipify.org 2>/dev/null || echo "")

    if [ -n "$ipv4" ]; then
        _host="$ipv4"
        [ -n "$pubip" ] && _host="$pubip"
    elif [ -n "$ipv6" ]; then
        _host="$ipv6"
    else
        _host="${pubip:-<unknown>}"
    fi

    _ue=$(urlenc "$user")
    _pe=$(urlenc "$pass")

    echo ""
    echo -e "${GREEN}========== SOCKS5 节点信息 ==========${NC}"
    local _stat
    if _service_running; then
        _stat="${GREEN}运行中${NC}"
    elif _service_installed; then
        _stat="${RED}未运行${NC}"
    else
        _stat="${RED}未安装${NC}"
    fi
    echo -e "🔧 服务状态: ${_stat}"
    echo -e "🌐 网络模式: ${YELLOW}$mode${NC}"
    echo -e "📡 监听端口: ${YELLOW}$port${NC}"
    echo -e "👤 用户名:   ${YELLOW}$user${NC}"
    [ -n "$pass" ] && echo -e "🔐 密码:     ${YELLOW}$pass${NC}"
    echo ""
    if [ -n "$user" ] && [ -n "$pass" ]; then
        _B64=$(b64 "${user}:${pass}")
        echo -e "${GREEN}📎 TG 链接:${NC}"
        echo -e "${YELLOW}tg://socks?server=${_host}&port=${port}&user=${_ue}&pass=${_pe}${NC}"
        echo -e "${YELLOW}小火箭:  socks://${_B64}@${_host}:${port}${NC}"
    else
        echo -e "${YELLOW}密码未知（本次运行未提供）。可用 SK5_PASS=你的密码 重跑脚本后选 2 查看${NC}"
    fi
    echo -e "${GREEN}========================================${NC}"
}

change_port() {
    local svc old new
    svc="$(_detect_service)"
    old="$(_detect_port)"
    if [ -z "$old" ]; then
        echo -e "${RED}❌ 未检测到 SOCKS5 服务，请先安装${NC}"
        return 1
    fi
    printf "当前端口: %s\n请输入新端口 (1-65535): " "$old"
    read -r new
    case "$new" in ''|*[!0-9]*) echo -e "${RED}❌ 无效端口${NC}"; return 1 ;; esac
    if [ "$new" -lt 1 ] || [ "$new" -gt 65535 ]; then
        echo -e "${RED}❌ 端口超出范围${NC}"; return 1
    fi

    if [ -f /etc/systemd/system/microsocks.service ]; then
        sed -i "s/-p [0-9][0-9]*/-p $new/" /etc/systemd/system/microsocks.service
        systemctl daemon-reload
    fi
    if [ -f /etc/danted.conf ]; then
        sed -i "s/^internal:.*port = [0-9][0-9]*/internal: :: port = $new/" /etc/danted.conf
    elif [ -f /etc/sockd.conf ]; then
        sed -i "s/^internal:.*port = [0-9][0-9]*/internal: :: port = $new/" /etc/sockd.conf
    fi

    if command -v apk >/dev/null 2>&1; then
        rc-service "$svc" restart >/dev/null 2>&1
    else
        systemctl restart "$svc" >/dev/null 2>&1
    fi
    sleep 2
    echo -e "${GREEN}✅ 端口已更改为 $new${NC}"
    PORT="$new"
    show_info
}

# ================= 菜单 =================
do_menu() {
    local choice
    while true; do
        local status
        if _service_running; then status="${GREEN}运行中${NC}"; elif _service_installed; then status="${RED}未运行${NC}"; else status="${RED}未安装${NC}"; fi

        clear
        echo -e "${GREEN}===============================================${NC}"
        echo -e " SOCKS5 代理管理脚本"
        echo -e " 当前系统: $(command -v apk >/dev/null 2>&1 && echo alpine || echo debian)"
        echo -e " 服务状态: $status"
        echo -e "${GREEN}===============================================${NC}"
        echo -e " ${CYAN}[1]${NC} 安装 SOCKS5"
        echo -e " ${CYAN}[2]${NC} 查看节点链接"
        echo -e " ${CYAN}[3]${NC} 更改监听端口"
        echo -e " ${CYAN}[4]${NC} 重启服务"
        echo -e " ${CYAN}[5]${NC} 卸载 SOCKS5"
        echo -e " ${CYAN}[0]${NC} 退出脚本"
        echo -e "${GREEN}===============================================${NC}"
        echo -ne "请输入数字选择 [0-5]: "
        read -r choice

        case "$choice" in
            1) install_sk5 ;;
            2) show_info ;;
            3) change_port ;;
            4) restart_service && echo -e "${GREEN}服务已重启${NC}" ;;
            5)
                printf "确定卸载 SOCKS5 吗？[y/N]: "
                read -r _c
                case "$_c" in y|Y|yes|YES) uninstall_sk5 ;; *) echo "已取消" ;; esac
                ;;
            0) echo "已退出"; exit 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac

        echo ""
        echo -e "${YELLOW}按任意键返回主菜单...${NC}"
        read -r _pause
    done
}

# ================= 入口 =================
case "${1:-}" in
    install)      install_sk5 ;;
    uninstall|remove|del) uninstall_sk5 ;;
    show)         show_info ;;
    *)
        if [ -t 0 ]; then
            do_menu
        else
            install_sk5
        fi
        ;;
esac