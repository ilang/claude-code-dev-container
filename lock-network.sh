#!/bin/bash
# lock-network.sh — create the network lock file to disable runtime domain additions.
# Usage: sudo lock-network.sh
#
# Creates /etc/claude-sandbox-locked (root-owned). Once created, allow-domain.sh
# will refuse to add domains. The node user cannot remove this file.
# This script can ONLY create the lock, never remove it — so even if a prompt
# injection calls it, it just re-locks (harmless).

set -euo pipefail

touch /etc/claude-sandbox-locked
echo "Network locked — runtime domain additions disabled."
