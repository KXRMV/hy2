#!/usr/bin/env bash
set -euo pipefail

# ─── Hysteria 2 Installer for Ubuntu 24.04 ───
# Usage: bash <(curl -Ls https://raw.githubusercontent.com/YukiKras/vless-scripts/refs/heads/main/hysteria-install.sh)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

HYSTERIA_DIR="/etc/hysteria"
HYSTERIA_BIN="/usr/local/bin/hysteria"
SERVICE_FILE="/etc/systemd/system/hysteria-server.service"

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── Helpers ───

# URL-encode a string (percent-encoding)
urlencode() {
    local str="$1" encoded="" i c
    for (( i = 0; i < ${#str}; i++ )); do
        c="${str:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            *) encoded+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    echo "$encoded"
}

# Escape string for use as sed replacement
sed_escape() {
    printf '%s\n' "$1" | sed 's/[&/\|]/\\&/g'
}

# Detect the default network interface
detect_iface() {
    ip route show default 2>/dev/null | awk '{print $5; exit}'
}

# Validate port number
validate_port() {
    local p="$1"
    if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
        return 1
    fi
    return 0
}

# Read a field from config.yaml safely (handles special chars)
config_get_auth_password() {
    awk '/^auth:/{found=1} found && /^  password:/{print substr($0, index($0,$2)); exit}' "$HYSTERIA_DIR/config.yaml"
}

config_get_obfs_password() {
    awk '/^obfs:/{found=1} found && /^    password:/{print substr($0, index($0,$2)); exit}' "$HYSTERIA_DIR/config.yaml"
}

config_get_port() {
    grep -oP '(?<=^listen: :)\d+' "$HYSTERIA_DIR/config.yaml"
}

# ─── Pre-checks ───
[[ $EUID -ne 0 ]] && err "Run as root: sudo bash <(curl -Ls ...)"

command -v curl  >/dev/null || { apt-get update && apt-get install -y curl; }
command -v openssl >/dev/null || { apt-get update && apt-get install -y openssl; }

# ─── Menu (loop, not recursion) ───
show_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}══════════════════════════════════════${NC}"
        echo -e "${CYAN}     Hysteria 2 Manager (Ubuntu)      ${NC}"
        echo -e "${CYAN}══════════════════════════════════════${NC}"
        echo ""
        echo "  1) Install Hysteria 2"
        echo "  2) Show current config & connection info"
        echo "  3) Change password"
        echo "  4) Change port"
        echo "  5) Uninstall Hysteria 2"
        echo "  0) Exit"
        echo ""
        read -rp "Select option: " choice
        case "$choice" in
            1) install_hysteria ;;
            2) show_config ;;
            3) change_password ;;
            4) change_port ;;
            5) uninstall_hysteria ;;
            0) exit 0 ;;
            *) warn "Invalid option" ;;
        esac
    done
}

# ─── Install ───
install_hysteria() {
    if [[ -f "$HYSTERIA_BIN" ]]; then
        warn "Hysteria 2 is already installed."
        read -rp "Reinstall? [y/N]: " ans
        [[ "${ans,,}" != "y" ]] && return
    fi

    info "Downloading latest Hysteria 2..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  HY_ARCH="amd64" ;;
        aarch64) HY_ARCH="arm64" ;;
        armv7l)  HY_ARCH="armv7" ;;
        *) err "Unsupported architecture: $ARCH" ;;
    esac

    DOWNLOAD_URL=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest \
        | grep "browser_download_url.*hysteria-linux-${HY_ARCH}\"" \
        | head -1 | cut -d '"' -f 4)

    [[ -z "$DOWNLOAD_URL" ]] && err "Failed to fetch download URL"

    curl -Lo "$HYSTERIA_BIN" "$DOWNLOAD_URL"
    chmod +x "$HYSTERIA_BIN"
    ok "Binary installed: $HYSTERIA_BIN"

    # Version check
    "$HYSTERIA_BIN" version

    # ─── Gather settings ───
    echo ""
    SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 icanhazip.com || echo "")
    if [[ -z "$SERVER_IP" ]]; then
        warn "Could not detect server IP automatically"
        read -rp "Enter your server IP: " SERVER_IP
        [[ -z "$SERVER_IP" ]] && err "Server IP is required"
    else
        info "Detected server IP: $SERVER_IP"
    fi

    while true; do
        read -rp "Port [443]: " PORT
        PORT=${PORT:-443}
        if validate_port "$PORT"; then
            break
        fi
        warn "Invalid port. Enter a number between 1 and 65535."
    done

    PASSWORD=$(openssl rand -base64 16)
    read -rp "Password [$PASSWORD]: " INPUT_PW
    PASSWORD=${INPUT_PW:-$PASSWORD}

    OBFS_PASSWORD=$(openssl rand -hex 8)
    read -rp "Obfs password (salamander) [$OBFS_PASSWORD]: " INPUT_OBFS
    OBFS_PASSWORD=${INPUT_OBFS:-$OBFS_PASSWORD}

    read -rp "Multi-port range (e.g. 20000-40000) [none]: " MPORT_RANGE

    # ─── Self-signed certificate ───
    info "Generating self-signed certificate..."
    mkdir -p "$HYSTERIA_DIR"
    openssl ecparam -genkey -name prime256v1 -out "$HYSTERIA_DIR/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$HYSTERIA_DIR/key.pem" \
        -out "$HYSTERIA_DIR/cert.pem" -subj "/CN=web.max.ru" 2>/dev/null
    ok "Certificate generated"

    # ─── Config ───
    cat > "$HYSTERIA_DIR/config.yaml" <<EOF
