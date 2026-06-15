#!/usr/bin/env bash
# =============================================================
# pve-cert.sh — Proxmox VE Local Certificate Generator
# Usage:
#   bash pve-cert.sh        Install local certificate
#   bash pve-cert.sh -u     Uninstall / restore original cert
# =============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

banner() {
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║     Proxmox VE Local Certificate Generator           ║"
  echo "║     pve-cert.sh                                      ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""
  echo "  Purpose:"
  echo "    Auto-detect PVE IP and FQDN, generate a self-signed"
  echo "    Root CA and node certificate, then install them into"
  echo "    Proxmox VE so browsers trust https://<hostname>:8006"
  echo "    without any certificate warning."
  echo ""
  echo "  Use with pve-cert.bat on Windows to import the CA cert,"
  echo "  update hosts file, and access the Web UI warning-free."
  echo ""
  echo "  Usage:"
  echo "    bash pve-cert.sh        # Install certificate"
  echo "    bash pve-cert.sh -u     # Uninstall / restore backup"
  echo ""
  echo -e "${RESET}"
}

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()   { error "$*"; exit 1; }

check_root() {
  [[ $EUID -eq 0 ]] || die "Please run as root (sudo bash pve-cert.sh)"
}

check_deps() {
  for cmd in openssl hostname ip; do
    command -v "$cmd" &>/dev/null || die "Required tool not found: $cmd"
  done
}

# ── Uninstall ────────────────────────────────────────────────
do_uninstall() {
  echo -e "${BOLD}Uninstall mode — restore original Proxmox certificates${RESET}"
  echo ""

  PVE_SSL_DIR="/etc/pve/local"

  # Find the most recent backup
  BACKUP_PEM=$(ls -t "${PVE_SSL_DIR}/pveproxy-ssl.pem.bak."* 2>/dev/null | head -1 || true)
  BACKUP_KEY=$(ls -t "${PVE_SSL_DIR}/pveproxy-ssl.key.bak."* 2>/dev/null | head -1 || true)

  echo -e "${BOLD}[ Files to be removed ]${RESET}"
  echo "  /root/pve-local-ca.key"
  echo "  /root/pve-local-ca.crt"
  echo "  /root/pve-node.key"
  echo "  /root/pve-node.crt"
  echo "  /root/pve-local-ca.srl"
  echo "  ${PVE_SSL_DIR}/pveproxy-ssl.pem  (custom cert)"
  echo "  ${PVE_SSL_DIR}/pveproxy-ssl.key  (custom key)"
  echo ""

  if [[ -n "$BACKUP_PEM" ]]; then
    echo -e "${BOLD}[ Backup found — will restore ]${RESET}"
    echo "  $BACKUP_PEM"
    echo "  $BACKUP_KEY"
  else
    echo -e "${YELLOW}[ No backup found — will delete custom cert entirely ]${RESET}"
    echo "  Proxmox will regenerate a self-signed cert on next restart."
  fi

  echo ""
  read -rp "$(echo -e "${YELLOW}Proceed with uninstall? [y/N]${RESET} ")" CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

  # Restore backup or remove custom cert
  if [[ -n "$BACKUP_PEM" && -f "$BACKUP_PEM" ]]; then
    cp "$BACKUP_PEM" "${PVE_SSL_DIR}/pveproxy-ssl.pem"
    ok "Restored: ${PVE_SSL_DIR}/pveproxy-ssl.pem"
  else
    rm -f "${PVE_SSL_DIR}/pveproxy-ssl.pem"
    info "Removed: ${PVE_SSL_DIR}/pveproxy-ssl.pem"
  fi

  if [[ -n "$BACKUP_KEY" && -f "$BACKUP_KEY" ]]; then
    cp "$BACKUP_KEY" "${PVE_SSL_DIR}/pveproxy-ssl.key"
    ok "Restored: ${PVE_SSL_DIR}/pveproxy-ssl.key"
  else
    rm -f "${PVE_SSL_DIR}/pveproxy-ssl.key"
    info "Removed: ${PVE_SSL_DIR}/pveproxy-ssl.key"
  fi

  # Remove all backup files
  rm -f "${PVE_SSL_DIR}/pveproxy-ssl.pem.bak."* 2>/dev/null || true
  rm -f "${PVE_SSL_DIR}/pveproxy-ssl.key.bak."* 2>/dev/null || true

  # Remove CA and node cert files
  for f in /root/pve-local-ca.key /root/pve-local-ca.crt \
            /root/pve-local-ca.srl /root/pve-node.key /root/pve-node.crt; do
    if [[ -f "$f" ]]; then
      rm -f "$f"
      info "Removed: $f"
    fi
  done

  # Restart services
  info "Restarting pveproxy / pvedaemon..."
  systemctl restart pveproxy pvedaemon
  sleep 2
  if systemctl is-active --quiet pveproxy; then
    ok "pveproxy restarted successfully!"
  else
    warn "pveproxy may have failed to restart. Run: systemctl status pveproxy"
  fi

  echo ""
  echo -e "${GREEN}Uninstall complete.${RESET}"
  echo ""
  echo "  Proxmox will use the default self-signed certificate."
  echo "  Remember to also run  pve-cert.bat -u  on each Windows client"
  echo "  to remove the hosts entry and CA certificate."
  echo ""
}

