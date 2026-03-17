#===============================================================================
# Salt State: Complete Server Onboarding
# File: onboarding/init.sls
# Usage: salt '<minion>' state.apply onboarding
#
# This runs all onboarding states in sequence:
#   1. salt_minion   - Salt Minion configuration
#   2. satellite     - Patch Management registration
#   3. siem_rsyslog  - SIEM Integration
#   4. vrli_agent    - VMware Log Insight Agent
#   5. dnf_automatic - DNF Automatic updates
#   6. dsa_agent     - DSA Agent
#   7. udagent       - UDAgent
#   8. ipa_client    - IPA Client enrollment
#===============================================================================

include:
  - onboarding.salt_minion
  - onboarding.satellite
  - onboarding.siem_rsyslog
  - onboarding.vrli_agent
  - onboarding.dnf_automatic
  - onboarding.dsa_agent
  - onboarding.udagent
  - onboarding.ipa_client
