#===============================================================================
# Salt State: IPA Client Offboarding
# File: offboarding/ipa_client.sls
# Usage: salt '<minion>' state.apply offboarding.ipa_client
#===============================================================================

# Stop SSSD service first
ipa_client_stop_sssd:
  service.dead:
    - name: sssd
    - onlyif: systemctl is-active sssd

# Unenroll from IPA
ipa_client_unenroll:
  cmd.run:
    - name: ipa-client-install --uninstall --unattended
    - onlyif: test -f /etc/ipa/default.conf
    - require:
      - service: ipa_client_stop_sssd

# Cleanup IPA configuration directory
ipa_client_cleanup_etc:
  file.absent:
    - name: /etc/ipa
    - require:
      - cmd: ipa_client_unenroll

# Remove Kerberos keytab
ipa_client_cleanup_keytab:
  file.absent:
    - name: /etc/krb5.keytab
    - require:
      - cmd: ipa_client_unenroll

# Clear SSSD database
ipa_client_cleanup_sss_db:
  cmd.run:
    - name: rm -rf /var/lib/sss/db/* /var/lib/sss/mc/*
    - onlyif: test -d /var/lib/sss/db
    - require:
      - cmd: ipa_client_unenroll