# ── Install ──────────────────────────────────────────────────
detect_pve_info() {
  info "Auto-detecting PVE network information..."

  PVE_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  [[ -z "$PVE_IP" ]] && PVE_IP=$(hostname -I | awk '{print $1}')

  PVE_HOSTNAME=$(hostname -s)
  PVE_FQDN=$(hostname -f 2>/dev/null || echo "${PVE_HOSTNAME}.local")
  [[ "$PVE_FQDN" == "$PVE_HOSTNAME" || "$PVE_FQDN" == "localhost" ]] && PVE_FQDN="${PVE_HOSTNAME}.local"

  echo ""
  echo -e "  Detected information:"
  echo -e "  ${BOLD}PVE IP Address :${RESET} ${GREEN}${PVE_IP}${RESET}"
  echo -e "  ${BOLD}PVE Hostname   :${RESET} ${GREEN}${PVE_HOSTNAME}${RESET}"
  echo -e "  ${BOLD}PVE FQDN       :${RESET} ${GREEN}${PVE_FQDN}${RESET}"
  echo ""
}

confirm_info() {
  echo -e "${YELLOW}Please confirm or modify the detected information:${RESET}"

  read -rp "  PVE IP Address [${PVE_IP}]: " INPUT_IP
  [[ -n "$INPUT_IP" ]] && PVE_IP="$INPUT_IP"

  read -rp "  PVE DNS Name (clients will use https://<this>:8006) [${PVE_FQDN}]: " INPUT_FQDN
  [[ -n "$INPUT_FQDN" ]] && PVE_FQDN="$INPUT_FQDN"

  echo ""
}

ask_proceed() {
  echo -e "${BOLD}The following actions will be performed:${RESET}"
  echo "  1. Create a local Root CA certificate (valid 10 years)"
  echo "  2. Create a Proxmox node certificate with SAN:"
  echo "     DNS: ${PVE_FQDN}"
  echo "     IP : ${PVE_IP}"
  echo "  3. Install certificate to /etc/pve/local/"
  echo "  4. Restart pveproxy / pvedaemon services"
  echo ""
  read -rp "$(echo -e "${YELLOW}Proceed? [y/N]${RESET} ")" CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "Aborted by user."; exit 0; }
}

generate_ca() {
  info "Generating Root CA certificate..."
  CA_KEY="/root/pve-local-ca.key"
  CA_CRT="/root/pve-local-ca.crt"

  if [[ -f "$CA_CRT" ]]; then
    warn "CA certificate already exists: $CA_CRT"
    read -rp "$(echo -e "${YELLOW}Regenerate CA? (N to reuse existing CA) [y/N]${RESET} ")" REGEN_CA
    if [[ ! "$REGEN_CA" =~ ^[Yy]$ ]]; then
      ok "Reusing existing CA certificate."
      return
    fi
  fi

  openssl genrsa -out "$CA_KEY" 4096 2>/dev/null
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 3650 \
    -out "$CA_CRT" \
    -subj "/C=TW/O=PVELocalCA/CN=Proxmox VE Local Root CA (${PVE_HOSTNAME})" \
    2>/dev/null
  chmod 600 "$CA_KEY"
  ok "Root CA certificate created: $CA_CRT"
}

generate_node_cert() {
  info "Generating node certificate (with SAN)..."
  NODE_KEY="/root/pve-node.key"
  NODE_CSR="/root/pve-node.csr"
  NODE_CRT="/root/pve-node.crt"

  openssl genrsa -out "$NODE_KEY" 2048 2>/dev/null
  openssl req -new -key "$NODE_KEY" \
    -out "$NODE_CSR" \
    -subj "/CN=${PVE_FQDN}" \
    2>/dev/null

  SAN_CONF=$(mktemp)
  cat > "$SAN_CONF" <<EOF
subjectAltName=DNS:${PVE_FQDN},IP:${PVE_IP}
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF

  openssl x509 -req -in "$NODE_CSR" \
    -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$NODE_CRT" -days 825 -sha256 \
    -extfile "$SAN_CONF" \
    2>/dev/null

  rm -f "$SAN_CONF" "$NODE_CSR"
  chmod 600 "$NODE_KEY"
  ok "Node certificate created: $NODE_CRT"
}

verify_cert() {
  info "Verifying SAN entries in the certificate..."
  SAN_LINE=$(openssl x509 -in "$NODE_CRT" -text -noout 2>/dev/null | grep -A1 "Subject Alt" | tail -1)
  echo -e "  SAN content: ${GREEN}${SAN_LINE}${RESET}"
  if echo "$SAN_LINE" | grep -q "IP Address:${PVE_IP}"; then
    ok "IP SAN verified successfully!"
  else
    warn "IP SAN not detected — certificate still works via DNS name."
  fi
}

