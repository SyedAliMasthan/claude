# Server Lifecycle Automation

Comprehensive server onboarding and offboarding automation for Indian Bank infrastructure using **Shell Scripts** and **Salt Stack**.

## Overview

This repository contains automation scripts for managing the complete server lifecycle:
- **Onboarding**: Provisioning new servers with all required agents and configurations
- **Offboarding**: Decommissioning servers by removing agents and cleaning up registrations

## Components Managed

| # | Component | Service | Purpose |
|---|-----------|---------|---------|
| 1 | Salt-Minion | salt-minion | Configuration management |
| 2 | Satellite/Foreman | subscription-manager | Patch management |
| 3 | SIEM Integration | rsyslog | Security event logging |
| 4 | VRLI Agent | liagentd | VMware Log Insight |
| 5 | DNF Automatic | dnf-automatic.timer | Automatic updates |
| 6 | DSA Agent | ds_agent | Deep Security Agent |
| 7 | UDAgent | udagent | Universal Discovery |
| 8 | IPA Client | sssd | Identity management |

## Repository Structure

```
server-lifecycle-automation/
├── server_onboarding_v7.sh      # Standalone onboarding script
├── server_offboarding_v1.sh     # Standalone offboarding script
├── README.md
│
├── onboarding/                  # Salt states for onboarding
│   ├── init.sls                 # Run all onboarding states
│   ├── salt_minion.sls
│   ├── satellite.sls
│   ├── siem_rsyslog.sls
│   ├── vrli_agent.sls
│   ├── dnf_automatic.sls
│   ├── dsa_agent.sls
│   ├── udagent.sls
│   └── ipa_client.sls
│
├── offboarding/                 # Salt states for offboarding
│   ├── init.sls                 # Run all offboarding states
│   ├── dsa_agent.sls
│   ├── udagent.sls
│   ├── vrli_agent.sls
│   ├── dnf_automatic.sls
│   ├── siem_rsyslog.sls
│   ├── satellite.sls
│   ├── ipa_client.sls
│   └── salt_minion.sls          # Run separately as final step
│
└── pillar/
    └── server_config.sls        # Configuration variables
```

## Usage

### Standalone Scripts

#### Server Onboarding
```bash
# Interactive mode
sudo bash server_onboarding_v7.sh

# Environment is auto-detected from hostname:
# Last alpha character = environment code
# P = PROD | R,G,C,S,D,U = NONPROD
```

#### Server Offboarding
```bash
# Interactive mode (with confirmation)
sudo bash server_offboarding_v1.sh

# Non-interactive mode
sudo bash server_offboarding_v1.sh -y
```

### Salt Stack States

#### Complete Onboarding
```bash
salt '<minion>' state.apply onboarding
```

#### Complete Offboarding
```bash
# Step 1: Run all offboarding states (except salt_minion)
salt '<minion>' state.apply offboarding

# Step 2: Remove salt minion (final step)
salt '<minion>' state.apply offboarding.salt_minion

# Step 3: Delete minion key on Salt master
salt-key -d <minion_id>
```

#### Individual States
```bash
# Onboarding
salt '<minion>' state.apply onboarding.dsa_agent
salt '<minion>' state.apply onboarding.udagent
salt '<minion>' state.apply onboarding.vrli_agent
salt '<minion>' state.apply onboarding.dnf_automatic
salt '<minion>' state.apply onboarding.siem_rsyslog
salt '<minion>' state.apply onboarding.satellite
salt '<minion>' state.apply onboarding.ipa_client
salt '<minion>' state.apply onboarding.salt_minion

# Offboarding
salt '<minion>' state.apply offboarding.dsa_agent
salt '<minion>' state.apply offboarding.udagent
salt '<minion>' state.apply offboarding.vrli_agent
salt '<minion>' state.apply offboarding.dnf_automatic
salt '<minion>' state.apply offboarding.siem_rsyslog
salt '<minion>' state.apply offboarding.satellite
salt '<minion>' state.apply offboarding.ipa_client
salt '<minion>' state.apply offboarding.salt_minion
```

## Configuration

### Pillar Variables

Add to your Salt pillar:

```yaml
# pillar/server_config.sls
salt_master: 10.100.204.145
satellite_server: 10.100.27.102
environment: NONPROD  # Optional override
```

### Environment Detection

The scripts auto-detect environment from hostname:

| Code | Environment | Category |
|------|-------------|----------|
| P | Production | PROD |
| R | Pre-Prod | NONPROD |
| G | CUG | NONPROD |
| C | POC | NONPROD |
| S | SIT | NONPROD |
| D | Dev | NONPROD |
| U | UAT | NONPROD |

## Post-Offboarding Manual Actions

After running offboarding, complete these manual steps:

```bash
# On Salt Master
salt-key -d <minion_id>

# On IPA Server
ipa host-del <hostname_fqdn>

# On Satellite Server
hammer host delete --name <hostname_fqdn>
```

## Supported Operating Systems

- Red Hat Enterprise Linux 8/9
- Oracle Linux 8/9

## Requirements

- Root/sudo access
- Network connectivity to:
  - Salt Master (10.100.204.145)
  - Satellite Server (10.100.27.102)
  - IPA Server

## Logs

- Onboarding: `/var/log/server_onboarding_<timestamp>.log`
- Offboarding: `/var/log/server_offboarding_<hostname>_<timestamp>.log`

## Author

IT Infrastructure Team - Jio Platforms Limited

## License

Internal Use Only - Indian Bank Infrastructure
