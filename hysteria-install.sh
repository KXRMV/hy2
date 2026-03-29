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

# ─── Pre-checks ───
[[ $EUID -ne 0 ]] && err "Run as root: sudo bash <(curl -Ls ...)"

command -v curl  >/dev/null || { apt-get update && apt-get install -y curl; }
command -v openssl >/dev/null || { apt-get update && apt-get install -y openssl; }

# ─── Menu ───
show_menu() {
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
        *) warn "Invalid option"; show_menu ;;
    esac
}

# ─── Install ───
install_hysteria() {
    if [[ -f "$HYSTERIA_BIN" ]]; then
        warn "Hysteria 2 is already installed."
        read -rp "Reinstall? [y/N]: " ans
        [[ "${ans,,}" != "y" ]] && show_menu && return
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
    SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 icanhazip.com || echo "0.0.0.0")
    info "Detected server IP: $SERVER_IP"

    read -rp "Port [443]: " PORT
    PORT=${PORT:-443}

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
        info "Setting up multi-port redirect: ${MPORT_RANGE} -> ${PORT}"
        iptables -t nat -A PREROUTING -i eth0 -p udp --dport "${MPORT_RANGE}" -j REDIRECT --to-ports "${PORT}" 2>/dev/null || true
        ip6tables -t nat -A PREROUTING -i eth0 -p udp --dport "${MPORT_RANGE}" -j REDIRECT --to-ports "${PORT}" 2>/dev/null || true

        # Persist rules
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save 2>/dev/null || true
        else
            apt-get install -y iptables-persistent 2>/dev/null || true
            netfilter-persistent save 2>/dev/null || true
        fi
        ok "Multi-port redirect configured"
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
    show_menu
}

# ─── Show config ───
show_config() {
    if [[ ! -f "$HYSTERIA_DIR/config.yaml" ]]; then
        warn "Hysteria 2 is not installed"
        show_menu
        return
    fi

    SERVER_IP=$(curl -s4 ifconfig.me || echo "YOUR_IP")
    PORT=$(grep -oP '(?<=^listen: :)\d+' "$HYSTERIA_DIR/config.yaml")
    PASSWORD=$(grep -A1 'type: password' "$HYSTERIA_DIR/config.yaml" | grep 'password:' | awk '{print $2}')
    OBFS_PASSWORD=$(grep -A2 'type: salamander' "$HYSTERIA_DIR/config.yaml" | grep 'password:' | awk '{print $2}')
    # Detect multi-port from iptables
    MPORT_RANGE=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "redir ports ${PORT}" | grep -oP 'udp dpts?:\K[\d:]+' | tr ':' '-' || echo "")

    echo ""
    info "Service status:"
    systemctl status hysteria-server --no-pager -l 2>/dev/null || true

    print_connection_info "$SERVER_IP" "$PORT" "$PASSWORD" "$OBFS_PASSWORD" "$MPORT_RANGE"
    echo ""
    show_menu
}

# ─── Change password ───
change_password() {
    if [[ ! -f "$HYSTERIA_DIR/config.yaml" ]]; then
        warn "Hysteria 2 is not installed"
        show_menu
        return
    fi

    read -rp "New password: " NEW_PW
    [[ -z "$NEW_PW" ]] && warn "Password cannot be empty" && show_menu && return

    sed -i "s|^  password:.*|  password: ${NEW_PW}|" "$HYSTERIA_DIR/config.yaml"
    systemctl restart hysteria-server
    ok "Password changed and service restarted"
    show_menu
}

# ─── Change port ───
change_port() {
    if [[ ! -f "$HYSTERIA_DIR/config.yaml" ]]; then
        warn "Hysteria 2 is not installed"
        show_menu
        return
    fi

    OLD_PORT=$(grep -oP '(?<=^listen: :)\d+' "$HYSTERIA_DIR/config.yaml")
    read -rp "New port [$OLD_PORT]: " NEW_PORT
    NEW_PORT=${NEW_PORT:-$OLD_PORT}

    sed -i "s|^listen: :.*|listen: :${NEW_PORT}|" "$HYSTERIA_DIR/config.yaml"

    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${OLD_PORT}/udp" >/dev/null 2>&1 || true
        ufw delete allow "${OLD_PORT}/tcp" >/dev/null 2>&1 || true
        ufw allow "${NEW_PORT}/udp" >/dev/null 2>&1
        ufw allow "${NEW_PORT}/tcp" >/dev/null 2>&1
    fi

    systemctl restart hysteria-server
    ok "Port changed to ${NEW_PORT} and service restarted"
    show_menu
}

# ─── Uninstall ───
uninstall_hysteria() {
    read -rp "Are you sure? This will remove Hysteria 2 completely. [y/N]: " ans
    [[ "${ans,,}" != "y" ]] && show_menu && return

    systemctl stop hysteria-server 2>/dev/null || true
    systemctl disable hysteria-server 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    rm -f "$HYSTERIA_BIN"
    rm -rf "$HYSTERIA_DIR"

    ok "Hysteria 2 has been completely removed"
    exit 0
}

# ─── Connection info ───
print_connection_info() {
    local ip="$1" port="$2" pw="$3" obfs_pw="$4" mport="$5"

    # Build URI with obfuscation and optional multi-port
    local PARAMS="insecure=1&sni=web.max.ru&obfs=salamander&obfs-password=${obfs_pw}"
    [[ -n "$mport" ]] && PARAMS="mport=${mport}&${PARAMS}"
    local URI="hy2://${pw}@${ip}:${port}?${PARAMS}#Hysteria2"

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
