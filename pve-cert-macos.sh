#!/usr/bin/env bash
# ============================================================
# pve-cert-macos.sh  —  Proxmox VE Client Certificate Installer
# Usage:
#   sudo bash pve-cert-macos.sh       Install cert, update hosts
#   sudo bash pve-cert-macos.sh -u    Uninstall cert, remove hosts entry
# Tested on: macOS 12 Monterey+
# ============================================================

set -euo pipefail

DISPLAY_NAME="pve-cert-macos.sh"
DATA_DIR="$HOME/Library/Application Support/pve-cert"
INFO_FILE="$DATA_DIR/pve-cert-info.txt"
HOSTS_FILE="/etc/hosts"

echo
echo "====================================================="
echo "  Proxmox VE Client Certificate Installer"
echo "  $DISPLAY_NAME"
echo "====================================================="
echo

# ── Check root ────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Please run this script with sudo:"
    echo "  sudo bash $DISPLAY_NAME"
    exit 1
fi

# ── Check dependencies ─────────────────────────────────────
for cmd in ssh scp openssl security; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[ERROR] Required command not found: $cmd"
        echo "  ssh/scp/openssl are included with macOS."
        echo "  'security' is a built-in macOS tool — if missing, your system may need repair."
        exit 1
    fi
done

mkdir -p "$DATA_DIR"

