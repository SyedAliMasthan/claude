#!/bin/bash
###############################################################################
# Installer for Linux Health Check v3.0 - Banking Environment
###############################################################################
set -e

echo "================================================"
echo " Linux Health & Security Check - Installer v3.0"
echo " Oracle Linux 8 / 9 / 10 (RHEL-compatible)"
echo "================================================"
echo ""

[[ $(id -u) -ne 0 ]] && echo "ERROR: Must run as root." && exit 1

OS_RELEASE=$(cat /etc/oracle-release 2>/dev/null || cat /etc/redhat-release 2>/dev/null)
echo "Detected OS: ${OS_RELEASE}"
echo ""

# [1] Dependency check - WARN ONLY, no auto-install
echo "[1/5] Checking prerequisites (warn only)..."
MISSING=0
for pkg in sysstat bc nfs-utils lsof net-tools iproute audit aide openssl; do
    if rpm -q "$pkg" &>/dev/null; then
        printf "  %-20s [OK]\n" "$pkg"
    else
        printf "  %-20s [MISSING] - install manually: yum install -y %s\n" "$pkg" "$pkg"
        MISSING=$((MISSING+1))
    fi
done
echo ""
if (( MISSING > 0 )); then
    echo "  WARNING: ${MISSING} package(s) missing. Some checks will be skipped."
    echo "  Script will still run but with reduced coverage."
    echo ""
fi

# [2] Create report directory
echo "[2/5] Creating report directory..."
mkdir -p /root/Linux_health
chmod 750 /root/Linux_health
echo "  Done: /root/Linux_health"

# [3] Deploy script
echo "[3/5] Deploying health check script..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "${SCRIPT_DIR}/linux_health_check_v3.sh" /usr/local/bin/linux_health_check.sh
chmod 750 /usr/local/bin/linux_health_check.sh
echo "  Installed: /usr/local/bin/linux_health_check.sh"

# [4] Deploy systemd units (cron-free)
echo "[4/5] Deploying systemd timer..."
cp "${SCRIPT_DIR}/linux-health-check.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/linux-health-check.timer" /etc/systemd/system/
chmod 644 /etc/systemd/system/linux-health-check.service
chmod 644 /etc/systemd/system/linux-health-check.timer
systemctl daemon-reload
systemctl enable --now linux-health-check.timer
echo "  Done."

# [5] Verify
echo "[5/5] Verification..."
echo ""
echo "  Timer status:"
systemctl status linux-health-check.timer --no-pager 2>/dev/null | head -5 || true
echo ""
echo "  Next run:"
systemctl list-timers linux-health-check.timer --no-pager 2>/dev/null || true
echo ""

echo "================================================"
echo " Installation Complete!"
echo "================================================"
echo ""
echo " Schedule     : Daily 06:00 AM (systemd timer)"
echo " Reports      : /root/Linux_health/"
echo " Manual run   : /usr/local/bin/linux_health_check.sh"
echo " Timer check  : systemctl list-timers linux-health-check.timer"
echo " Logs         : journalctl -u linux-health-check.service"
echo ""
echo " CONFIGURE: Edit /usr/local/bin/linux_health_check.sh"
echo "   - EMAIL_RECIPIENTS  (line ~36)"
echo "   - BANK_NAME         (line ~42)"
echo "   - THRESH_* values   (lines ~17-30)"
echo "   - CERT_SCAN_PATHS   (line ~75)"
echo "   - BACKUP_AGENTS     (line ~80)"
echo ""
