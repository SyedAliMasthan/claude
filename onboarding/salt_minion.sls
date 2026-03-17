#===============================================================================
# Salt State: Salt Minion Configuration
# File: onboarding/salt_minion.sls
# Usage: salt '<minion>' state.apply onboarding.salt_minion
#===============================================================================

{% set salt_master = pillar.get('salt_master', '10.100.204.145') %}

# Ensure salt-minion package is installed
salt_minion_pkg:
  pkg.installed:
    - name: salt-minion

# Configure Salt master in minion config
salt_minion_config:
  file.managed:
    - name: /etc/salt/minion.d/master.conf
    - contents: |
        # Salt Master Configuration
        # Managed by Salt
        master: {{ salt_master }}
    - user: root
    - group: root
    - mode: 644
    - makedirs: True
    - require:
      - pkg: salt_minion_pkg

# Copy and execute master config script from Salt file server
salt_minion_copy_master_config:
  file.managed:
    - name: /tmp/master_config.sh
    - source: salt://scripts/master_config.sh
    - user: root
    - group: root
    - mode: 755
    - require:
      - file: salt_minion_config

salt_minion_run_master_config:
  cmd.run:
    - name: bash /tmp/master_config.sh && rm -f /tmp/master_config.sh
    - require:
      - file: salt_minion_copy_master_config
    - onchanges:
      - file: salt_minion_config

# Ensure salt-minion service is running
salt_minion_service:
  service.running:
    - name: salt-minion
    - enable: True
    - restart: True
    - watch:
      - file: salt_minion_config

# Verify salt-minion connectivity
salt_minion_verify:
  cmd.run:
    - name: |
        sleep 5
        if salt-call test.ping 2>&1 | grep -q "True"; then
          echo "Salt minion connected to master successfully"
          exit 0
        else
          echo "Salt minion running but key may need acceptance"
          exit 0
        fi
    - require:
      - service: salt_minion_service
