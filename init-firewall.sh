#!/bin/bash
# init-firewall.sh — Lock down the container's network so Claude can only reach approved domains.
#
# STRATEGY: "Default deny" — block ALL outbound traffic, then poke holes for specific
# domains (GitHub, npm, Anthropic API, etc.). This prevents Claude from accessing
# arbitrary websites, leaking code, or downloading unapproved packages.
#
# TOOLS USED:
#   iptables  — the Linux firewall. Think of it as a bouncer that checks every network
#               packet against a list of rules and decides: ACCEPT, DROP, or REJECT.
#   ipset     — a companion to iptables that holds large sets of IP addresses efficiently.
#               Instead of one iptables rule per IP, we put all IPs in a "set" and write
#               one rule: "allow anything in the set."
#   dig       — DNS lookup tool. Converts "github.com" → "140.82.121.3" (IP address).
#               The firewall works with IPs, not domain names, so we need to resolve first.
#   aggregate — merges overlapping IP ranges into compact CIDR blocks (e.g., merging
#               140.82.121.0/25 and 140.82.121.128/25 into 140.82.121.0/24).

set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting (prevents issues with spaces in IPs)

# If --no-install was requested, create a flag file that install-package.sh checks.
# Unlike the previous approach (removing sudoers entries), this is reversible —
# restarting without --no-install removes the flag file and re-enables installs.
if [ -f /tmp/.claude-no-install ]; then
    touch /etc/claude-sandbox-no-install
    echo "Package installation disabled."
else
    rm -f /etc/claude-sandbox-no-install
fi

# STEP 1: Save Docker's internal DNS rules BEFORE we wipe everything.
# Docker uses a built-in DNS server at 127.0.0.11 so containers can resolve
# other container names. It sets up NAT rules (Network Address Translation) to
# redirect DNS queries to this server. If we lose these, DNS stops working entirely.
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Wipe ALL existing firewall rules — start from a clean slate.
# -F = flush (delete all rules in a chain)
# -X = delete user-defined chains
# We flush three "tables": filter (default), nat (address translation), mangle (packet modification)
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
# Also destroy any previous ipset (our IP allowlist) so we rebuild it fresh
ipset destroy allowed-domains 2>/dev/null || true

# STEP 2: Restore Docker's DNS rules that we saved above.
# Without this, `dig`, `curl`, and every other DNS lookup would fail.
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    # Recreate the Docker NAT chains that the rules reference
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    # Re-add each saved rule
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# STEP 3: Add foundational "always allow" rules BEFORE locking things down.
# These must come first because iptables rules are evaluated top-to-bottom —
# the first matching rule wins.

# Allow DNS lookups (port 53) ONLY to the container's configured DNS resolver(s).
# Without DNS, we can't resolve domain names to IP addresses.
# IMPORTANT: We restrict DNS to only the resolvers in /etc/resolv.conf to prevent
# "DNS tunneling" — a technique where data is encoded into DNS queries and sent to
# an attacker-controlled DNS server, bypassing the IP-based firewall.
# See: github.com/anthropics/claude-code/issues/36907
#
# Docker uses different DNS setups depending on the platform:
#   - Docker Desktop (macOS/Windows): resolver is the VM gateway (e.g., 192.168.65.7)
#   - Docker Engine (Linux): embedded DNS at 127.0.0.11
# We read the actual resolver(s) from /etc/resolv.conf to handle both cases.
for dns_ip in $(grep '^nameserver' /etc/resolv.conf | awk '{print $2}'); do
    iptables -A OUTPUT -p udp --dport 53 -d "$dns_ip" -j ACCEPT
    iptables -A INPUT -p udp --sport 53 -s "$dns_ip" -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -d "$dns_ip" -j ACCEPT
    iptables -A INPUT -p tcp --sport 53 -s "$dns_ip" -j ACCEPT
done
# Also allow 127.0.0.11 in case Docker's embedded DNS is used alongside resolv.conf
iptables -A OUTPUT -p udp --dport 53 -d 127.0.0.11 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -s 127.0.0.11 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -d 127.0.0.11 -j ACCEPT
iptables -A INPUT -p tcp --sport 53 -s 127.0.0.11 -j ACCEPT

# Allow SSH (port 22) ONLY to whitelisted IPs (the allowed-domains ipset).
# This lets git push/pull over SSH to approved hosts (e.g., github.com) while
# preventing SSH connections to arbitrary servers (which could be used for
# data exfiltration). Note: the ipset must be created before this rule.
# We create it here early so this rule works; it gets populated later.
ipset create allowed-domains hash:net 2>/dev/null || true
iptables -A OUTPUT -p tcp --dport 22 -m set --match-set allowed-domains dst -j ACCEPT
# Only allow ESTABLISHED SSH responses (not new inbound SSH connections)
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT

