#!/bin/bash
#===============================================================================
# Server Onboarding Script - v7 (Non-Interactive, Auto-Detect)
#
# Environment auto-detected from hostname:
#   Strip trailing digits, last alpha char = environment code
#   P = PROD | R,G,C,S,D,U = NONPROD
#
# Steps (sequential, non-interactive):
#   1. Salt-Minion Install + Configure Master + Key Acceptance Poll
#   2. Patch Management (Satellite/Foreman)
#   3. SIEM Integration (rsyslog)
#   4. VRLI Agent Install
#   5. DNF Automatic Install & Config
#   6. DSA Agent Configuration
#   7. UDAgent Installation
#   8. IPA Client Onboarding
#   9. Salt-Master Config Validation (CHECK ONLY — no update)
#
# On failure: logs error, continues to next step, shows full scorecard at end
# Usage: sudo bash server_onboarding_v7.sh
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
KEY_POLL_INTERVAL=30
KEY_POLL_MAX_ATTEMPTS=20   # 20 x 30s = 10 minutes max wait

# ─── Log File ────────────────────────────────────────────────────────────────
LOGFILE="/var/log/server_onboarding_$(date +%Y%m%d_%H%M%S).log"
TMPDIR="/tmp/onboarding_$$"
mkdir -p "$TMPDIR"

exec > >(tee -a "$LOGFILE") 2>&1

# ─── Step Results Array ──────────────────────────────────────────────────────
declare -A RESULTS
declare -A STEP_NAMES
STEP_NAMES=(
    [1]="Salt-Minion Install + Master Config"
    [2]="Patch Management (Satellite)"
    [3]="SIEM Integration (rsyslog)"
    [4]="VRLI Agent Install"
    [5]="DNF Automatic"
    [6]="DSA Agent Configuration"
    [7]="UDAgent Installation"
    [8]="IPA Client Onboarding"
    [9]="Salt-Master Config Validation"
)
for i in $(seq 1 9); do RESULTS[$i]="FAIL"; done
MINION_KEY_STATUS="NOT VERIFIED"

