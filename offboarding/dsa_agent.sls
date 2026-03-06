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

# Verify removal
dsa_agent_verify:
  cmd.run:
    - name: |
        if ! rpm -q ds_agent &>/dev/null && ! systemctl is-active ds_agent &>/dev/null; then
          echo "DSA Agent removed successfully"
          exit 0
        else
          echo "DSA Agent removal incomplete"
          exit 1
        fi
    - require:
      - file: dsa_agent_cleanup_opt
      - file: dsa_agent_cleanup_var