# Allow localhost (loopback interface "lo"). Many tools communicate internally
# over localhost — blocking it would break things like npm, the DNS resolver, etc.
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# STEP 4: Create the IP allowlist set.
# "hash:net" means it stores network ranges (CIDR blocks like 140.82.121.0/24),
# not just individual IPs. This is more efficient for large ranges like GitHub's.
# The ipset may already exist (created early for the SSH rule above)
ipset create allowed-domains hash:net 2>/dev/null || true

# STEP 5: Populate the allowlist with approved IP addresses.

# --- Essential Claude Code domains (always whitelisted) ---
# These are required for Claude Code to function. They are hardcoded here
# and cannot be removed by the user. Additional domains (GitHub, npm, VS Code)
# are configured per-project via the .allowed-domains file.
#
# Why each domain is needed:
#   api.anthropic.com               — Claude Code's API (the AI backend)
#   claude.ai                       — authentication
#   downloads.claude.ai             — auto-update downloads
#   storage.googleapis.com          — auto-update downloads (legacy, being deprecated)
#   sentry.io                       — error reporting for Claude Code
#   statsig.anthropic.com, statsig.com — feature flags / analytics for Claude Code
#
# NOTE: DNS-resolved IPs can change over time. If a domain starts failing after a
# container restart, the new IPs will be re-resolved on the next restart.
# Clear any previous /etc/hosts entries we added (marked with our tag).
# We re-add fresh entries below so connections work even after DNS is blocked.
# Note: Docker mounts /etc/hosts as a bind mount that can't be renamed (sed -i fails).
# Instead, we filter to a temp file and copy the contents back.
grep -v '# claude-sandbox-managed' /etc/hosts > /tmp/hosts.clean || true
cp /tmp/hosts.clean /etc/hosts
rm -f /tmp/hosts.clean

echo "Resolving essential domains..."
for domain in \
    "api.anthropic.com" \
    "claude.ai" \
    "downloads.claude.ai" \
    "storage.googleapis.com" \
    "sentry.io" \
    "statsig.anthropic.com" \
    "statsig.com"; do
    # dig +noall +answer: suppress everything except the answer section
    # awk '$4 == "A"': only grab IPv4 address records (not CNAMEs, etc.)
    # sort -u: deduplicate IPs (DNS often returns the same IP multiple times)
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}' | sort -u)
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi

    # Validate and add each unique IP
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        # 2>/dev/null || true: silently skip if this IP was already added (e.g., shared CDN IPs)
        ipset add allowed-domains "$ip" 2>/dev/null || true
        # Also add to /etc/hosts so connections work after DNS is blocked for the node user
        echo "$ip $domain # claude-sandbox-managed" >> /etc/hosts
    done < <(echo "$ips")
    echo "  $domain → $(echo "$ips" | tr '\n' ', ' | sed 's/, $//')"
done

# STEP 6: Allow communication with the Docker host.
# The container needs to talk to the host machine (e.g., for Docker Desktop's
# DNS proxy, volume mounts, etc.). We detect the host's IP from the default
# network route, then allow the entire /24 subnet (e.g., 172.17.0.0/24).
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

# Convert host IP to a /24 subnet (e.g., 172.17.0.1 → 172.17.0.0/24)
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "  Host network: $HOST_NETWORK"

# Allow all traffic to/from the host network
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# STEP 7: Set the default policies to DROP (block everything not explicitly allowed).
# -P sets the "policy" — the fallback action when no rule matches a packet.
# DROP = silently discard the packet (for INPUT and FORWARD)
# We set this AFTER adding our allow rules above so we don't lock ourselves out.
iptables -P INPUT DROP
iptables -P FORWARD DROP    # FORWARD = traffic passing through (not applicable here, but safe to block)
iptables -P OUTPUT DROP

# STEP 8: Allow responses to connections we already initiated.
# "ESTABLISHED" = part of an existing connection (e.g., a response to our HTTPS request)
# "RELATED" = related to an existing connection (e.g., ICMP error about our connection)
# Without this, even allowed connections would fail because the responses would be dropped.
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# STEP 9: Allow outbound traffic ONLY to IPs in our allowlist.
# This is the key rule — it checks every outbound packet's destination IP against
# the "allowed-domains" ipset. If the IP is in the set, the packet is allowed.
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# REJECT (not DROP) everything else. REJECT sends back an error message so
# curl/wget fail immediately instead of hanging until timeout. Much better UX.
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# STEP 10: Verify the firewall actually works.
# Two sanity checks:
#   1. example.com SHOULD be blocked (it's not in our allowlist)
#   2. api.anthropic.com SHOULD be reachable (it IS in our allowlist)
# If either check fails, something went wrong and we bail out rather than
# running Claude in an insecure environment.
echo "Verifying firewall..."
echo "  Testing blocked site (example.com)..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "  FAILED: example.com should be blocked but was reachable!"
    exit 1
else
    echo "  Blocked as expected."
fi
echo "  Testing allowed site (api.anthropic.com)..."
if ! curl --connect-timeout 5 https://api.anthropic.com >/dev/null 2>&1; then
    echo "  FAILED: api.anthropic.com should be reachable but was blocked!"
    exit 1
else
    echo "  Reachable as expected."
fi
echo "Firewall ready."
