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

# Restart rsyslog to apply changes
siem_rsyslog_restart:
  service.running:
    - name: rsyslog
    - enable: True
    - reload: True
    - watch:
      - cmd: siem_rsyslog_remove_siem_conf
      - cmd: siem_rsyslog_remove_remote_conf