# ============================================================
#  UNINSTALL MODE
# ============================================================
if [[ "${1:-}" == "-u" ]]; then
    echo "[Uninstall Mode] Removing PVE certificate and hosts entry"
    echo "-----------------------------------------------------"
    echo

    if [[ ! -f "$INFO_FILE" ]]; then
        echo "  No registered sites found."
        exit 0
    fi

    # Read info file into array (bash 3.2 compatible)
    LINES=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && LINES+=("$line")
    done < "$INFO_FILE"
    SITE_COUNT=${#LINES[@]}

    if [[ $SITE_COUNT -eq 0 ]]; then
        echo "  No registered sites found."
        exit 0
    fi

    echo "  Registered PVE sites:"
    echo "  -----------------------------------"
    for i in "${!LINES[@]}"; do
        IP=$(echo "${LINES[$i]}" | awk '{print $1}')
        DNS=$(echo "${LINES[$i]}" | awk '{print $2}')
        echo "    [$((i+1))]  $IP  <>  $DNS"
    done
    echo "    [0]  Remove ALL"
    echo
    read -rp "  Select [1-$SITE_COUNT, 0=all]: " CHOICE

    remove_one() {
        local R_IP="$1" R_DNS="$2" R_FINGER="$3"
        echo
        echo "  --- Removing: $R_IP $R_DNS ---"

        # Remove from /etc/hosts (BSD sed: no \b, match by IP+DNS pattern)
        if grep -qi "$R_DNS" "$HOSTS_FILE" 2>/dev/null; then
            sed -i '' "/# Proxmox VE \[$R_IP\]/d" "$HOSTS_FILE"
            sed -i '' "/^$R_IP[[:space:]][[:space:]]*$R_DNS/d" "$HOSTS_FILE"
            echo "  [OK] Removed hosts entry: $R_DNS"
        else
            echo "  [SKIP] No hosts entry for: $R_DNS"
        fi

        # Remove CA cert from Keychain by fingerprint
        if [[ -n "$R_FINGER" ]]; then
            local SHA1
            SHA1=$(echo "$R_FINGER" | tr -d ':' | tr '[:upper:]' '[:lower:]')
            if security delete-certificate -Z "$SHA1" /Library/Keychains/System.keychain 2>/dev/null; then
                echo "  [OK] CA cert removed from Keychain."
            else
                echo "  [WARN] Could not remove cert. Remove manually:"
                echo "  Keychain Access > System > Certificates > delete entry for $R_DNS"
            fi
        else
            echo "  [WARN] No fingerprint saved. Remove cert manually via Keychain Access."
        fi

        # Remove local cert file
        [[ -f "$DATA_DIR/pve-ca-${R_IP}.crt" ]] && rm -f "$DATA_DIR/pve-ca-${R_IP}.crt" && echo "  [OK] Cert file deleted."

        # Remove from info file
        if [[ -n "$R_IP" && -f "$INFO_FILE" ]]; then
            grep -v "^$R_IP " "$INFO_FILE" > "$INFO_FILE.tmp" || true
            mv "$INFO_FILE.tmp" "$INFO_FILE"
        fi
    }

    if [[ "$CHOICE" == "0" ]]; then
        read -rp "  Remove ALL $SITE_COUNT sites? [y/N]: " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
        for LINE in "${LINES[@]}"; do
            remove_one "$(echo "$LINE" | awk '{print $1}')" \
                       "$(echo "$LINE" | awk '{print $2}')" \
                       "$(echo "$LINE" | awk '{print $3}')"
        done
    else
        IDX=$((CHOICE-1))
        LINE="${LINES[$IDX]:-}"
        [[ -z "$LINE" ]] && { echo "  Invalid choice. Aborted."; exit 1; }
        read -rp "  Proceed? [y/N]: " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
        remove_one "$(echo "$LINE" | awk '{print $1}')" \
                   "$(echo "$LINE" | awk '{print $2}')" \
                   "$(echo "$LINE" | awk '{print $3}')"
    fi

    echo
    echo "====================================================="
    echo "  Uninstall Complete!"
    echo "====================================================="
    echo
    echo "  Restart your browser to apply changes."
    echo "  Run pve-cert.sh -u on each PVE server too."
    echo
    exit 0
fi

# ============================================================
#  INSTALL MODE
# ============================================================

# ── Show existing sites ───────────────────────────────────────
if [[ -f "$INFO_FILE" ]]; then
    echo "  Currently registered PVE sites:"
    echo "  -----------------------------------"
    awk '{print "    " $1 "  <>  " $2}' "$INFO_FILE"
    echo
fi

# ── Step 1 ───────────────────────────────────────────────
echo "[Step 1/5] Enter Proxmox VE server information"
echo "-----------------------------------------------------"
echo
read -rp "  PVE IP address [e.g. 192.168.21.60]: " PVE_IP
[[ -z "$PVE_IP" ]] && { echo "[ERROR] IP cannot be empty."; exit 1; }

if [[ -f "$INFO_FILE" ]] && grep -q "^$PVE_IP " "$INFO_FILE"; then
    echo "  [WARN] This IP is already registered."
    echo
    read -rp "  Re-import anyway? [y/N]: " REIMPORT
    [[ "$REIMPORT" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
fi

read -rp "  SSH username [default: root]: " PVE_USER
PVE_USER=${PVE_USER:-root}

echo
echo "  [NOTE] You will be prompted for the SSH password below."
echo

# ── Step 2 ───────────────────────────────────────────────
echo "[Step 2/5] Downloading CA certificate from PVE"
echo "-----------------------------------------------------"

CA_REMOTE="/root/pve-local-ca.crt"
CA_LOCAL="$DATA_DIR/pve-ca-${PVE_IP}.crt"

echo "  Source : ${PVE_USER}@${PVE_IP}:${CA_REMOTE}"
echo "  Dest   : $CA_LOCAL"
echo

if ! scp -o StrictHostKeyChecking=no "${PVE_USER}@${PVE_IP}:${CA_REMOTE}" "$CA_LOCAL"; then
    echo
    echo "[ERROR] Failed to download certificate! Please check:"
    echo "  1. IP address is correct: $PVE_IP"
    echo "  2. SSH credentials are correct"
    echo "  3. pve-cert.sh has been run on PVE"
    echo "  4. PVE firewall allows SSH [port 22]"
    exit 1
fi

echo
echo "  [OK] Certificate downloaded!"
echo

# ── Get cert fingerprint (SHA-1 for Keychain) ────────────────────
CERT_FINGER_SHA256=$(openssl x509 -noout -fingerprint -sha256 -in "$CA_LOCAL" 2>/dev/null | cut -d= -f2)
CERT_FINGER_SHA1=$(openssl x509 -noout -fingerprint -sha1 -in "$CA_LOCAL" 2>/dev/null | cut -d= -f2 | tr -d ':')
echo "  [INFO] Cert fingerprint (SHA-256): $CERT_FINGER_SHA256"
echo

# ── Step 3 ───────────────────────────────────────────────
echo "[Step 3/5] Auto-detecting PVE DNS name via SSH"
echo "-----------------------------------------------------"
echo

PVE_DNS=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${PVE_USER}@${PVE_IP}" 'hostname -f' 2>/dev/null || true)

if [[ -z "$PVE_DNS" ]]; then
    echo "  [WARN] Auto-detection failed."
    read -rp "  PVE DNS name [e.g. proxmox.local]: " PVE_DNS
    [[ -z "$PVE_DNS" ]] && { echo "[ERROR] DNS name cannot be empty."; exit 1; }
fi

echo "  [OK] PVE DNS name: $PVE_DNS"
echo

# ── Save site info ────────────────────────────────────────────
if [[ -f "$INFO_FILE" ]]; then
    grep -v "^$PVE_IP " "$INFO_FILE" > "$INFO_FILE.tmp" || true
    mv "$INFO_FILE.tmp" "$INFO_FILE"
fi
echo "$PVE_IP $PVE_DNS $CERT_FINGER_SHA1" >> "$INFO_FILE"

# ── Step 4 ───────────────────────────────────────────────
echo "[Step 4/5] Updating /etc/hosts"
echo "-----------------------------------------------------"

if grep -qi "$PVE_DNS" "$HOSTS_FILE" 2>/dev/null; then
    echo "  [WARN] Entry for $PVE_DNS already exists:"
    grep -i "$PVE_DNS" "$HOSTS_FILE"
    echo
    read -rp "  Overwrite? [y/N]: " OVERWRITE
    if [[ "$OVERWRITE" =~ ^[Yy]$ ]]; then
        sed -i '' "/# Proxmox VE \[$PVE_IP\]/d" "$HOSTS_FILE"
        sed -i '' "/^$PVE_IP[[:space:]][[:space:]]*$PVE_DNS/d" "$HOSTS_FILE"
        echo "  [OK] Old entry removed."
    else
        echo "  [SKIP] Keeping existing entry."
    fi
fi

if ! grep -qi "$PVE_DNS" "$HOSTS_FILE" 2>/dev/null; then
    echo "" >> "$HOSTS_FILE"
    echo "# Proxmox VE [$PVE_IP] - Added by pve-cert-macos.sh" >> "$HOSTS_FILE"
    echo "$PVE_IP    $PVE_DNS" >> "$HOSTS_FILE"
    echo "  [OK] hosts updated: $PVE_IP    $PVE_DNS"
fi
echo

# ── Step 5 ───────────────────────────────────────────────
echo "[Step 5/5] Importing CA certificate to macOS Keychain"
echo "-----------------------------------------------------"

if security add-trusted-cert -d -r trustRoot \
       -k /Library/Keychains/System.keychain \
       "$CA_LOCAL"; then
    echo "  [OK] CA certificate imported to System Keychain!"
else
    echo "  [ERROR] Import failed. Install manually:"
    echo "  Open Keychain Access > System > File > Import Items"
    echo "  Then right-click the cert > Get Info > Trust > Always Trust"
fi
echo

# ── Summary ──────────────────────────────────────────────
echo "====================================================="
echo "  Setup Complete!"
echo "====================================================="
echo
echo "  PVE IP      : $PVE_IP"
echo "  PVE DNS     : $PVE_DNS"
echo "  Fingerprint : $CERT_FINGER_SHA256"
echo "  CA cert     : $CA_LOCAL"
echo
echo "  All registered PVE sites:"
echo "  -----------------------------------"
awk '{print "    " $1 "  <>  " $2}' "$INFO_FILE"
echo
echo "  Open browser: https://${PVE_DNS}:8006"
echo
echo "  Uninstall   : sudo bash pve-cert-macos.sh -u"
echo

read -rp "  Open PVE Web UI now? [y/N]: " OPEN_BROWSER
if [[ "$OPEN_BROWSER" =~ ^[Yy]$ ]]; then
    open "https://${PVE_DNS}:8006"
fi
