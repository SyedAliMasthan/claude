#!/usr/bin/env bash
###############################################################################
# OpenShift Cluster Health Check Script
# 
# Usage:
#   ./openshift_health_check.sh --kubeconfig /path/to/kubeconfig
#   ./openshift_health_check.sh --kubeconfig /path/to/kubeconfig --output report.html
#   ./openshift_health_check.sh --kubeconfig /path/to/kubeconfig --json
#
# Requirements:
#   - oc CLI (or kubectl as fallback)
#   - jq
#   - Valid kubeconfig with cluster-admin or equivalent read permissions
###############################################################################

set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION & GLOBALS
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
TIMESTAMP_HUMAN="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Counters
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
INFO_COUNT=0
TOTAL_CHECKS=0

# Output control
OUTPUT_FORMAT="text"  # text | json | html
OUTPUT_FILE=""
JSON_RESULTS="[]"
HTML_BUFFER=""
KUBECONFIG_PATH=""
OC_CMD=""

# Cluster identity (resolved at runtime from API URL)
CLUSTER_DISPLAY_NAME=""
CLUSTER_API_URL=""

# Email
EMAIL_RECIPIENTS=""
EMAIL_SUBJECT=""

# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}Indian Bank — OpenShift Cluster Health Check${NC}

Usage:
  $SCRIPT_NAME --kubeconfig <path> [OPTIONS]

Options:
  --kubeconfig <path>       Path to kubeconfig file (required)
  --output <file>           Save HTML report to file
  --json                    Output results as JSON
  --cluster-name <name>     Override auto-detected cluster name (e.g. "DCPROD")
  --email <recipients>      Send HTML report as email body (comma-separated)
  --email-subject <subject> Custom email subject line
  --skip-events             Skip cluster events collection (faster)
  --skip-certs              Skip certificate expiry checks
  --namespace <ns>          Also check a specific user namespace
  -h, --help                Show this help message

Cluster Name Auto-Detection (from API URL):
  The script automatically maps the API URL to Indian Bank environment names:
    *dcprod*     → "Indian Bank DCPROD"
    *dcdev*      → "Indian Bank DCDEV"
    *dcmgmt*     → "Indian Bank DC MANAGEMENT"
    *drprod*     → "Indian Bank DR PROD"
    *drmgmt*     → "Indian Bank DR MANAGEMENT"
    *dcuat*      → "Indian Bank DC UAT"
  Use --cluster-name to override if needed.

Examples:
  $SCRIPT_NAME --kubeconfig ~/.kube/config
  $SCRIPT_NAME --kubeconfig ~/.kube/config --output report.html
  $SCRIPT_NAME --kubeconfig ~/.kube/config --output report.html \\
      --email "teamlead@indianbank.in,ocp-admins@indianbank.in"
  $SCRIPT_NAME --kubeconfig ~/.kube/config --cluster-name "DCPROD" --output report.html
  $SCRIPT_NAME --kubeconfig ~/.kube/config --json > results.json
EOF
    exit 0
}

log_header() {
    local section="$1"
    echo ""
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $section${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
}

log_subheader() {
    echo -e "\n${BOLD}${CYAN}── $1 ──${NC}"
}

log_pass() {
    ((PASS_COUNT++)) || true
    ((TOTAL_CHECKS++)) || true
    echo -e "  ${GREEN}✔ PASS${NC}  $1"
    append_json "PASS" "$1" "${2:-}"
}

log_warn() {
    ((WARN_COUNT++)) || true
    ((TOTAL_CHECKS++)) || true
    echo -e "  ${YELLOW}⚠ WARN${NC}  $1"
    append_json "WARN" "$1" "${2:-}"
}

log_fail() {
    ((FAIL_COUNT++)) || true
    ((TOTAL_CHECKS++)) || true
    echo -e "  ${RED}✘ FAIL${NC}  $1"
    append_json "FAIL" "$1" "${2:-}"
}

log_info() {
    ((INFO_COUNT++)) || true
    echo -e "  ${BLUE}ℹ INFO${NC}  $1"
    append_json "INFO" "$1" "${2:-}"
}

append_json() {
    local status="$1"
    local message="$2"
    local detail="${3:-}"
    if [[ "$OUTPUT_FORMAT" == "json" || -n "$OUTPUT_FILE" ]]; then
        JSON_RESULTS=$(printf '%s' "$JSON_RESULTS" | jq --arg s "$status" --arg m "$message" --arg d "$detail" '. + [{"status": $s, "message": $m, "detail": $d}]' 2>/dev/null || printf '%s' "$JSON_RESULTS")
    fi
}

run_oc() {
    $OC_CMD --kubeconfig="$KUBECONFIG_PATH" "$@" 2>/dev/null
}

# Safe numeric comparison
is_gt() {
    awk "BEGIN { exit !($1 > $2) }" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────
SKIP_EVENTS=false
SKIP_CERTS=false
EXTRA_NAMESPACES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kubeconfig)     KUBECONFIG_PATH="$2"; shift 2 ;;
        --output)         OUTPUT_FILE="$2"; shift 2 ;;
        --json)           OUTPUT_FORMAT="json"; shift ;;
        --cluster-name)   CLUSTER_DISPLAY_NAME="$2"; shift 2 ;;
        --email)          EMAIL_RECIPIENTS="$2"; shift 2 ;;
        --email-subject)  EMAIL_SUBJECT="$2"; shift 2 ;;
        --skip-events)    SKIP_EVENTS=true; shift ;;
        --skip-certs)     SKIP_CERTS=true; shift ;;
        --namespace)      EXTRA_NAMESPACES+=("$2"); shift 2 ;;
        -h|--help)        usage ;;
        *)                echo "Unknown option: $1"; usage ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────
