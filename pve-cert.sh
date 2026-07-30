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

  # Find the oldest backup (original PVE factory cert)
  BACKUP_PEM=$(ls -tr "${PVE_SSL_DIR}/pveproxy-ssl.pem.bak."* 2>/dev/null | head -1 || true)
  BACKUP_KEY=$(ls -tr "${PVE_SSL_DIR}/pveproxy-ssl.key.bak."* 2>/dev/null | head -1 || true)

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
  info "Auto-detecting PVE network settings..."

  PVE_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  [[ -z "$PVE_IP" ]] && PVE_IP=$(hostname -I | awk '{print $1}')

  DETECTED_HOSTNAME=$(hostname -s)
  DETECTED_FQDN=$(hostname -f 2>/dev/null || echo "${DETECTED_HOSTNAME}.local")
  [[ "$DETECTED_FQDN" == "$DETECTED_HOSTNAME" || "$DETECTED_FQDN" == "localhost" ]] && DETECTED_FQDN="${DETECTED_HOSTNAME}.local"

  PVE_HOSTNAME="$DETECTED_HOSTNAME"
  PVE_FQDN="$DETECTED_FQDN"

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

  read -rp "  Extra IP addresses for SAN (space-separated, e.g., Tailscale IP) []: " EXTRA_IPS

  echo ""
}

ask_proceed() {
  echo -e "${BOLD}The following actions will be performed:${RESET}"
  echo "  1. Create a local Root CA certificate (valid 10 years)"
  echo "  2. Create a Proxmox node certificate with SAN:"
  echo "     DNS: ${PVE_FQDN}, localhost${DETECTED_HOSTNAME:+, $DETECTED_HOSTNAME}${DETECTED_FQDN:+, $DETECTED_FQDN}"
  echo "     IP : ${PVE_IP}, 127.0.0.1 ${EXTRA_IPS:+ (Extra: $EXTRA_IPS)}"
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
    read -rp "$(echo -e "${YELLOW}Regenerate CA? (N to reuse existing CA, recommended: N) [y/N]${RESET} ")" REGEN_CA
    if [[ ! "$REGEN_CA" =~ ^[Yy]$ ]]; then
      ok "Reusing existing Root CA certificate. (Client devices DO NOT need to re-import CA!)"
      return
    fi
  fi

  openssl genrsa -out "$CA_KEY" 4096 2>/dev/null
  
  local ca_conf
  ca_conf=$(mktemp)
  cat > "$ca_conf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca

[req_distinguished_name]

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
EOF

  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 3650 \
    -out "$CA_CRT" \
    -subj "/C=TW/O=PVELocalCA/CN=Proxmox VE Local Root CA (${PVE_HOSTNAME})" \
    -config "$ca_conf" \
    -extensions v3_ca \
    2>/dev/null

  rm -f "$ca_conf"
  chmod 600 "$CA_KEY"
  chmod 644 "$CA_CRT"
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

  local SAN_DNS="DNS:${PVE_FQDN},DNS:localhost"
  if [[ -n "${DETECTED_HOSTNAME:-}" && "${DETECTED_HOSTNAME}" != "${PVE_FQDN}" ]]; then
    SAN_DNS="${SAN_DNS},DNS:${DETECTED_HOSTNAME}"
  fi
  if [[ -n "${DETECTED_FQDN:-}" && "${DETECTED_FQDN}" != "${PVE_FQDN}" && "${DETECTED_FQDN}" != "${DETECTED_HOSTNAME}" ]]; then
    SAN_DNS="${SAN_DNS},DNS:${DETECTED_FQDN}"
  fi

  local SAN_IPS="IP:${PVE_IP},IP:127.0.0.1"
  for EIP in ${EXTRA_IPS:-}; do
    [[ "$EIP" == "$PVE_IP" || "$EIP" == "127.0.0.1" ]] && continue
    SAN_IPS="${SAN_IPS},IP:${EIP}"
  done

  SAN_CONF=$(mktemp)
  cat > "$SAN_CONF" <<EOF
subjectAltName=${SAN_DNS},${SAN_IPS}
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
  chmod 644 "$NODE_CRT"
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
  # Only backup if an original backup does NOT exist yet (protects PVE factory cert backup)
  if ! ls "${PVE_SSL_DIR}/pveproxy-ssl.pem.bak."* &>/dev/null; then
    [[ -f "${PVE_SSL_DIR}/pveproxy-ssl.pem" ]] && \
      cp "${PVE_SSL_DIR}/pveproxy-ssl.pem" "${PVE_SSL_DIR}/pveproxy-ssl.pem.bak.${TS}"
    [[ -f "${PVE_SSL_DIR}/pveproxy-ssl.key" ]] && \
      cp "${PVE_SSL_DIR}/pveproxy-ssl.key" "${PVE_SSL_DIR}/pveproxy-ssl.key.bak.${TS}"
    ok "Original PVE factory certificate backed up to ${PVE_SSL_DIR}/pveproxy-ssl.pem.bak.${TS}"
  else
    info "Preserving original PVE factory certificate backup."
  fi

  cp "$NODE_CRT" "${PVE_SSL_DIR}/pveproxy-ssl.pem"
  cp "$NODE_KEY" "${PVE_SSL_DIR}/pveproxy-ssl.key"
  ok "Certificate installed to ${PVE_SSL_DIR}"
}

