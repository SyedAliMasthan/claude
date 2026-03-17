#===============================================================================
# Salt State: UDAgent Onboarding
# File: onboarding/udagent.sls
# Usage: salt '<minion>' state.apply onboarding.udagent
#===============================================================================

# Copy UDAgent installation script from Salt file server
udagent_copy_script:
  file.managed:
    - name: /tmp/udagent.sh
    - source: salt://scripts/udagent.sh
    - user: root
    - group: root
    - mode: 755
    - unless: systemctl is-active udagent

# Execute UDAgent installation script
udagent_install:
  cmd.run:
    - name: bash /tmp/udagent.sh
    - require:
      - file: udagent_copy_script
    - unless: systemctl is-active udagent

# Ensure udagent service is running
udagent_service:
  service.running:
    - name: udagent
    - enable: True
    - require:
      - cmd: udagent_install

# Cleanup installation script
udagent_cleanup:
  file.absent:
    - name: /tmp/udagent.sh
    - require:
      - service: udagent_service