preflight() {
    log_header "PRE-FLIGHT CHECKS"

    # Kubeconfig
    if [[ -z "$KUBECONFIG_PATH" ]]; then
        echo -e "${RED}ERROR: --kubeconfig is required${NC}"
        usage
    fi
    if [[ ! -f "$KUBECONFIG_PATH" ]]; then
        echo -e "${RED}ERROR: Kubeconfig not found: $KUBECONFIG_PATH${NC}"
        exit 1
    fi
    log_pass "Kubeconfig file found: $KUBECONFIG_PATH"

    # CLI tool
    if command -v oc &>/dev/null; then
        OC_CMD="oc"
        log_pass "oc CLI found: $(oc version --client 2>/dev/null | head -1)"
    elif command -v kubectl &>/dev/null; then
        OC_CMD="kubectl"
        log_warn "oc CLI not found, falling back to kubectl (some OpenShift-specific checks will be limited)"
    else
        echo -e "${RED}ERROR: Neither oc nor kubectl found in PATH${NC}"
        exit 1
    fi

    # jq
    if command -v jq &>/dev/null; then
        log_pass "jq found"
    else
        echo -e "${RED}ERROR: jq is required but not installed${NC}"
        exit 1
    fi

    # Connectivity test
    if run_oc cluster-info &>/dev/null; then
        log_pass "Cluster is reachable"
    else
        log_fail "Cannot reach cluster — check kubeconfig and network"
        exit 1
    fi

    # Identify cluster
    local api_url
    api_url=$(run_oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "unknown")
    CLUSTER_API_URL="$api_url"
    local context
    context=$(run_oc config current-context 2>/dev/null || echo "unknown")
    log_info "API Server: $api_url"
    log_info "Context: $context"

    # Auto-detect Indian Bank cluster name from API URL if not overridden
    if [[ -z "$CLUSTER_DISPLAY_NAME" ]]; then
        local api_lower
        api_lower=$(echo "$api_url" | tr '[:upper:]' '[:lower:]')
        if [[ "$api_lower" == *"dcprod"* ]]; then
            CLUSTER_DISPLAY_NAME="Indian Bank DCPROD"
        elif [[ "$api_lower" == *"dcdev"* ]]; then
            CLUSTER_DISPLAY_NAME="Indian Bank DCDEV"
        elif [[ "$api_lower" == *"dcuat"* ]]; then
            CLUSTER_DISPLAY_NAME="Indian Bank DC UAT"
        elif [[ "$api_lower" == *"dcmgmt"* || "$api_lower" == *"dc-mgmt"* || "$api_lower" == *"dcmanagement"* ]]; then
            CLUSTER_DISPLAY_NAME="Indian Bank DC MANAGEMENT"
        elif [[ "$api_lower" == *"drprod"* ]]; then
            CLUSTER_DISPLAY_NAME="Indian Bank DR PROD"
        elif [[ "$api_lower" == *"drmgmt"* || "$api_lower" == *"dr-mgmt"* || "$api_lower" == *"drmanagement"* ]]; then
            CLUSTER_DISPLAY_NAME="Indian Bank DR MANAGEMENT"
        elif [[ "$api_lower" == *"drdev"* ]]; then
            CLUSTER_DISPLAY_NAME="Indian Bank DR DEV"
        elif [[ "$api_lower" == *"druat"* ]]; then
            CLUSTER_DISPLAY_NAME="Indian Bank DR UAT"
        else
            # Fallback: extract cluster name from API URL
            local extracted
            extracted=$(echo "$api_url" | sed -E 's|https?://api\.||; s|:[0-9]+$||; s|\.[^.]+\.[^.]+$||' | tr '[:lower:]' '[:upper:]')
            CLUSTER_DISPLAY_NAME="Indian Bank ${extracted:-OPENSHIFT}"
        fi
    fi
    log_info "Cluster Identity: $CLUSTER_DISPLAY_NAME"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. CLUSTER VERSION & OVERVIEW
# ─────────────────────────────────────────────────────────────────────────────
check_cluster_version() {
    log_header "1. CLUSTER VERSION & OVERVIEW"

    local cv_json
    cv_json=$(run_oc get clusterversion version -o json 2>/dev/null) || {
        log_warn "Could not retrieve ClusterVersion (may not be OpenShift)"
        return
    }

    local version desired_version
    version=$(echo "$cv_json" | jq -r '.status.desired.version // "unknown"')
    local channel
    channel=$(echo "$cv_json" | jq -r '.spec.channel // "none"')
    local cluster_id
    cluster_id=$(echo "$cv_json" | jq -r '.spec.clusterID // "unknown"')
    local progressing available degraded
    available=$(echo "$cv_json" | jq -r '.status.conditions[]? | select(.type=="Available") | .status')
    progressing=$(echo "$cv_json" | jq -r '.status.conditions[]? | select(.type=="Progressing") | .status')
    degraded=$(echo "$cv_json" | jq -r '.status.conditions[]? | select(.type=="Degraded") | .status')

    log_info "Cluster Version: ${version}"
    log_info "Update Channel: ${channel}"
    log_info "Cluster ID: ${cluster_id}"

    if [[ "$available" == "True" ]]; then log_pass "ClusterVersion Available: True"; else log_fail "ClusterVersion Available: ${available}"; fi
    if [[ "$progressing" == "False" ]]; then log_pass "ClusterVersion Progressing: False"; else log_warn "ClusterVersion Progressing: ${progressing} (upgrade in progress)"; fi
    if [[ "$degraded" == "False" ]]; then log_pass "ClusterVersion Degraded: False"; else log_fail "ClusterVersion Degraded: ${degraded}"; fi

    # Available updates
    local update_count
    update_count=$(echo "$cv_json" | jq '[.status.availableUpdates[]?] | length')
    log_info "Available updates: ${update_count}"

    # History
    log_subheader "Upgrade History (last 5)"
    echo "$cv_json" | jq -r '.status.history[:5][]? | "    \(.version) — \(.state) — \(.completionTime // "in progress")"'
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. CLUSTER OPERATORS
# ─────────────────────────────────────────────────────────────────────────────
check_cluster_operators() {
    log_header "2. CLUSTER OPERATORS"

    local co_json
    co_json=$(run_oc get clusteroperators -o json 2>/dev/null) || {
        log_warn "Could not retrieve ClusterOperators"
        return
    }

    local total_co degraded_co unavailable_co progressing_co
    total_co=$(echo "$co_json" | jq '.items | length')
    degraded_co=0
    unavailable_co=0
    progressing_co=0

    log_subheader "Operator Status Summary"

    while IFS='|' read -r name avail prog degr msg; do
        if [[ "$degr" == "True" ]]; then
            log_fail "DEGRADED: $name — $msg"
            ((degraded_co++)) || true
        elif [[ "$avail" != "True" ]]; then
            log_fail "UNAVAILABLE: $name — $msg"
            ((unavailable_co++)) || true
        elif [[ "$prog" == "True" ]]; then
            log_warn "PROGRESSING: $name"
            ((progressing_co++)) || true
        fi
    done < <(echo "$co_json" | jq -r '
        .items[]? | 
        (.metadata.name) + "|" +
        ([.status.conditions[]? | select(.type=="Available") | .status][0] // "Unknown") + "|" +
        ([.status.conditions[]? | select(.type=="Progressing") | .status][0] // "Unknown") + "|" +
        ([.status.conditions[]? | select(.type=="Degraded") | .status][0] // "Unknown") + "|" +
        ([.status.conditions[]? | select(.type=="Degraded") | select(.status=="True") | .message][0] // "")
    ')

    local healthy_co=$((total_co - degraded_co - unavailable_co - progressing_co))

    echo ""
    log_info "Total Operators: $total_co"
    if [[ $healthy_co -eq $total_co ]]; then log_pass "All $total_co operators healthy"; fi
    if [[ $degraded_co -gt 0 ]]; then log_fail "$degraded_co operator(s) degraded"; fi
    if [[ $unavailable_co -gt 0 ]]; then log_fail "$unavailable_co operator(s) unavailable"; fi
    if [[ $progressing_co -gt 0 ]]; then log_warn "$progressing_co operator(s) progressing"; fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. NODE HEALTH
# ─────────────────────────────────────────────────────────────────────────────
check_nodes() {
    log_header "3. NODE HEALTH"

    local nodes_json
    nodes_json=$(run_oc get nodes -o json 2>/dev/null) || {
        log_fail "Could not retrieve nodes"
        return
    }

    local total_nodes=0 ready_nodes=0 notready_nodes=0 scheduling_disabled=0

    log_subheader "Node Status"
    while IFS='|' read -r name status roles age version mem_pressure disk_pressure pid_pressure unschedulable; do
        ((total_nodes++)) || true
        local node_status_icon=""

        if [[ "$status" == "True" ]]; then
            ((ready_nodes++)) || true
            node_status_icon="${GREEN}Ready${NC}"
        else
            ((notready_nodes++)) || true
            node_status_icon="${RED}NotReady${NC}"
        fi

        [[ "$unschedulable" == "true" ]] && { ((scheduling_disabled++)) || true; node_status_icon+=" ${YELLOW}(SchedulingDisabled)${NC}"; }

        echo -e "  Node: ${BOLD}$name${NC} [$roles] — $node_status_icon — $version"

        # Pressure conditions
        if [[ "$mem_pressure" == "True" ]]; then log_warn "  $name: MemoryPressure detected"; fi
        if [[ "$disk_pressure" == "True" ]]; then log_warn "  $name: DiskPressure detected"; fi
        if [[ "$pid_pressure" == "True" ]]; then log_warn "  $name: PIDPressure detected"; fi
    done < <(echo "$nodes_json" | jq -r '
        .items[]? |
        (.metadata.name) + "|" +
        ([.status.conditions[]? | select(.type=="Ready") | .status][0] // "Unknown") + "|" +
        ([.metadata.labels["node-role.kubernetes.io/master"] // empty | "master"] // [.metadata.labels["node-role.kubernetes.io/worker"] // empty | "worker"] // ["unknown"] | .[0] // "unknown") + "|" +
        (.metadata.creationTimestamp) + "|" +
        (.status.nodeInfo.kubeletVersion) + "|" +
        ([.status.conditions[]? | select(.type=="MemoryPressure") | .status][0] // "False") + "|" +
        ([.status.conditions[]? | select(.type=="DiskPressure") | .status][0] // "False") + "|" +
        ([.status.conditions[]? | select(.type=="PIDPressure") | .status][0] // "False") + "|" +
        (.spec.unschedulable // false | tostring)
    ')

    echo ""
    log_info "Total Nodes: $total_nodes"
    if [[ $ready_nodes -eq $total_nodes ]]; then log_pass "All $total_nodes nodes Ready"; fi
    if [[ $notready_nodes -gt 0 ]]; then log_fail "$notready_nodes node(s) NotReady"; fi
    if [[ $scheduling_disabled -gt 0 ]]; then log_warn "$scheduling_disabled node(s) with SchedulingDisabled"; fi

    # Node resource summary
    log_subheader "Node Resource Capacity"
    run_oc top nodes 2>/dev/null | head -20 || log_warn "Could not get node resource usage (metrics-server may be unavailable)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. MACHINE CONFIG POOLS
# ─────────────────────────────────────────────────────────────────────────────
check_machine_config_pools() {
    log_header "4. MACHINE CONFIG POOLS (MCP)"

    local mcp_json
    mcp_json=$(run_oc get machineconfigpools -o json 2>/dev/null) || {
        log_warn "Could not retrieve MachineConfigPools"
        return
    }

    while IFS='|' read -r name updated updating degraded mc_count ready_count unavail_count degraded_count; do
        echo -e "  MCP: ${BOLD}$name${NC}  MachineCount=$mc_count  Ready=$ready_count  Unavailable=$unavail_count"

        if [[ "$updated" == "True" ]]; then log_pass "MCP $name: Updated"; else log_warn "MCP $name: Not fully updated"; fi
        if [[ "$updating" == "False" ]]; then log_pass "MCP $name: Not updating"; else log_warn "MCP $name: Update in progress"; fi
        if [[ "$degraded" == "False" ]]; then log_pass "MCP $name: Not degraded"; else log_fail "MCP $name: DEGRADED (degraded nodes: $degraded_count)"; fi
    done < <(echo "$mcp_json" | jq -r '
        .items[]? |
        (.metadata.name) + "|" +
        ([.status.conditions[]? | select(.type=="Updated") | .status][0] // "Unknown") + "|" +
        ([.status.conditions[]? | select(.type=="Updating") | .status][0] // "Unknown") + "|" +
        ([.status.conditions[]? | select(.type=="Degraded") | .status][0] // "Unknown") + "|" +
        (.status.machineCount // 0 | tostring) + "|" +
        (.status.readyMachineCount // 0 | tostring) + "|" +
        (.status.unavailableMachineCount // 0 | tostring) + "|" +
        (.status.degradedMachineCount // 0 | tostring)
    ')
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. ETCD HEALTH
# ─────────────────────────────────────────────────────────────────────────────
check_etcd() {
    log_header "5. ETCD HEALTH"

    # Check etcd pods
    local etcd_pods
    etcd_pods=$(run_oc get pods -n openshift-etcd -l app=etcd -o json 2>/dev/null) || {
        log_warn "Could not query openshift-etcd namespace"
        return
    }

    local total_etcd running_etcd
    total_etcd=$(echo "$etcd_pods" | jq '.items | length')
    running_etcd=$(echo "$etcd_pods" | jq '[.items[]? | select(.status.phase=="Running")] | length')

    if [[ $running_etcd -eq $total_etcd && $total_etcd -gt 0 ]]; then
        log_pass "All $total_etcd etcd pods running"
    else
        log_fail "etcd: $running_etcd/$total_etcd pods running"
    fi

    # Check etcd operator
    local etcd_co
    etcd_co=$(run_oc get clusteroperator etcd -o json 2>/dev/null)
    if [[ -n "$etcd_co" ]]; then
        local etcd_avail etcd_degr
        etcd_avail=$(echo "$etcd_co" | jq -r '[.status.conditions[]? | select(.type=="Available") | .status][0] // "Unknown"')
        etcd_degr=$(echo "$etcd_co" | jq -r '[.status.conditions[]? | select(.type=="Degraded") | .status][0] // "Unknown"')
        if [[ "$etcd_avail" == "True" ]]; then log_pass "etcd operator: Available"; else log_fail "etcd operator: Not Available"; fi
        if [[ "$etcd_degr" == "False" ]]; then log_pass "etcd operator: Not Degraded"; else log_fail "etcd operator: DEGRADED"; fi
    fi

    # Check for high restart counts
    log_subheader "etcd Pod Restart Counts"
    while IFS='|' read -r pod_name restarts; do
        if [[ $restarts -gt 5 ]]; then
            log_warn "etcd pod $pod_name has $restarts restarts"
        else
            log_pass "etcd pod $pod_name: $restarts restarts"
        fi
    done < <(echo "$etcd_pods" | jq -r '.items[]? | (.metadata.name) + "|" + (.status.containerStatuses[0].restartCount // 0 | tostring)')
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. CRITICAL NAMESPACE POD HEALTH
# ─────────────────────────────────────────────────────────────────────────────
check_namespace_health() {
    local ns="$1"
    local pods_json
    pods_json=$(run_oc get pods -n "$ns" -o json 2>/dev/null) || {
        log_warn "Could not query namespace: $ns"
        return
    }

    local total running succeeded failed pending crashloop imagepull
    total=$(echo "$pods_json" | jq '.items | length')
    running=$(echo "$pods_json" | jq '[.items[]? | select(.status.phase=="Running")] | length')
    succeeded=$(echo "$pods_json" | jq '[.items[]? | select(.status.phase=="Succeeded")] | length')
    failed=$(echo "$pods_json" | jq '[.items[]? | select(.status.phase=="Failed")] | length')
    pending=$(echo "$pods_json" | jq '[.items[]? | select(.status.phase=="Pending")] | length')

    # CrashLoopBackOff
    crashloop=$(echo "$pods_json" | jq '[.items[]? | select(.status.containerStatuses[]? | .state.waiting.reason == "CrashLoopBackOff")] | length')
    imagepull=$(echo "$pods_json" | jq '[.items[]? | select(.status.containerStatuses[]? | .state.waiting.reason == "ImagePullBackOff" or .state.waiting.reason == "ErrImagePull")] | length')

    local active=$((running + succeeded))
    if [[ $total -eq 0 ]]; then
        log_info "$ns: No pods found"
    elif [[ $failed -eq 0 && $pending -eq 0 && $crashloop -eq 0 && $imagepull -eq 0 ]]; then
        log_pass "$ns: All $total pods healthy ($running running, $succeeded completed)"
    else
        if [[ $failed -gt 0 ]]; then log_fail "$ns: $failed pod(s) in Failed state"; fi
        if [[ $pending -gt 0 ]]; then log_warn "$ns: $pending pod(s) in Pending state"; fi
        if [[ $imagepull -gt 0 ]]; then log_fail "$ns: $imagepull pod(s) in ImagePullBackOff"; fi

        # CrashLoopBackOff — log each pod with details
        if [[ $crashloop -gt 0 ]]; then
            log_fail "$ns: $crashloop pod(s) in CrashLoopBackOff"
            local clb_details
            clb_details=$(echo "$pods_json" | jq -r '
                .items[]? |
                select(.status.containerStatuses[]? | .state.waiting.reason == "CrashLoopBackOff") |
                {
                    pod: .metadata.name,
                    restarts: ([.status.containerStatuses[]?.restartCount] | max),
                    container: ([.status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff") | .name][0]),
                    last_exit_code: ([.status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff") | .lastState.terminated.exitCode // null][0]),
                    last_reason: ([.status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff") | .lastState.terminated.reason // "Unknown"][0]),
                    last_finished: ([.status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff") | .lastState.terminated.finishedAt // "N/A"][0])
                } |
                "\(.pod)|\(.container)|\(.restarts)|\(.last_exit_code // "N/A")|\(.last_reason)|\(.last_finished)"
            ')
            while IFS='|' read -r clb_pod clb_container clb_restarts clb_exit clb_reason clb_finished; do
                [[ -z "$clb_pod" ]] && continue
                log_fail "$ns: CrashLoop → Pod=$clb_pod Container=$clb_container Restarts=$clb_restarts ExitCode=$clb_exit Reason=$clb_reason LastTerminated=$clb_finished"
            done <<< "$clb_details"
        fi
    fi

    # High restart counts (>10)
    local high_restart_pods
    high_restart_pods=$(echo "$pods_json" | jq -r '
        .items[]? | select(.status.containerStatuses[]? | .restartCount > 10) |
        (.metadata.name) + " (restarts: " + ([.status.containerStatuses[]?.restartCount] | max | tostring) + ")"
    ')
    if [[ -n "$high_restart_pods" ]]; then
        while IFS= read -r line; do
            log_warn "$ns: High restarts — $line"
        done <<< "$high_restart_pods"
    fi
}

check_critical_namespaces() {
    log_header "6. CRITICAL NAMESPACE POD HEALTH"

    local CRITICAL_NAMESPACES=(
        "openshift-etcd"
        "openshift-kube-apiserver"
        "openshift-kube-controller-manager"
        "openshift-kube-scheduler"
        "openshift-apiserver"
        "openshift-controller-manager"
        "openshift-authentication"
        "openshift-oauth-apiserver"
        "openshift-console"
        "openshift-ingress"
        "openshift-dns"
        "openshift-image-registry"
        "openshift-monitoring"
        "openshift-logging"
        "openshift-machine-api"
        "openshift-machine-config-operator"
        "openshift-network-operator"
        "openshift-sdn"
        "openshift-ovn-kubernetes"
        "openshift-marketplace"
        "openshift-operator-lifecycle-manager"
        "openshift-operators"
        "openshift-storage"
        "openshift-cluster-csi-drivers"
    )

    for ns in "${CRITICAL_NAMESPACES[@]}"; do
        # Only check if namespace exists
        if run_oc get namespace "$ns" &>/dev/null; then
            check_namespace_health "$ns"
        fi
    done

    # Check user-specified namespaces
    for ns in "${EXTRA_NAMESPACES[@]}"; do
        log_subheader "User Namespace: $ns"
        if run_oc get namespace "$ns" &>/dev/null; then
            check_namespace_health "$ns"
        else
            log_warn "Namespace $ns does not exist"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. INGRESS / ROUTER HEALTH
# ─────────────────────────────────────────────────────────────────────────────
check_ingress() {
    log_header "7. INGRESS CONTROLLERS"

    local ic_json
    ic_json=$(run_oc get ingresscontrollers -n openshift-ingress-operator -o json 2>/dev/null) || {
        log_warn "Could not retrieve IngressControllers"
        return
    }

    while IFS='|' read -r name avail replicas ready_replicas domain; do
        echo -e "  IngressController: ${BOLD}$name${NC}  Domain=$domain  Replicas=$replicas  Ready=$ready_replicas"

        if [[ "$replicas" == "$ready_replicas" && "$replicas" != "0" ]]; then
            log_pass "IngressController $name: All replicas ready ($ready_replicas/$replicas)"
        else
            log_fail "IngressController $name: $ready_replicas/$replicas replicas ready"
        fi

        if [[ "$avail" == "True" ]]; then log_pass "IngressController $name: Available"; else log_fail "IngressController $name: NOT Available"; fi
    done < <(echo "$ic_json" | jq -r '
        .items[]? |
        (.metadata.name) + "|" +
        ([.status.conditions[]? | select(.type=="Available") | .status][0] // "Unknown") + "|" +
        (.spec.replicas // .status.availableReplicas // 0 | tostring) + "|" +
        (.status.availableReplicas // 0 | tostring) + "|" +
        (.status.domain // "unknown")
    ')
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. PERSISTENT STORAGE
# ─────────────────────────────────────────────────────────────────────────────
check_storage() {
    log_header "8. PERSISTENT STORAGE"

    # PVs
    log_subheader "PersistentVolumes"
    local pv_json
    pv_json=$(run_oc get pv -o json 2>/dev/null) || {
        log_warn "Could not retrieve PersistentVolumes"
        return
    }

    local total_pv bound_pv released_pv failed_pv available_pv
    total_pv=$(echo "$pv_json" | jq '.items | length')
    bound_pv=$(echo "$pv_json" | jq '[.items[]? | select(.status.phase=="Bound")] | length')
    released_pv=$(echo "$pv_json" | jq '[.items[]? | select(.status.phase=="Released")] | length')
    failed_pv=$(echo "$pv_json" | jq '[.items[]? | select(.status.phase=="Failed")] | length')
    available_pv=$(echo "$pv_json" | jq '[.items[]? | select(.status.phase=="Available")] | length')

    log_info "Total PVs: $total_pv (Bound=$bound_pv, Available=$available_pv, Released=$released_pv, Failed=$failed_pv)"
    if [[ $failed_pv -gt 0 ]]; then log_fail "$failed_pv PV(s) in Failed state"; fi
    if [[ $released_pv -gt 0 ]]; then log_warn "$released_pv PV(s) in Released state (may need cleanup)"; fi

    # PVCs
    log_subheader "PersistentVolumeClaims (non-Bound)"
    local problem_pvcs
    problem_pvcs=$(run_oc get pvc --all-namespaces -o json 2>/dev/null | jq -r '
        .items[]? | select(.status.phase != "Bound") |
        "    \(.metadata.namespace)/\(.metadata.name) — \(.status.phase)"
    ')
    if [[ -n "$problem_pvcs" ]]; then
        echo "$problem_pvcs"
        local count
        count=$(echo "$problem_pvcs" | wc -l)
        log_warn "$count PVC(s) not in Bound state"
    else
        log_pass "All PVCs are Bound"
    fi

    # StorageClasses
    log_subheader "StorageClasses"
    local sc_count default_sc
    sc_count=$(run_oc get storageclass -o json 2>/dev/null | jq '.items | length')
    default_sc=$(run_oc get storageclass -o json 2>/dev/null | jq -r '.items[]? | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true") | .metadata.name')
    log_info "StorageClasses: $sc_count"
    if [[ -n "$default_sc" ]]; then log_pass "Default StorageClass: $default_sc"; else log_warn "No default StorageClass defined"; fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. CERTIFICATE HEALTH
# ─────────────────────────────────────────────────────────────────────────────
check_certificates() {
    log_header "9. CERTIFICATE HEALTH"

    if [[ "$SKIP_CERTS" == "true" ]]; then
        log_info "Certificate checks skipped (--skip-certs)"
        return
    fi

    # Pending CSRs
    log_subheader "Certificate Signing Requests"
    local pending_csrs
    pending_csrs=$(run_oc get csr -o json 2>/dev/null | jq '[.items[]? | select(.status == {} or .status.conditions == null)] | length')
    if [[ $pending_csrs -gt 0 ]]; then
        log_warn "$pending_csrs CSR(s) pending approval"
        run_oc get csr 2>/dev/null | grep -i pending | head -10
    else
        log_pass "No pending CSRs"
    fi

    # Check secrets with TLS certs for upcoming expiry
    log_subheader "Certificate Expiry (critical namespaces)"
    local cert_warnings=0

    for ns in openshift-kube-apiserver openshift-etcd openshift-ingress openshift-authentication; do
        local secrets
        secrets=$(run_oc get secrets -n "$ns" -o json 2>/dev/null | jq -r '.items[]? | select(.type=="kubernetes.io/tls") | .metadata.name' 2>/dev/null)
        while IFS= read -r secret; do
            [[ -z "$secret" ]] && continue
            local cert_data
            cert_data=$(run_oc get secret "$secret" -n "$ns" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null)
            if [[ -n "$cert_data" ]]; then
                local expiry
                expiry=$(echo "$cert_data" | openssl x509 -enddate -noout 2>/dev/null | sed 's/notAfter=//')
                if [[ -n "$expiry" ]]; then
                    local expiry_epoch now_epoch days_left
                    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
                    now_epoch=$(date +%s)
                    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                    if [[ $days_left -lt 30 ]]; then
                        log_fail "CERT EXPIRING in ${days_left}d: $ns/$secret (expires $expiry)"
                        ((cert_warnings++)) || true
                    elif [[ $days_left -lt 90 ]]; then
                        log_warn "Cert expiring in ${days_left}d: $ns/$secret"
                        ((cert_warnings++)) || true
                    fi
                fi
            fi
        done <<< "$secrets"
    done

    if [[ $cert_warnings -eq 0 ]]; then log_pass "No certificates expiring within 90 days (checked critical namespaces)"; fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. WORKLOAD HEALTH (cluster-wide)
# ─────────────────────────────────────────────────────────────────────────────
check_workloads() {
    log_header "10. WORKLOAD HEALTH (Cluster-Wide)"

    # Problem pods
    log_subheader "Problem Pods Across All Namespaces"
    local problem_pods
    problem_pods=$(run_oc get pods --all-namespaces --field-selector 'status.phase!=Running,status.phase!=Succeeded' -o json 2>/dev/null)

    local pending_pods failed_pods unknown_pods
    pending_pods=$(echo "$problem_pods" | jq '[.items[]? | select(.status.phase=="Pending")] | length')
    failed_pods=$(echo "$problem_pods" | jq '[.items[]? | select(.status.phase=="Failed")] | length')
    unknown_pods=$(echo "$problem_pods" | jq '[.items[]? | select(.status.phase=="Unknown")] | length')

    if [[ $pending_pods -gt 0 ]]; then log_warn "$pending_pods pod(s) in Pending state cluster-wide"; else log_pass "No Pending pods"; fi
    if [[ $failed_pods -gt 0 ]]; then log_warn "$failed_pods pod(s) in Failed state cluster-wide"; else log_pass "No Failed pods"; fi
    if [[ $unknown_pods -gt 0 ]]; then log_warn "$unknown_pods pod(s) in Unknown state cluster-wide"; fi

    # Show top offenders
    if [[ $((pending_pods + failed_pods)) -gt 0 ]]; then
        echo ""
        echo "  Top problem pods:"
        echo "$problem_pods" | jq -r '.items[]? | select(.status.phase=="Pending" or .status.phase=="Failed") | "    \(.metadata.namespace)/\(.metadata.name) — \(.status.phase) — \(.status.reason // "unknown reason")"' | head -15
    fi

    # CrashLoopBackOff pods — with per-pod detail
    log_subheader "CrashLoopBackOff Pods"
    local all_pods_json
    all_pods_json=$(run_oc get pods --all-namespaces -o json 2>/dev/null)

    local crash_details
    crash_details=$(echo "$all_pods_json" | jq -r '
        .items[]? |
        select(.status.containerStatuses[]? | .state.waiting.reason == "CrashLoopBackOff") |
        {
            ns: .metadata.namespace,
            pod: .metadata.name,
            restarts: ([.status.containerStatuses[]?.restartCount] | max),
            container: ([.status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff") | .name][0]),
            exit_code: ([.status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff") | .lastState.terminated.exitCode // null][0]),
            reason: ([.status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff") | .lastState.terminated.reason // "Unknown"][0]),
            finished: ([.status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff") | .lastState.terminated.finishedAt // "N/A"][0]),
            node: (.spec.nodeName // "unassigned")
        } |
        "\(.ns)|\(.pod)|\(.container)|\(.restarts)|\(.exit_code // "N/A")|\(.reason)|\(.finished)|\(.node)"
    ')

    if [[ -n "$crash_details" ]]; then
        local crash_count
        crash_count=$(echo "$crash_details" | grep -c '|' || true)
        log_fail "$crash_count pod(s) in CrashLoopBackOff cluster-wide"
        while IFS='|' read -r c_ns c_pod c_ctr c_restarts c_exit c_reason c_finished c_node; do
            [[ -z "$c_pod" ]] && continue
            log_fail "CrashLoop → $c_ns/$c_pod Container=$c_ctr Restarts=$c_restarts ExitCode=$c_exit Reason=$c_reason Node=$c_node LastTerminated=$c_finished"
        done <<< "$crash_details"
    else
        log_pass "No pods in CrashLoopBackOff"
    fi

    # Deployments not at desired replicas
    log_subheader "Deployments with Unavailable Replicas"
    local deploy_issues
    deploy_issues=$(run_oc get deployments --all-namespaces -o json 2>/dev/null | jq -r '
        .items[]? | select((.status.unavailableReplicas // 0) > 0) |
        "    \(.metadata.namespace)/\(.metadata.name) — desired=\(.spec.replicas) available=\(.status.availableReplicas // 0) unavailable=\(.status.unavailableReplicas)"
    ')
    if [[ -n "$deploy_issues" ]]; then
        local deploy_issue_count
        deploy_issue_count=$(echo "$deploy_issues" | wc -l)
        log_warn "$deploy_issue_count deployment(s) with unavailable replicas"
        echo "$deploy_issues" | head -15
    else
        log_pass "All deployments at desired replica count"
    fi

    # DaemonSets
    log_subheader "DaemonSets with Unavailable Nodes"
    local ds_issues
    ds_issues=$(run_oc get daemonsets --all-namespaces -o json 2>/dev/null | jq -r '
        .items[]? | select((.status.numberUnavailable // 0) > 0) |
        "    \(.metadata.namespace)/\(.metadata.name) — desired=\(.status.desiredNumberScheduled) ready=\(.status.numberReady) unavailable=\(.status.numberUnavailable)"
    ')
    if [[ -n "$ds_issues" ]]; then
        log_warn "DaemonSets with unavailable instances:"
        echo "$ds_issues" | head -10
    else
        log_pass "All DaemonSets fully scheduled"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 10b. APPLICATION NAMESPACE — DEPLOYMENTS & HPA
#      (excludes openshift-*, kube-*, default, and operator namespaces)
# ─────────────────────────────────────────────────────────────────────────────
is_system_namespace() {
    local ns="$1"
    case "$ns" in
        openshift-*|kube-*|default|openshift|kube-system|kube-public|kube-node-lease) return 0 ;;
        *operator*|*olm*|*marketplace*|*csi*|*cert-manager*) return 0 ;;
        *) return 1 ;;
    esac
}

check_application_namespaces() {
    log_header "10b. APPLICATION NAMESPACE — PODS, DEPLOYMENTS, HPA & RESOURCE USAGE"
    log_info "Scanning non-system namespaces (excludes openshift-*, kube-*, operators)..."

    # Get all namespaces, filter out system ones
    local all_ns
    all_ns=$(run_oc get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    local app_ns_count=0
    local app_ns_list=()

    for ns in $all_ns; do
        if ! is_system_namespace "$ns"; then
            app_ns_list+=("$ns")
            ((app_ns_count++)) || true
        fi
    done

    if [[ $app_ns_count -eq 0 ]]; then
        log_info "No application namespaces found (all namespaces are system/operator namespaces)"
        return
    fi

    log_info "Application namespaces found: $app_ns_count"

    for ns in "${app_ns_list[@]}"; do
        log_subheader "━━━ Namespace: $ns ━━━"

        # ══════════════════════════════════════
        # A. POD LISTING — all pods in namespace
        # ══════════════════════════════════════
        local pods_json
        pods_json=$(run_oc get pods -n "$ns" -o json 2>/dev/null)
        local pod_total pod_running pod_failed pod_pending pod_crashloop
        pod_total=$(echo "$pods_json" | jq '.items | length' 2>/dev/null || echo "0")
        pod_running=$(echo "$pods_json" | jq '[.items[]? | select(.status.phase=="Running")] | length' 2>/dev/null || echo "0")
        pod_failed=$(echo "$pods_json" | jq '[.items[]? | select(.status.phase=="Failed")] | length' 2>/dev/null || echo "0")
        pod_pending=$(echo "$pods_json" | jq '[.items[]? | select(.status.phase=="Pending")] | length' 2>/dev/null || echo "0")
        pod_crashloop=$(echo "$pods_json" | jq '[.items[]? | select(.status.containerStatuses[]? | .state.waiting.reason == "CrashLoopBackOff")] | length' 2>/dev/null || echo "0")

        log_info "$ns: Total Pods=$pod_total Running=$pod_running Pending=$pod_pending Failed=$pod_failed CrashLoop=$pod_crashloop"

        # List every pod with status
        if [[ "$pod_total" -gt 0 ]]; then
            while IFS='|' read -r p_name p_phase p_ready_ct p_total_ct p_restarts p_node p_age; do
                [[ -z "$p_name" ]] && continue
                local p_ready_str="${p_ready_ct}/${p_total_ct}"

                if [[ "$p_phase" == "Running" && "$p_ready_ct" == "$p_total_ct" ]]; then
                    log_pass "$ns: Pod=$p_name Status=$p_phase Ready=$p_ready_str Restarts=$p_restarts Node=$p_node"
                elif [[ "$p_phase" == "Succeeded" ]]; then
                    log_info "$ns: Pod=$p_name Status=Completed"
                elif [[ "$p_phase" == "Running" && "$p_ready_ct" != "$p_total_ct" ]]; then
                    log_warn "$ns: Pod=$p_name Status=$p_phase Ready=$p_ready_str (NOT ALL READY) Restarts=$p_restarts Node=$p_node"
                else
                    log_fail "$ns: Pod=$p_name Status=$p_phase Ready=$p_ready_str Restarts=$p_restarts Node=$p_node"
                fi
            done < <(echo "$pods_json" | jq -r '
                .items[]? |
                (.metadata.name) + "|" +
                (.status.phase // "Unknown") + "|" +
                ([.status.containerStatuses[]? | select(.ready==true)] | length | tostring) + "|" +
                ([.status.containerStatuses[]?] | length | tostring) + "|" +
                ([.status.containerStatuses[]?.restartCount // 0] | add // 0 | tostring) + "|" +
                (.spec.nodeName // "unassigned") + "|" +
                (.metadata.creationTimestamp // "")
            ')

            # CrashLoopBackOff details
            if [[ "$pod_crashloop" -gt 0 ]]; then
                while IFS='|' read -r cl_pod cl_ctr cl_restarts cl_exit cl_reason; do
                    [[ -z "$cl_pod" ]] && continue
                    log_fail "$ns: CRASHLOOP → Pod=$cl_pod Container=$cl_ctr Restarts=$cl_restarts ExitCode=$cl_exit Reason=$cl_reason"
                done < <(echo "$pods_json" | jq -r '
                    .items[]? |
                    select(.status.containerStatuses[]? | .state.waiting.reason == "CrashLoopBackOff") |
                    (.metadata.name) + "|" +
                    ([.status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff") | .name][0] // "unknown") + "|" +
                    ([.status.containerStatuses[]?.restartCount] | max | tostring) + "|" +
                    ([.status.containerStatuses[]? | .lastState.terminated.exitCode // null][0] | tostring) + "|" +
                    ([.status.containerStatuses[]? | .lastState.terminated.reason // "Unknown"][0])
                ')
            fi
        fi

        # ══════════════════════════════════════════════════════
        # B. RESOURCE USAGE — oc adm top pods with thresholds
        #    >80% CPU or Memory = WARN, >90% = FAIL
        # ══════════════════════════════════════════════════════
        log_subheader "$ns — Resource Usage (oc adm top pods)"
        local top_output
        top_output=$(run_oc adm top pods -n "$ns" --no-headers 2>/dev/null)

        if [[ -n "$top_output" ]]; then
            # Get resource requests/limits for comparison
            local resources_json
            resources_json=$(run_oc get pods -n "$ns" -o json 2>/dev/null | jq '[
                .items[]? | select(.status.phase=="Running") | {
                    name: .metadata.name,
                    cpu_req: ([.spec.containers[]?.resources.requests.cpu // "0"] | first),
                    cpu_lim: ([.spec.containers[]?.resources.limits.cpu // "0"] | first),
                    mem_req: ([.spec.containers[]?.resources.requests.memory // "0"] | first),
                    mem_lim: ([.spec.containers[]?.resources.limits.memory // "0"] | first)
                }
            ]' 2>/dev/null)

            while read -r line; do
                [[ -z "$line" ]] && continue
                local t_pod t_cpu t_mem
                t_pod=$(echo "$line" | awk '{print $1}')
                t_cpu=$(echo "$line" | awk '{print $2}')
                t_mem=$(echo "$line" | awk '{print $3}')

                # Extract numeric CPU in millicores
                local cpu_val=0
                if [[ "$t_cpu" == *"m" ]]; then
                    cpu_val=$(echo "$t_cpu" | sed 's/m//')
                else
                    cpu_val=$((${t_cpu:-0} * 1000))
                fi

                # Extract numeric Memory in Mi
                local mem_val=0
                if [[ "$t_mem" == *"Mi" ]]; then
                    mem_val=$(echo "$t_mem" | sed 's/Mi//')
                elif [[ "$t_mem" == *"Gi" ]]; then
                    mem_val=$(echo "$t_mem" | sed 's/Gi//' | awk '{printf "%.0f", $1 * 1024}')
                fi

                # Get limits for this pod
                local pod_cpu_lim pod_mem_lim
                pod_cpu_lim=$(echo "$resources_json" | jq -r --arg p "$t_pod" '[.[]? | select(.name==$p) | .cpu_lim][0] // "0"' 2>/dev/null)
                pod_mem_lim=$(echo "$resources_json" | jq -r --arg p "$t_pod" '[.[]? | select(.name==$p) | .mem_lim][0] // "0"' 2>/dev/null)

                # Calculate CPU limit in millicores
                local cpu_lim_val=0
                if [[ "$pod_cpu_lim" == *"m" ]]; then
                    cpu_lim_val=$(echo "$pod_cpu_lim" | sed 's/m//')
                elif [[ "$pod_cpu_lim" != "0" && "$pod_cpu_lim" != "null" ]]; then
                    cpu_lim_val=$((${pod_cpu_lim:-0} * 1000))
                fi

                # Calculate Memory limit in Mi
                local mem_lim_val=0
                if [[ "$pod_mem_lim" == *"Mi" ]]; then
                    mem_lim_val=$(echo "$pod_mem_lim" | sed 's/Mi//')
                elif [[ "$pod_mem_lim" == *"Gi" ]]; then
                    mem_lim_val=$(echo "$pod_mem_lim" | sed 's/Gi//' | awk '{printf "%.0f", $1 * 1024}')
                fi

                # Determine threshold status
                local top_status="PASS"
                local cpu_pct="N/A" mem_pct="N/A"

                if [[ $cpu_lim_val -gt 0 ]]; then
                    cpu_pct=$((cpu_val * 100 / cpu_lim_val))
                    if [[ $cpu_pct -ge 90 ]]; then
                        top_status="FAIL"
                    elif [[ $cpu_pct -ge 80 ]]; then
                        if [[ "$top_status" != "FAIL" ]]; then top_status="WARN"; fi
                    fi
                    cpu_pct="${cpu_pct}%"
                fi

                if [[ $mem_lim_val -gt 0 ]]; then
                    mem_pct=$((mem_val * 100 / mem_lim_val))
                    if [[ $mem_pct -ge 90 ]]; then
                        top_status="FAIL"
                    elif [[ $mem_pct -ge 80 ]]; then
                        if [[ "$top_status" != "FAIL" ]]; then top_status="WARN"; fi
                    fi
                    mem_pct="${mem_pct}%"
                fi

                local top_msg="$ns: Pod=$t_pod CPU=${t_cpu}(${cpu_pct}of_limit) MEM=${t_mem}(${mem_pct}of_limit)"

                case "$top_status" in
                    PASS) log_pass "$top_msg" ;;
                    WARN) log_warn "$top_msg ⚠ ABOVE 80% THRESHOLD" ;;
                    FAIL) log_fail "$top_msg ✘ ABOVE 90% THRESHOLD — CRITICAL" ;;
                esac
            done <<< "$top_output"
        else
            log_info "$ns: No resource usage data (no running pods or metrics-server unavailable)"
        fi

        # ══════════════════════════════════════
        # C. DEPLOYMENTS — full details
        # ══════════════════════════════════════
        log_subheader "$ns — Deployments"
        local deploy_json
        deploy_json=$(run_oc get deployments -n "$ns" -o json 2>/dev/null)
        local deploy_count
        deploy_count=$(echo "$deploy_json" | jq '.items | length' 2>/dev/null || echo "0")

        if [[ "$deploy_count" -eq 0 ]]; then
            log_info "$ns: No deployments found"
        else
            log_info "$ns: $deploy_count deployment(s)"
            while IFS='|' read -r d_name d_desired d_ready d_available d_unavailable d_updated d_image d_strategy d_gen d_observed_gen; do
                [[ -z "$d_name" ]] && continue

                if [[ "$d_desired" == "$d_available" && "$d_desired" != "0" ]]; then
                    log_pass "$ns: Deploy=$d_name Replicas=$d_desired/$d_available Ready=$d_ready Updated=$d_updated Strategy=$d_strategy Image=$d_image"
                elif [[ "${d_unavailable:-0}" != "0" && "${d_unavailable:-0}" -gt 0 ]]; then
                    log_fail "$ns: Deploy=$d_name Desired=$d_desired Available=$d_available UNAVAILABLE=$d_unavailable Ready=$d_ready Image=$d_image"
                elif [[ "$d_desired" == "0" ]]; then
                    log_warn "$ns: Deploy=$d_name SCALED TO ZERO Image=$d_image"
                else
                    log_warn "$ns: Deploy=$d_name Desired=$d_desired Available=${d_available:-0} Ready=$d_ready Image=$d_image"
                fi
            done < <(echo "$deploy_json" | jq -r '
                .items[]? |
                (.metadata.name) + "|" +
                (.spec.replicas // 0 | tostring) + "|" +
                (.status.readyReplicas // 0 | tostring) + "|" +
                (.status.availableReplicas // 0 | tostring) + "|" +
                (.status.unavailableReplicas // 0 | tostring) + "|" +
                (.status.updatedReplicas // 0 | tostring) + "|" +
                ([.spec.template.spec.containers[0].image] | first // "unknown" | split("/") | last) + "|" +
                (.spec.strategy.type // "RollingUpdate") + "|" +
                (.metadata.generation // 0 | tostring) + "|" +
                (.status.observedGeneration // 0 | tostring)
            ')
        fi

        # ══════════════════════════════════════
        # D. HPA (HorizontalPodAutoscalers)
        # ══════════════════════════════════════
        log_subheader "$ns — HPA (Horizontal Pod Autoscaler)"
        local hpa_json
        hpa_json=$(run_oc get hpa -n "$ns" -o json 2>/dev/null)
        local hpa_count
        hpa_count=$(echo "$hpa_json" | jq '.items | length' 2>/dev/null || echo "0")

        if [[ "$hpa_count" -eq 0 ]]; then
            log_info "$ns: No HPA configured"
        else
            log_info "$ns: $hpa_count HPA(s)"
            while IFS='|' read -r h_name h_target h_min h_max h_current h_cpu_target h_cpu_current h_mem_target h_mem_current; do
                [[ -z "$h_name" ]] && continue

                local hpa_health="PASS"
                local hpa_detail="HPA=$h_name Target=$h_target Min=$h_min Max=$h_max Current=$h_current"

                # CPU info
                if [[ "$h_cpu_target" != "null" && -n "$h_cpu_target" ]]; then
                    hpa_detail+=" CPU=${h_cpu_current:-?}%/${h_cpu_target}%"
                    # Check if CPU above target
                    if [[ "$h_cpu_current" != "null" && -n "$h_cpu_current" && "$h_cpu_target" != "0" ]]; then
                        if [[ "$h_cpu_current" -gt "$h_cpu_target" ]]; then
                            hpa_health="WARN"
                            hpa_detail+="(ABOVE TARGET)"
                        fi
                    fi
                fi

                # Memory info
                if [[ "$h_mem_target" != "null" && -n "$h_mem_target" ]]; then
                    hpa_detail+=" Mem=${h_mem_current:-?}%/${h_mem_target}%"
                fi

                # At max replicas
                if [[ "$h_current" == "$h_max" && "$h_max" != "0" ]]; then
                    hpa_health="WARN"
                    hpa_detail+=" ⚠ AT MAX REPLICAS — CANNOT SCALE FURTHER"
                fi

                # No replicas
                if [[ "$h_current" == "0" ]]; then
                    hpa_health="FAIL"
                    hpa_detail+=" ✘ NO ACTIVE REPLICAS"
                fi

                case "$hpa_health" in
                    PASS) log_pass "$ns: $hpa_detail" ;;
                    WARN) log_warn "$ns: $hpa_detail" ;;
                    FAIL) log_fail "$ns: $hpa_detail" ;;
                esac
            done < <(echo "$hpa_json" | jq -r '
                .items[]? |
                (.metadata.name) + "|" +
                (.spec.scaleTargetRef.name // "unknown") + "|" +
                (.spec.minReplicas // 1 | tostring) + "|" +
                (.spec.maxReplicas // 0 | tostring) + "|" +
                (.status.currentReplicas // 0 | tostring) + "|" +
                ([.spec.metrics[]? | select(.type=="Resource" and .resource.name=="cpu") | .resource.target.averageUtilization // null][0] | tostring) + "|" +
                ([.status.currentMetrics[]? | select(.type=="Resource" and .resource.name=="cpu") | .resource.current.averageUtilization // null][0] | tostring) + "|" +
                ([.spec.metrics[]? | select(.type=="Resource" and .resource.name=="memory") | .resource.target.averageUtilization // null][0] | tostring) + "|" +
                ([.status.currentMetrics[]? | select(.type=="Resource" and .resource.name=="memory") | .resource.current.averageUtilization // null][0] | tostring)
            ')
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 11. OLM OPERATORS & CATALOG SOURCES
# ─────────────────────────────────────────────────────────────────────────────
check_olm_operators() {
    log_header "11. OLM OPERATORS & CATALOG SOURCES"

    # ClusterServiceVersions
    log_subheader "ClusterServiceVersions (CSVs)"
    local csv_json
    csv_json=$(run_oc get csv --all-namespaces -o json 2>/dev/null) || {
        log_warn "Could not retrieve CSVs"
        return
    }

    local total_csv succeeded_csv failed_csv pending_csv
    total_csv=$(echo "$csv_json" | jq '.items | length')
    succeeded_csv=$(echo "$csv_json" | jq '[.items[]? | select(.status.phase=="Succeeded")] | length')
    failed_csv=$(echo "$csv_json" | jq '[.items[]? | select(.status.phase=="Failed")] | length')
    pending_csv=$(echo "$csv_json" | jq '[.items[]? | select(.status.phase!="Succeeded" and .status.phase!="Failed")] | length')

    log_info "Total CSVs: $total_csv (Succeeded=$succeeded_csv, Failed=$failed_csv, Other=$pending_csv)"

    if [[ $failed_csv -gt 0 ]]; then
        log_fail "$failed_csv CSV(s) in Failed state:"
        echo "$csv_json" | jq -r '.items[]? | select(.status.phase=="Failed") | "    \(.metadata.namespace)/\(.metadata.name) — \(.status.reason // "unknown")"' | head -10
    fi

    if [[ $succeeded_csv -eq $total_csv ]]; then log_pass "All CSVs in Succeeded state"; fi

    # CatalogSources
    log_subheader "CatalogSources"
    local cs_json
    cs_json=$(run_oc get catalogsource --all-namespaces -o json 2>/dev/null)
    if [[ -n "$cs_json" ]]; then
        while IFS='|' read -r ns name state; do
            if [[ "$state" == "READY" ]]; then
                log_pass "CatalogSource $ns/$name: $state"
            else
                log_fail "CatalogSource $ns/$name: $state"
            fi
        done < <(echo "$cs_json" | jq -r '.items[]? | (.metadata.namespace) + "|" + (.metadata.name) + "|" + (.status.connectionState.lastObservedState // "UNKNOWN")')
    fi

    # Subscriptions
    log_subheader "Operator Subscriptions"
    local sub_json
    sub_json=$(run_oc get subscriptions --all-namespaces -o json 2>/dev/null)
    if [[ -n "$sub_json" ]]; then
        local total_subs
        total_subs=$(echo "$sub_json" | jq '.items | length')
        local problem_subs
        problem_subs=$(echo "$sub_json" | jq -r '
            .items[]? | select(.status.state != "AtLatestKnown" and .status.state != null) |
            "    \(.metadata.namespace)/\(.metadata.name) — state=\(.status.state // "unknown") currentCSV=\(.status.currentCSV // "none")"
        ')
        log_info "Total Subscriptions: $total_subs"
        if [[ -n "$problem_subs" ]]; then
            log_warn "Subscriptions not at latest:"
            echo "$problem_subs"
        else
            log_pass "All subscriptions at latest known version"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 12. NETWORKING
# ─────────────────────────────────────────────────────────────────────────────
check_networking() {
    log_header "12. NETWORKING"

    # Network operator
    local net_co
    net_co=$(run_oc get clusteroperator network -o json 2>/dev/null)
    if [[ -n "$net_co" ]]; then
        local net_avail net_degr
        net_avail=$(echo "$net_co" | jq -r '[.status.conditions[]? | select(.type=="Available") | .status][0] // "Unknown"')
        net_degr=$(echo "$net_co" | jq -r '[.status.conditions[]? | select(.type=="Degraded") | .status][0] // "Unknown"')
        if [[ "$net_avail" == "True" ]]; then log_pass "Network operator: Available"; else log_fail "Network operator: NOT Available"; fi
        if [[ "$net_degr" == "False" ]]; then log_pass "Network operator: Not Degraded"; else log_fail "Network operator: DEGRADED"; fi
    fi

    # DNS operator
    local dns_co
    dns_co=$(run_oc get clusteroperator dns -o json 2>/dev/null)
    if [[ -n "$dns_co" ]]; then
        local dns_avail dns_degr
        dns_avail=$(echo "$dns_co" | jq -r '[.status.conditions[]? | select(.type=="Available") | .status][0] // "Unknown"')
        dns_degr=$(echo "$dns_co" | jq -r '[.status.conditions[]? | select(.type=="Degraded") | .status][0] // "Unknown"')
        if [[ "$dns_avail" == "True" ]]; then log_pass "DNS operator: Available"; else log_fail "DNS operator: NOT Available"; fi
        if [[ "$dns_degr" == "False" ]]; then log_pass "DNS operator: Not Degraded"; else log_fail "DNS operator: DEGRADED"; fi
    fi

    # Network type
    local network_type
    network_type=$(run_oc get network.config cluster -o jsonpath='{.spec.networkType}' 2>/dev/null || echo "unknown")
    log_info "Network Type: $network_type"

    # Cluster CIDR
    local cluster_cidr service_cidr
    cluster_cidr=$(run_oc get network.config cluster -o jsonpath='{.spec.clusterNetwork[0].cidr}' 2>/dev/null || echo "unknown")
    service_cidr=$(run_oc get network.config cluster -o jsonpath='{.spec.serviceNetwork[0]}' 2>/dev/null || echo "unknown")
    log_info "Cluster CIDR: $cluster_cidr"
    log_info "Service CIDR: $service_cidr"
}

# ─────────────────────────────────────────────────────────────────────────────
# 13. MONITORING STACK
# ─────────────────────────────────────────────────────────────────────────────
check_monitoring() {
    log_header "13. MONITORING STACK"

    local mon_co
    mon_co=$(run_oc get clusteroperator monitoring -o json 2>/dev/null)
    if [[ -n "$mon_co" ]]; then
        local mon_avail mon_degr
        mon_avail=$(echo "$mon_co" | jq -r '[.status.conditions[]? | select(.type=="Available") | .status][0] // "Unknown"')
        mon_degr=$(echo "$mon_co" | jq -r '[.status.conditions[]? | select(.type=="Degraded") | .status][0] // "Unknown"')
        if [[ "$mon_avail" == "True" ]]; then log_pass "Monitoring operator: Available"; else log_fail "Monitoring operator: NOT Available"; fi
        if [[ "$mon_degr" == "False" ]]; then log_pass "Monitoring operator: Not Degraded"; else log_fail "Monitoring operator: DEGRADED"; fi
    fi

    # Key monitoring pods
    log_subheader "Monitoring Components"
    for component in prometheus-k8s alertmanager-main thanos-querier grafana; do
        local pod_count
        pod_count=$(run_oc get pods -n openshift-monitoring -l "app.kubernetes.io/name=$component" -o json 2>/dev/null | jq '[.items[]? | select(.status.phase=="Running")] | length' 2>/dev/null || echo "0")
        if [[ "$pod_count" -gt 0 ]]; then
            log_pass "$component: $pod_count pod(s) running"
        else
            # Try alternate labels
            pod_count=$(run_oc get pods -n openshift-monitoring -l "app=$component" -o json 2>/dev/null | jq '[.items[]? | select(.status.phase=="Running")] | length' 2>/dev/null || echo "0")
            if [[ "$pod_count" -gt 0 ]]; then
                log_pass "$component: $pod_count pod(s) running"
            else
                log_warn "$component: No running pods found"
            fi
        fi
    done

    # Firing alerts — critical and warning from Alertmanager
    log_subheader "Firing Alerts (Alertmanager)"
    local firing_alerts=""

    # Method 1: via alertmanager pod exec
    firing_alerts=$(run_oc exec -n openshift-monitoring -c alertmanager alertmanager-main-0 -- wget -qO- 'http://localhost:9093/api/v2/alerts?active=true&silenced=false&inhibited=false' 2>/dev/null || echo "")

    # Method 2: try via thanos-querier if method 1 failed
    if [[ -z "$firing_alerts" || "$firing_alerts" == "" ]]; then
        firing_alerts=$(run_oc exec -n openshift-monitoring -c thanos-query thanos-querier-0 -- wget -qO- 'http://localhost:9090/api/v1/alerts' 2>/dev/null | jq '.data.alerts // []' 2>/dev/null || echo "")
    fi

    # Method 3: try via prometheus pod
    if [[ -z "$firing_alerts" || "$firing_alerts" == "" ]]; then
        firing_alerts=$(run_oc exec -n openshift-monitoring -c prometheus prometheus-k8s-0 -- wget -qO- 'http://localhost:9090/api/v1/alerts' 2>/dev/null | jq '.data.alerts // []' 2>/dev/null || echo "")
    fi

    if [[ -n "$firing_alerts" && "$firing_alerts" != "" && "$firing_alerts" != "[]" ]]; then
        local alert_count
        alert_count=$(echo "$firing_alerts" | jq 'length' 2>/dev/null || echo "0")
        local critical_count warning_count info_count
        critical_count=$(echo "$firing_alerts" | jq '[.[]? | select(.labels.severity == "critical")] | length' 2>/dev/null || echo "0")
        warning_count=$(echo "$firing_alerts" | jq '[.[]? | select(.labels.severity == "warning")] | length' 2>/dev/null || echo "0")
        info_count=$(echo "$firing_alerts" | jq '[.[]? | select(.labels.severity != "critical" and .labels.severity != "warning")] | length' 2>/dev/null || echo "0")

        log_info "Active alerts: $alert_count (Critical=$critical_count Warning=$warning_count Other=$info_count)"

        # Show CRITICAL alerts — each one as FAIL
        if [[ "$critical_count" -gt 0 ]]; then
            log_subheader "🔴 CRITICAL Alerts"
            while IFS='|' read -r a_name a_ns a_severity a_summary a_desc a_since; do
                [[ -z "$a_name" ]] && continue
                local a_msg="CRITICAL ALERT: $a_name"
                if [[ -n "$a_ns" && "$a_ns" != "null" ]]; then a_msg+=" Namespace=$a_ns"; fi
                if [[ -n "$a_summary" && "$a_summary" != "null" ]]; then
                    a_msg+=" — $a_summary"
                elif [[ -n "$a_desc" && "$a_desc" != "null" ]]; then
                    a_msg+=" — ${a_desc:0:150}"
                fi
                if [[ -n "$a_since" && "$a_since" != "null" ]]; then a_msg+=" (since $a_since)"; fi
                log_fail "$a_msg"
            done < <(echo "$firing_alerts" | jq -r '
                [.[]? | select(.labels.severity == "critical")] | sort_by(.labels.alertname)[] |
                (.labels.alertname // "unknown") + "|" +
                (.labels.namespace // "null") + "|" +
                (.labels.severity // "unknown") + "|" +
                (.annotations.summary // "null") + "|" +
                (.annotations.description // "null") + "|" +
                (.startsAt // "null" | split("T")[0] // "")
            ')
        fi

        # Show WARNING alerts — each one as WARN
        if [[ "$warning_count" -gt 0 ]]; then
            log_subheader "🟡 Warning Alerts"
            while IFS='|' read -r a_name a_ns a_severity a_summary a_desc; do
                [[ -z "$a_name" ]] && continue
                local a_msg="WARNING ALERT: $a_name"
                if [[ -n "$a_ns" && "$a_ns" != "null" ]]; then a_msg+=" Namespace=$a_ns"; fi
                if [[ -n "$a_summary" && "$a_summary" != "null" ]]; then
                    a_msg+=" — $a_summary"
                elif [[ -n "$a_desc" && "$a_desc" != "null" ]]; then
                    a_msg+=" — ${a_desc:0:150}"
                fi
                log_warn "$a_msg"
            done < <(echo "$firing_alerts" | jq -r '
                [.[]? | select(.labels.severity == "warning")] | sort_by(.labels.alertname)[] |
                (.labels.alertname // "unknown") + "|" +
                (.labels.namespace // "null") + "|" +
                (.labels.severity // "unknown") + "|" +
                (.annotations.summary // "null") + "|" +
                (.annotations.description // "null")
            ')
        fi

        # Show other/info alerts summary
        if [[ "$info_count" -gt 0 ]]; then
            log_info "$info_count other/info alerts firing (not shown individually)"
        fi

        if [[ "$critical_count" -eq 0 ]]; then
            log_pass "No CRITICAL alerts firing"
        fi
    else
        log_info "Could not retrieve alerts from Alertmanager/Prometheus (may need direct pod access)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 14. LOGGING STACK & LOKISTACK
# ─────────────────────────────────────────────────────────────────────────────
check_logging_stack() {
    log_header "14. LOGGING STACK & LOKISTACK"

    # ── 14a. Cluster Logging Operator (CLO) ──
    log_subheader "Cluster Logging Operator"
    local clo_csv
    clo_csv=$(run_oc get csv -n openshift-logging -o json 2>/dev/null | jq -r '
        [.items[]? | select(.metadata.name | test("cluster-logging"))] | first // empty
    ')
    if [[ -n "$clo_csv" ]]; then
        local clo_name clo_phase clo_version
        clo_name=$(echo "$clo_csv" | jq -r '.metadata.name')
        clo_phase=$(echo "$clo_csv" | jq -r '.status.phase // "Unknown"')
        clo_version=$(echo "$clo_csv" | jq -r '.spec.version // "unknown"')
        log_info "Cluster Logging Operator: $clo_name (v$clo_version)"
        if [[ "$clo_phase" == "Succeeded" ]]; then
            log_pass "CLO CSV: Succeeded"
        else
            log_fail "CLO CSV: $clo_phase"
        fi
    else
        log_warn "Cluster Logging Operator CSV not found in openshift-logging"
    fi

    # ── 14b. Loki Operator ──
    log_subheader "Loki Operator"
    # Loki Operator can be in openshift-operators-redhat or openshift-logging
    local loki_csv="" loki_ns=""
    for ns in openshift-operators-redhat openshift-logging openshift-operators; do
        loki_csv=$(run_oc get csv -n "$ns" -o json 2>/dev/null | jq -r '
            [.items[]? | select(.metadata.name | test("loki"))] | first // empty
        ')
        if [[ -n "$loki_csv" ]]; then
            loki_ns="$ns"
            break
        fi
    done

    if [[ -n "$loki_csv" ]]; then
        local loki_op_name loki_op_phase loki_op_version
        loki_op_name=$(echo "$loki_csv" | jq -r '.metadata.name')
        loki_op_phase=$(echo "$loki_csv" | jq -r '.status.phase // "Unknown"')
        loki_op_version=$(echo "$loki_csv" | jq -r '.spec.version // "unknown"')
        log_info "Loki Operator: $loki_op_name (v$loki_op_version) in $loki_ns"
        if [[ "$loki_op_phase" == "Succeeded" ]]; then
            log_pass "Loki Operator CSV: Succeeded"
        else
            log_fail "Loki Operator CSV: $loki_op_phase"
        fi
    else
        log_warn "Loki Operator CSV not found (checked openshift-operators-redhat, openshift-logging, openshift-operators)"
    fi

    # Loki Operator controller pod
    for ns in openshift-operators-redhat openshift-logging openshift-operators; do
        local loki_ctrl_pods
        loki_ctrl_pods=$(run_oc get pods -n "$ns" -l "name=loki-operator-controller-manager" -o json 2>/dev/null | jq '[.items[]? | select(.status.phase=="Running")] | length' 2>/dev/null || echo "0")
        if [[ "$loki_ctrl_pods" -gt 0 ]]; then
            log_pass "Loki Operator controller-manager: $loki_ctrl_pods pod(s) running in $ns"
            break
        fi
    done

    # ── 14c. LokiStack Custom Resource ──
    log_subheader "LokiStack Instance"
    local lokistack_json
    # LokiStack is usually in openshift-logging
    lokistack_json=$(run_oc get lokistack --all-namespaces -o json 2>/dev/null) || {
        log_warn "Could not retrieve LokiStack resources (CRD may not exist)"
        lokistack_json=""
    }

    if [[ -n "$lokistack_json" ]]; then
        local ls_count
        ls_count=$(echo "$lokistack_json" | jq '.items | length')

        if [[ "$ls_count" -eq 0 ]]; then
            log_warn "No LokiStack instances found"
        else
            while IFS='|' read -r ls_ns ls_name ls_size ls_storage_type ls_storage_secret; do
                echo -e "  LokiStack: ${BOLD}$ls_ns/$ls_name${NC}"
                log_info "  Size: $ls_size"
                log_info "  Storage Type: $ls_storage_type"
                log_info "  Storage Secret: $ls_storage_secret"

                # LokiStack conditions
                local ls_ready ls_degraded ls_pending
                ls_ready=$(run_oc get lokistack "$ls_name" -n "$ls_ns" -o json 2>/dev/null | jq -r '
                    [.status.conditions[]? | select(.type=="Ready") | .status][0] // "Unknown"
                ')
                ls_degraded=$(run_oc get lokistack "$ls_name" -n "$ls_ns" -o json 2>/dev/null | jq -r '
                    [.status.conditions[]? | select(.type=="Degraded") | .status][0] // "Unknown"
                ')
                ls_pending=$(run_oc get lokistack "$ls_name" -n "$ls_ns" -o json 2>/dev/null | jq -r '
                    [.status.conditions[]? | select(.type=="Pending") | .status][0] // "Unknown"
                ')

                if [[ "$ls_ready" == "True" ]]; then log_pass "LokiStack $ls_name: Ready"; else log_fail "LokiStack $ls_name: NOT Ready (status=$ls_ready)"; fi
                if [[ "$ls_degraded" != "True" ]]; then log_pass "LokiStack $ls_name: Not Degraded"; else log_fail "LokiStack $ls_name: DEGRADED"; fi
                if [[ "$ls_pending" != "True" ]]; then log_pass "LokiStack $ls_name: Not Pending"; else log_warn "LokiStack $ls_name: Pending (deployment may still be in progress)"; fi

                # Print all conditions for full visibility
                log_subheader "LokiStack $ls_name Conditions"
                run_oc get lokistack "$ls_name" -n "$ls_ns" -o json 2>/dev/null | jq -r '
                    .status.conditions[]? |
                    "    \(.type): \(.status) — \(.reason // "") — \(.message // "" | .[0:120])"
                '

                # ── LokiStack Component Pods ──
                log_subheader "LokiStack $ls_name Component Pods"

                local LOKI_COMPONENTS=(
                    "compactor:app.kubernetes.io/component=compactor"
                    "distributor:app.kubernetes.io/component=distributor"
                    "gateway:app.kubernetes.io/component=lokistack-gateway"
                    "index-gateway:app.kubernetes.io/component=index-gateway"
                    "ingester:app.kubernetes.io/component=ingester"
                    "querier:app.kubernetes.io/component=querier"
                    "query-frontend:app.kubernetes.io/component=query-frontend"
                    "ruler:app.kubernetes.io/component=ruler"
                )

                for comp_entry in "${LOKI_COMPONENTS[@]}"; do
                    local comp_name="${comp_entry%%:*}"
                    local comp_label="${comp_entry##*:}"

                    local comp_total comp_running comp_restarts
                    local comp_pods_json
                    comp_pods_json=$(run_oc get pods -n "$ls_ns" -l "$comp_label" -o json 2>/dev/null)

                    comp_total=$(echo "$comp_pods_json" | jq '.items | length' 2>/dev/null || echo "0")
                    comp_running=$(echo "$comp_pods_json" | jq '[.items[]? | select(.status.phase=="Running")] | length' 2>/dev/null || echo "0")
                    comp_restarts=$(echo "$comp_pods_json" | jq '[.items[]?.status.containerStatuses[]?.restartCount // 0] | add // 0' 2>/dev/null || echo "0")

                    if [[ "$comp_total" -eq 0 ]]; then
                        # Try alternate label pattern (some versions use app.kubernetes.io/name)
                        comp_pods_json=$(run_oc get pods -n "$ls_ns" -l "app.kubernetes.io/component=${comp_name},app.kubernetes.io/instance=${ls_name}" -o json 2>/dev/null)
                        comp_total=$(echo "$comp_pods_json" | jq '.items | length' 2>/dev/null || echo "0")
                        comp_running=$(echo "$comp_pods_json" | jq '[.items[]? | select(.status.phase=="Running")] | length' 2>/dev/null || echo "0")
                        comp_restarts=$(echo "$comp_pods_json" | jq '[.items[]?.status.containerStatuses[]?.restartCount // 0] | add // 0' 2>/dev/null || echo "0")
                    fi

                    if [[ "$comp_total" -eq 0 ]]; then
                        log_info "Loki $comp_name: no pods found (may not be enabled for this size)"
                    elif [[ "$comp_running" -eq "$comp_total" ]]; then
                        log_pass "Loki $comp_name: $comp_running/$comp_total running (restarts=$comp_restarts)"
                        if [[ "$comp_restarts" -gt 10 ]]; then log_warn "Loki $comp_name: High total restart count ($comp_restarts)"; fi
                    else
                        log_fail "Loki $comp_name: $comp_running/$comp_total running (restarts=$comp_restarts)"
                    fi
                done

                # ── LokiStack PVCs ──
                log_subheader "LokiStack $ls_name PVCs"
                local loki_pvcs
                loki_pvcs=$(run_oc get pvc -n "$ls_ns" -l "app.kubernetes.io/instance=$ls_name" -o json 2>/dev/null)
                if [[ -n "$loki_pvcs" ]]; then
                    local loki_pvc_total loki_pvc_bound
                    loki_pvc_total=$(echo "$loki_pvcs" | jq '.items | length')
                    loki_pvc_bound=$(echo "$loki_pvcs" | jq '[.items[]? | select(.status.phase=="Bound")] | length')

                    if [[ "$loki_pvc_total" -eq 0 ]]; then
                        log_info "No PVCs found for LokiStack (may use emptyDir or object storage only)"
                    elif [[ "$loki_pvc_bound" -eq "$loki_pvc_total" ]]; then
                        log_pass "LokiStack PVCs: All $loki_pvc_total Bound"
                    else
                        log_fail "LokiStack PVCs: $loki_pvc_bound/$loki_pvc_total Bound"
                        echo "$loki_pvcs" | jq -r '.items[]? | select(.status.phase!="Bound") | "    \(.metadata.name) — \(.status.phase)"'
                    fi

                    # Show PVC sizes
                    echo "$loki_pvcs" | jq -r '.items[]? | "    \(.metadata.name): \(.status.capacity.storage // "unknown") (\(.status.phase))"' | head -15
                else
                    log_info "No LokiStack PVCs found"
                fi

                # ── LokiStack Object Storage Secret ──
                log_subheader "LokiStack $ls_name Object Storage Secret"
                if [[ -n "$ls_storage_secret" && "$ls_storage_secret" != "null" ]]; then
                    if run_oc get secret "$ls_storage_secret" -n "$ls_ns" &>/dev/null; then
                        log_pass "Object storage secret '$ls_storage_secret' exists"
                        # Validate expected keys based on storage type
                        local secret_keys
                        secret_keys=$(run_oc get secret "$ls_storage_secret" -n "$ls_ns" -o json 2>/dev/null | jq -r '.data | keys[]')
                        log_info "Secret keys: $(echo $secret_keys | tr '\n' ', ')"

                        case "$ls_storage_type" in
                            s3)
                                if ! echo "$secret_keys" | grep -q "endpoint"; then log_warn "S3 secret missing 'endpoint' key"; fi
                                if ! echo "$secret_keys" | grep -q "bucketnames"; then log_warn "S3 secret missing 'bucketnames' key"; fi
                                if ! echo "$secret_keys" | grep -q "access_key_id"; then log_warn "S3 secret missing 'access_key_id' key"; fi
                                if ! echo "$secret_keys" | grep -q "access_key_secret"; then log_warn "S3 secret missing 'access_key_secret' key"; fi
                                ;;
                            azure)
                                if ! echo "$secret_keys" | grep -q "container"; then log_warn "Azure secret missing 'container' key"; fi
                                if ! echo "$secret_keys" | grep -q "account_name"; then log_warn "Azure secret missing 'account_name' key"; fi
                                if ! echo "$secret_keys" | grep -q "account_key"; then log_warn "Azure secret missing 'account_key' key"; fi
                                ;;
                            gcs)
                                if ! echo "$secret_keys" | grep -q "bucketname"; then log_warn "GCS secret missing 'bucketname' key"; fi
                                if ! echo "$secret_keys" | grep -q "key.json"; then log_warn "GCS secret missing 'key.json' key"; fi
                                ;;
                            swift)
                                if ! echo "$secret_keys" | grep -q "container_name"; then log_warn "Swift secret missing 'container_name' key"; fi
                                if ! echo "$secret_keys" | grep -q "auth_url"; then log_warn "Swift secret missing 'auth_url' key"; fi
                                ;;
                        esac
                    else
                        log_fail "Object storage secret '$ls_storage_secret' NOT FOUND — LokiStack cannot function"
                    fi
                fi

                # ── LokiStack Services ──
                log_subheader "LokiStack $ls_name Services"
                local loki_services
                loki_services=$(run_oc get svc -n "$ls_ns" -l "app.kubernetes.io/instance=$ls_name" -o json 2>/dev/null)
                if [[ -n "$loki_services" ]]; then
                    local svc_count
                    svc_count=$(echo "$loki_services" | jq '.items | length')
                    log_info "LokiStack services: $svc_count"
                    echo "$loki_services" | jq -r '.items[]? | "    \(.metadata.name): \(.spec.type) — ports: \([.spec.ports[]?.port] | join(","))"'

                    # Check gateway service specifically
                    local gw_svc
                    gw_svc=$(echo "$loki_services" | jq -r '.items[]? | select(.metadata.name | test("gateway")) | .metadata.name')
                    if [[ -n "$gw_svc" ]]; then
                        log_pass "LokiStack gateway service exists: $gw_svc"
                    else
                        log_warn "LokiStack gateway service not found"
                    fi
                fi

                # ── LokiStack StatefulSets ──
                log_subheader "LokiStack $ls_name StatefulSets"
                local loki_sts
                loki_sts=$(run_oc get statefulsets -n "$ls_ns" -l "app.kubernetes.io/instance=$ls_name" -o json 2>/dev/null)
                if [[ -n "$loki_sts" ]]; then
                    while IFS='|' read -r sts_name sts_desired sts_ready sts_current; do
                        [[ -z "$sts_name" ]] && continue
                        if [[ "$sts_desired" == "$sts_ready" && "$sts_desired" != "0" ]]; then
                            log_pass "StatefulSet $sts_name: $sts_ready/$sts_desired ready"
                        else
                            log_fail "StatefulSet $sts_name: $sts_ready/$sts_desired ready (current=$sts_current)"
                        fi
                    done < <(echo "$loki_sts" | jq -r '
                        .items[]? |
                        (.metadata.name) + "|" +
                        (.spec.replicas // 0 | tostring) + "|" +
                        (.status.readyReplicas // 0 | tostring) + "|" +
                        (.status.currentReplicas // 0 | tostring)
                    ')
                fi

            done < <(echo "$lokistack_json" | jq -r '
                .items[]? |
                (.metadata.namespace) + "|" +
                (.metadata.name) + "|" +
                (.spec.size // "unknown") + "|" +
                (.spec.storage.schemas[0].objectStore // .spec.storage.type // "unknown") + "|" +
                (.spec.storage.secret.name // "null")
            ')
        fi
    fi

    # ── 14d. ClusterLogging CR ──
    log_subheader "ClusterLogging Instance"
    local cl_json
    cl_json=$(run_oc get clusterlogging --all-namespaces -o json 2>/dev/null) || {
        log_info "ClusterLogging CRD not found"
        cl_json=""
    }

    if [[ -n "$cl_json" ]]; then
        local cl_count
        cl_count=$(echo "$cl_json" | jq '.items | length')

        if [[ "$cl_count" -eq 0 ]]; then
            log_warn "No ClusterLogging instances found"
        else
            while IFS='|' read -r cl_ns cl_name cl_mgmt cl_log_store_type cl_collection_type; do
                echo -e "  ClusterLogging: ${BOLD}$cl_ns/$cl_name${NC}"
                log_info "  ManagementState: $cl_mgmt"
                log_info "  LogStore Type: $cl_log_store_type"
                log_info "  Collection Type: $cl_collection_type"

                if [[ "$cl_mgmt" == "Managed" ]]; then
                    log_pass "ClusterLogging $cl_name: Managed"
                else
                    log_warn "ClusterLogging $cl_name: $cl_mgmt (not actively managed)"
                fi

                # ClusterLogging conditions
                local cl_ready
                cl_ready=$(run_oc get clusterlogging "$cl_name" -n "$cl_ns" -o json 2>/dev/null | jq -r '
                    [.status.conditions[]? | select(.type=="Ready") | .status][0] // "Unknown"
                ')
                if [[ "$cl_ready" == "True" ]]; then
                    log_pass "ClusterLogging $cl_name: Ready"
                else
                    log_fail "ClusterLogging $cl_name: Not Ready ($cl_ready)"
                fi

                # Show all conditions
                run_oc get clusterlogging "$cl_name" -n "$cl_ns" -o json 2>/dev/null | jq -r '
                    .status.conditions[]? // empty |
                    "    \(.type): \(.status) — \(.reason // "") — \(.message // "" | .[0:120])"
                ' 2>/dev/null

            done < <(echo "$cl_json" | jq -r '
                .items[]? |
                (.metadata.namespace) + "|" +
                (.metadata.name) + "|" +
                (.spec.managementState // "unknown") + "|" +
                (.spec.logStore.type // "unknown") + "|" +
                (.spec.collection.type // .spec.collection.logs.type // "unknown")
            ')
        fi
    fi

    # ── 14e. ClusterLogForwarder ──
    log_subheader "ClusterLogForwarder"
    local clf_json
    clf_json=$(run_oc get clusterlogforwarder --all-namespaces -o json 2>/dev/null) || {
        log_info "ClusterLogForwarder CRD not found"
        clf_json=""
    }

    if [[ -n "$clf_json" ]]; then
        local clf_count
        clf_count=$(echo "$clf_json" | jq '.items | length')

        if [[ "$clf_count" -eq 0 ]]; then
            log_info "No ClusterLogForwarder instances found"
        else
            while IFS='|' read -r clf_ns clf_name; do
                echo -e "  ClusterLogForwarder: ${BOLD}$clf_ns/$clf_name${NC}"

                # Conditions
                local clf_ready
                clf_ready=$(run_oc get clusterlogforwarder "$clf_name" -n "$clf_ns" -o json 2>/dev/null | jq -r '
                    [.status.conditions[]? | select(.type=="Ready") | .status][0] // "Unknown"
                ')
                if [[ "$clf_ready" == "True" ]]; then
                    log_pass "ClusterLogForwarder $clf_name: Ready"
                else
                    log_fail "ClusterLogForwarder $clf_name: Not Ready"
                fi

                # Pipelines
                local pipeline_count
                pipeline_count=$(run_oc get clusterlogforwarder "$clf_name" -n "$clf_ns" -o json 2>/dev/null | jq '.spec.pipelines | length' 2>/dev/null || echo "0")
                log_info "Pipelines configured: $pipeline_count"

                # Pipeline conditions
                run_oc get clusterlogforwarder "$clf_name" -n "$clf_ns" -o json 2>/dev/null | jq -r '
                    .status.pipelines[]? |
                    "    Pipeline \(.name): \([.conditions[]? | "\(.type)=\(.status)"] | join(", "))"
                ' 2>/dev/null

                # Outputs
                local output_names
                output_names=$(run_oc get clusterlogforwarder "$clf_name" -n "$clf_ns" -o json 2>/dev/null | jq -r '
                    .spec.outputs[]? | "    Output: \(.name) → \(.type) \(.url // "")"
                ')
                [[ -n "$output_names" ]] && echo "$output_names"

                # Inputs / sources
                local input_types
                input_types=$(run_oc get clusterlogforwarder "$clf_name" -n "$clf_ns" -o json 2>/dev/null | jq -r '
                    [.spec.pipelines[]?.inputRefs[]?] | unique | join(", ")
                ')
                log_info "Log inputs: $input_types"

            done < <(echo "$clf_json" | jq -r '.items[]? | (.metadata.namespace) + "|" + (.metadata.name)')
        fi
    fi

    # ── 14f. Log Collector Pods (Vector / Fluentd) ──
    log_subheader "Log Collector Pods"
    local collector_found=false

    # Check Vector DaemonSet (preferred in newer versions)
    local vector_ds
    vector_ds=$(run_oc get daemonset -n openshift-logging -l "component=collector,logging.openshift.io/impl=vector" -o json 2>/dev/null)
    local vector_count
    vector_count=$(echo "$vector_ds" | jq '.items | length' 2>/dev/null || echo "0")

    if [[ "$vector_count" -gt 0 ]]; then
        collector_found=true
        while IFS='|' read -r ds_name ds_desired ds_ready ds_available ds_unavailable; do
            log_info "Collector: Vector DaemonSet ($ds_name)"
            if [[ "$ds_desired" == "$ds_ready" && "$ds_desired" != "0" ]]; then
                log_pass "Vector collector: $ds_ready/$ds_desired ready on all nodes"
            else
                log_fail "Vector collector: $ds_ready/$ds_desired ready (unavailable=$ds_unavailable)"
            fi
        done < <(echo "$vector_ds" | jq -r '
            .items[]? |
            (.metadata.name) + "|" +
            (.status.desiredNumberScheduled // 0 | tostring) + "|" +
            (.status.numberReady // 0 | tostring) + "|" +
            (.status.numberAvailable // 0 | tostring) + "|" +
            (.status.numberUnavailable // 0 | tostring)
        ')
    fi

    # Check Fluentd DaemonSet (older/alternative)
    local fluentd_ds
    fluentd_ds=$(run_oc get daemonset -n openshift-logging -l "component=collector,logging.openshift.io/impl=fluentd" -o json 2>/dev/null)
    local fluentd_count
    fluentd_count=$(echo "$fluentd_ds" | jq '.items | length' 2>/dev/null || echo "0")

    if [[ "$fluentd_count" -gt 0 ]]; then
        collector_found=true
        while IFS='|' read -r ds_name ds_desired ds_ready ds_unavailable; do
            log_info "Collector: Fluentd DaemonSet ($ds_name)"
            if [[ "$ds_desired" == "$ds_ready" && "$ds_desired" != "0" ]]; then
                log_pass "Fluentd collector: $ds_ready/$ds_desired ready on all nodes"
            else
                log_fail "Fluentd collector: $ds_ready/$ds_desired ready (unavailable=$ds_unavailable)"
            fi
        done < <(echo "$fluentd_ds" | jq -r '
            .items[]? |
            (.metadata.name) + "|" +
            (.status.desiredNumberScheduled // 0 | tostring) + "|" +
            (.status.numberReady // 0 | tostring) + "|" +
            (.status.numberUnavailable // 0 | tostring)
        ')
    fi

    # Fallback: generic collector label
    if [[ "$collector_found" == "false" ]]; then
        local generic_collector
        generic_collector=$(run_oc get daemonset -n openshift-logging -l "component=collector" -o json 2>/dev/null)
        local gen_count
        gen_count=$(echo "$generic_collector" | jq '.items | length' 2>/dev/null || echo "0")
        if [[ "$gen_count" -gt 0 ]]; then
            collector_found=true
            while IFS='|' read -r ds_name ds_desired ds_ready; do
                log_info "Collector DaemonSet: $ds_name"
                if [[ "$ds_desired" == "$ds_ready" && "$ds_desired" != "0" ]]; then
                    log_pass "Log collector: $ds_ready/$ds_desired ready"
                else
                    log_fail "Log collector: $ds_ready/$ds_desired ready"
                fi
            done < <(echo "$generic_collector" | jq -r '
                .items[]? |
                (.metadata.name) + "|" +
                (.status.desiredNumberScheduled // 0 | tostring) + "|" +
                (.status.numberReady // 0 | tostring)
            ')
        fi
    fi

    if [[ "$collector_found" == "false" ]]; then log_warn "No log collector DaemonSet found in openshift-logging"; fi

    # ── 14g. LokiStack Gateway Route ──
    log_subheader "LokiStack Routes & Access"
    local loki_routes
    loki_routes=$(run_oc get routes -n openshift-logging -o json 2>/dev/null | jq -r '
        .items[]? | select(.metadata.name | test("loki|logging")) |
        "    \(.metadata.name): \(.spec.host) (\(.spec.tls.termination // "no-tls"))"
    ')
    if [[ -n "$loki_routes" ]]; then
        log_info "Logging/Loki routes:"
        echo "$loki_routes"
    else
        log_info "No Loki-related routes found in openshift-logging"
    fi

    # ── 14h. Log Storage tenant validation ──
    log_subheader "LokiStack Tenants"
    local ls_tenants
    ls_tenants=$(run_oc get lokistack --all-namespaces -o json 2>/dev/null | jq -r '
        .items[]? | .spec.tenants // empty |
        "    Mode: \(.mode // "unknown")"
    ' 2>/dev/null)
    if [[ -n "$ls_tenants" ]]; then
        echo "$ls_tenants"
        # Check if RBAC/authentication is in openshift-logging mode
        local tenant_mode
        tenant_mode=$(run_oc get lokistack --all-namespaces -o json 2>/dev/null | jq -r '.items[0]?.spec.tenants.mode // "unknown"')
        if [[ "$tenant_mode" == "openshift-logging" ]]; then
            log_pass "LokiStack tenant mode: openshift-logging (integrated with OCP auth)"
        else
            log_info "LokiStack tenant mode: $tenant_mode"
        fi
    fi

    # ── 14i. Namespace pod summary for openshift-logging ──
    log_subheader "openshift-logging Namespace Full Pod Summary"
    check_namespace_health "openshift-logging"
}

# ─────────────────────────────────────────────────────────────────────────────
# 15. RESOURCE QUOTAS
# ─────────────────────────────────────────────────────────────────────────────
check_resource_quotas() {
    log_header "15. RESOURCE QUOTAS & LIMITS"

    local quota_json
    quota_json=$(run_oc get resourcequota --all-namespaces -o json 2>/dev/null)
    local quota_count
    quota_count=$(echo "$quota_json" | jq '.items | length' 2>/dev/null || echo "0")

    if [[ "$quota_count" -eq 0 ]]; then
        log_info "No ResourceQuotas configured"
        return
    fi

    log_info "Total ResourceQuotas: $quota_count"

    # Check for high utilization (>80%)
    echo "$quota_json" | jq -r '
        .items[]? |
        .metadata.namespace as $ns |
        .metadata.name as $name |
        .status.hard // {} | to_entries[] |
        . as $hard |
        {ns: $ns, name: $name, resource: .key, hard: .value} +
        ({used: (input_line_number | tostring)} // {})
    ' 2>/dev/null | head -20 || true

    # Simplified: list quotas that are >80% used
    local high_usage_quotas
    high_usage_quotas=$(echo "$quota_json" | jq -r '
        .items[]? | 
        .metadata.namespace as $ns | .metadata.name as $name |
        .status as $status |
        ($status.hard // {} | to_entries[]) as $h |
        ($status.used // {} | to_entries[] | select(.key == $h.key)) as $u |
        select($h.value != "0" and $u.value != "0") |
        "\($ns)/\($name): \($h.key) used=\($u.value) hard=\($h.value)"
    ' 2>/dev/null)

    if [[ -n "$high_usage_quotas" ]]; then
        log_info "Resource Quota Usage:"
        echo "$high_usage_quotas" | head -15 | sed 's/^/    /'
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 16. EVENTS
# ─────────────────────────────────────────────────────────────────────────────
check_events() {
    log_header "16. RECENT WARNING EVENTS"

    if [[ "$SKIP_EVENTS" == "true" ]]; then
        log_info "Events check skipped (--skip-events)"
        return
    fi

    log_subheader "Warning Events (last 1 hour, top 20)"
    local warning_events
    warning_events=$(run_oc get events --all-namespaces --field-selector type=Warning \
        --sort-by='.lastTimestamp' -o json 2>/dev/null)

    local event_count
    event_count=$(echo "$warning_events" | jq '.items | length' 2>/dev/null || echo "0")
    log_info "Total warning events: $event_count"

    if [[ $event_count -gt 0 ]]; then
        echo ""
        echo "$warning_events" | jq -r '
            .items | sort_by(.lastTimestamp) | reverse | .[0:20][] |
            "  \(.lastTimestamp // "unknown") | \(.metadata.namespace)/\(.involvedObject.name) | \(.reason): \(.message[0:120])"
        ' 2>/dev/null
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 17. MACHINE API (Machines & MachineSets)
# ─────────────────────────────────────────────────────────────────────────────
check_machine_api() {
    log_header "17. MACHINE API"

    # Machines
    log_subheader "Machines"
    local machines_json
    machines_json=$(run_oc get machines -n openshift-machine-api -o json 2>/dev/null) || {
        log_info "Machine API not available (bare-metal or unsupported platform)"
        return
    }

    local total_machines running_machines
    total_machines=$(echo "$machines_json" | jq '.items | length')
    running_machines=$(echo "$machines_json" | jq '[.items[]? | select(.status.phase=="Running")] | length')

    if [[ $running_machines -eq $total_machines ]]; then
        log_pass "All $total_machines machines in Running state"
    else
        log_warn "$running_machines/$total_machines machines running"
    fi

    # Non-running machines
    local bad_machines
    bad_machines=$(echo "$machines_json" | jq -r '.items[]? | select(.status.phase!="Running") | "    \(.metadata.name) — \(.status.phase // "unknown")"')
    [[ -n "$bad_machines" ]] && echo "$bad_machines"

    # MachineSets
    log_subheader "MachineSets"
    local ms_json
    ms_json=$(run_oc get machinesets -n openshift-machine-api -o json 2>/dev/null)
    if [[ -n "$ms_json" ]]; then
        while IFS='|' read -r name desired ready available; do
            if [[ "$desired" == "$ready" ]]; then
                log_pass "MachineSet $name: $ready/$desired ready"
            else
                log_warn "MachineSet $name: $ready/$desired ready (available=$available)"
            fi
        done < <(echo "$ms_json" | jq -r '
            .items[]? |
            (.metadata.name) + "|" +
            (.spec.replicas // 0 | tostring) + "|" +
            (.status.readyReplicas // 0 | tostring) + "|" +
            (.status.availableReplicas // 0 | tostring)
        ')
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 18. IMAGE REGISTRY
# ─────────────────────────────────────────────────────────────────────────────
check_image_registry() {
    log_header "18. IMAGE REGISTRY"

    local reg_co
    reg_co=$(run_oc get clusteroperator image-registry -o json 2>/dev/null)
    if [[ -n "$reg_co" ]]; then
        local reg_avail reg_degr
        reg_avail=$(echo "$reg_co" | jq -r '[.status.conditions[]? | select(.type=="Available") | .status][0] // "Unknown"')
        reg_degr=$(echo "$reg_co" | jq -r '[.status.conditions[]? | select(.type=="Degraded") | .status][0] // "Unknown"')
        if [[ "$reg_avail" == "True" ]]; then log_pass "Image Registry operator: Available"; else log_fail "Image Registry operator: NOT Available"; fi
        if [[ "$reg_degr" == "False" ]]; then log_pass "Image Registry operator: Not Degraded"; else log_fail "Image Registry operator: DEGRADED"; fi
    fi

    # Registry config
    local reg_config
    reg_config=$(run_oc get configs.imageregistry.operator.openshift.io cluster -o json 2>/dev/null)
    if [[ -n "$reg_config" ]]; then
        local mgmt_state storage_type
        mgmt_state=$(echo "$reg_config" | jq -r '.spec.managementState // "unknown"')
        storage_type=$(echo "$reg_config" | jq -r '.spec.storage | keys[0] // "none"')
        log_info "Management State: $mgmt_state"
        log_info "Storage Backend: $storage_type"
        if [[ "$mgmt_state" == "Removed" ]]; then log_warn "Image registry is in Removed state"; fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE HTML REPORT
# ─────────────────────────────────────────────────────────────────────────────
generate_html_report() {
    local output_file="$1"

    # Determine health status for badge
    local health_class="healthy" health_text="CLUSTER IS HEALTHY" health_emoji="🟢"
    if [[ $FAIL_COUNT -gt 0 ]]; then
        health_class="critical"
        health_text="CLUSTER HAS FAILURES — Immediate attention needed"
        health_emoji="🔴"
    elif [[ $WARN_COUNT -gt 0 ]]; then
        health_class="warning"
        health_text="CLUSTER HAS WARNINGS — Review recommended"
        health_emoji="🟡"
    fi

    cat > "$output_file" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${CLUSTER_DISPLAY_NAME} — Cluster Health Report</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0d1117; color: #c9d1d9; padding: 20px; }
  .container { max-width: 1200px; margin: 0 auto; }
  h1 { color: #58a6ff; margin-bottom: 4px; font-size: 1.6em; }
  .subtitle { color: #8b949e; margin-bottom: 4px; font-size: 0.9em; }
  .api-url { color: #6e7681; font-family: monospace; font-size: 0.82em; margin-bottom: 20px; }
  .health-banner { padding: 12px 20px; border-radius: 8px; margin-bottom: 20px; font-weight: bold; font-size: 1em; display: flex; align-items: center; gap: 10px; }
  .health-banner.healthy   { background: #0d1f0d; border: 1px solid #238636; color: #3fb950; }
  .health-banner.warning   { background: #1f1a0d; border: 1px solid #9e6a03; color: #d29922; }
  .health-banner.critical  { background: #1f0d0d; border: 1px solid #da3633; color: #f85149; }
  .summary { display: flex; gap: 16px; margin-bottom: 24px; flex-wrap: wrap; }
  .summary-card { padding: 16px 24px; border-radius: 8px; border: 1px solid #30363d; flex: 1; min-width: 120px; text-align: center; }
  .summary-card .number { font-size: 2em; font-weight: bold; }
  .summary-card.pass { border-color: #238636; } .summary-card.pass .number { color: #3fb950; }
  .summary-card.warn { border-color: #9e6a03; } .summary-card.warn .number { color: #d29922; }
  .summary-card.fail { border-color: #da3633; } .summary-card.fail .number { color: #f85149; }
  .summary-card.info { border-color: #1f6feb; } .summary-card.info .number { color: #58a6ff; }
  .check { padding: 8px 12px; margin: 2px 0; border-radius: 4px; font-family: monospace; font-size: 0.85em; word-break: break-word; }
  .check.PASS { background: #0d1f0d; border-left: 3px solid #3fb950; }
  .check.WARN { background: #1f1a0d; border-left: 3px solid #d29922; }
  .check.FAIL { background: #1f0d0d; border-left: 3px solid #f85149; }
  .check.INFO { background: #0d1525; border-left: 3px solid #58a6ff; }
  .status-badge { display: inline-block; width: 50px; font-weight: bold; }
  .status-badge.PASS { color: #3fb950; } .status-badge.WARN { color: #d29922; }
  .status-badge.FAIL { color: #f85149; } .status-badge.INFO { color: #58a6ff; }
  .filter-bar { margin-bottom: 16px; display: flex; gap: 8px; flex-wrap: wrap; }
  .filter-btn { padding: 6px 16px; border-radius: 16px; border: 1px solid #30363d; background: #161b22; color: #c9d1d9; cursor: pointer; font-size: 0.85em; }
  .filter-btn.active { background: #1f6feb; border-color: #1f6feb; color: white; }
  .filter-btn:hover { border-color: #58a6ff; }
  .footer { margin-top: 30px; padding-top: 16px; border-top: 1px solid #21262d; color: #484f58; font-size: 0.78em; text-align: center; }
</style>
</head>
<body>
<div class="container">
  <h1>${health_emoji} ${CLUSTER_DISPLAY_NAME} — Cluster Health Report</h1>
  <p class="subtitle">Generated: ${TIMESTAMP_HUMAN}</p>
  <p class="api-url">API: ${CLUSTER_API_URL}</p>
  <div class="health-banner ${health_class}">${health_emoji} ${health_text}</div>
  <div class="summary">
    <div class="summary-card pass"><div class="number">${PASS_COUNT}</div><div>Passed</div></div>
    <div class="summary-card warn"><div class="number">${WARN_COUNT}</div><div>Warnings</div></div>
    <div class="summary-card fail"><div class="number">${FAIL_COUNT}</div><div>Failed</div></div>
    <div class="summary-card info"><div class="number">${INFO_COUNT}</div><div>Info</div></div>
  </div>
  <div class="filter-bar">
    <button class="filter-btn active" onclick="filterAll(this,'all')">All</button>
    <button class="filter-btn" onclick="filterAll(this,'FAIL')">Failures (${FAIL_COUNT})</button>
    <button class="filter-btn" onclick="filterAll(this,'WARN')">Warnings (${WARN_COUNT})</button>
    <button class="filter-btn" onclick="filterAll(this,'PASS')">Passed (${PASS_COUNT})</button>
    <button class="filter-btn" onclick="filterAll(this,'INFO')">Info (${INFO_COUNT})</button>
  </div>
  <div id="results">
RESULTS_PLACEHOLDER
  </div>
  <div class="footer">${CLUSTER_DISPLAY_NAME} &middot; Report generated ${TIMESTAMP_HUMAN}</div>
</div>
<script>
function filterAll(btn, type) {
  document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('.check').forEach(el => {
    el.style.display = (type === 'all' || el.classList.contains(type)) ? 'block' : 'none';
  });
}
</script>
</body>
</html>
HTMLEOF

    # Build results HTML
    local results_html=""
    results_html=$(echo "$JSON_RESULTS" | jq -r '
        .[] | 
        "<div class=\"check \(.status)\"><span class=\"status-badge \(.status)\">\(.status)</span> \(.message | gsub("<";"&lt;") | gsub(">";"&gt;"))</div>"
    ')

    # Insert results (use a temp file to handle special chars)
    local tmpfile
    tmpfile=$(mktemp)
    echo "$results_html" > "$tmpfile"
    sed -i "/RESULTS_PLACEHOLDER/r $tmpfile" "$output_file"
    sed -i "/RESULTS_PLACEHOLDER/d" "$output_file"
    rm -f "$tmpfile"

    echo -e "\n${GREEN}HTML report saved to: ${output_file}${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE INDIAN BANK CHECKLIST REPORT (10-point email format)
# Matches the exact format sent by IBDCJIO team to CDC/NIVETHA
# ─────────────────────────────────────────────────────────────────────────────
generate_checklist_report() {
    local output_file="$1"

    echo -e "${BLUE}Generating Indian Bank checklist report...${NC}"

    # Collect all raw oc outputs
    local node_status node_top co_output mcp_output

    # 1. Node Status
    node_status=$(run_oc get nodes -o wide 2>/dev/null || echo "Unable to fetch node status")

    # 2. Node Utilization
    node_top=$(run_oc adm top nodes 2>/dev/null || echo "Unable to fetch node utilization (metrics-server may be unavailable)")

    # 3. Cluster Operators
    co_output=$(run_oc get co 2>/dev/null || echo "Unable to fetch cluster operators")

    # 4. MachineConfigPools
    mcp_output=$(run_oc get mcp 2>/dev/null || echo "Unable to fetch MCP")

    # 5-7. Deployment Status per application namespace
    # Get app namespaces
    local all_ns_list
    all_ns_list=$(run_oc get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    local app_deploy_sections=""
    local app_hpa_sections=""
    local checklist_num=5

    for ns in $all_ns_list; do
        if ! is_system_namespace "$ns"; then
            # Deployment status
            local deploy_out
            deploy_out=$(run_oc get deploy -n "$ns" -o wide 2>/dev/null || echo "No deployments found")
            local ns_upper
            ns_upper=$(echo "$ns" | tr '[:lower:]' '[:upper:]' | sed 's/-/_/g')

            app_deploy_sections+="
<div class='section'>
  <h2>${checklist_num}. Deployment Status — ${ns}</h2>
  <pre>${deploy_out}</pre>
</div>"
            ((checklist_num++)) || true

            # HPA status
            local hpa_out
            hpa_out=$(run_oc get hpa -n "$ns" 2>/dev/null)
            if [[ -n "$hpa_out" ]]; then
                app_hpa_sections+="
<div class='section'>
  <h2>${checklist_num}. HPA Status — ${ns}</h2>
  <pre>${hpa_out}</pre>
</div>"
                ((checklist_num++)) || true
            fi
        fi
    done

    # Pod resource usage per app namespace
    local app_top_sections=""
    for ns in $all_ns_list; do
        if ! is_system_namespace "$ns"; then
            local top_out
            top_out=$(run_oc adm top pods -n "$ns" 2>/dev/null)
            if [[ -n "$top_out" ]]; then
                app_top_sections+="
<div class='section'>
  <h2>${checklist_num}. Pod Resource Usage — ${ns}</h2>
  <pre>${top_out}</pre>
</div>"
                ((checklist_num++)) || true
            fi
        fi
    done

    # LokiStack status
    local loki_out
    loki_out=$(run_oc get lokistack -n openshift-logging 2>/dev/null || echo "LokiStack not found")
    local loki_pods
    loki_pods=$(run_oc get pods -n openshift-logging 2>/dev/null || echo "No pods found")

    # Alertmanager firing alerts
    local alerts_out
    alerts_out=$(run_oc exec -n openshift-monitoring -c alertmanager alertmanager-main-0 -- wget -qO- 'http://localhost:9093/api/v2/alerts?active=true&silenced=false&inhibited=false' 2>/dev/null | jq -r '.[]? | "[\(.labels.severity)] \(.labels.alertname) ns=\(.labels.namespace // "-") — \(.annotations.summary // .annotations.description // "no description" | .[0:120])"' 2>/dev/null || echo "No alerts or unable to reach Alertmanager")

    # Determine time of day
    local time_slot="Morning"
    local current_hour
    current_hour=$(date '+%H')
    if [[ $current_hour -ge 12 && $current_hour -lt 18 ]]; then
        time_slot="Afternoon"
    elif [[ $current_hour -ge 18 ]]; then
        time_slot="Evening"
    fi

    # Build the HTML
    cat > "$output_file" <<CHECKLISTEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OCP Checklist — ${CLUSTER_DISPLAY_NAME} — $(date '+%d-%m-%Y') — ${time_slot}</title>
<style>
  body { font-family: Calibri, 'Segoe UI', Arial, sans-serif; background: #fff; color: #222; margin: 20px; font-size: 14px; }
  .header { background: #003366; color: #fff; padding: 16px 24px; border-radius: 6px; margin-bottom: 20px; }
  .header h1 { font-size: 18px; margin: 0 0 4px 0; }
  .header p { margin: 2px 0; font-size: 13px; opacity: 0.9; }
  .summary-bar { display: flex; gap: 12px; margin-bottom: 20px; flex-wrap: wrap; }
  .summary-item { padding: 10px 18px; border-radius: 6px; font-weight: bold; text-align: center; min-width: 100px; }
  .summary-item.pass { background: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
  .summary-item.fail { background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
  .summary-item.warn { background: #fff3cd; color: #856404; border: 1px solid #ffeeba; }
  .summary-item .num { font-size: 22px; display: block; }
  .section { margin-bottom: 24px; border: 1px solid #dee2e6; border-radius: 6px; overflow: hidden; }
  .section h2 { background: #f8f9fa; padding: 10px 16px; margin: 0; font-size: 14px; border-bottom: 1px solid #dee2e6; color: #003366; }
  .section pre { padding: 12px 16px; margin: 0; font-family: 'Consolas', 'Courier New', monospace; font-size: 12px; white-space: pre-wrap; word-wrap: break-word; background: #fafafa; overflow-x: auto; line-height: 1.5; }
  .section.alert pre { background: #fff5f5; }
  .badge-ok { display: inline-block; background: #28a745; color: #fff; padding: 2px 8px; border-radius: 3px; font-size: 11px; margin-left: 8px; }
  .badge-warn { display: inline-block; background: #ffc107; color: #333; padding: 2px 8px; border-radius: 3px; font-size: 11px; margin-left: 8px; }
  .badge-fail { display: inline-block; background: #dc3545; color: #fff; padding: 2px 8px; border-radius: 3px; font-size: 11px; margin-left: 8px; }
  .footer { margin-top: 20px; padding-top: 12px; border-top: 1px solid #dee2e6; color: #6c757d; font-size: 12px; text-align: center; }
  .greeting { margin-bottom: 16px; font-size: 14px; }
</style>
</head>
<body>

<div class="header">
  <h1>OCP Checklist — ${CLUSTER_DISPLAY_NAME} — $(date '+%d-%m-%Y') — ${time_slot}</h1>
  <p>API: ${CLUSTER_API_URL} | OCP Version: $(run_oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "N/A")</p>
  <p>Generated: ${TIMESTAMP_HUMAN}</p>
</div>

<p class="greeting">Dear Team,<br><br>Please find below the OCP Daily Health Check Report for <b>${CLUSTER_DISPLAY_NAME}</b>:</p>

<div class="summary-bar">
  <div class="summary-item pass"><span class="num">${PASS_COUNT}</span>Passed</div>
  <div class="summary-item warn"><span class="num">${WARN_COUNT}</span>Warnings</div>
  <div class="summary-item fail"><span class="num">${FAIL_COUNT}</span>Failures</div>
</div>

<div class="section">
  <h2>1. Node Status</h2>
  <pre>$(echo "$node_status" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>
</div>

<div class="section">
  <h2>2. Node Utilization</h2>
  <pre>$(echo "$node_top" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>
</div>

<div class="section">
  <h2>3. Cluster Operators (oc get co)</h2>
  <pre>$(echo "$co_output" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>
</div>

<div class="section">
  <h2>4. MachineConfigPools (oc get mcp)</h2>
  <pre>$(echo "$mcp_output" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>
</div>

${app_deploy_sections}

${app_hpa_sections}

${app_top_sections}

<div class="section">
  <h2>${checklist_num}. LokiStack Status</h2>
  <pre>$(echo "$loki_out" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

--- Pods in openshift-logging ---
$(echo "$loki_pods" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>
</div>

<div class="section alert">
  <h2>$((checklist_num + 1)). Firing Alerts (Alertmanager / Prometheus)</h2>
  <pre>$(echo "$alerts_out" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>
</div>

<div class="footer">
  ${CLUSTER_DISPLAY_NAME} — Health Check Report — $(date '+%d-%m-%Y %H:%M IST')<br>
  Generated automatically by OCP Health Check Script
</div>

</body>
</html>
CHECKLISTEOF

    echo -e "${GREEN}Checklist report saved to: ${output_file}${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
# EMAIL HTML REPORT
# ─────────────────────────────────────────────────────────────────────────────
send_email_report() {
    local html_file="$1"
    local recipients="$2"
    local subject="$3"

    if [[ -z "$recipients" ]]; then
        return
    fi

    # Auto-generate subject if not provided
    if [[ -z "$subject" ]]; then
        local health_tag="HEALTHY"
        [[ $FAIL_COUNT -gt 0 ]] && health_tag="FAILURES_DETECTED"
        [[ $WARN_COUNT -gt 0 && $FAIL_COUNT -eq 0 ]] && health_tag="WARNINGS"
        subject="${CLUSTER_DISPLAY_NAME} Health Report — ${health_tag} — $(date '+%Y-%m-%d')"
    fi

    echo -e "${BLUE}Sending HTML report via email...${NC}"
    echo -e "  To: $recipients"
    echo -e "  Subject: $subject"

    # Method 1: mailx with HTML content-type (most common on RHEL/OCP bastion)
    if command -v mailx &>/dev/null; then
        (
            echo "MIME-Version: 1.0"
            echo "Content-Type: text/html; charset=UTF-8"
            echo "Subject: $subject"
            echo "To: $recipients"
            echo ""
            cat "$html_file"
        ) | sendmail -t "$recipients" 2>/dev/null || \
        mailx -s "$(echo -e "$subject\nContent-Type: text/html; charset=UTF-8\nMIME-Version: 1.0")" \
            "$recipients" < "$html_file" 2>/dev/null

        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✔ Email sent successfully via mailx/sendmail${NC}"
            return 0
        fi
    fi

    # Method 2: mutt
    if command -v mutt &>/dev/null; then
        mutt -e "set content_type=text/html" -s "$subject" -- $recipients < "$html_file" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✔ Email sent successfully via mutt${NC}"
            return 0
        fi
    fi

    # Method 3: curl with SMTP (if SMTP_SERVER env is set)
    if [[ -n "${SMTP_SERVER:-}" ]] && command -v curl &>/dev/null; then
        local from="${SMTP_FROM:-openshift-healthcheck@indianbank.in}"
        local smtp_url="${SMTP_SERVER}"

        # Build RFC 2822 email with HTML body
        local email_tmpfile
        email_tmpfile=$(mktemp)
        cat > "$email_tmpfile" <<EMAILEOF
From: $from
To: $recipients
Subject: $subject
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8

$(cat "$html_file")
EMAILEOF

        # Send via curl
        local rcpt_args=""
        IFS=',' read -ra ADDR <<< "$recipients"
        for addr in "${ADDR[@]}"; do
            rcpt_args+=" --mail-rcpt $(echo $addr | xargs)"
        done

        curl --silent --url "$smtp_url" \
            --mail-from "$from" \
            $rcpt_args \
            --upload-file "$email_tmpfile" 2>/dev/null

        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✔ Email sent successfully via SMTP ($smtp_url)${NC}"
            rm -f "$email_tmpfile"
            return 0
        fi
        rm -f "$email_tmpfile"
    fi

    echo -e "${YELLOW}⚠ Could not send email. Ensure mailx, mutt, or sendmail is installed.${NC}"
    echo -e "${YELLOW}  Alternatively set SMTP_SERVER and SMTP_FROM env vars for curl-based sending.${NC}"
    echo -e "${YELLOW}  Example: SMTP_SERVER=smtp://mailrelay.indianbank.in:25 SMTP_FROM=ocp-health@indianbank.in${NC}"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
print_summary() {
    log_header "HEALTH CHECK SUMMARY — ${CLUSTER_DISPLAY_NAME}"
    echo ""
    echo -e "  ${GREEN}✔ PASSED:${NC}   $PASS_COUNT"
    echo -e "  ${YELLOW}⚠ WARNINGS:${NC} $WARN_COUNT"
    echo -e "  ${RED}✘ FAILED:${NC}   $FAIL_COUNT"
    echo -e "  ${BLUE}ℹ INFO:${NC}     $INFO_COUNT"
    echo -e "  ${BOLD}Total Checks: $TOTAL_CHECKS${NC}"
    echo ""

    if [[ $FAIL_COUNT -eq 0 && $WARN_COUNT -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}🟢 CLUSTER IS HEALTHY${NC}"
    elif [[ $FAIL_COUNT -eq 0 ]]; then
        echo -e "  ${YELLOW}${BOLD}🟡 CLUSTER HAS WARNINGS — Review recommended${NC}"
    else
        echo -e "  ${RED}${BOLD}🔴 CLUSTER HAS FAILURES — Immediate attention needed${NC}"
    fi
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${BLUE}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║   Indian Bank — OpenShift Cluster Health Check          ║"
    echo "  ║   $(date '+%Y-%m-%d %H:%M:%S %Z')                               ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    preflight

    echo -e "${BOLD}${CYAN}  Cluster: ${CLUSTER_DISPLAY_NAME}${NC}\n"

    # Auto-generate output path if not specified: /root/Cluster_health/<cluster>_<date>_<time>.html
    if [[ -z "$OUTPUT_FILE" ]]; then
        local report_dir="/root/Cluster_health"
        mkdir -p "$report_dir" 2>/dev/null || true
        local cluster_tag
        cluster_tag=$(echo "$CLUSTER_DISPLAY_NAME" | sed 's/ /_/g; s/[^a-zA-Z0-9_-]//g')
        OUTPUT_FILE="${report_dir}/${cluster_tag}_$(date '+%Y-%m-%d_%H%M%S').html"
        echo -e "${BLUE}  Report will be saved to: ${OUTPUT_FILE}${NC}\n"
    fi

    check_cluster_version
    check_cluster_operators
    check_nodes
    check_machine_config_pools
    check_etcd
    check_critical_namespaces
    check_ingress
    check_storage
    check_certificates
    check_workloads
    check_application_namespaces
    check_olm_operators
    check_networking
    check_monitoring
    check_logging_stack
    check_resource_quotas
    check_events
    check_machine_api
    check_image_registry
    print_summary

    # Output formats
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        local json_file
        json_file=$(echo "$OUTPUT_FILE" | sed 's/\.html$/.json/')
        echo "$JSON_RESULTS" | jq '{
            timestamp: "'"$TIMESTAMP"'",
            cluster_name: "'"$CLUSTER_DISPLAY_NAME"'",
            api_url: "'"$CLUSTER_API_URL"'",
            summary: {
                pass: '"$PASS_COUNT"',
                warn: '"$WARN_COUNT"',
                fail: '"$FAIL_COUNT"',
                info: '"$INFO_COUNT"',
                total: '"$TOTAL_CHECKS"'
            },
            results: .
        }' > "$json_file" 2>/dev/null
        echo -e "${GREEN}JSON report saved to: ${json_file}${NC}"
    fi

    # Always generate detailed HTML report
    generate_html_report "$OUTPUT_FILE"

    # Generate Indian Bank checklist report (email-friendly format matching IBDCJIO team style)
    local checklist_file
    checklist_file=$(echo "$OUTPUT_FILE" | sed 's/\.html$/_checklist.html/')
    generate_checklist_report "$checklist_file"

    # Send email if requested — use checklist format as email body
    if [[ -n "$EMAIL_RECIPIENTS" ]]; then
        send_email_report "$checklist_file" "$EMAIL_RECIPIENTS" "$EMAIL_SUBJECT"
    fi

    echo -e "\n${BOLD}${GREEN}Reports generated:${NC}"
    echo -e "  ${GREEN}Detailed report:   ${OUTPUT_FILE}${NC}"
    echo -e "  ${GREEN}Checklist (email): ${checklist_file}${NC}"

    # Cleanup old reports (keep last 30 days)
    find /root/Cluster_health/ -name "*.html" -mtime +30 -delete 2>/dev/null || true
    find /root/Cluster_health/ -name "*.json" -mtime +30 -delete 2>/dev/null || true

    # Exit code based on failures
    if [[ $FAIL_COUNT -gt 0 ]]; then exit 2; fi
    if [[ $WARN_COUNT -gt 0 ]]; then exit 1; fi
    exit 0
}

main