save_config() {
  local CONF_DIR="/etc/pve-cert"
  local CONF_FILE="$CONF_DIR/pve-cert.conf"
  mkdir -p "$CONF_DIR"
  cat > "$CONF_FILE" <<EOF
SERVER_FQDN="${PVE_FQDN}"
SERVER_IP="${PVE_IP}"
PROFILE="pve"
PROXY_PORTS="8006"
PORT_OFFSET="0"
EOF
  chmod 644 "$CONF_FILE"
  ok "Configuration saved to $CONF_FILE"
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

  echo -e "${BOLD}--------------------------------------------${RESET}"
  echo -e "${BOLD}[ Client Device Setup Steps ]${RESET}"
  echo ""
  echo -e "${BOLD}Option A: Automatic Client Script (CLI / Remote) ${GREEN}[Recommended ⭐]${RESET}"
  echo ""
  echo -e "  Execute the client script directly on the client machine:"
  echo -e "     - Windows: ${CYAN}pve-cert-windows.bat -s ${PVE_IP}${RESET}  (as Administrator)"
  echo -e "     - Linux:   ${CYAN}sudo bash pve-cert-linux.sh -s ${PVE_IP}${RESET}"
  echo -e "     - macOS:   ${CYAN}sudo bash pve-cert-macos.sh -s ${PVE_IP}${RESET}"
  echo -e "     (Zero prompt: automatically fetches CA and configures system trust & hosts)"
  echo ""
  echo -e "${BOLD}Option B: Manual Setup${RESET}"
  echo ""
  echo -e "  1. Download Root CA via SCP:"
  echo -e "     SCP:  ${YELLOW}scp -o StrictHostKeyChecking=no root@${PVE_IP}:${CA_CRT} ./pve-local-ca.crt${RESET}"
  echo ""
  echo -e "  2. Add the following entry to client's hosts file:"
  echo -e "     ${YELLOW}${PVE_IP}  ${PVE_FQDN}${RESET}"
  echo ""
  echo -e "  3. Access Proxmox VE Web Console using FQDN or IP:"
  echo -e "     ${GREEN}https://${PVE_FQDN}:8006${RESET}  or  ${GREEN}https://${PVE_IP}:8006${RESET}"
  echo ""
  echo -e "  -> To uninstall on Windows clients: ${BOLD}pve-cert-windows.bat -u${RESET}"
  echo -e "  -> To uninstall on Linux clients:   ${BOLD}sudo bash pve-cert-linux.sh -u${RESET}"
  echo -e "  -> To uninstall on macOS clients:   ${BOLD}sudo bash pve-cert-macos.sh -u${RESET}"
  echo -e "  -> To uninstall on this PVE server: ${BOLD}bash pve-cert.sh -u${RESET}"
  echo ""
  echo -e "${GREEN}Done!${RESET}"
}

