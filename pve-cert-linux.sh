#!/usr/bin/env bash
# ============================================================
# pve-cert-linux.sh  —  Proxmox VE Client Certificate Installer
# Usage:
#   sudo bash pve-cert-linux.sh       Install cert, update hosts
#   sudo bash pve-cert-linux.sh -u    Uninstall cert, remove hosts entry
# Tested on: Ubuntu 20.04+, Debian 11+
# ============================================================

set -euo pipefail

DISPLAY_NAME="pve-cert-linux.sh"
HOSTS_FILE="/etc/hosts"

echo
echo "====================================================="
echo "  Proxmox VE Client Certificate Installer"
echo "  $DISPLAY_NAME"
echo "====================================================="
echo

# ── Check root ───────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Please run this script with sudo:"
    echo "  sudo bash $DISPLAY_NAME"
    exit 1
fi

# ── Resolve real user (the one who ran sudo) ─────────────────
REAL_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-}")
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    REAL_USER="${SUDO_USER:-root}"
fi
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6 2>/dev/null || echo "/home/$REAL_USER")

DATA_DIR="$REAL_HOME/.local/share/pve-cert"
INFO_FILE="$DATA_DIR/pve-cert-info.txt"

# ── Package install helper ───────────────────────────────────
auto_install_cmd() {
    local CMD="$1"
    local PKG="$2"
    if command -v "$CMD" &>/dev/null; then
        return 0
    fi

    echo "  [INFO] Installing missing dependency: $PKG"

    if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y "$PKG" >/dev/null 2>&1 || {
            echo "[ERROR] Failed to install package: $PKG"
            exit 1
        }
    elif command -v dnf &>/dev/null; then
        dnf install -y "$PKG" >/dev/null 2>&1 || {
            echo "[ERROR] Failed to install package: $PKG"
            exit 1
        }
    elif command -v yum &>/dev/null; then
        yum install -y "$PKG" >/dev/null 2>&1 || {
            echo "[ERROR] Failed to install package: $PKG"
            exit 1
        }
    elif command -v zypper &>/dev/null; then
        zypper --non-interactive install "$PKG" >/dev/null 2>&1 || {
            echo "[ERROR] Failed to install package: $PKG"
            exit 1
        }
    else
        echo "[ERROR] Unsupported package manager. Please install manually: $PKG"
        exit 1
    fi

    command -v "$CMD" &>/dev/null || {
        echo "[ERROR] Command still missing after install: $CMD"
        exit 1
    }
    echo "  [OK] Installed: $PKG"
}

# ── Check / auto-install dependencies ────────────────────────
auto_install_cmd ssh openssh-client
auto_install_cmd scp openssh-client
auto_install_cmd openssl openssl
auto_install_cmd certutil libnss3-tools

mkdir -p "$DATA_DIR"
chown "$REAL_USER" "$DATA_DIR"

# ── Detect system trust store update tool ────────────────────
if command -v update-ca-certificates &>/dev/null; then
    CA_TOOL="update-ca-certificates"
    CA_TRUST_DIR="/usr/local/share/ca-certificates"
elif command -v update-ca-trust &>/dev/null; then
    CA_TOOL="update-ca-trust"
    CA_TRUST_DIR="/etc/pki/ca-trust/source/anchors"
else
    echo "[ERROR] Cannot find update-ca-certificates or update-ca-trust."
    exit 1
fi

# ── NSS import into a single profile dir ──────────────────────
import_nss_profile() {
    local PROFILE_DIR="$1" CERT_FILE="$2" CERT_NICK="$3" LABEL="$4"
    if [[ ! -f "$PROFILE_DIR/cert9.db" ]]; then return 1; fi
    sudo -u "$REAL_USER" certutil -d sql:"$PROFILE_DIR" -D -n "$CERT_NICK" >/dev/null 2>&1 || true
    if sudo -u "$REAL_USER" certutil -d sql:"$PROFILE_DIR" \
            -A -t "CT,," -n "$CERT_NICK" -i "$CERT_FILE" >/dev/null 2>&1; then
        echo "  [OK] Imported to $LABEL: $(basename "$PROFILE_DIR")"
        return 0
    else
        echo "  [WARN] NSS import failed for $LABEL: $(basename "$PROFILE_DIR")"
        return 1
    fi
}

