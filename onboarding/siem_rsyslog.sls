#===============================================================================
# Salt State: SIEM Integration (rsyslog) Onboarding
# File: onboarding/siem_rsyslog.sls
# Usage: salt '<minion>' state.apply onboarding.siem_rsyslog
#===============================================================================

# Reset existing rsyslog configuration
siem_rsyslog_reset:
  module.run:
    - name: state.apply
    - mods: rsyslog.reset

# Apply SIEM rsyslog configuration
siem_rsyslog_apply:
  module.run:
    - name: state.apply
    - mods: rsyslog.siem
    - require:
      - module: siem_rsyslog_reset

# Ensure rsyslog service is running
siem_rsyslog_service:
  service.running:
    - name: rsyslog
    - enable: True
    - reload: True
    - require:
      - module: siem_rsyslog_apply

# Verify rsyslog is running
siem_rsyslog_verify:
  cmd.run:
    - name: systemctl is-active rsyslog && echo "rsyslog SIEM integration active"
    - require:
      - service: siem_rsyslog_service
