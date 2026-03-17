#===============================================================================
# Salt State: UDAgent Offboarding
# File: offboarding/udagent.sls
# Usage: salt '<minion>' state.apply offboarding.udagent
#===============================================================================

# Stop udagent service
udagent_stop:
  service.dead:
    - name: udagent
    - enable: False
    - onlyif: systemctl list-unit-files | grep -q udagent

# Remove udagent package
udagent_remove:
  pkg.removed:
    - name: udagent
    - require:
      - service: udagent_stop

# Cleanup UDAgent directories
udagent_cleanup_opt:
  file.absent:
    - name: /opt/udagent
    - require:
      - pkg: udagent_remove

udagent_cleanup_var:
  file.absent:
    - name: /var/opt/udagent
    - require:
      - pkg: udagent_remove

udagent_cleanup_etc:
  file.absent:
    - name: /etc/udagent
    - require:
      - pkg: udagent_remove