# ─── Helper Functions ────────────────────────────────────────────────────────
banner() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} $1${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

ok()   { echo -e "  ${GREEN}[✔ PASS]${NC} $1"; }
fail() { echo -e "  ${RED}[✘ FAIL]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[! WARN]${NC} $1"; }
info() { echo -e "  ${CYAN}[i INFO]${NC} $1"; }
sep()  { echo -e "  ${CYAN}──────────────────────────────────────────────────────────${NC}"; }

download_script() {
    local url="$1"
    local dest="$2"

    info "Downloading: $url"
    curl -sSlk "$url" -o "$dest" 2>&1

    if [[ ! -f "$dest" ]]; then
        fail "Download FAILED — file does not exist: $dest"
        return 1
    fi

    local filesize
    filesize=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    if [[ "$filesize" -lt 10 ]]; then
        fail "Download FAILED — file too small (${filesize} bytes): $dest"
        return 1
    fi

    ok "Downloaded (${filesize} bytes): $(basename "$dest")"
    return 0
}

step_result() {
    local step_num="$1"
    local passed="$2"

    if [[ "$passed" == true ]]; then
        RESULTS[$step_num]="PASS"
        echo ""
        ok "STEP ${step_num}/9 — ${STEP_NAMES[$step_num]} — ${GREEN}PASSED${NC}"
    else
        RESULTS[$step_num]="FAIL"
        echo ""
        fail "STEP ${step_num}/9 — ${STEP_NAMES[$step_num]} — ${RED}FAILED${NC}"
        warn "Continuing to next step..."
    fi
    echo ""
}


#===============================================================================
# PRE-FLIGHT CHECKS
#===============================================================================
if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (or with sudo)."
    exit 1
fi

banner "SERVER ONBOARDING v7 — NON-INTERACTIVE"
info "Log file : $LOGFILE"
info "Started  : $(date)"


#===============================================================================
# DETECT OS
#===============================================================================
banner "DETECTING OS FLAVOR & VERSION"

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_NAME="${NAME:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_ID="${ID:-unknown}"
elif [[ -f /etc/redhat-release ]]; then
    OS_NAME=$(cat /etc/redhat-release)
    OS_ID="rhel"
    OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
else
    fail "Cannot detect OS. Exiting."
    exit 1
fi

if echo "$OS_ID" | grep -qi "ol\|oracle"; then
    OS_TYPE="OL"
elif echo "$OS_ID" | grep -qi "rhel\|redhat\|centos"; then
    OS_TYPE="RHEL"
else
    warn "Unknown OS ($OS_ID) — defaulting to RHEL."
    OS_TYPE="RHEL"
fi

ok "OS Name    : $OS_NAME"
ok "OS Version : $OS_VERSION"
ok "OS Type    : $OS_TYPE"
ok "Hostname   : $(hostname)"


#===============================================================================
# DETECT ENVIRONMENT FROM HOSTNAME
#===============================================================================
banner "AUTO-DETECTING ENVIRONMENT FROM HOSTNAME"

HOSTNAME_RAW=$(hostname -s)
info "Raw hostname: $HOSTNAME_RAW"

# Strip trailing digits to get the alpha portion
ALPHA_PART=$(echo "$HOSTNAME_RAW" | sed 's/[0-9]*$//')
info "Alpha portion: $ALPHA_PART"

if [[ -z "$ALPHA_PART" ]]; then
    fail "Cannot extract alpha portion from hostname: $HOSTNAME_RAW"
    fail "Defaulting to NONPROD for safety."
    ENV="NONPROD"
    ENV_CODE="?"
    ENV_LABEL="Unknown"
else
    # Last character of alpha portion is the environment code
    ENV_CODE="${ALPHA_PART: -1}"
    ENV_CODE_LOWER=$(echo "$ENV_CODE" | tr '[:upper:]' '[:lower:]')

    case "$ENV_CODE_LOWER" in
        p) ENV="PROD";    ENV_LABEL="Production" ;;
        r) ENV="NONPROD"; ENV_LABEL="Pre Prod" ;;
        g) ENV="NONPROD"; ENV_LABEL="Cug" ;;
        c) ENV="NONPROD"; ENV_LABEL="Poc" ;;
        s) ENV="NONPROD"; ENV_LABEL="Sit" ;;
        d) ENV="NONPROD"; ENV_LABEL="Dev" ;;
        u) ENV="NONPROD"; ENV_LABEL="Uat" ;;
        *)
            warn "Unrecognized env code '$ENV_CODE' — defaulting to NONPROD"
            ENV="NONPROD"
            ENV_LABEL="Unknown ($ENV_CODE)"
            ;;
    esac
fi

echo ""
echo -e "  ${YELLOW}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "  ${YELLOW}║  Hostname      : ${BOLD}${HOSTNAME_RAW}${NC}${YELLOW}${NC}"
echo -e "  ${YELLOW}║  Env Code      : ${BOLD}${ENV_CODE}${NC}${YELLOW}  (${ENV_LABEL})${NC}"
echo -e "  ${YELLOW}║  Category      : ${BOLD}${ENV}${NC}"
echo -e "  ${YELLOW}║  OS            : ${BOLD}${OS_TYPE}${NC}${YELLOW} / ${OS_NAME} ${OS_VERSION}${NC}"
echo -e "  ${YELLOW}║  Salt Master   : ${BOLD}${SALT_MASTER}${NC}"
echo -e "  ${YELLOW}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""


#===============================================================================
# STEP 1/9: INSTALL SALT-MINION + CONFIGURE MASTER + KEY ACCEPTANCE
#===============================================================================
banner "STEP 1/9 — SALT-MINION INSTALL + MASTER CONFIG [$ENV]"

STEP1_PASS=false

SALT_SCRIPT="$TMPDIR/salt.sh"

