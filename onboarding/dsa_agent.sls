#===============================================================================
# Salt State: DSA Agent Onboarding
# File: onboarding/dsa_agent.sls
# Usage: salt '<minion>' state.apply onboarding.dsa_agent
#===============================================================================

# Copy DSA Agent installation script from Salt file server
dsa_agent_copy_script:
  file.managed:
    - name: /tmp/dsagent.sh
    - source: salt://scripts/dsagent.sh
    - user: root
    - group: root
    - mode: 755
    - unless: systemctl is-active ds_agent

# Execute DSA Agent installation script
dsa_agent_install:
  cmd.run:
    - name: bash /tmp/dsagent.sh
    - require:
      - file: dsa_agent_copy_script
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
