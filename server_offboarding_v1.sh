#!/bin/bash
#===============================================================================
# Server Offboarding Script - v1 (Matches Onboarding v7)
#
# Steps (reverse of onboarding):
#   1. DSA Agent Stop & Uninstall
#   2. UDAgent Stop & Uninstall
#   3. VRLI Agent Uninstall
#   4. DNF Automatic Disable & Remove
#   5. SIEM Integration Cleanup (rsyslog reset)
#   6. Satellite/Foreman Unregister
#   7. IPA Client Unenroll
#   8. Salt-Minion Uninstall (FINAL)
#
# Usage: sudo bash server_offboarding_v1.sh [-y]
#===============================================================================

set -o pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Config ──────────────────────────────────────────────────────────────────
SALT_MASTER="10.100.204.145"
SATELLITE_SERVER="10.100.27.102"

# ─── Log File ────────────────────────────────────────────────────────────────
LOGFILE="/var/log/server_offboarding_$(hostname -s)_$(date +%Y%m%d_%H%M%S).log"
SUMMARY_FILE="/tmp/offboarding_summary_$(hostname -s).txt"

exec > >(tee -a "$LOGFILE") 2>&1

# ─── Step Results Array ──────────────────────────────────────────────────────
declare -A RESULTS
declare -A STEP_NAMES
STEP_NAMES=(
    [1]="DSA Agent Stop & Uninstall"
    [2]="UDAgent Stop & Uninstall"
    [3]="VRLI Agent Uninstall"
    [4]="DNF Automatic Disable"
    [5]="SIEM Integration Cleanup"
    [6]="Satellite/Foreman Unregister"
    [7]="IPA Client Unenroll"
    [8]="Salt-Minion Uninstall"
)
for i in $(seq 1 8); do RESULTS[$i]="SKIP"; done

# ─── Helper Functions ────────────────────────────────────────────────────────
banner() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} $1${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

ok()   { echo -e "  ${GREEN}[✔ DONE]${NC} $1"; }
fail() { echo -e "  ${RED}[✘ FAIL]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[! WARN]${NC} $1"; }
info() { echo -e "  ${CYAN}[i INFO]${NC} $1"; }
skip() { echo -e "  ${YELLOW}[- SKIP]${NC} $1"; }
sep()  { echo -e "  ${CYAN}──────────────────────────────────────────────────────────${NC}"; }

step_result() {
    local step_num="$1"
    local status="$2"  # PASS, FAIL, SKIP

    RESULTS[$step_num]="$status"
    echo ""
    case "$status" in
        PASS) ok "STEP ${step_num}/8 — ${STEP_NAMES[$step_num]} — ${GREEN}COMPLETED${NC}" ;;
        FAIL) fail "STEP ${step_num}/8 — ${STEP_NAMES[$step_num]} — ${RED}FAILED${NC}" ;;
        SKIP) skip "STEP ${step_num}/8 — ${STEP_NAMES[$step_num]} — ${YELLOW}SKIPPED${NC}" ;;
    esac
    echo ""
}

#===============================================================================
# PRE-FLIGHT CHECKS
#===============================================================================
if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (or with sudo)."
    exit 1
fi

banner "SERVER OFFBOARDING v1"
info "Log file : $LOGFILE"
info "Started  : $(date)"
info "Hostname : $(hostname -f)"

# ─── Confirmation ────────────────────────────────────────────────────────────
if [[ "$1" != "-y" && "$1" != "--yes" ]]; then
    echo ""
    echo -e "  ${RED}${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${RED}${BOLD}║   ⚠  WARNING: SERVER DECOMMISSION / OFFBOARDING              ║${NC}"
    echo -e "  ${RED}${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  This script will:"
    echo "    1. Stop & uninstall DSA Agent (ds_agent)"
    echo "    2. Stop & uninstall UDAgent"
    echo "    3. Uninstall VRLI Agent (VMware Log Insight)"
    echo "    4. Disable DNF Automatic updates"
    echo "    5. Reset rsyslog SIEM configuration"
    echo "    6. Unregister from Satellite/Foreman"
    echo "    7. Unenroll from IPA/IDM domain"
    echo "    8. Uninstall Salt-Minion"
    echo ""
    read -p "  Are you sure you want to proceed? (yes/no): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        info "Offboarding cancelled by user."
        exit 0
    fi
    echo ""
fi

