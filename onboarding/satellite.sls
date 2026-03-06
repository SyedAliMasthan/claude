#===============================================================================
# Salt State: Satellite/Foreman Patch Management Onboarding
# File: onboarding/satellite.sls
# Usage: salt '<minion>' state.apply onboarding.satellite
# Pillar: environment (PROD/NONPROD)
#===============================================================================

{% set satellite_server = pillar.get('satellite_server', '10.100.27.102') %}
{% set environment = pillar.get('environment', 'NONPROD') %}

# Detect OS type
{% set os_family = grains['os_family'] %}
{% set os = grains['os'] %}

{% if os == 'OracleLinux' or 'oracle' in grains.get('osfinger', '')|lower %}
  {% set reg_script = 'olregistration.sh' %}
  {% set os_type = 'OL' %}
{% else %}
  {% set reg_script = 'rhel.sh' %}
  {% set os_type = 'RHEL' %}
{% endif %}

# Download registration script
satellite_download_script:
  cmd.run:
    - name: curl -sSlk "https://{{ satellite_server }}/pub/{{ reg_script }}" -o /tmp/{{ reg_script }}
    - creates: /tmp/{{ reg_script }}

# Execute registration script
satellite_register:
  cmd.run:
    - name: bash /tmp/{{ reg_script }} actual {{ environment }}
    - require:
      - cmd: satellite_download_script
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
