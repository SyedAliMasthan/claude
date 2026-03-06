# Linux Health Check - Banking Production Environment

## Overview
Comprehensive daily Linux health check system designed for **Oracle Linux 8/9/10 (RHEL-compatible)** in regulated banking environments. Generates dual-format reports (TXT + HTML) with threshold-based alerting, Oracle database process awareness, and full audit trail compliance.

## Key Features

| Feature | Details |
|---------|---------|
| **CPU Analysis** | Real-time + SAR historical, per-core, Oracle process detection |
| **Memory Analysis** | Physical + HugePages (Oracle), top consumers, 24h trends |
| **Swap Monitoring** | Per-process swap usage via /proc/smaps, Oracle-aware alerts |
| **Disk I/O & Latency** | iostat await/svctm/%util, SAN latency detection |
| **Filesystem** | Local + NFS + S3FS, inode monitoring, 85% threshold |
| **NFS Health** | Mount responsiveness, stale handles, RPC stats, hung detection |
| **S3FS Mounts** | Auto-detection, responsiveness check, credential validation |
| **24h Historical** | SAR CPU/Memory/Swap/Disk with breach timestamp identification |
| **Recommendations** | Auto-generated per-finding with team notification mapping |
| **Alerting** | Email + Salt Event Bus (configurable) |
| **Scheduling** | Systemd Timer (cron-free, banking compliant) |

## Architecture

```
┌──────────────────────────────────────────────────┐
│           Systemd Timer (Daily 06:00)            │
│         (Cron-free, audit-friendly)              │
└──────────────────┬───────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────┐
│         linux_health_check.sh                    │
│  ┌────────────┐ ┌────────────┐ ┌──────────────┐ │
│  │  Live Data  │ │ SAR/Hist   │ │  Threshold   │ │
│  │  Collection │ │ Analysis   │ │  Engine      │ │
│  └──────┬─────┘ └─────┬──────┘ └──────┬───────┘ │
│         └──────────────┼───────────────┘         │
│                        ▼                         │
│  ┌──────────────────────────────────────────┐    │
│  │  Dual Report Generation (TXT + HTML)     │    │
│  └──────────────────┬───────────────────────┘    │
│                     │                            │
│  ┌──────────┐ ┌─────┴────┐ ┌──────────────┐     │
│  │  Email   │ │  Salt    │ │   Report     │     │
│  │  Alert   │ │  Event   │ │   /root/     │     │
│  └──────────┘ └──────────┘ └──────────────┘     │
└──────────────────────────────────────────────────┘
```

## Installation

### Option 1: Quick Install (Standalone)
```bash
chmod +x install_health_check.sh
sudo ./install_health_check.sh
```

### Option 2: SaltStack Deployment (Centralized)
```bash
# Copy files to Salt file server
cp linux_health_check.sh /srv/salt/linux_health_check/
cp linux-health-check.service /srv/salt/linux_health_check/
cp linux-health-check.timer /srv/salt/linux_health_check/
cp health_check.sls /srv/salt/linux_health_check/init.sls

# Deploy to all minions
salt '*' state.apply linux_health_check

# Or target specific groups
salt -G 'os:OracleLinux' state.apply linux_health_check
```

## Configuration

Edit the **CONFIGURABLE THRESHOLDS** section at the top of `linux_health_check.sh`:

```bash
THRESH_CPU=85          # CPU %
THRESH_MEMORY=85       # Memory %
THRESH_SWAP=70         # Swap % (lower for early warning)
THRESH_DISK_UTIL=85    # Disk I/O utilization %
THRESH_DISK_AWAIT=50   # Disk await milliseconds
THRESH_FS=85           # Filesystem usage %
THRESH_NFS_RETRANS=5   # NFS retransmission %
THRESH_LOAD_FACTOR=2   # Load = factor x CPU_count
```

### Email Configuration
```bash
ENABLE_EMAIL_ALERT="yes"
EMAIL_RECIPIENTS="unix-team@bank.com,infra-alerts@bank.com"
```

### Salt Event Configuration
```bash
ENABLE_SALT_EVENT="yes"
SALT_EVENT_TAG="infra/health/alert"
```

## Scheduling (Cron-Free)

This uses **systemd timers** instead of cron for banking compliance:

```bash
# Check timer status
systemctl status linux-health-check.timer

# View next scheduled run
systemctl list-timers linux-health-check.timer

# View execution logs (audit trail)
journalctl -u linux-health-check.service --since today

# Manual trigger
systemctl start linux-health-check.service

# Change schedule (edit timer, then reload)
systemctl edit linux-health-check.timer
systemctl daemon-reload
```

## Output Files

| File | Location | Purpose |
|------|----------|---------|
| TXT Report | `/root/Linux_health/<host>_health_YYYYMMDD.txt` | Quick grep/review |
| HTML Report | `/root/Linux_health/<host>_health_YYYYMMDD.html` | Color-coded dashboard |
| Alert Log | `/root/Linux_health/.alert_findings_YYYYMMDD.tmp` | Temporary (auto-cleaned) |

Reports auto-cleanup after **30 days**.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All healthy, no breaches |
| 1 | Warning-level breaches found |
| 2 | Critical-level breaches found |

## RBI Compliance Notes

- **Audit Trail**: All executions logged via journald (`journalctl -u linux-health-check.service`)
- **No Cron**: Uses systemd timers (compliance-approved scheduling)
- **Immutable Scheduling**: Timer changes require systemctl commands (auditable via journald)
- **Report Retention**: 30-day retention with timestamp-based filenames
- **Security**: Script runs with resource limits (CPUQuota=30%, MemoryMax=512M)

## Prerequisites

- `sysstat` (for sar/iostat/mpstat)
- `bc` (for calculations)
- `nfs-utils` (for nfsstat/nfsiostat)
- `mailx` or `sendmail` (for email alerts, optional)
- `salt-minion` (for Salt events, optional)