# Initialize summary
> "$SUMMARY_FILE"
echo "Server Offboarding Summary" >> "$SUMMARY_FILE"
echo "==========================" >> "$SUMMARY_FILE"
echo "Hostname: $(hostname -f)" >> "$SUMMARY_FILE"
echo "Date: $(date)" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"


#===============================================================================
# STEP 1/8: DSA AGENT STOP & UNINSTALL
#===============================================================================
banner "STEP 1/8 — DSA AGENT STOP & UNINSTALL"

STEP1_STATUS="SKIP"

if systemctl list-unit-files | grep -q "ds_agent" || rpm -q ds_agent &>/dev/null 2>&1; then
    info "DSA Agent detected, stopping service..."
    
    systemctl stop ds_agent 2>/dev/null
    systemctl disable ds_agent 2>/dev/null
    
    if systemctl is-active ds_agent &>/dev/null; then
        fail "ds_agent service still running"
    else
        ok "ds_agent service stopped"
    fi
    
    info "Uninstalling DSA Agent..."
    if rpm -q ds_agent &>/dev/null; then
        dnf remove -y ds_agent 2>&1 || yum remove -y ds_agent 2>&1
        ok "ds_agent package removed"
    fi
    
    # Cleanup DSA directories
    rm -rf /opt/ds_agent 2>/dev/null
    rm -rf /var/opt/ds_agent 2>/dev/null
    
    STEP1_STATUS="PASS"
    echo "DSA Agent: REMOVED" >> "$SUMMARY_FILE"
else
    skip "DSA Agent not installed"
    echo "DSA Agent: NOT INSTALLED" >> "$SUMMARY_FILE"
fi

step_result 1 "$STEP1_STATUS"


#===============================================================================
# STEP 2/8: UDAGENT STOP & UNINSTALL
#===============================================================================
banner "STEP 2/8 — UDAGENT STOP & UNINSTALL"

STEP2_STATUS="SKIP"

if systemctl list-unit-files | grep -q "udagent" || rpm -q udagent &>/dev/null 2>&1; then
    info "UDAgent detected, stopping service..."
    
    systemctl stop udagent 2>/dev/null
    systemctl disable udagent 2>/dev/null
    
    if systemctl is-active udagent &>/dev/null; then
        fail "udagent service still running"
    else
        ok "udagent service stopped"
    fi
    
    info "Uninstalling UDAgent..."
    if rpm -q udagent &>/dev/null; then
        dnf remove -y udagent 2>&1 || yum remove -y udagent 2>&1
        ok "udagent package removed"
    fi
    
    # Cleanup UDAgent directories
    rm -rf /opt/udagent 2>/dev/null
    rm -rf /var/opt/udagent 2>/dev/null
    rm -rf /etc/udagent 2>/dev/null
    
    STEP2_STATUS="PASS"
    echo "UDAgent: REMOVED" >> "$SUMMARY_FILE"
else
    skip "UDAgent not installed"
    echo "UDAgent: NOT INSTALLED" >> "$SUMMARY_FILE"
fi

step_result 2 "$STEP2_STATUS"


#===============================================================================
# STEP 3/8: VRLI AGENT UNINSTALL
#===============================================================================
banner "STEP 3/8 — VRLI AGENT (VMware Log Insight) UNINSTALL"

STEP3_STATUS="SKIP"

if rpm -qa | grep -qi "VMware-Log-Insight-Agent"; then
    info "VRLI Agent detected, stopping service..."
    
    systemctl stop liagentd 2>/dev/null
    systemctl disable liagentd 2>/dev/null
    
    info "Uninstalling VMware Log Insight Agent..."
    VRLI_PKG=$(rpm -qa | grep -i "VMware-Log-Insight-Agent")
    dnf remove -y "$VRLI_PKG" 2>&1 || yum remove -y "$VRLI_PKG" 2>&1
    
    # Cleanup VRLI directories
    rm -rf /var/lib/loginsight-agent 2>/dev/null
    rm -rf /var/log/loginsight-agent 2>/dev/null
    
    if rpm -qa | grep -qi "VMware-Log-Insight-Agent"; then
        fail "VRLI Agent still installed"
        STEP3_STATUS="FAIL"
    else
        ok "VRLI Agent removed"
        STEP3_STATUS="PASS"
    fi
    echo "VRLI Agent: REMOVED" >> "$SUMMARY_FILE"