# ── NSS import helper (Firefox / Chrome / Chromium) ──────────
import_nss() {
    local CERT_FILE="$1" CERT_NICK="$2"
    local IMPORTED=0

    # Chrome / Chromium
    local CHROME_DB="$REAL_HOME/.pki/nssdb"
    if [[ -d "$CHROME_DB" ]]; then
        sudo -u "$REAL_USER" certutil -d sql:"$CHROME_DB" -D -n "$CERT_NICK" >/dev/null 2>&1 || true
        if sudo -u "$REAL_USER" certutil -d sql:"$CHROME_DB" \
                -A -t "CT,," -n "$CERT_NICK" -i "$CERT_FILE" >/dev/null 2>&1; then
            echo "  [OK] Imported to Chrome/Chromium NSS store."
            IMPORTED=1
        else
            echo "  [WARN] Chrome NSS import failed."
        fi
    fi

    # Firefox (standard path)
    local FF_BASE="$REAL_HOME/.mozilla/firefox"
    if [[ -d "$FF_BASE" ]]; then
        for PROFILE_DIR in "$FF_BASE"/*/; do
            import_nss_profile "$PROFILE_DIR" "$CERT_FILE" "$CERT_NICK" "Firefox" && IMPORTED=1 || true
        done
    fi

    # Firefox (snap path - Ubuntu 22.04+)
    local FF_SNAP_BASE="$REAL_HOME/snap/firefox/common/.mozilla/firefox"
    if [[ -d "$FF_SNAP_BASE" ]]; then
        for PROFILE_DIR in "$FF_SNAP_BASE"/*/; do
            import_nss_profile "$PROFILE_DIR" "$CERT_FILE" "$CERT_NICK" "Firefox (snap)" && IMPORTED=1 || true
        done
    fi

    if [[ $IMPORTED -eq 0 ]]; then
        echo "  [INFO] No Chrome/Firefox NSS profiles found for: $REAL_USER ($REAL_HOME)"
        echo "  [INFO] Open Chrome/Firefox once, then re-run this script to import."
    fi
}

# ── NSS remove helper ─────────────────────────────────────────
remove_nss() {
    local CERT_NICK="$1"

    local CHROME_DB="$REAL_HOME/.pki/nssdb"
    if [[ -d "$CHROME_DB" ]]; then
        sudo -u "$REAL_USER" certutil -d sql:"$CHROME_DB" \
            -D -n "$CERT_NICK" >/dev/null 2>&1 && \
            echo "  [OK] Removed from Chrome/Chromium NSS store." || true
    fi

    local FF_BASE="$REAL_HOME/.mozilla/firefox"
    if [[ -d "$FF_BASE" ]]; then
        for PROFILE_DIR in "$FF_BASE"/*/; do
            if [[ -f "$PROFILE_DIR/cert9.db" ]]; then
                sudo -u "$REAL_USER" certutil -d sql:"$PROFILE_DIR" \
                    -D -n "$CERT_NICK" >/dev/null 2>&1 && \
                    echo "  [OK] Removed from Firefox profile: $(basename "$PROFILE_DIR")" || true
            fi
        done
    fi

    local FF_SNAP_BASE="$REAL_HOME/snap/firefox/common/.mozilla/firefox"
    if [[ -d "$FF_SNAP_BASE" ]]; then
        for PROFILE_DIR in "$FF_SNAP_BASE"/*/; do
            if [[ -f "$PROFILE_DIR/cert9.db" ]]; then
                sudo -u "$REAL_USER" certutil -d sql:"$PROFILE_DIR" \
                    -D -n "$CERT_NICK" >/dev/null 2>&1 && \
                    echo "  [OK] Removed from Firefox (snap) profile: $(basename "$PROFILE_DIR")" || true
            fi
        done
    fi
}

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

    mapfile -t LINES < "$INFO_FILE"
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

        if grep -qi "$R_DNS" "$HOSTS_FILE" 2>/dev/null; then
            sed -i "/# Proxmox VE \[$R_IP\]/d" "$HOSTS_FILE"
            sed -i "/^$R_IP[[:space:]]\+$R_DNS/d" "$HOSTS_FILE"
            echo "  [OK] Removed hosts entry: $R_DNS"
        else
            echo "  [SKIP] No hosts entry for: $R_DNS"
        fi

        local CERT_NAME="pve-ca-${R_IP}.crt"
        if [[ -f "$CA_TRUST_DIR/$CERT_NAME" ]]; then
            rm -f "$CA_TRUST_DIR/$CERT_NAME"
            if [[ "$CA_TOOL" == "update-ca-trust" ]]; then
                update-ca-trust extract
            else
                update-ca-certificates
            fi
            echo "  [OK] CA cert removed from system trust store."
        else
            echo "  [WARN] CA cert not found in $CA_TRUST_DIR. Remove manually if needed."
        fi

        remove_nss "pve-ca-${R_IP}"

        [[ -f "$DATA_DIR/pve-ca-${R_IP}.crt" ]] && rm -f "$DATA_DIR/pve-ca-${R_IP}.crt" && echo "  [OK] Cert file deleted."

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

