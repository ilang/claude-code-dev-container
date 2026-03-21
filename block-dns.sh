#!/bin/bash
# block-dns.sh — block DNS queries for the node user (anti-tunneling measure).
# Usage: sudo block-dns.sh
#
# After this runs, the node user (UID 1000) cannot make DNS queries.
# Root processes (like allow-domain.sh via sudo) can still resolve domains.
# All approved domains should already be in /etc/hosts so connections work
# without DNS resolution.
#
# This prevents DNS tunneling — encoding data in DNS query labels to
# exfiltrate it through the resolver to an attacker's DNS server.

set -euo pipefail

# Insert at the top of the OUTPUT chain (before other rules) so it takes priority.
# -m owner --uid-owner 1000 matches packets from the node user only.
iptables -I OUTPUT 1 -m owner --uid-owner 1000 -p udp --dport 53 -j REJECT
iptables -I OUTPUT 2 -m owner --uid-owner 1000 -p tcp --dport 53 -j REJECT
echo "DNS blocked for node user."
