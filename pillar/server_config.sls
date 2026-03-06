#===============================================================================
# Pillar: Server Onboarding/Offboarding Configuration
# File: pillar/server_config.sls
#===============================================================================

# Salt Master configuration
salt_master: 10.100.204.145

# Satellite/Foreman server
satellite_server: 10.100.27.102

# Environment (auto-detected from hostname, but can be overridden)
# Values: PROD, NONPROD
# environment: NONPROD

# Environment codes mapping (for reference):
# P = PROD (Production)
# R = NONPROD (Pre Prod)
# G = NONPROD (CUG)
# C = NONPROD (POC)
# S = NONPROD (SIT)
# D = NONPROD (Dev)
# U = NONPROD (UAT)
