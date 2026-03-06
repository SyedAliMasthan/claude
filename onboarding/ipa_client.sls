#===============================================================================
# Salt State: IPA Client Onboarding
# File: onboarding/ipa_client.sls
# Usage: salt '<minion>' state.apply onboarding.ipa_client
#===============================================================================

# Apply IPA client configuration via existing Salt state
ipa_client_apply:
  module.run:
    - name: state.apply
    - mods: ipa
    - unless: test -f /etc/ipa/default.conf

# Verify IPA client enrollment
ipa_client_verify:
  cmd.run:
    - name: |
        if [ -f /etc/ipa/default.conf ]; then
          echo "IPA client enrolled successfully"
          ipa_server=$(grep -i "server" /etc/ipa/default.conf | head -1)
          echo "IPA Server: $ipa_server"
          exit 0
        else
          echo "IPA enrollment failed - /etc/ipa/default.conf not found"
          exit 1
        fi
    - require:
      - module: ipa_client_apply

# Ensure SSSD service is running
ipa_client_sssd:
  service.running:
    - name: sssd
    - enable: True
    - require:
      - cmd: ipa_client_verify
