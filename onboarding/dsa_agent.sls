#===============================================================================
# Salt State: DSA Agent Onboarding
# File: onboarding/dsa_agent.sls
# Usage: salt '<minion>' state.apply onboarding.dsa_agent
#===============================================================================

{% set salt_master = pillar.get('salt_master', '10.100.204.145') %}

# Download DSA Agent installation script
dsa_agent_download_script:
  cmd.run:
    - name: curl -sSlk "https://{{ salt_master }}/pub/dsagent.sh" -o /tmp/dsagent.sh
    - creates: /tmp/dsagent.sh
    - unless: systemctl is-active ds_agent

# Execute DSA Agent installation script
dsa_agent_install:
  cmd.run:
    - name: bash /tmp/dsagent.sh
    - require:
      - cmd: dsa_agent_download_script
    - unless: systemctl is-active ds_agent

# Ensure ds_agent service is running
dsa_agent_service:
  service.running:
    - name: ds_agent
    - enable: True
    - require:
      - cmd: dsa_agent_install

# Cleanup installation script
dsa_agent_cleanup:
  file.absent:
    - name: /tmp/dsagent.sh
    - require:
      - service: dsa_agent_service
