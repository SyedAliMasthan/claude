# Linux Health Check v3.0 - Banking Production Environment

## Oracle Linux 8/9/10 | vSphere VMs | SaltStack Managed

Comprehensive daily health + security + compliance check script (2059 lines, 68 alert checks, 14 sections).

### Sections
| # | Section | Category |
|---|---------|----------|
| 0 | Dependency Check (warn only) | Pre-flight |
| 1-9 | CPU, Memory, Swap, Disk I/O, FS, NFS, S3FS, SAR History | Performance |
| 10 | SSH, Brute Force, Users, SUID/SGID, Firewall, SELinux, Ports, Certs, Passwords, Auditd | Security/VAPT |
| 11 | Kernel sysctl, Modules, /tmp, Core Dumps, ASLR, AIDE, Umask | CIS Compliance |
| 12 | Zombies, Reboot, Errata, DNS, Backup, Systemd, Kdump, Logs | Infrastructure |
| 13 | Patching, Satellite, Compliance Summary | Patching |
| 14 | Alert Summary + Recommendations + Team Notification | Summary |

### Files
- `linux_health_check_v3.sh` — Main script
- `linux-health-check.service` — Systemd service unit
- `linux-health-check.timer` — Daily 06:00 AM (cron-free)
- `health_check.sls` — SaltStack deployment state
- `install_health_check_v3.sh` — Standalone installer

### Quick Start
```bash
chmod +x install_health_check_v3.sh
sudo ./install_health_check_v3.sh
```

### Output
- TXT: `/root/Linux_health/<host>_health_YYYYMMDD.txt`
- HTML: `/root/Linux_health/<host>_health_YYYYMMDD.html` (color-coded, collapsible)
