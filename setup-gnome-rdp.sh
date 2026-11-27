#!/usr/bin/env bash
# Ubuntu 26.04：配置 GNOME 原生远程登录（RDP），从 xrdp 迁移到 TCP 3389。
# 本脚本不安装软件、不修改防火墙，也不会注销本地图形会话。
set -euo pipefail

usage() {
    cat <<'EOF'
用法：sudo bash ./setup-gnome-rdp.sh

请在 Ubuntu 本机终端执行。需要 GDM、gnome-remote-desktop 和 OpenSSL。
每次运行都会提示设置 RDP 凭据并重启 GNOME RDP 服务，现有远程连接可能断开。
Windows 用 mstsc 连接脚本输出的 IP:3389：先输入 RDP 凭据，再用 Ubuntu 账号登录。
若提示「会话已在运行」，可选「强行停止」结束旧会话；未保存的工作会丢失。
只在可信局域网或 VPN 内使用，不要在路由器上把 3389 转发到公网。
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac
if (( $# != 0 || EUID != 0 )) || [[ ! -t 0 ]]; then
    usage >&2
    exit 1
fi

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset XDG_DATA_HOME XDG_CONFIG_HOME
umask 077
trap 'printf "配置在第 %s 行失败，请查看上面的报错。\n" "$LINENO" >&2' ERR

for command_name in grdctl openssl systemctl runuser ss ip; do
    if ! command -v "$command_name" >/dev/null; then
        printf '缺少命令：%s\n' "$command_name" >&2
        exit 1
    fi
done

service_user=gnome-remote-desktop
service_unit=gnome-remote-desktop.service
if ! service_home=$(getent passwd "$service_user" | cut -d: -f6) ||
    [[ ! -d "$service_home" || ! -r /usr/share/wayland-sessions/ubuntu.desktop ]]; then
    printf '找不到 GNOME 远程桌面服务账户目录或 Ubuntu GNOME 会话。\n' >&2
    exit 1
fi
tls_dir=$service_home/.local/share/gnome-remote-desktop
tls_cert=$tls_dir/remote-login.crt
tls_key=$tls_dir/remote-login.key

as_grd() {
    runuser -u "$service_user" -- "$@"
}

grd() {
    as_grd grdctl --system "$@"
}

# GDM 提供远程登录界面。启动服务即可，不重启 GDM，以免注销本地用户。
systemctl start gdm.service

# 复用未到期的自签名证书；密钥和证书由服务账户创建，并保存在其主目录。
printf '准备 GNOME RDP 的 TLS 证书。\n'
as_grd mkdir -p "$tls_dir"
if ! as_grd test -s "$tls_key" || ! as_grd openssl x509 -checkend 86400 -noout -in "$tls_cert" >/dev/null 2>&1; then
    as_grd openssl req -x509 -newkey rsa:3072 -sha256 -noenc -days 365 \
        -subj "/CN=$(hostname)" -keyout "$tls_key" -out "$tls_cert"
fi
grd rdp set-tls-key "$tls_key"
grd rdp set-tls-cert "$tls_cert"
grd rdp set-port 3389

# 让 grdctl 交互读取凭据，不把密码写入脚本、命令参数或 shell 历史。
printf '\n请设置独立的 RDP 用户名和强密码，供 Windows 首次连接时使用。\n'
grd rdp set-credentials

# 兼容未安装 xrdp 的机器。切换成功前保留旧服务的开机启动配置。
xrdp_units=()
xrdp_active_units=()
xrdp_unit_files=$(systemctl list-unit-files --type=service --no-legend --no-pager)
while read -r unit_name unit_state; do
    case "$unit_name" in
        xrdp.service|xrdp-sesman.service)
            xrdp_units+=("$unit_name")
            if systemctl is-active --quiet "$unit_name"; then
                xrdp_active_units+=("$unit_name")
            fi
            ;;
    esac
done <<< "$xrdp_unit_files"

# 切换失败时打印日志，并尝试恢复切换前正在运行的 xrdp 服务。
restore_on_error() {
    local status=$?
    if (( status == 0 )); then
        return
    fi
    journalctl -u "$service_unit" -u gdm.service -n 25 --no-pager >&2 || true
    if (( ${#xrdp_active_units[@]} > 0 )); then
        printf 'GNOME 未接管 3389，尝试恢复原 xrdp 服务。\n' >&2
        systemctl disable --now "$service_unit" || true
        systemctl start "${xrdp_active_units[@]}" || true
    fi
}

printf '\n切换 TCP 3389 到 GNOME 原生远程登录。\n'
trap restore_on_error EXIT
if (( ${#xrdp_units[@]} > 0 )); then
    systemctl stop "${xrdp_units[@]}"
fi
grd rdp enable
systemctl restart "$service_unit"

# 端口开放不代表切换成功：确认 3389 的监听进程就是 GNOME 服务的主进程。
for attempt in {1..10}; do
    daemon_pid=$(systemctl show --property=MainPID --value "$service_unit")
    listener=$(ss -H -ltnp 'sport = :3389')
    if [[ "$daemon_pid" =~ ^[1-9][0-9]*$ && "$listener" == *"pid=$daemon_pid,"* ]]; then
        break
    fi
    sleep 1
done
if [[ ! "$daemon_pid" =~ ^[1-9][0-9]*$ || "$listener" != *"pid=$daemon_pid,"* ]]; then
    printf '未检测到 GNOME 远程桌面监听 TCP 3389。\n%s\n' "${listener:-TCP 3389 无监听进程。}" >&2
    exit 1
fi

systemctl enable "$service_unit"
trap - EXIT
if (( ${#xrdp_units[@]} > 0 )); then
    systemctl disable "${xrdp_units[@]}"
fi

printf '\nGNOME 远程登录已监听 TCP 3389（服务 PID %s）：\n%s\n' "$daemon_pid" "$listener"
printf '\nWindows 用 mstsc 连接下列局域网 IP 的 3389 端口。\n'
ip -br -4 address show scope global
printf '\n自签名 RDP 证书指纹（SHA-256）：\n'
as_grd openssl x509 -in "$tls_cert" -noout -fingerprint -sha256
