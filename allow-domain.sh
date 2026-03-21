#!/bin/bash
# allow-domain.sh — add a domain to the firewall whitelist at runtime.
# Usage: sudo allow-domain.sh <domain>
#
# How it works: Resolves the domain to IP addresses via DNS, then adds those IPs
# to the "allowed-domains" ipset that iptables checks against. After running this,
# outbound connections to that domain will succeed.
#
# This script is called by Claude after getting user approval in chat (see CLAUDE.md).
# In --locked mode, this script refuses to run — no runtime additions allowed.
#
# All additions are logged to /var/log/firewall-changes.log for audit.
# These additions are in-memory only and reset on container restart.
# To make them permanent, add the domain to /workspace/.allowed-domains instead.

set -euo pipefail

domain="${1:-}"
if [ -z "$domain" ]; then
    echo "Usage: allow-domain.sh <domain>"
    exit 1
fi

# In locked mode, runtime domain additions are disabled.
# The lock file is created by entrypoint.sh as root — the node user cannot delete it.
# This is a hard security boundary (unlike env vars, which sudo strips).
if [ -f /etc/claude-sandbox-locked ]; then
    echo "Network is LOCKED — runtime domain additions are disabled."
    echo "To allow $domain, add it to .allowed-domains and restart the container."
    exit 1
fi

# Resolve the domain to IP addresses.
# dig +short A = look up IPv4 addresses, compact output
# grep filters to only lines starting with a number (actual IPs, not CNAME aliases)
# sort -u removes duplicates
ips=$(dig +short A "$domain" | grep -E '^[0-9]' | sort -u)
if [ -z "$ips" ]; then
    echo "Failed to resolve $domain"
    exit 1
fi

echo "Resolving $domain → $(echo "$ips" | tr '\n' ', ' | sed 's/,$//')"

# Add each resolved IP to the firewall allowlist and /etc/hosts.
# /etc/hosts is needed because DNS is blocked for the node user (anti-tunneling).
# This script runs as root (via sudo), so it can write to both.
for ip in $ips; do
    ipset add allowed-domains "$ip" 2>/dev/null || true
    # Add to /etc/hosts only if not already present (prevents duplicates on repeated calls)
    grep -q "$ip $domain" /etc/hosts 2>/dev/null || echo "$ip $domain # claude-sandbox-managed" >> /etc/hosts
done

# Audit log — record what was allowed and when
echo "$(date '+%Y-%m-%d %H:%M:%S') DOMAIN_ADDED $domain → $ips" >> /var/log/firewall-changes.log 2>/dev/null || true
echo "$domain is now accessible."
