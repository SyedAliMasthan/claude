#===============================================================================
# Salt State: VRLI Agent (VMware Log Insight) Onboarding
# File: onboarding/vrli_agent.sls
# Usage: salt '<minion>' state.apply onboarding.vrli_agent
#===============================================================================

# Remove existing VMware Log Insight Agent if present (for clean install)
vrli_agent_remove_existing:
  cmd.run:
    - name: dnf remove -y VMware-Log-Insight-Agent* || yum remove -y VMware-Log-Insight-Agent* || true
    - onlyif: rpm -qa | grep -qi VMware-Log-Insight-Agent

# Refresh Salt pillar before deployment
vrli_agent_refresh_pillar:
  module.run:
    - name: saltutil.refresh_pillar

# Deploy LogInsight agent via Salt state
vrli_agent_deploy:
  module.run:
    - name: state.apply
    - mods: liagent
    - require:
      - module: vrli_agent_refresh_pillar

# Verify VRLI Agent installation
vrli_agent_verify:
  cmd.run:
    - name: rpm -qa | grep -i VMware-Log-Insight-Agent && echo "VRLI Agent installed successfully"
    - require:
      - module: vrli_agent_deploy
