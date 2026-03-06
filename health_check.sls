# =============================================================================
# Salt State: Linux Health Check Deployment
# Deploy and manage health check across all Oracle Linux minions
# =============================================================================
# Usage: salt '*' state.apply linux_health_check
# =============================================================================

# Ensure report directory exists
health_check_report_dir:
  file.directory:
    - name: /root/Linux_health
    - user: root
    - group: root
    - mode: '0750'

# Deploy the health check script
health_check_script:
  file.managed:
    - name: /usr/local/bin/linux_health_check.sh
    - source: salt://linux_health_check/linux_health_check.sh
    - user: root
    - group: root
    - mode: '0750'
    - require:
      - file: health_check_report_dir

# Deploy systemd service unit
health_check_service:
  file.managed:
    - name: /etc/systemd/system/linux-health-check.service
    - source: salt://linux_health_check/linux-health-check.service
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - file: health_check_script

# Deploy systemd timer unit
health_check_timer:
  file.managed:
    - name: /etc/systemd/system/linux-health-check.timer
    - source: salt://linux_health_check/linux-health-check.timer
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - file: health_check_service

# Reload systemd daemon
systemd_daemon_reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: health_check_service
      - file: health_check_timer

# Enable and start the timer
health_check_timer_enabled:
  service.running:
    - name: linux-health-check.timer
    - enable: True
    - require:
      - cmd: systemd_daemon_reload
      - file: health_check_timer

# Ensure sysstat is installed and running (for SAR data collection)
sysstat_package:
  pkg.installed:
    - name: sysstat

sysstat_service:
  service.running:
    - name: sysstat
    - enable: True
    - require:
      - pkg: sysstat_package

# Ensure bc is installed (used in calculations)
bc_package:
  pkg.installed:
    - name: bc

# Ensure nfs-utils is installed (for nfsstat/nfsiostat)
nfs_utils_package:
  pkg.installed:
    - name: nfs-utils
