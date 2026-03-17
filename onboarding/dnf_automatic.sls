#===============================================================================
# Salt State: DNF Automatic Onboarding
# File: onboarding/dnf_automatic.sls
# Usage: salt '<minion>' state.apply onboarding.dnf_automatic
#===============================================================================

# Copy dnfauto.sh script from Salt file server
dnf_auto_copy_script:
  file.managed:
    - name: /tmp/dnfauto.sh
    - source: salt://scripts/dnfauto.sh
    - user: root
    - group: root
    - mode: 755

# Execute dnfauto.sh
dnf_auto_install:
  cmd.run:
    - name: bash /tmp/dnfauto.sh
    - require:
      - file: dnf_auto_copy_script
    - unless: rpm -q dnf-automatic

# Copy dnfautoconf.sh script from Salt file server
dnf_auto_conf_copy_script:
  file.managed:
    - name: /tmp/dnfautoconf.sh
    - source: salt://scripts/dnfautoconf.sh
    - user: root
    - group: root
    - mode: 755
    - require:
      - cmd: dnf_auto_install

# Execute dnfautoconf.sh
dnf_auto_configure:
  cmd.run:
    - name: bash /tmp/dnfautoconf.sh
    - require:
      - file: dnf_auto_conf_copy_script

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