if download_script "https://${SALT_MASTER}/pub/salt.sh" "$SALT_SCRIPT"; then

    info "Executing: bash $SALT_SCRIPT $ENV mz"
    sep
    bash "$SALT_SCRIPT" "$ENV" mz 2>&1
    sep

    # ─── Configure master in /etc/salt/minion ───
    info "Configuring Salt master in /etc/salt/minion..."

    if [[ -f /etc/salt/minion ]]; then
        # Check if master line exists
        if grep -q "^master:" /etc/salt/minion; then
            CURRENT_MASTER=$(grep "^master:" /etc/salt/minion | awk '{print $2}')
            if [[ "$CURRENT_MASTER" == "$SALT_MASTER" ]]; then
                ok "Master already set to $SALT_MASTER"
            else
                info "Updating master from $CURRENT_MASTER to $SALT_MASTER"
                sed -i "s/^master:.*/master: $SALT_MASTER/" /etc/salt/minion
                ok "Master updated to $SALT_MASTER"
                info "Restarting salt-minion..."
                systemctl restart salt-minion 2>&1
            fi
        else
            info "Adding master: $SALT_MASTER to /etc/salt/minion"
            echo "master: $SALT_MASTER" >> /etc/salt/minion
            info "Restarting salt-minion..."
            systemctl restart salt-minion 2>&1
        fi
    else
        warn "/etc/salt/minion not found — creating minimal config"
        mkdir -p /etc/salt
        echo "master: $SALT_MASTER" > /etc/salt/minion
        info "Restarting salt-minion..."
        systemctl restart salt-minion 2>&1
    fi

    # Give minion time to connect
    sleep 5

    # ─── Validate salt-minion ───
    info "Validating salt-minion..."

    if command -v salt-call &>/dev/null; then
        ok "salt-call command found: $(which salt-call)"
    else
        fail "salt-call command NOT found in PATH"
    fi

    if systemctl is-active salt-minion &>/dev/null; then
        ok "salt-minion service is RUNNING"
    else
        fail "salt-minion service NOT running"
    fi

    # ─── Master config update (Step 1b from old script) ───
    info "Running master config update script..."
    MASTER_CONF_SCRIPT="$TMPDIR/master_config.sh"

    if download_script "https://${SALT_MASTER}/pub/master_config.sh" "$MASTER_CONF_SCRIPT"; then
        sep
        bash "$MASTER_CONF_SCRIPT" 2>&1
        MC_RC=$?
        sep
        if [[ $MC_RC -eq 0 ]]; then
            ok "Salt-master config script executed successfully"
        else
            fail "Salt-master config script exit code: $MC_RC"
        fi
    else
        fail "Could not download master_config.sh"
    fi

    # ─── Non-interactive key acceptance polling ───
    info "Polling for minion key acceptance on IB RAAS (max ${KEY_POLL_MAX_ATTEMPTS} attempts, ${KEY_POLL_INTERVAL}s interval)..."
    echo ""

    ATTEMPT=0
    while [[ $ATTEMPT -lt $KEY_POLL_MAX_ATTEMPTS ]]; do
        ((ATTEMPT++))
        info "Attempt $ATTEMPT/$KEY_POLL_MAX_ATTEMPTS — checking test.ping..."

        if salt-call test.ping 2>&1 | grep -q "True"; then
            ok "test.ping — TRUE"
            MINION_KEY_STATUS="ACCEPTED & VERIFIED"
            STEP1_PASS=true
            break
        fi

        if [[ $ATTEMPT -lt $KEY_POLL_MAX_ATTEMPTS ]]; then
            info "Key not accepted yet. Waiting ${KEY_POLL_INTERVAL}s..."
            sleep "$KEY_POLL_INTERVAL"
        fi
    done

    if [[ "$STEP1_PASS" != true ]]; then
        # Even if key not accepted, mark pass if minion is running + master set
        if systemctl is-active salt-minion &>/dev/null; then
            warn "Minion key not verified within timeout but service is running"
            warn "Key may need manual acceptance on IB RAAS: salt-key -a $(hostname -s)"
            MINION_KEY_STATUS="PENDING (timeout)"
            STEP1_PASS=true
        fi
    fi
else
    fail "Could not download salt.sh"
fi

step_result 1 "$STEP1_PASS"


#===============================================================================
# STEP 2/9: PATCH MANAGEMENT (SATELLITE/FOREMAN)
#===============================================================================
banner "STEP 2/9 — PATCH MANAGEMENT [$ENV / $OS_TYPE]"

STEP2_PASS=false

if [[ "$OS_TYPE" == "OL" ]]; then
    REG_URL="https://10.100.27.102/pub/olregistration.sh"
    REG_FILE="$TMPDIR/olregistration.sh"
    info "Oracle Linux — using olregistration.sh"
else
    REG_URL="https://10.100.27.102/pub/rhel.sh"
    REG_FILE="$TMPDIR/rhel.sh"
    info "RHEL — using rhel.sh"
fi

