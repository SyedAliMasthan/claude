# Server Lifecycle Automation - Salt States v2

Salt states for server onboarding and offboarding using **Salt File Server** instead of curl downloads.

## Key Change from v1

**v1 (curl download):**
```yaml
dsa_agent_download_script:
  cmd.run:
    - name: curl -sSlk "https://{{ salt_master }}/pub/dsagent.sh" -o /tmp/dsagent.sh
```

**v2 (Salt file server):**
```yaml
dsa_agent_copy_script:
  file.managed:
    - name: /tmp/dsagent.sh
    - source: salt://scripts/dsagent.sh
    - mode: 755
```

## Required File Server Setup

Upload your scripts to Salt file server under `scripts/` directory:

```
/srv/salt/scripts/
├── dsagent.sh          # DSA Agent installer
├── udagent.sh          # UDAgent installer
├── dnfauto.sh          # DNF Automatic installer
├── dnfautoconf.sh      # DNF Automatic configurator
├── master_config.sh    # Salt master config script
├── rhel.sh             # RHEL Satellite registration
└── olregistration.sh   # Oracle Linux Satellite registration
```

## Directory Structure

```
├── onboarding/
│   ├── init.sls           # Run all onboarding states
│   ├── salt_minion.sls    # Salt Minion configuration
│   ├── satellite.sls      # Satellite/Foreman registration
│   ├── siem_rsyslog.sls   # SIEM rsyslog integration
│   ├── vrli_agent.sls     # VMware Log Insight Agent
│   ├── dnf_automatic.sls  # DNF Automatic updates
│   ├── dsa_agent.sls      # DSA Agent
│   ├── udagent.sls        # UDAgent
│   └── ipa_client.sls     # IPA Client enrollment
│
├── offboarding/
│   ├── init.sls           # Run all offboarding (except salt_minion)
│   ├── dsa_agent.sls      # DSA Agent removal
│   ├── udagent.sls        # UDAgent removal
│   ├── vrli_agent.sls     # VRLI Agent removal
│   ├── dnf_automatic.sls  # DNF Automatic disable
│   ├── siem_rsyslog.sls   # SIEM config cleanup
│   ├── satellite.sls      # Satellite unregister
│   ├── ipa_client.sls     # IPA Client unenroll
│   └── salt_minion.sls    # Salt Minion removal (run last!)
│
└── pillar/
    └── server_config.sls  # Configuration variables
```

## Usage

### Complete Onboarding
```bash
salt '<minion>' state.apply onboarding
```

### Complete Offboarding
```bash
# Step 1: Run all offboarding states (except salt_minion)
salt '<minion>' state.apply offboarding

# Step 2: Remove salt minion (final step)
salt '<minion>' state.apply offboarding.salt_minion

# Step 3: Delete minion key on Salt master
salt-key -d <minion_id>
```

### Individual States
```bash
# Onboarding
salt '<minion>' state.apply onboarding.dsa_agent
salt '<minion>' state.apply onboarding.udagent
salt '<minion>' state.apply onboarding.satellite

# Offboarding  
salt '<minion>' state.apply offboarding.dsa_agent
salt '<minion>' state.apply offboarding.ipa_client
```

## Components Managed

| # | Component | Service | Onboarding | Offboarding |
|---|-----------|---------|------------|-------------|
| 1 | Salt-Minion | salt-minion | ✅ | ✅ |
| 2 | Satellite/Foreman | subscription-manager | ✅ | ✅ |
| 3 | SIEM Integration | rsyslog | ✅ | ✅ |
| 4 | VRLI Agent | liagentd | ✅ | ✅ |
| 5 | DNF Automatic | dnf-automatic.timer | ✅ | ✅ |
| 6 | DSA Agent | ds_agent | ✅ | ✅ |
| 7 | UDAgent | udagent | ✅ | ✅ |
| 8 | IPA Client | sssd | ✅ | ✅ |

## Post-Offboarding Manual Actions

```bash
# On Salt Master
salt-key -d <minion_id>

# On IPA Server
ipa host-del <hostname_fqdn>

# On Satellite Server
hammer host delete --name <hostname_fqdn>
```

## Pillar Configuration

```yaml
# pillar/server_config.sls
salt_master: 10.100.204.145
satellite_server: 10.100.27.102
environment: NONPROD  # Optional override
```

## Author

IT Infrastructure Team - Jio Platforms Limited
