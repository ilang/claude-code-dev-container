#!/bin/bash
# entrypoint.sh — the startup script that runs every time the container launches.
# It handles: credential sharing, memory sync, firewall setup, domain loading,
# and then either keeps the container alive (persistent mode) or launches Claude (temp mode).

set -e  # Exit immediately if any command fails

# CLAUDE_MODE is set by the claude-sandbox script via `docker run -e`.
# "persistent" = long-lived container you can attach to multiple times
# "temp"       = one-shot container that is deleted when Claude exits
CLAUDE_MODE="${CLAUDE_MODE:-temp}"

# --- .claude.json shared credentials ---
# Claude Code stores login tokens in ~/.claude.json. We need this to persist
# across all containers so you only log in once.
#
# Solution: A shared Docker volume is mounted at ~/.claude-json. We symlink
# ~/.claude.json → ~/.claude-json/.claude.json so Claude reads/writes directly
# to the shared volume. All containers see changes instantly — no copying needed.
CLAUDE_JSON_VOLUME="$HOME/.claude-json"
CLAUDE_JSON="$HOME/.claude.json"

if [ -d "$CLAUDE_JSON_VOLUME" ]; then
    # Remove any existing file (from a previous non-symlink setup) and create the symlink.
    rm -f "$CLAUDE_JSON"
    ln -sf "$CLAUDE_JSON_VOLUME/.claude.json" "$CLAUDE_JSON"
fi

# --- Container config files ---
# The Dockerfile stages these at /usr/local/share/claude-sandbox/ because the volume
# mount at ~/.claude shadows the image contents after first creation.
DEFAULTS="/usr/local/share/claude-sandbox"

# CLAUDE.md: always overwrite so image rebuilds propagate updates.
cp "$DEFAULTS/CLAUDE.md" "$HOME/.claude/CLAUDE.md" 2>/dev/null || true

# Statusline: always overwrite (same reason — updates propagate with image rebuilds).
cp "$DEFAULTS/statusline-command.sh" "$HOME/.claude/statusline-command.sh" 2>/dev/null || true

# Settings: seed only if missing. Don't overwrite — user may have customized inside container.
if [ ! -f "$HOME/.claude/settings.json" ]; then
    cp "$DEFAULTS/settings.json" "$HOME/.claude/settings.json" 2>/dev/null || true
fi

