#===============================================================================
# Salt State: SIEM Integration (rsyslog) Offboarding
# File: offboarding/siem_rsyslog.sls
# Usage: salt '<minion>' state.apply offboarding.siem_rsyslog
#===============================================================================

# Backup current rsyslog.conf before changes
siem_rsyslog_backup:
  cmd.run:
    - name: cp /etc/rsyslog.conf /etc/rsyslog.conf.pre-offboard.bak
    - onlyif: test -f /etc/rsyslog.conf
    - unless: test -f /etc/rsyslog.conf.pre-offboard.bak

# Remove SIEM-specific rsyslog config files
siem_rsyslog_remove_siem_conf:
  cmd.run:
    - name: rm -f /etc/rsyslog.d/*siem* /etc/rsyslog.d/*SIEM*
    - onlyif: ls /etc/rsyslog.d/*siem* /etc/rsyslog.d/*SIEM* 2>/dev/null

siem_rsyslog_remove_remote_conf:
  cmd.run:
    - name: rm -f /etc/rsyslog.d/*remote* /etc/rsyslog.d/*Remote*
    - onlyif: ls /etc/rsyslog.d/*remote* /etc/rsyslog.d/*Remote* 2>/dev/null

# Remove Salt-managed markers from rsyslog.conf
siem_rsyslog_clean_main_conf:
  cmd.run:
    - name: |
        if grep -q "# SIEM\|# Salt managed\|# Managed by Salt" /etc/rsyslog.conf; then
          sed -i '/# SIEM/d; /# Salt managed/d; /# Managed by Salt/d' /etc/rsyslog.conf
          echo "Cleaned Salt-managed entries from rsyslog.conf"
        fi
    - onlyif: grep -q "# SIEM\|# Salt managed" /etc/rsyslog.conf

# Restart rsyslog to apply changes
siem_rsyslog_restart:
  service.running:
    - name: rsyslog
    - enable: True
    - reload: True
    - watch:
      - cmd: siem_rsyslog_remove_siem_conf
      - cmd: siem_rsyslog_remove_remote_conf
      - cmd: siem_rsyslog_clean_main_conf

# Verify rsyslog is running
siem_rsyslog_verify:
  cmd.run:
    - name: |
        if systemctl is-active rsyslog &>/dev/null; then
          echo "rsyslog running - SIEM config cleaned"
          exit 0
        else
          echo "rsyslog not running - check manually"
          exit 1
        fi
    - require:
      - service: siem_rsyslog_restart
