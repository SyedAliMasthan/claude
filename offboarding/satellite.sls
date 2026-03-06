#===============================================================================
# Salt State: Satellite/Foreman Offboarding
# File: offboarding/satellite.sls
# Usage: salt '<minion>' state.apply offboarding.satellite
#===============================================================================

{% set satellite_server = pillar.get('satellite_server', '10.100.27.102') %}

# Unregister from subscription-manager
satellite_unregister:
  cmd.run:
    - name: subscription-manager unregister
    - onlyif: subscription-manager identity 2>/dev/null | grep -q "system identity"

# Clean subscription-manager
satellite_clean:
  cmd.run:
    - name: subscription-manager clean
    - require:
      - cmd: satellite_unregister
    - onlyif: test -f /etc/rhsm/rhsm.conf

# Remove Katello CA certificate package
satellite_remove_katello:
  cmd.run:
    - name: |
        KATELLO_PKG=$(rpm -qa | grep katello-ca-consumer | head -1)
        if [ -n "$KATELLO_PKG" ]; then
          dnf remove -y "$KATELLO_PKG" || yum remove -y "$KATELLO_PKG"
          echo "Removed: $KATELLO_PKG"
        else
          echo "Katello CA not installed"
        fi
    - require:
      - cmd: satellite_clean

# Verify unregistration
satellite_verify:
  cmd.run:
    - name: |
        if ! subscription-manager identity &>/dev/null; then
          echo "Successfully unregistered from Satellite"
          echo "NOTE: Delete host from Satellite manually:"
          echo "  hammer host delete --name $(hostname -f)"
          exit 0
        else
          echo "Still registered to Satellite"
          exit 1
        fi
    - require:
      - cmd: satellite_remove_katello