else
    skip "VRLI Agent not installed"
    echo "VRLI Agent: NOT INSTALLED" >> "$SUMMARY_FILE"
fi

step_result 3 "$STEP3_STATUS"


#===============================================================================
# STEP 4/8: DNF AUTOMATIC DISABLE & REMOVE
#===============================================================================
banner "STEP 4/8 — DNF AUTOMATIC DISABLE"

STEP4_STATUS="SKIP"

if systemctl list-unit-files | grep -q "dnf-automatic"; then
    info "Stopping dnf-automatic timer..."
    
    systemctl stop dnf-automatic.timer 2>/dev/null
    systemctl disable dnf-automatic.timer 2>/dev/null
    systemctl stop dnf-automatic.service 2>/dev/null
    systemctl disable dnf-automatic.service 2>/dev/null
    
    if systemctl is-active dnf-automatic.timer &>/dev/null; then
        fail "dnf-automatic.timer still active"
    else
        ok "dnf-automatic.timer stopped and disabled"
    fi
    
    info "Removing dnf-automatic package..."
    dnf remove -y dnf-automatic 2>&1 || yum remove -y dnf-automatic 2>&1
    
    # Remove config files
    rm -f /etc/dnf/automatic.conf.bak 2>/dev/null
    
    STEP4_STATUS="PASS"
    echo "DNF Automatic: DISABLED & REMOVED" >> "$SUMMARY_FILE"
else
    skip "dnf-automatic not installed"
    echo "DNF Automatic: NOT INSTALLED" >> "$SUMMARY_FILE"
fi

step_result 4 "$STEP4_STATUS"


#===============================================================================
# STEP 5/8: SIEM INTEGRATION CLEANUP (RSYSLOG)
#===============================================================================
banner "STEP 5/8 — SIEM INTEGRATION CLEANUP"

STEP5_STATUS="SKIP"

info "Checking for SIEM rsyslog configuration..."

# Check for SIEM-specific rsyslog configs
SIEM_CONFIGS=$(find /etc/rsyslog.d/ -name "*siem*" -o -name "*remote*" 2>/dev/null)

