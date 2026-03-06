#===============================================================================
# Salt State: Salt Minion Offboarding (FINAL STEP)
# File: offboarding/salt_minion.sls
# Usage: salt '<minion>' state.apply offboarding.salt_minion
#
# WARNING: This should be the LAST step in offboarding!
# After this runs, the minion will no longer be managed by Salt.
#===============================================================================

{% set salt_master = pillar.get('salt_master', '10.100.204.145') %}

# Save minion ID for reference before removal
salt_minion_save_id:
  cmd.run:
    - name: |
        MINION_ID=$(cat /etc/salt/minion_id 2>/dev/null || hostname -s)
        echo "$MINION_ID" > /tmp/.salt_minion_id_backup
        echo "Minion ID: $MINION_ID"
    - onlyif: test -f /etc/salt/minion_id

# Stop salt-minion service
salt_minion_stop:
  service.dead:
    - name: salt-minion
    - enable: False
    - require:
      - cmd: salt_minion_save_id

# Note: Package removal and cleanup should be done via orchestration
# or manually since this state won't complete after minion stops

# Display manual cleanup instructions
salt_minion_instructions:
  cmd.run:
    - name: |
        MINION_ID=$(cat /tmp/.salt_minion_id_backup 2>/dev/null || hostname -s)
        echo ""
        echo "=========================================="
        echo "SALT MINION STOPPED"
        echo "=========================================="
        echo ""
        echo "To complete removal, run manually on this server:"
        echo "  dnf remove -y salt-minion salt"
        echo "  rm -rf /etc/salt /var/cache/salt /var/log/salt"
        echo ""
        echo "On Salt Master ({{ salt_master }}):"
        echo "  salt-key -d $MINION_ID"
        echo ""
        echo "=========================================="
    - require:
      - service: salt_minion_stop
