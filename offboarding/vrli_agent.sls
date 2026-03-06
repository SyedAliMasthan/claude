#===============================================================================
# Salt State: VRLI Agent (VMware Log Insight) Offboarding
# File: offboarding/vrli_agent.sls
# Usage: salt '<minion>' state.apply offboarding.vrli_agent
#===============================================================================

# Stop liagentd service
vrli_agent_stop:
  service.dead:
    - name: liagentd
    - enable: False
    - onlyif: systemctl list-unit-files | grep -q liagentd

# Remove VMware Log Insight Agent package
vrli_agent_remove:
  cmd.run:
    - name: |
        VRLI_PKG=$(rpm -qa | grep -i "VMware-Log-Insight-Agent" | head -1)
        if [ -n "$VRLI_PKG" ]; then
          dnf remove -y "$VRLI_PKG" || yum remove -y "$VRLI_PKG"
          echo "Removed: $VRLI_PKG"
        else
          echo "VRLI Agent not installed"
        fi
    - require:
      - service: vrli_agent_stop

# Cleanup VRLI directories
vrli_agent_cleanup_lib:
  file.absent:
    - name: /var/lib/loginsight-agent
    - require:
      - cmd: vrli_agent_remove

vrli_agent_cleanup_log:
  file.absent:
    - name: /var/log/loginsight-agent
    - require:
      - cmd: vrli_agent_remove

# Verify removal
vrli_agent_verify:
  cmd.run:
    - name: |
        if ! rpm -qa | grep -qi "VMware-Log-Insight-Agent"; then
          echo "VRLI Agent removed successfully"
          exit 0
        else
          echo "VRLI Agent removal incomplete"
          exit 1
        fi
    - require:
      - file: vrli_agent_cleanup_log
