#===============================================================================
# Salt State: DSA Agent Offboarding
# File: offboarding/dsa_agent.sls
# Usage: salt '<minion>' state.apply offboarding.dsa_agent
#===============================================================================

# Stop ds_agent service
dsa_agent_stop:
  service.dead:
    - name: ds_agent
    - enable: False
    - onlyif: systemctl list-unit-files | grep -q ds_agent

# Remove ds_agent package
dsa_agent_remove:
  pkg.removed:
    - name: ds_agent
    - require:
      - service: dsa_agent_stop

# Cleanup DSA Agent directories
dsa_agent_cleanup_opt:
  file.absent:
    - name: /opt/ds_agent
    - require:
      - pkg: dsa_agent_remove

dsa_agent_cleanup_var:
  file.absent:
    - name: /var/opt/ds_agent
    - require:
      - pkg: dsa_agent_remove