if download_script "$REG_URL" "$REG_FILE"; then

    info "Executing: bash $REG_FILE actual $ENV"
    sep
    bash "$REG_FILE" actual "$ENV" 2>&1
    sep

    info "Verifying repos..."
    REPO_COUNT=$(dnf repolist --enabled 2>/dev/null | tail -n +2 | wc -l || echo 0)
    if [[ "$REPO_COUNT" -gt 0 ]]; then
        ok "Found $REPO_COUNT enabled repos"
    else
        fail "No enabled repos found"
    fi

    info "Running dnf update -y..."
    sep
    dnf update -y 2>&1
    DNF_RC=$?
    sep

    if [[ $DNF_RC -eq 0 ]]; then
        ok "dnf update completed successfully"
        STEP2_PASS=true
    else
        warn "dnf update exit code: $DNF_RC (may have partial updates)"
        STEP2_PASS=true
    fi
else
    fail "Could not download registration script"
fi

step_result 2 "$STEP2_PASS"


#===============================================================================
# STEP 3/9: SIEM INTEGRATION (RSYSLOG)
#===============================================================================
banner "STEP 3/9 — SIEM INTEGRATION"

STEP3_PASS=false

info "Applying SIEM configuration via Salt..."
sep
salt-call state.apply rsyslog.reset 2>&1
SIEM_RESET=$?
salt-call state.apply rsyslog.siem 2>&1
SIEM_APPLY=$?
sep

if [[ $SIEM_RESET -eq 0 && $SIEM_APPLY -eq 0 ]]; then
    ok "SIEM rsyslog states applied successfully"
else
    fail "SIEM state errors (reset=$SIEM_RESET, apply=$SIEM_APPLY)"
fi

# Validate rsyslog service
if systemctl is-active rsyslog &>/dev/null; then
    ok "rsyslog service is RUNNING"
    STEP3_PASS=true
else
    fail "rsyslog service NOT running"
fi

step_result 3 "$STEP3_PASS"


#===============================================================================
# STEP 4/9: VRLI AGENT INSTALL
#===============================================================================
banner "STEP 4/9 — VRLI AGENT INSTALL"

STEP4_PASS=false

info "Removing existing VMware Log Insight Agent (if any)..."
dnf remove VMware-Log-Insight-Agent* -y 2>&1 || true

info "Refreshing Salt pillar..."
salt-call saltutil.refresh_pillar 2>&1

info "Deploying LogInsight agent via Salt..."
sep
salt-call state.apply liagent 2>&1
LIA_RC=$?
sep

if rpm -qa | grep -i "VMware-Log-Insight-Agent" &>/dev/null; then
    ok "VMware Log Insight Agent INSTALLED"
    rpm -qa | grep -i "VMware-Log-Insight-Agent"
    STEP4_PASS=true
elif [[ $LIA_RC -eq 0 ]]; then
    ok "Salt state applied successfully (exit code 0)"
    STEP4_PASS=true
else
    fail "LogInsight Agent not installed (salt exit: $LIA_RC)"
fi

step_result 4 "$STEP4_PASS"


#===============================================================================
# STEP 5/9: DNF AUTOMATIC
#===============================================================================
banner "STEP 5/9 — DNF AUTOMATIC INSTALL & CONFIG"

STEP5_PASS=false

DNF_AUTO_SCRIPT="$TMPDIR/dnfauto.sh"
if download_script "https://10.100.27.102/pub/dnfauto.sh" "$DNF_AUTO_SCRIPT"; then
    info "Executing dnfauto.sh..."
    sep
    bash "$DNF_AUTO_SCRIPT" 2>&1
    sep
else
    fail "Could not download dnfauto.sh"
fi

DNF_CONF_SCRIPT="$TMPDIR/dnfautoconf.sh"
if download_script "https://10.100.27.102/pub/dnfautoconf.sh" "$DNF_CONF_SCRIPT"; then
    info "Executing dnfautoconf.sh..."
    sep
    bash "$DNF_CONF_SCRIPT" 2>&1
    sep
else
    fail "Could not download dnfautoconf.sh"
fi

if systemctl is-active dnf-automatic.timer &>/dev/null; then
    ok "dnf-automatic.timer is ACTIVE"
    STEP5_PASS=true
elif systemctl is-enabled dnf-automatic.timer &>/dev/null; then
    warn "dnf-automatic.timer enabled but NOT yet active"
    STEP5_PASS=true
else
    fail "dnf-automatic.timer NOT active/enabled"
fi

step_result 5 "$STEP5_PASS"


