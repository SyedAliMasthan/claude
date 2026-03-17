#!/usr/bin/env bash
###############################################################################
# setup_cron.sh — Configure health check to run 3 times daily
#
# Usage:
#   chmod +x setup_cron.sh
#   ./setup_cron.sh
#
# This will add cron entries to run health checks at:
#   06:00 IST — Morning check
#   14:00 IST — Afternoon check
#   22:00 IST — Night check
#
# To customize email recipients, edit the EMAIL variable below.
###############################################################################

# ── CONFIGURATION — EDIT THESE ──
SCRIPT_PATH="/root/Cluster_health/health_ocp.sh"
KUBECONFIG_PATH="/root/.kube/config"
LOG_DIR="/root/Cluster_health/logs"
EMAIL=""  # e.g. "admin@indianbank.in,team@indianbank.in"
# ── END CONFIGURATION ──

# Create directories
mkdir -p "$LOG_DIR"
mkdir -p /root/Cluster_health

# Ensure script is executable
chmod +x "$SCRIPT_PATH" 2>/dev/null

# Build the cron command
CRON_CMD="$SCRIPT_PATH --kubeconfig $KUBECONFIG_PATH"
if [[ -n "$EMAIL" ]]; then
    CRON_CMD+=" --email \"$EMAIL\""
fi
CRON_CMD+=" >> $LOG_DIR/health_check_\$(date +\\%Y-\\%m-\\%d_\\%H\\%M).log 2>&1"

# Remove existing health check cron entries
crontab -l 2>/dev/null | grep -v 'health_ocp.sh' | grep -v '# OCP-HEALTH-CHECK' > /tmp/cron_clean 2>/dev/null

# Add new entries — 3 times daily IST (06:00, 14:00, 22:00)
cat >> /tmp/cron_clean <<CRONEOF

# OCP-HEALTH-CHECK — Morning 06:00 IST (00:30 UTC)
30 0 * * * $CRON_CMD
# OCP-HEALTH-CHECK — Afternoon 14:00 IST (08:30 UTC)
30 8 * * * $CRON_CMD
# OCP-HEALTH-CHECK — Night 22:00 IST (16:30 UTC)
30 16 * * * $CRON_CMD
CRONEOF

# Install the cron
crontab /tmp/cron_clean
rm -f /tmp/cron_clean

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Cron configured — Health check 3x daily                  ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                            ║"
echo "║   Schedule (IST):                                          ║"
echo "║     06:00 AM — Morning check                               ║"
echo "║     02:00 PM — Afternoon check                             ║"
echo "║     10:00 PM — Night check                                 ║"
echo "║                                                            ║"
echo "║   Reports saved to: /root/Cluster_health/                  ║"
echo "║   Logs saved to:    /root/Cluster_health/logs/             ║"
echo "║   Old reports auto-deleted after 30 days                   ║"
echo "║                                                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Current crontab:"
echo "────────────────"
crontab -l | grep -A1 'OCP-HEALTH'
echo ""
echo "To verify: crontab -l"
echo "To remove: crontab -l | grep -v 'health_ocp\|OCP-HEALTH' | crontab -"
echo "To change times: edit this script and re-run"
echo ""

# Quick test
echo "Running a quick connectivity test..."
if $SCRIPT_PATH --kubeconfig "$KUBECONFIG_PATH" --help &>/dev/null; then
    echo "✔ Script is accessible and executable"
else
    echo "⚠ Script may have issues — check path: $SCRIPT_PATH"
fi
