#===============================================================================
# Salt State: UDAgent Onboarding
# File: onboarding/udagent.sls
# Usage: salt '<minion>' state.apply onboarding.udagent
#===============================================================================

{% set salt_master = pillar.get('salt_master', '10.100.204.145') %}

# Download UDAgent installation script
udagent_download_script:
  cmd.run:
    - name: curl -sSlk "https://{{ salt_master }}/pub/udagent.sh" -o /tmp/udagent.sh
    - creates: /tmp/udagent.sh
    - unless: systemctl is-active udagent

# Execute UDAgent installation script
udagent_install:
  cmd.run:
    - name: bash /tmp/udagent.sh
    - require:
      - cmd: udagent_download_script
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
