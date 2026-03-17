#===============================================================================
# Salt State: Satellite/Foreman Patch Management Onboarding
# File: onboarding/satellite.sls
# Usage: salt '<minion>' state.apply onboarding.satellite
# Pillar: environment (PROD/NONPROD)
#===============================================================================

{% set environment = pillar.get('environment', 'NONPROD') %}

# Detect OS type
{% set os = grains['os'] %}

{% if os == 'OracleLinux' or 'oracle' in grains.get('osfinger', '')|lower %}
  {% set reg_script = 'olregistration.sh' %}
{% else %}
  {% set reg_script = 'rhel.sh' %}
{% endif %}

# Copy registration script from Salt file server
satellite_copy_script:
  file.managed:
    - name: /tmp/{{ reg_script }}
    - source: salt://scripts/{{ reg_script }}
    - user: root
    - group: root
    - mode: 755

# Execute registration script
satellite_register:
  cmd.run:
    - name: bash /tmp/{{ reg_script }} actual {{ environment }}
    - require:
      - file: satellite_copy_script
    - unless: subscription-manager identity 2>/dev/null | grep -q "system identity"

# Run dnf update after registration
satellite_dnf_update:
  cmd.run:
    - name: dnf update -y || yum update -y
    - require:
      - cmd: satellite_register
    - timeout: 1800

# Verify repos are enabled
satellite_verify_repos:
  cmd.run:
    - name: |
        REPO_COUNT=$(dnf repolist --enabled 2>/dev/null | tail -n +2 | wc -l)
        if [ "$REPO_COUNT" -gt 0 ]; then
          echo "Found $REPO_COUNT enabled repos"
          exit 0
        else
          echo "No repos found"
          exit 1
        fi
    - require:
      - cmd: satellite_register

# Cleanup registration script
satellite_cleanup:
  file.absent:
    - name: /tmp/{{ reg_script }}
    - require:
      - cmd: satellite_verify_repos
