#===============================================================================
# Salt State: Satellite/Foreman Offboarding
# File: offboarding/satellite.sls
# Usage: salt '<minion>' state.apply offboarding.satellite
#===============================================================================

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