do_uninstall_cleanup_config() {
  local CONF_FILE="/etc/pve-cert/pve-cert.conf"
  if [[ -f "$CONF_FILE" ]]; then
    rm -f "$CONF_FILE"
    info "Removed: $CONF_FILE"
  fi
}

check_existing_cert() {
  local NODE_CRT="/etc/pve/local/pveproxy-ssl.pem"
  if [[ ! -f "$NODE_CRT" ]]; then
    NODE_CRT="/root/pve-node.crt"
  fi

  if [[ -f "$NODE_CRT" ]]; then
    echo "An existing Proxmox VE certificate setup is detected."
    echo "-----------------------------------------------------"

    local CERT_SUBJ EXP_DATE EXP_EPOCH NOW_EPOCH DAYS_LEFT=0
    CERT_SUBJ=$(openssl x509 -subject -noout -in "$NODE_CRT" 2>/dev/null | sed -e 's/subject=//' -e 's/.*CN[ =]*//' -e 's/\/.*//' | xargs)
    EXP_DATE=$(openssl x509 -enddate -noout -in "$NODE_CRT" 2>/dev/null | cut -d= -f2)
    EXP_EPOCH=$(date -d "$EXP_DATE" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$EXP_DATE" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    if [[ $EXP_EPOCH -gt 0 ]]; then
      DAYS_LEFT=$(( (EXP_EPOCH - NOW_EPOCH) / 86400 ))
    fi

    local SAN_LINE
    SAN_LINE=$(openssl x509 -in "$NODE_CRT" -text -noout 2>/dev/null | grep -A1 "Subject Alt" | tail -1 | xargs || true)

    echo -e "  ${BOLD}Subject/FQDN :${RESET} ${GREEN}${CERT_SUBJ}${RESET}"
    echo -e "  ${BOLD}Days Left    :${RESET} ${GREEN}${DAYS_LEFT} days${RESET}"
    echo -e "  ${BOLD}SAN Contents :${RESET} ${GREEN}${SAN_LINE}${RESET}"
    echo -e "  ${BOLD}Applied Cert :${RESET} /etc/pve/local/pveproxy-ssl.pem"
    echo ""

    if [[ $DAYS_LEFT -lt 30 ]]; then
      warn "This node certificate is expiring soon ($DAYS_LEFT days left)!"
      echo ""
    fi

    echo "Please choose an action:"
    echo "  [1] Reissue / Renew Proxmox VE SSL certificate"
    echo "  [2] Uninstall and restore original Proxmox VE certificates"
    echo "  [0] Keep existing and exit"
    echo ""

    local choice=""
    while true; do
      read -rp "  Please choose [1, 2, 0]: " choice
      if [[ "$choice" =~ ^[120]$ ]]; then
        break
      fi
      warn "Invalid choice, please try again."
    done

    if [[ "$choice" == "1" ]]; then
      echo ""
      info "Reissuing Proxmox VE SSL Certificate..."
      echo ""
      RENEW_MODE=1
    elif [[ "$choice" == "2" ]]; then
      do_uninstall
      exit 0
    elif [[ "$choice" == "0" ]]; then
      info "Keeping existing certificate. Exiting..."
      exit 0
    fi
  fi
}

# ── Entry point ──────────────────────────────────────────────
banner
check_root
check_deps

if [[ "${1:-}" == "-u" ]]; then
  do_uninstall
  exit 0
fi

check_existing_cert

detect_pve_info
confirm_info
ask_proceed
generate_ca
generate_node_cert
verify_cert
install_cert
save_config
restart_services
show_summary