# --- Sync user memory from host ---
# User memory contains preferences, feedback, and personal context (e.g., "user prefers
# concise answers"). Low security risk — not project-specific. We copy from the host
# mount but don't overwrite memories the container has already built.
if [ -d /host-claude-config/memory ]; then
    mkdir -p "$HOME/.claude/memory"
    cp -rn /host-claude-config/memory/* "$HOME/.claude/memory/" 2>/dev/null || true
fi

# --- Clear readiness sentinel from any previous run ---
# The sentinel file tells the claude-sandbox script that setup is complete.
# We remove any stale one from a previous run so the script doesn't think
# we're ready before the firewall is actually configured.
rm -f /tmp/.claude-sandbox-ready

# --- Flag overrides ---
# When restarting an existing container with different flags (e.g., switching from
# default to --open-network), the env vars are baked in from creation time.
# The claude-sandbox script writes override files via `docker cp` before starting.
# We read them here, then delete them (one-shot overrides).
if [ -f /tmp/.claude-network-override ]; then
    CLAUDE_NETWORK=$(cat /tmp/.claude-network-override)
    rm -f /tmp/.claude-network-override
    echo "Network mode overridden to: $CLAUDE_NETWORK"
fi
if [ -f /tmp/.claude-no-install-override ]; then
    CLAUDE_NO_INSTALL=$(cat /tmp/.claude-no-install-override)
    rm -f /tmp/.claude-no-install-override
fi

# --- Package installation flag ---
# If --no-install was requested, write a flag file that init-firewall.sh reads.
# init-firewall.sh creates/removes /etc/claude-sandbox-no-install accordingly.
rm -f /tmp/.claude-no-install
if [ "${CLAUDE_NO_INSTALL:-}" = "1" ]; then
    touch /tmp/.claude-no-install
fi

# --- Network setup ---
# CLAUDE_NETWORK controls the firewall mode:
#   "default" — firewall + .allowed-domains + runtime approval via allow-domain.sh
#   "locked"  — firewall + .allowed-domains only (no runtime additions)
#   "open"    — no firewall at all, full internet access
#
# In all modes, Anthropic API and claude.ai are always reachable (baked into
# init-firewall.sh). The .allowed-domains file ships with GitHub, npm, and
# VS Code by default — users can remove entries they don't need.
CLAUDE_NETWORK="${CLAUDE_NETWORK:-default}"

# --- Save effective flags ---
# Write the resolved flags to a config file so the host script (claude-sandbox) can
# read the current state when reattaching. This file lives on the container's writable
# layer (per-container, persists across stop/start). It replaces Docker labels as the
# source of truth for the container's current settings.
# This must come AFTER the defaults are applied above.
echo "NETWORK=$CLAUDE_NETWORK" > "$HOME/.sandbox-config"
echo "NO_INSTALL=${CLAUDE_NO_INSTALL:-0}" >> "$HOME/.sandbox-config"

# Helper: load domains from .allowed-domains file into the firewall.
# Uses allow-domain.sh (via sudo) which has root access to ipset.
# These are pre-approved domains (user put them in the file), so no
# interactive confirmation is needed — allow-domain.sh just resolves and adds.
load_allowed_domains() {
    if [ -f /workspace/.allowed-domains ]; then
        echo "Loading allowed domains from .allowed-domains..."
        while IFS= read -r domain || [ -n "$domain" ]; do
            [[ -z "$domain" || "$domain" =~ ^# ]] && continue
            sudo /usr/local/bin/allow-domain.sh "$domain" || true
        done < /workspace/.allowed-domains
    fi
}

if [ "$CLAUDE_NETWORK" = "open" ]; then
    echo "Network: OPEN (no firewall — full internet access)"
    echo "WARNING: This disables all network security. Use only with trusted code."
elif [ "$CLAUDE_NETWORK" = "locked" ]; then
    echo "Network: LOCKED (whitelist only — no runtime domain additions)"
    echo "Setting up firewall..."
    sudo /usr/local/bin/init-firewall.sh
    # Load pre-approved domains BEFORE locking — once locked, allow-domain.sh refuses.
    load_allowed_domains
    # Create the root-owned lock file. lock-network.sh can only create, never remove.
    sudo /usr/local/bin/lock-network.sh
    # Block DNS for the node user to prevent DNS tunneling.
    # All domains are in /etc/hosts. Root (sudo) can still resolve, node cannot.
    sudo /usr/local/bin/block-dns.sh
else
    # Default: firewall + whitelist + runtime additions via allow-domain.sh
    echo "Network: DEFAULT (firewall + chat-based domain approval)"
    echo "Setting up firewall..."
    sudo /usr/local/bin/init-firewall.sh
    load_allowed_domains
    # Block DNS for the node user to prevent DNS tunneling.
    # allow-domain.sh runs as root (via sudo) so it can still resolve new domains.
    # Claude's connections use /etc/hosts for resolution.
    sudo /usr/local/bin/block-dns.sh
fi

# --- Signal readiness ---
# Create a sentinel file that the claude-sandbox script polls for.
# This tells it "the container is fully set up, firewall is active, ready to go."
touch /tmp/.claude-sandbox-ready

# --- Launch ---
# The container operates in one of two modes, set by the CLAUDE_MODE env var:
if [ "$CLAUDE_MODE" = "persistent" ]; then
    # PERSISTENT MODE: The container stays running in the background indefinitely.
    # You attach to it later with `docker exec` (the claude-sandbox script does this).
    #
    # We need PID 1 to handle SIGTERM so `docker stop` shuts down cleanly.
    trap 'exit 0' SIGTERM SIGINT

    echo ""
    echo "Container ready. Waiting for sessions..."
    echo ""

    tail -f /dev/null &
    TAIL_PID=$!
    # wait returns non-zero (128+signal) when interrupted by a signal; || true prevents
    # set -e from killing the script before the trap has a chance to run.
    wait $TAIL_PID || true
else
    # TEMP MODE: Launch Claude Code interactively right now.
    # The container will be deleted (--rm) when Claude exits.
    # If a subfolder was specified (for monorepos), cd into it first.
    WORKDIR="/workspace"
    if [ -n "${CLAUDE_SUBFOLDER:-}" ]; then
        WORKDIR="/workspace/$CLAUDE_SUBFOLDER"
        if [ ! -d "$WORKDIR" ]; then
            echo "Error: subfolder '$CLAUDE_SUBFOLDER' not found in /workspace"
            exit 1
        fi
    fi
    echo ""
    echo "Starting Claude Code in $WORKDIR..."
    echo ""
    cd "$WORKDIR"
    # --dangerously-skip-permissions: Skips Claude's normal permission prompts.
    # This is safe here because the firewall restricts what the container can access,
    # and the container isolates Claude from your host system.
    claude --dangerously-skip-permissions
fi
