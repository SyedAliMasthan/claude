#===============================================================================
# Salt State: Complete Server Offboarding
# File: offboarding/init.sls
# Usage: salt '<minion>' state.apply offboarding
#
# This runs all offboarding states in sequence (reverse of onboarding):
#   1. dsa_agent     - DSA Agent removal
#   2. udagent       - UDAgent removal
#   3. vrli_agent    - VRLI Agent removal
#   4. dnf_automatic - DNF Automatic disable
#   5. siem_rsyslog  - SIEM config cleanup
#   6. satellite     - Satellite unregister
#   7. ipa_client    - IPA Client unenroll
#
# NOTE: Salt Minion removal (salt_minion.sls) is NOT included here.
#       Run it separately as the final step:
#         salt '<minion>' state.apply offboarding.salt_minion
#===============================================================================

include:
  - offboarding.dsa_agent
  - offboarding.udagent
  - offboarding.vrli_agent
  - offboarding.dnf_automatic
  - offboarding.siem_rsyslog
  - offboarding.satellite
  - offboarding.ipa_client