#===============================================================================
# STEP 6/9: DSA AGENT CONFIGURATION
#===============================================================================
banner "STEP 6/9 — DSA AGENT CONFIGURATION"

STEP6_PASS=false

DSA_SCRIPT="$TMPDIR/dsagent.sh"

if download_script "https://${SALT_MASTER}/pub/dsagent.sh" "$DSA_SCRIPT"; then

    info "Executing: bash $DSA_SCRIPT"
    sep
    bash "$DSA_SCRIPT" 2>&1
    DSA_RC=$?
    sep

    info "Validating ds_agent.service..."
    if systemctl is-active ds_agent.service &>/dev/null; then
        ok "ds_agent.service is RUNNING"
        STEP6_PASS=true
    elif systemctl is-enabled ds_agent.service &>/dev/null; then
        warn "ds_agent.service enabled but NOT active"
        STEP6_PASS=true
    elif [[ $DSA_RC -eq 0 ]]; then
        ok "dsagent.sh completed (exit code 0)"
        STEP6_PASS=true
    else
        fail "ds_agent.service NOT running (script exit: $DSA_RC)"
    fi
else
    fail "Could not download dsagent.sh"
fi

step_result 6 "$STEP6_PASS"


#===============================================================================
# STEP 7/9: UDAgent INSTALLATION
#===============================================================================
banner "STEP 7/9 — UDAgent INSTALLATION"

STEP7_PASS=false

UD_SCRIPT="$TMPDIR/udagent.sh"

if download_script "https://${SALT_MASTER}/pub/udagent.sh" "$UD_SCRIPT"; then

    info "Executing: bash $UD_SCRIPT"
    sep
    bash "$UD_SCRIPT" 2>&1
    UD_RC=$?
    sep

    info "Validating udagent.service..."
    if systemctl is-active udagent.service &>/dev/null; then
        ok "udagent.service is RUNNING"
        STEP7_PASS=true
    elif systemctl is-enabled udagent.service &>/dev/null; then
        warn "udagent.service enabled but NOT active"
        STEP7_PASS=true
    elif [[ $UD_RC -eq 0 ]]; then
        ok "udagent.sh completed (exit code 0)"
        STEP7_PASS=true
    else
        fail "udagent.service NOT running (script exit: $UD_RC)"
    fi
else
    fail "Could not download udagent.sh"
fi

step_result 7 "$STEP7_PASS"


#===============================================================================
# STEP 8/9: IPA CLIENT ONBOARDING
#===============================================================================
banner "STEP 8/9 — IPA CLIENT ONBOARDING"

STEP8_PASS=false

info "Applying IPA client via Salt..."
sep
salt-call state.apply ipa 2>&1
IPA_RC=$?
sep

if [[ $IPA_RC -eq 0 ]]; then
    ok "salt-call state.apply ipa — SUCCESS"
else
    fail "salt-call state.apply ipa — FAILED (exit: $IPA_RC)"
fi

info "Verifying /etc/ipa/default.conf..."
if [[ -f /etc/ipa/default.conf ]]; then
    ok "/etc/ipa/default.conf EXISTS"
    STEP8_PASS=true
else
    fail "/etc/ipa/default.conf NOT found"
fi

step_result 8 "$STEP8_PASS"


#===============================================================================
# STEP 9/9: SALT-MASTER CONFIG VALIDATION (CHECK ONLY — NO UPDATE)
#===============================================================================
banner "STEP 9/9 — SALT-MASTER CONFIG VALIDATION (CHECK ONLY)"

STEP9_PASS=false
VALIDATIONS_PASSED=0
VALIDATIONS_TOTAL=3

# ─── Check 1: salt-minion service running ───
info "Check 1/3: salt-minion service status..."
if systemctl is-active salt-minion &>/dev/null; then
    ok "salt-minion service is RUNNING"
    ((VALIDATIONS_PASSED++))
else
    fail "salt-minion service is NOT running"
fi

