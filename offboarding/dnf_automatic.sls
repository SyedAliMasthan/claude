#===============================================================================
# Salt State: DNF Automatic Offboarding
# File: offboarding/dnf_automatic.sls
# Usage: salt '<minion>' state.apply offboarding.dnf_automatic
#===============================================================================

# Stop dnf-automatic timer
dnf_automatic_timer_stop:
  service.dead:
    - name: dnf-automatic.timer
    - enable: False
    - onlyif: systemctl list-unit-files | grep -q dnf-automatic.timer

# Stop dnf-automatic service
dnf_automatic_service_stop:
  service.dead:
    - name: dnf-automatic.service
    - enable: False
    - onlyif: systemctl list-unit-files | grep -q dnf-automatic.service
    - require:
      - service: dnf_automatic_timer_stop

# Remove dnf-automatic package
dnf_automatic_remove:
  pkg.removed:
    - name: dnf-automatic
    - require:
      - service: dnf_automatic_service_stop

# Cleanup config backup if exists
dnf_automatic_cleanup:
  file.absent:
    - name: /etc/dnf/automatic.conf.bak
    - require:
      - pkg: dnf_automatic_remove