install_cert() {
  info "Installing certificate to Proxmox..."
  PVE_SSL_DIR="/etc/pve/local"

  TS=$(date +%Y%m%d%H%M%S)
  [[ -f "${PVE_SSL_DIR}/pveproxy-ssl.pem" ]] && \
    cp "${PVE_SSL_DIR}/pveproxy-ssl.pem" "${PVE_SSL_DIR}/pveproxy-ssl.pem.bak.${TS}"
  [[ -f "${PVE_SSL_DIR}/pveproxy-ssl.key" ]] && \
    cp "${PVE_SSL_DIR}/pveproxy-ssl.key" "${PVE_SSL_DIR}/pveproxy-ssl.key.bak.${TS}"

  cp "$NODE_CRT" "${PVE_SSL_DIR}/pveproxy-ssl.pem"
  cp "$NODE_KEY" "${PVE_SSL_DIR}/pveproxy-ssl.key"
  ok "Certificate installed to ${PVE_SSL_DIR}"
}

restart_services() {
  info "Restarting pveproxy / pvedaemon..."
  systemctl restart pveproxy pvedaemon
  sleep 2
  if systemctl is-active --quiet pveproxy; then
    ok "pveproxy restarted successfully!"
  else
    warn "pveproxy may have failed to restart. Run: systemctl status pveproxy"
  fi
}

show_summary() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
  echo -e "${CYAN}║            Certificate Setup Summary                 ║${RESET}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "${BOLD}[ Certificate Details ]${RESET}"

  SUBJECT=$(openssl x509    -in "$NODE_CRT" -noout -subject    2>/dev/null | sed 's/subject=//')
  ISSUER=$(openssl x509     -in "$NODE_CRT" -noout -issuer     2>/dev/null | sed 's/issuer=//')
  NOT_BEFORE=$(openssl x509 -in "$NODE_CRT" -noout -startdate  2>/dev/null | sed 's/notBefore=//')
  NOT_AFTER=$(openssl x509  -in "$NODE_CRT" -noout -enddate    2>/dev/null | sed 's/notAfter=//')
  FINGERPRINT=$(openssl x509 -in "$NODE_CRT" -noout -fingerprint -sha256 2>/dev/null | sed 's/SHA256 Fingerprint=//')
  SAN_FULL=$(openssl x509   -in "$NODE_CRT" -text  -noout 2>/dev/null | grep -A1 "Subject Alt" | tail -1 | xargs)

  printf "  %-18s %s\n" "Subject:"            "$SUBJECT"
  printf "  %-18s %s\n" "Issuer:"             "$ISSUER"
  printf "  %-18s %s\n" "Valid From:"         "$NOT_BEFORE"
  printf "  %-18s %s\n" "Valid Until:"        "$NOT_AFTER"
  printf "  %-18s %s\n" "SAN:"                "$SAN_FULL"
  printf "  %-18s %s\n" "SHA256 Fingerprint:" "$FINGERPRINT"

  echo ""
  echo -e "${BOLD}[ File Locations ]${RESET}"
  printf "  %-35s %s\n" "Root CA cert (distribute to clients):" "$CA_CRT"
  printf "  %-35s %s\n" "Root CA private key:"                  "$CA_KEY"
  printf "  %-35s %s\n" "Node certificate:"                     "/etc/pve/local/pveproxy-ssl.pem"
  printf "  %-35s %s\n" "Node private key:"                     "/etc/pve/local/pveproxy-ssl.key"

  echo ""
  echo -e "${BOLD}[ Next Steps on Client Machines ]${RESET}"
  echo -e "  1. Download the CA certificate from PVE:"
  echo -e "     ${YELLOW}scp root@${PVE_IP}:${CA_CRT} ./pve-local-ca.crt${RESET}"
  echo ""
  echo -e "  2. Add this entry to the client's hosts file:"
  echo -e "     ${YELLOW}${PVE_IP}  ${PVE_FQDN}${RESET}"
  echo ""
  echo -e "  3. After installing the CA cert, open in browser:"
  echo -e "     ${GREEN}https://${PVE_FQDN}:8006${RESET}"
  echo ""
  echo -e "  -> Run ${BOLD}pve-cert.bat${RESET} on Windows to do all steps automatically!"
  echo -e "  -> Run ${BOLD}pve-cert.bat -u${RESET} to uninstall on Windows clients."
  echo -e "  -> Run ${BOLD}pve-cert.sh -u${RESET} to uninstall on this PVE server."
  echo ""
  echo -e "${GREEN}Done!${RESET}"
}

# ── Entry point ──────────────────────────────────────────────
banner
check_root
check_deps

if [[ "${1:-}" == "-u" ]]; then
  do_uninstall
  exit 0
fi

detect_pve_info
confirm_info
ask_proceed
generate_ca
generate_node_cert
verify_cert
install_cert
restart_services
show_summary
