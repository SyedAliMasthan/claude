#!/bin/bash
###############################################################################
# Installer for Linux Health Check - Banking Environment
# Run as: bash install_health_check.sh
###############################################################################

set -e

echo "=============================================="
echo " Linux Health Check - Installer"
echo " Compatible: Oracle Linux 8, 9, 10"
echo "=============================================="
echo ""

# Check root
if [[ $(id -u) -ne 0 ]]; then
    echo "ERROR: Must run as root."
    exit 1
fi

# Detect OS
OS_RELEASE=$(cat /etc/oracle-release 2>/dev/null || cat /etc/redhat-release 2>/dev/null)
echo "Detected OS: ${OS_RELEASE}"

# Pre-requisites
echo ""
echo "[1/6] Installing prerequisites..."
yum install -y sysstat bc nfs-utils 2>/dev/null || dnf install -y sysstat bc nfs-utils 2>/dev/null
echo "      Done."

# Enable sysstat
echo "[2/6] Enabling sysstat for SAR data collection..."
systemctl enable --now sysstat
echo "      Done."

# Create report directory
echo "[3/6] Creating report directory..."
mkdir -p /root/Linux_health
chmod 750 /root/Linux_health
echo "      Done."

# Deploy script
echo "[4/6] Deploying health check script..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "${SCRIPT_DIR}/linux_health_check.sh" /usr/local/bin/linux_health_check.sh
chmod 750 /usr/local/bin/linux_health_check.sh
echo "      Installed: /usr/local/bin/linux_health_check.sh"

# Deploy systemd units
echo "[5/6] Deploying systemd timer (cron-free scheduling)..."
cp "${SCRIPT_DIR}/linux-health-check.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/linux-health-check.timer" /etc/systemd/system/
chmod 644 /etc/systemd/system/linux-health-check.service
chmod 644 /etc/systemd/system/linux-health-check.timer
systemctl daemon-reload
systemctl enable --now linux-health-check.timer
echo "      Done."

# Verify
echo "[6/6] Verification..."
echo ""
echo "  Timer status:"
systemctl status linux-health-check.timer --no-pager 2>/dev/null | head -5
echo ""
echo "  Next run:"
systemctl list-timers linux-health-check.timer --no-pager 2>/dev/null
echo ""

echo "=============================================="
echo " Installation Complete!"
echo "=============================================="
echo ""
echo " Schedule    : Daily at 06:00 AM (systemd timer)"
echo " Reports     : /root/Linux_health/"
echo " Manual run  : /usr/local/bin/linux_health_check.sh"
echo " Timer check : systemctl list-timers linux-health-check.timer"
echo " Logs        : journalctl -u linux-health-check.service"
echo ""
echo " IMPORTANT: Edit /usr/local/bin/linux_health_check.sh to configure:"
echo "   - Email recipients (EMAIL_RECIPIENTS)"
echo "   - Threshold values (THRESH_CPU, THRESH_MEMORY, etc.)"
echo "   - Bank name (BANK_NAME)"
echo "   - Salt event settings (SALT_EVENT_TAG)"
echo ""