listen: :${PORT}

tls:
  cert: ${HYSTERIA_DIR}/cert.pem
  key: ${HYSTERIA_DIR}/key.pem

auth:
  type: password
  password: ${PASSWORD}

obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://web.max.ru
    rewriteHost: true
EOF
    ok "Config written: $HYSTERIA_DIR/config.yaml"

    # ─── Systemd service ───
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
ExecStart=${HYSTERIA_BIN} server -c ${HYSTERIA_DIR}/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now hysteria-server
    ok "Service started and enabled"

    # ─── Multi-port iptables redirect ───
    if [[ -n "$MPORT_RANGE" ]]; then
        setup_multiport_redirect "$MPORT_RANGE" "$PORT"
    fi

    # ─── Firewall ───
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${PORT}/udp" >/dev/null 2>&1 && info "UFW rule added: ${PORT}/udp"
        ufw allow "${PORT}/tcp" >/dev/null 2>&1 && info "UFW rule added: ${PORT}/tcp"
        if [[ -n "$MPORT_RANGE" ]]; then
            ufw allow "${MPORT_RANGE}/udp" >/dev/null 2>&1 && info "UFW rule added: ${MPORT_RANGE}/udp"
        fi
    fi

    # ─── Print connection info ───
    print_connection_info "$SERVER_IP" "$PORT" "$PASSWORD" "$OBFS_PASSWORD" "$MPORT_RANGE"
    echo ""
}

# ─── Multi-port helpers ───
setup_multiport_redirect() {
    local mport_range="$1" port="$2"
    local iface
    iface=$(detect_iface)

    info "Setting up multi-port redirect: ${mport_range} -> ${port}"
    if [[ -n "$iface" ]]; then
        iptables  -t nat -A PREROUTING -i "$iface" -p udp --dport "${mport_range}" -j REDIRECT --to-ports "${port}" 2>/dev/null || true
        ip6tables -t nat -A PREROUTING -i "$iface" -p udp --dport "${mport_range}" -j REDIRECT --to-ports "${port}" 2>/dev/null || true
    else
        warn "Could not detect network interface, using all interfaces"
        iptables  -t nat -A PREROUTING -p udp --dport "${mport_range}" -j REDIRECT --to-ports "${port}" 2>/dev/null || true
        ip6tables -t nat -A PREROUTING -p udp --dport "${mport_range}" -j REDIRECT --to-ports "${port}" 2>/dev/null || true
    fi

    save_iptables
    ok "Multi-port redirect configured"
}

remove_multiport_redirect() {
    local port="$1"
    # Remove all PREROUTING rules that redirect to this port
    local rule_num
    while rule_num=$(iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null \
            | grep "redir ports ${port}$" | head -1 | awk '{print $1}'); do
        [[ -z "$rule_num" ]] && break
        iptables -t nat -D PREROUTING "$rule_num" 2>/dev/null || break
    done
    while rule_num=$(ip6tables -t nat -L PREROUTING --line-numbers -n 2>/dev/null \
            | grep "redir ports ${port}$" | head -1 | awk '{print $1}'); do
        [[ -z "$rule_num" ]] && break
        ip6tables -t nat -D PREROUTING "$rule_num" 2>/dev/null || break
    done
    save_iptables
}

save_iptables() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save 2>/dev/null || true
    else
        apt-get install -y iptables-persistent 2>/dev/null || true
        netfilter-persistent save 2>/dev/null || true
    fi
}

# ─── Show config ───
show_config() {
    if [[ ! -f "$HYSTERIA_DIR/config.yaml" ]]; then
        warn "Hysteria 2 is not installed"
        return
    fi

    local server_ip port password obfs_password mport_range
    server_ip=$(curl -s4 ifconfig.me || echo "YOUR_IP")
    port=$(config_get_port)
    password=$(config_get_auth_password)
    obfs_password=$(config_get_obfs_password)
    # Detect multi-port from iptables
    mport_range=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "redir ports ${port}" | grep -oP 'udp dpts?:\K[\d:]+' | tr ':' '-' || echo "")

    echo ""
    info "Service status:"
    systemctl status hysteria-server --no-pager -l 2>/dev/null || true

    print_connection_info "$server_ip" "$port" "$password" "$obfs_password" "$mport_range"
    echo ""
}

