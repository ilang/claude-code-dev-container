#!/bin/bash
# install-package.sh — safely install apt packages without exposing full apt-get.
# Usage: sudo install-package.sh <package1> [package2] ...
#
# Direct sudo apt-get is dangerous because apt-get accepts -o flags that can
# execute arbitrary shell commands via APT::Update::Pre-Invoke hooks, effectively
# giving root access. This wrapper only allows package names (no flags).

set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: install-package.sh <package1> [package2] ..."
    exit 1
fi

# Validate all arguments are package names (no flags or special characters).
# Package names can only contain lowercase letters, numbers, hyphens, dots, and plus signs.
for arg in "$@"; do
    if [[ "$arg" =~ ^- ]] || [[ ! "$arg" =~ ^[a-z0-9][a-z0-9.+\-]*$ ]]; then
        echo "Error: invalid package name '$arg'. Only package names allowed, no flags."
        exit 1
    fi
done

apt-get update -qq && apt-get install -y --no-install-recommends "$@"