if [[ -n "$SIEM_CONFIGS" ]] || grep -rq "@@.*514\|@.*514" /etc/rsyslog.d/ 2>/dev/null; then
    info "SIEM rsyslog configuration found, cleaning up..."
    
    # Remove SIEM-specific config files
    rm -f /etc/rsyslog.d/*siem* 2>/dev/null
    rm -f /etc/rsyslog.d/*remote* 2>/dev/null
    
    # Backup and reset main rsyslog.conf if modified
    if grep -q "# SIEM\|# Salt managed" /etc/rsyslog.conf 2>/dev/null; then
        cp /etc/rsyslog.conf /etc/rsyslog.conf.pre-offboard.bak
        info "Backed up rsyslog.conf"
    fi
    
    # Restart rsyslog to apply changes
    systemctl restart rsyslog 2>/dev/null
    
    if systemctl is-active rsyslog &>/dev/null; then
        ok "rsyslog restarted successfully"
        STEP5_STATUS="PASS"
    else
        warn "rsyslog restart issue - check manually"
        STEP5_STATUS="PASS"
    fi
    echo "SIEM Config: CLEANED" >> "$SUMMARY_FILE"
else
    skip "No SIEM rsyslog configuration found"
    echo "SIEM Config: NOT FOUND" >> "$SUMMARY_FILE"
fi

step_result 5 "$STEP5_STATUS"


#===============================================================================
# STEP 6/8: SATELLITE/FOREMAN UNREGISTER
#===============================================================================
banner "STEP 6/8 — SATELLITE/FOREMAN UNREGISTER"

STEP6_STATUS="SKIP"

# Check if registered to Satellite
if command -v subscription-manager &>/dev/null && subscription-manager identity &>/dev/null 2>&1; then
    info "System registered to Satellite, unregistering..."
    
    # Unregister from subscription-manager
    subscription-manager unregister 2>&1
    subscription-manager clean 2>&1
    
    ok "Unregistered from subscription-manager"
    
    # Remove katello-ca-consumer if present
    if rpm -q katello-ca-consumer* &>/dev/null 2>&1; then
        info "Removing Katello CA certificate..."
        KATELLO_PKG=$(rpm -qa | grep katello-ca-consumer)
        dnf remove -y "$KATELLO_PKG" 2>&1 || yum remove -y "$KATELLO_PKG" 2>&1
        ok "Katello CA removed"
    fi
    
    STEP6_STATUS="PASS"
    echo "Satellite: UNREGISTERED" >> "$SUMMARY_FILE"
    
elif [[ -f /etc/rhsm/rhsm.conf ]]; then
    info "RHSM config found but not registered, cleaning..."
    subscription-manager clean 2>&1
    STEP6_STATUS="PASS"
    echo "Satellite: CLEANED" >> "$SUMMARY_FILE"
else
    skip "System not registered to Satellite"
    echo "Satellite: NOT REGISTERED" >> "$SUMMARY_FILE"
fi

step_result 6 "$STEP6_STATUS"


#===============================================================================
# STEP 7/8: IPA CLIENT UNENROLL
#===============================================================================
banner "STEP 7/8 — IPA CLIENT UNENROLL"

STEP7_STATUS="SKIP"

if [[ -f /etc/ipa/default.conf ]] || rpm -q ipa-client &>/dev/null 2>&1; then
    HOSTNAME_FQDN=$(hostname -f)
    info "IPA client enrolled, unenrolling..."
    info "Hostname: $HOSTNAME_FQDN"
    
    # Stop SSSD first
    systemctl stop sssd 2>/dev/null
    
    # Unenroll from IPA
    if command -v ipa-client-install &>/dev/null; then
        sep
        ipa-client-install --uninstall --unattended 2>&1
        IPA_RC=$?
        sep
        
        if [[ $IPA_RC -eq 0 ]]; then
            ok "IPA client unenrolled successfully"
            STEP7_STATUS="PASS"
        else
            warn "IPA unenroll completed with warnings (exit: $IPA_RC)"
            STEP7_STATUS="PASS"
        fi
    else
        fail "ipa-client-install command not found"
        STEP7_STATUS="FAIL"
    fi
    
    # Cleanup IPA files
    rm -rf /etc/ipa 2>/dev/null
    rm -f /etc/krb5.keytab 2>/dev/null
    rm -rf /var/lib/sss/db/* 2>/dev/null
    rm -rf /var/lib/sss/mc/* 2>/dev/null
    
    echo "IPA Client: UNENROLLED" >> "$SUMMARY_FILE"
    echo "" >> "$SUMMARY_FILE"
    echo "NOTE: Delete host from IPA server manually:" >> "$SUMMARY_FILE"
    echo "  ipa host-del $HOSTNAME_FQDN" >> "$SUMMARY_FILE"
    
    warn "Manual action required on IPA server:"
    warn "  ipa host-del $HOSTNAME_FQDN"
else
    skip "IPA client not enrolled"
    echo "IPA Client: NOT ENROLLED" >> "$SUMMARY_FILE"
fi

step_result 7 "$STEP7_STATUS"


#===============================================================================
# STEP 8/8: SALT-MINION UNINSTALL (FINAL)
#===============================================================================
banner "STEP 8/8 — SALT-MINION UNINSTALL"

STEP8_STATUS="SKIP"

MINION_ID=$(cat /etc/salt/minion_id 2>/dev/null || hostname -s)

if rpm -q salt-minion &>/dev/null 2>&1 || [[ -f /etc/salt/minion ]]; then
    info "Salt minion detected: $MINION_ID"
    info "Salt master was: $SALT_MASTER"
    
    # Stop salt-minion service
    info "Stopping salt-minion service..."
    systemctl stop salt-minion 2>/dev/null
    systemctl disable salt-minion 2>/dev/null
    
    if systemctl is-active salt-minion &>/dev/null; then
        fail "salt-minion service still running"
    else
        ok "salt-minion service stopped"
    fi
    
    # Uninstall salt packages
    info "Uninstalling Salt packages..."
    dnf remove -y salt-minion salt 2>&1 || yum remove -y salt-minion salt 2>&1
    
    # Cleanup Salt directories
    info "Cleaning up Salt configuration and cache..."
    rm -rf /etc/salt 2>/dev/null
    rm -rf /var/cache/salt 2>/dev/null
    rm -rf /var/log/salt 2>/dev/null
    rm -rf /var/run/salt 2>/dev/null
    rm -rf /srv/salt 2>/dev/null
    rm -rf /srv/pillar 2>/dev/null
    
    ok "Salt minion uninstalled and cleaned up"
    STEP8_STATUS="PASS"
    
    echo "" >> "$SUMMARY_FILE"
    echo "Salt Minion: REMOVED" >> "$SUMMARY_FILE"
    echo "" >> "$SUMMARY_FILE"
    echo "NOTE: Delete minion key on Salt master manually:" >> "$SUMMARY_FILE"
    echo "  salt-key -d $MINION_ID" >> "$SUMMARY_FILE"
    
    warn "Manual action required on Salt master ($SALT_MASTER):"
    warn "  salt-key -d $MINION_ID"
else
    skip "Salt minion not installed"
    echo "Salt Minion: NOT INSTALLED" >> "$SUMMARY_FILE"
fi

step_result 8 "$STEP8_STATUS"


#===============================================================================
# FINAL CLEANUP
#===============================================================================
banner "FINAL CLEANUP"

info "Reloading systemd daemon..."
systemctl daemon-reload 2>/dev/null

info "Cleaning package cache..."
dnf clean all 2>/dev/null || yum clean all 2>/dev/null

ok "Cleanup complete"


#===============================================================================
# FINAL SCORECARD
#===============================================================================
banner "OFFBOARDING COMPLETE — FINAL SCORECARD"

echo -e "  ${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}║                    SERVER INFORMATION                         ║${NC}"
echo -e "  ${BOLD}╠═══════════════════════════════════════════════════════════════╣${NC}"
echo -e "  ${BOLD}║${NC}  Hostname     : ${BOLD}$(hostname)${NC}"
echo -e "  ${BOLD}║${NC}  Completed    : $(date)"
echo -e "  ${BOLD}║${NC}  Log File     : ${BOLD}$LOGFILE${NC}"
echo -e "  ${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

sep
echo -e "  ${BOLD}STEP RESULTS:${NC}"
echo ""

TOTAL_PASS=0
TOTAL_SKIP=0
for i in $(seq 1 8); do
    case "${RESULTS[$i]}" in
        PASS)
            echo -e "  ${GREEN}[✔ DONE]${NC}  Step $i — ${STEP_NAMES[$i]}"
            ((TOTAL_PASS++))
            ;;
        FAIL)
            echo -e "  ${RED}[✘ FAIL]${NC}  Step $i — ${STEP_NAMES[$i]}"
            ;;
        SKIP)
            echo -e "  ${YELLOW}[- SKIP]${NC}  Step $i — ${STEP_NAMES[$i]}"
            ((TOTAL_SKIP++))
            ;;
    esac
done

echo ""
sep
echo ""

# Manual actions reminder
echo -e "  ${YELLOW}${BOLD}MANUAL ACTIONS REQUIRED:${NC}"
echo ""
if [[ -n "$MINION_ID" ]]; then
    echo -e "  ${YELLOW}1.${NC} On Salt Master ($SALT_MASTER):"
    echo -e "     ${CYAN}salt-key -d $MINION_ID${NC}"
fi
if [[ -f /tmp/.ipa_hostname ]]; then
    HOSTNAME_FQDN=$(cat /tmp/.ipa_hostname 2>/dev/null || hostname -f)
else
    HOSTNAME_FQDN=$(hostname -f)
fi
echo -e "  ${YELLOW}2.${NC} On IPA Server:"
echo -e "     ${CYAN}ipa host-del $HOSTNAME_FQDN${NC}"
echo -e "  ${YELLOW}3.${NC} On Satellite Server ($SATELLITE_SERVER):"
echo -e "     ${CYAN}hammer host delete --name $HOSTNAME_FQDN${NC}"
echo ""

# Final verdict
TOTAL_ACTIONS=$((TOTAL_PASS + TOTAL_SKIP))
if [[ $TOTAL_ACTIONS -eq 8 ]]; then
    echo -e "  ${GREEN}${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}${BOLD}║   ✔  OFFBOARDING COMPLETE — ${TOTAL_PASS} removed, ${TOTAL_SKIP} skipped           ║${NC}"
    echo -e "  ${GREEN}${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
else
    echo -e "  ${YELLOW}${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${YELLOW}${BOLD}║   !  OFFBOARDING PARTIAL — REVIEW FAILED STEPS               ║${NC}"
    echo -e "  ${YELLOW}${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
fi

echo ""
info "Full log: ${BOLD}$LOGFILE${NC}"
info "Summary:  ${BOLD}$SUMMARY_FILE${NC}"
echo ""

exit 0