# ─── Change password ───
change_password() {
    if [[ ! -f "$HYSTERIA_DIR/config.yaml" ]]; then
        warn "Hysteria 2 is not installed"
        return
    fi

    read -rp "New password: " NEW_PW
    [[ -z "$NEW_PW" ]] && warn "Password cannot be empty" && return

    # Replace only the auth password (the line after "type: password"), not the obfs one
    awk -v newpw="$NEW_PW" '
        /^auth:/ { in_auth=1 }
        /^[a-z]/ && !/^auth:/ { in_auth=0 }
        in_auth && /^  password:/ {
            print "  password: " newpw
            next
        }
        { print }
    ' "$HYSTERIA_DIR/config.yaml" > "$HYSTERIA_DIR/config.yaml.tmp" \
        && mv "$HYSTERIA_DIR/config.yaml.tmp" "$HYSTERIA_DIR/config.yaml"

    systemctl restart hysteria-server
    ok "Password changed and service restarted"
}

# ─── Change port ───
change_port() {
    if [[ ! -f "$HYSTERIA_DIR/config.yaml" ]]; then
        warn "Hysteria 2 is not installed"
        return
    fi

    local old_port new_port mport_range
    old_port=$(config_get_port)

    while true; do
        read -rp "New port [$old_port]: " new_port
        new_port=${new_port:-$old_port}
        if validate_port "$new_port"; then
            break
        fi
        warn "Invalid port. Enter a number between 1 and 65535."
    done

    sed -i "s|^listen: :.*|listen: :${new_port}|" "$HYSTERIA_DIR/config.yaml"

    # Update UFW rules
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${old_port}/udp" >/dev/null 2>&1 || true
        ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
        ufw allow "${new_port}/udp" >/dev/null 2>&1
        ufw allow "${new_port}/tcp" >/dev/null 2>&1
    fi

    # Update multi-port iptables redirect if present
    mport_range=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "redir ports ${old_port}" | grep -oP 'udp dpts?:\K[\d:]+' | tr ':' '-' || echo "")
    if [[ -n "$mport_range" ]]; then
        info "Updating multi-port redirect: ${mport_range} -> ${new_port}"
        remove_multiport_redirect "$old_port"
        setup_multiport_redirect "$mport_range" "$new_port"
    fi

    systemctl restart hysteria-server
    ok "Port changed to ${new_port} and service restarted"
}

# ─── Uninstall ───
uninstall_hysteria() {
    read -rp "Are you sure? This will remove Hysteria 2 completely. [y/N]: " ans
    [[ "${ans,,}" != "y" ]] && return

    # Get port before removing config, to clean up iptables
    local port=""
    if [[ -f "$HYSTERIA_DIR/config.yaml" ]]; then
        port=$(config_get_port || echo "")
    fi

    systemctl stop hysteria-server 2>/dev/null || true
    systemctl disable hysteria-server 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    # Clean up iptables multi-port rules
    if [[ -n "$port" ]]; then
        remove_multiport_redirect "$port"
        # Clean up UFW rules
        if command -v ufw >/dev/null 2>&1; then
            ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
            ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
        fi
    fi

    rm -f "$HYSTERIA_BIN"
    rm -rf "$HYSTERIA_DIR"

    ok "Hysteria 2 has been completely removed"
    exit 0
}

# ─── Connection info ───
print_connection_info() {
    local ip="$1" port="$2" pw="$3" obfs_pw="$4" mport="$5"

    # URL-encode passwords for safe URI
    local pw_enc obfs_enc
    pw_enc=$(urlencode "$pw")
    obfs_enc=$(urlencode "$obfs_pw")

    local PARAMS="insecure=1&sni=web.max.ru&obfs=salamander&obfs-password=${obfs_enc}"
    [[ -n "$mport" ]] && PARAMS="mport=${mport}&${PARAMS}"
    local URI="hy2://${pw_enc}@${ip}:${port}?${PARAMS}#Hysteria2"

    echo ""
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    echo -e "${GREEN}       Connection Information         ${NC}"
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    echo -e "  Server:      ${CYAN}${ip}${NC}"
    echo -e "  Port:        ${CYAN}${port}${NC}"
    echo -e "  Password:    ${CYAN}${pw}${NC}"
    echo -e "  SNI:         ${CYAN}web.max.ru${NC}"
    echo -e "  Insecure:    ${CYAN}true${NC} (self-signed cert)"
    echo -e "  Obfs:        ${CYAN}salamander${NC}"
    echo -e "  Obfs pass:   ${CYAN}${obfs_pw}${NC}"
    [[ -n "$mport" ]] && echo -e "  Multi-port:  ${CYAN}${mport}${NC}"
    echo ""
    echo -e "  ${YELLOW}URI (copy into client):${NC}"
    echo -e "  ${GREEN}${URI}${NC}"
    echo -e "${GREEN}══════════════════════════════════════${NC}"
}

# ─── Entry point ───
show_menu