if [[ -f "$INFO_FILE" ]]; then
    echo "  Currently registered PVE sites:"
    echo "  -----------------------------------"
    awk '{print "    " $1 "  <>  " $2}' "$INFO_FILE"
    echo
fi

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

CERT_FINGER=$(openssl x509 -noout -fingerprint -sha256 -in "$CA_LOCAL" 2>/dev/null | cut -d= -f2)
echo "  [INFO] Cert fingerprint (SHA-256): $CERT_FINGER"
echo

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

if [[ -f "$INFO_FILE" ]]; then
    grep -v "^$PVE_IP " "$INFO_FILE" > "$INFO_FILE.tmp" || true
    mv "$INFO_FILE.tmp" "$INFO_FILE"
fi
echo "$PVE_IP $PVE_DNS $CERT_FINGER" >> "$INFO_FILE"

echo "[Step 4/5] Updating /etc/hosts"
echo "-----------------------------------------------------"

if grep -qi "$PVE_DNS" "$HOSTS_FILE" 2>/dev/null; then
    echo "  [WARN] Entry for $PVE_DNS already exists:"
    grep -i "$PVE_DNS" "$HOSTS_FILE"
    echo
    read -rp "  Overwrite? [y/N]: " OVERWRITE
    if [[ "$OVERWRITE" =~ ^[Yy]$ ]]; then
        sed -i "/# Proxmox VE \[$PVE_IP\]/d" "$HOSTS_FILE"
        sed -i "/^$PVE_IP[[:space:]]\+$PVE_DNS/d" "$HOSTS_FILE"
        echo "  [OK] Old entry removed."
    else
        echo "  [SKIP] Keeping existing entry."
    fi
fi

if ! grep -qi "$PVE_DNS" "$HOSTS_FILE" 2>/dev/null; then
    echo "" >> "$HOSTS_FILE"
    echo "# Proxmox VE [$PVE_IP] - Added by pve-cert-linux.sh" >> "$HOSTS_FILE"
    echo "$PVE_IP    $PVE_DNS" >> "$HOSTS_FILE"
    echo "  [OK] hosts updated: $PVE_IP    $PVE_DNS"
fi
echo

echo "[Step 5/5] Importing CA certificate to trust stores"
echo "-----------------------------------------------------"

CERT_DEST="$CA_TRUST_DIR/pve-ca-${PVE_IP}.crt"
cp "$CA_LOCAL" "$CERT_DEST"
if [[ "$CA_TOOL" == "update-ca-trust" ]]; then
    update-ca-trust extract
else
    update-ca-certificates
fi
echo "  [OK] System trust store updated."
echo

echo "  Importing to browser NSS stores (Firefox / Chrome / Chromium)..."
import_nss "$CA_LOCAL" "pve-ca-${PVE_IP}"
echo

echo "====================================================="
echo "  Setup Complete!"
echo "====================================================="
echo
echo "  PVE IP      : $PVE_IP"
echo "  PVE DNS     : $PVE_DNS"
echo "  Fingerprint : $CERT_FINGER"
echo "  CA cert     : $CA_LOCAL"
echo
echo "  All registered PVE sites:"
echo "  -----------------------------------"
awk '{print "    " $1 "  <>  " $2}' "$INFO_FILE"
echo
echo "  Open browser: https://${PVE_DNS}:8006"
echo
echo "  Uninstall   : sudo bash pve-cert-linux.sh -u"
echo

read -rp "  Open PVE Web UI now? [y/N]: " OPEN_BROWSER
if [[ "$OPEN_BROWSER" =~ ^[Yy]$ ]]; then
    if command -v xdg-open &>/dev/null; then
        if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
            sudo -u "$REAL_USER" \
                DISPLAY="${DISPLAY:-:0}" \
                DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u "$REAL_USER")/bus}" \
                xdg-open "https://${PVE_DNS}:8006" &>/dev/null &
        else
            echo "  [INFO] Could not detect login user. Open manually: https://${PVE_DNS}:8006"
        fi
    else
        echo "  [INFO] xdg-open not found. Open manually: https://${PVE_DNS}:8006"
    fi
fi
