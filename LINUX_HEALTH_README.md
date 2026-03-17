# OpenShift Container Platform — Automated Health Check

## Indian Bank | JIO OCP Operations

Automated daily health check solution for 5 OpenShift clusters (DC Prod, DC Dev, DC Management, DR Prod, DR Management). Replaces manual screenshot-based reporting with automated HTML email reports.

---

## Repository Structure

```
ocp-health-check/
├── README.md
├── scripts/
│   ├── health_ocp.sh                 # Main health check script (2300+ lines, 19 sections)
│   └── setup_cron.sh                 # Cron scheduler for 3x daily execution
├── docs/
│   └── OCP_Health_Check_Proposal.docx # Architecture proposal for management approval
├── samples/
│   └── sample_checklist_report.html   # Sample bank-format 10-point checklist report
└── manifests/                         # K8s CronJob manifests (Phase 2)
```

## Features

### Main Health Check Script (`health_ocp.sh`)

**19 health check sections covering:**
- Cluster version & upgrade history
- Cluster operators (all 32+)
- Node health, pressure conditions, resource utilization
- MachineConfigPools
- etcd health
- Critical namespace pod health (24 openshift-* namespaces)
- Ingress / Router health
- Storage (PV/PVC, StorageClass)
- Certificate expiry (90-day warning)
- Workload health (cluster-wide CrashLoopBackOff with pod-level detail)
- Application namespace monitoring (Pods, Deployments, HPA, `oc adm top pods` with 80%/90% thresholds)
- OLM operators & catalog sources
- Networking (network/DNS operator)
- Monitoring (Prometheus, AlertManager, Grafana) + Critical/Warning alert listing
- Logging stack (CLO, Loki Operator, LokiStack components, PVCs, storage secrets, collectors)
- Resource quotas
- Cluster events
- Machine API
- Image Registry

**Two report formats generated:**
1. **Detailed HTML Report** — dark theme dashboard with PASS/WARN/FAIL filter buttons (internal use)
2. **Bank Checklist Report** — white Outlook-friendly 10-point numbered format matching IBDCJIO email template (sent to CDC/bank team)

**Key capabilities:**
- Auto-detects cluster name from API URL (dcprod → "Indian Bank DCPROD")
- Auto-saves to `/root/Cluster_health/` with date-time stamped filenames
- 30-day auto-cleanup of old reports
- HTML email support via mailx/mutt/curl-SMTP
- CrashLoopBackOff pods show: Pod name, Container, ExitCode, Restart count, Reason, Node
- Resource usage thresholds: >80% = Warning (amber), >90% = Critical (red)
- Critical alerts from Alertmanager shown individually with severity badges

## Quick Start

```bash
# Basic run — reports auto-saved to /root/Cluster_health/
./scripts/health_ocp.sh --kubeconfig ~/.kube/config

# With email to bank team
./scripts/health_ocp.sh --kubeconfig ~/.kube/config \
  --email "admin@indianbank.in,team@indianbank.in"

# Override cluster name
./scripts/health_ocp.sh --kubeconfig ~/.kube/config \
  --cluster-name "DCPROD"

# JSON output for CI/CD
./scripts/health_ocp.sh --kubeconfig ~/.kube/config --json
```

## Cron Setup (3x Daily)

```bash
# Edit email recipients in setup_cron.sh, then:
chmod +x scripts/setup_cron.sh
./scripts/setup_cron.sh
```

Schedule: 06:00 IST (Morning) | 14:00 IST (Afternoon) | 22:00 IST (Night)

## Cluster Coverage

| Cluster | API Pattern | Auto-Detected Name |
|---------|------------|-------------------|
| DC Prod | `*dcprod*` | Indian Bank DCPROD |
| DC Dev | `*dcdev*` | Indian Bank DCDEV |
| DC Management | `*dcmgmt*` | Indian Bank DC MANAGEMENT |
| DR Prod | `*drprod*` | Indian Bank DR PROD |
| DR Management | `*drmgmt*` | Indian Bank DR MANAGEMENT |

## Requirements

- `oc` CLI (or `kubectl` as fallback)
- `jq`
- Valid kubeconfig with cluster-reader or equivalent read permissions
- `mailx`/`mutt`/`sendmail` for email (optional)

## License

Internal use — Indian Bank IT Department