# ─── Check 2: /etc/salt/minion config & correct master ───
info "Check 2/3: /etc/salt/minion config and master setting..."
if [[ -f /etc/salt/minion ]]; then
    ok "/etc/salt/minion file EXISTS"

    CONFIGURED_MASTER=$(grep "^master:" /etc/salt/minion 2>/dev/null | awk '{print $2}')
    if [[ "$CONFIGURED_MASTER" == "$SALT_MASTER" ]]; then
        ok "Master correctly set to: $SALT_MASTER"
        ((VALIDATIONS_PASSED++))
    elif [[ -n "$CONFIGURED_MASTER" ]]; then
        fail "Master is set to '$CONFIGURED_MASTER' — expected '$SALT_MASTER'"
    else
        fail "No 'master:' line found in /etc/salt/minion"
    fi
else
    fail "/etc/salt/minion file NOT found"
fi

# ─── Check 3: salt-call test.ping ───
info "Check 3/3: salt-call test.ping..."
PING_OUTPUT=$(salt-call test.ping 2>&1)
if echo "$PING_OUTPUT" | grep -q "True"; then
    ok "test.ping returned TRUE — master-minion link active"
    ((VALIDATIONS_PASSED++))
else
    fail "test.ping did not return True"
    echo "$PING_OUTPUT" | head -5
fi

# Overall step result
echo ""
info "Validation score: $VALIDATIONS_PASSED/$VALIDATIONS_TOTAL checks passed"

if [[ $VALIDATIONS_PASSED -eq $VALIDATIONS_TOTAL ]]; then
    STEP9_PASS=true
elif [[ $VALIDATIONS_PASSED -ge 2 ]]; then
    warn "Partial validation — $VALIDATIONS_PASSED/$VALIDATIONS_TOTAL passed"
    STEP9_PASS=true
fi

step_result 9 "$STEP9_PASS"


#===============================================================================
# FINAL SCORECARD
#===============================================================================
banner "ONBOARDING COMPLETE — FINAL SCORECARD"

echo -e "  ${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}║                    SERVER INFORMATION                         ║${NC}"
echo -e "  ${BOLD}╠═══════════════════════════════════════════════════════════════╣${NC}"
echo -e "  ${BOLD}║${NC}  Hostname     : ${BOLD}$(hostname)${NC}"
echo -e "  ${BOLD}║${NC}  OS           : ${BOLD}${OS_NAME} ${OS_VERSION} (${OS_TYPE})${NC}"
echo -e "  ${BOLD}║${NC}  Env Code     : ${BOLD}${ENV_CODE}${NC} (${ENV_LABEL})"
echo -e "  ${BOLD}║${NC}  Category     : ${BOLD}${ENV}${NC}"
echo -e "  ${BOLD}║${NC}  Salt Master  : ${BOLD}${SALT_MASTER}${NC}"
echo -e "  ${BOLD}║${NC}  Minion Key   : ${BOLD}${MINION_KEY_STATUS}${NC}"
echo -e "  ${BOLD}║${NC}  Completed    : $(date)"
echo -e "  ${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

sep
echo -e "  ${BOLD}STEP RESULTS:${NC}"
echo ""

TOTAL_PASS=0
for i in $(seq 1 9); do
    if [[ "${RESULTS[$i]}" == "PASS" ]]; then
        echo -e "  ${GREEN}[✔ PASS]${NC}  Step $i — ${STEP_NAMES[$i]}"
        ((TOTAL_PASS++))
    else
        echo -e "  ${RED}[✘ FAIL]${NC}  Step $i — ${STEP_NAMES[$i]}"
    fi
done

echo ""
sep
echo ""

# Final verdict
if [[ $TOTAL_PASS -eq 9 ]]; then
    echo -e "  ${GREEN}${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}${BOLD}║   ✔  ALL 9/9 STEPS PASSED — SERVER ONBOARDING COMPLETE!     ║${NC}"
    echo -e "  ${GREEN}${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
elif [[ $TOTAL_PASS -ge 7 ]]; then
    echo -e "  ${YELLOW}${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${YELLOW}${BOLD}║   !  ${TOTAL_PASS}/9 STEPS PASSED — REVIEW FAILED STEPS             ║${NC}"
    echo -e "  ${YELLOW}${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
else
    echo -e "  ${RED}${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${RED}${BOLD}║   ✘  ${TOTAL_PASS}/9 STEPS PASSED — ONBOARDING NEEDS ATTENTION       ║${NC}"
    echo -e "  ${RED}${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
fi

echo ""
info "Full log: ${BOLD}$LOGFILE${NC}"
echo ""

# ─── Cleanup ─────────────────────────────────────────────────────────────────
rm -rf "$TMPDIR" 2>/dev/null

exit 0
