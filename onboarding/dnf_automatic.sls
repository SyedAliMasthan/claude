#===============================================================================
# Salt State: DNF Automatic Onboarding
# File: onboarding/dnf_automatic.sls
# Usage: salt '<minion>' state.apply onboarding.dnf_automatic
#===============================================================================

{% set satellite_server = pillar.get('satellite_server', '10.100.27.102') %}

# Download dnfauto.sh script
dnf_auto_download:
  cmd.run:
    - name: curl -sSlk "https://{{ satellite_server }}/pub/dnfauto.sh" -o /tmp/dnfauto.sh
    - creates: /tmp/dnfauto.sh

# Execute dnfauto.sh
dnf_auto_install:
  cmd.run:
    - name: bash /tmp/dnfauto.sh
    - require:
      - cmd: dnf_auto_download
    - unless: rpm -q dnf-automatic

# Download dnfautoconf.sh script
dnf_auto_conf_download:
  cmd.run:
    - name: curl -sSlk "https://{{ satellite_server }}/pub/dnfautoconf.sh" -o /tmp/dnfautoconf.sh
    - creates: /tmp/dnfautoconf.sh
    - require:
      - cmd: dnf_auto_install

# Execute dnfautoconf.sh
dnf_auto_configure:
  cmd.run:
    - name: bash /tmp/dnfautoconf.sh
    - require:
      - cmd: dnf_auto_conf_download

# Ensure dnf-automatic timer is enabled and running
dnf_automatic_timer:
  service.running:
    - name: dnf-automatic.timer
    - enable: True
    - require:
      - cmd: dnf_auto_configure

# Cleanup scripts
dnf_auto_cleanup:
  file.absent:
    - names:
      - /tmp/dnfauto.sh
      - /tmp/dnfautoconf.sh
    - require:
      - service: dnf_automatic_timer
