#!/bin/bash
# entrypoint.sh — the startup script that runs every time the container launches.
# It handles: credential sharing, statusline sync, firewall setup, domain loading,
# and then either keeps the container alive (persistent mode) or launches Claude (temp mode).

set -e  # Exit immediately if any command fails

# CLAUDE_MODE is set by the claude-sandbox script via `docker run -e`.
# "persistent" = long-lived container you can attach to multiple times
# "temp"       = one-shot container that is deleted when Claude exits
CLAUDE_MODE="${CLAUDE_MODE:-temp}"

# --- .claude.json shared credentials ---
# Problem: Claude Code stores your login token in ~/.claude.json. In temp mode,
# that file is destroyed when the container exits. In persistent mode, each
# container has its own copy. We need credentials to survive across all containers.
#
# Solution: A shared Docker volume (claude-code-json) mounted at ~/.claude-json
# acts as a "credential vault". On startup we restore from it; on exit we save to it.
CLAUDE_JSON_VOLUME="$HOME/.claude-json"
CLAUDE_JSON="$HOME/.claude.json"

# Restore credentials from the shared volume if:
#   - The shared volume exists and has a saved copy, AND
#   - The local copy is missing or doesn't contain login info ("oauthAccount")
if [ -d "$CLAUDE_JSON_VOLUME" ] && [ -f "$CLAUDE_JSON_VOLUME/.claude.json" ]; then
    if [ ! -f "$CLAUDE_JSON" ] || ! grep -q "oauthAccount" "$CLAUDE_JSON" 2>/dev/null; then
        cp "$CLAUDE_JSON_VOLUME/.claude.json" "$CLAUDE_JSON"
        echo "Restored Claude credentials from shared store."
    fi
fi

# Save credentials back to the shared volume so the next container can pick them up.
# Only saves if our copy has login info (oauthAccount) — prevents a container with
# bare/stale credentials from overwriting good ones if two containers exit at once.
save_credentials() {
    if [ -d "$CLAUDE_JSON_VOLUME" ] && [ -f "$CLAUDE_JSON" ] && \
       grep -q "oauthAccount" "$CLAUDE_JSON" 2>/dev/null; then
        cp "$CLAUDE_JSON" "$CLAUDE_JSON_VOLUME/.claude.json"
    fi
}

# Register as an EXIT trap so credentials are saved when this script exits
# (whether normally or due to an error). In persistent mode, we also register
# SIGTERM/SIGINT traps to ensure this runs on `docker stop`.
trap save_credentials EXIT

# --- Sync statusline and settings from host ---
# The host's Claude config files are mounted read-only at /host-claude-config/
# (see the claude-sandbox script for the -v mounts). This copies your host's
# statusline script and settings into the container so the Claude UI matches.
#
# The statusline is the custom info bar at the bottom of Claude Code's terminal UI.
if [ -f /host-claude-config/statusline-command.sh ]; then
    cp /host-claude-config/statusline-command.sh "$HOME/.claude/statusline-command.sh"
fi
# For settings.json: if the container already has settings, we merge ONLY the
# statusLine section from the host (using jq). This preserves container-specific
# settings while keeping your statusline config in sync.
# If no container settings exist yet, just copy the whole file from the host.
if [ -f /host-claude-config/settings.json ]; then
    CONTAINER_SETTINGS="$HOME/.claude/settings.json"
    if [ -f "$CONTAINER_SETTINGS" ]; then
        jq -s '.[0] * {statusLine: .[1].statusLine, enabledPlugins: .[1].enabledPlugins}' "$CONTAINER_SETTINGS" /host-claude-config/settings.json > "$CONTAINER_SETTINGS.tmp" && mv "$CONTAINER_SETTINGS.tmp" "$CONTAINER_SETTINGS"
    else
        cp /host-claude-config/settings.json "$CONTAINER_SETTINGS"
    fi
fi

# --- Sync plugins from host ---
# If the host's plugins directory is mounted, copy plugins into the container.
# The installed_plugins.json has hardcoded host paths (e.g., /Users/yourname/.claude/...),
# so we rewrite them to the container's home directory (/home/node/.claude/...).
if [ -d /host-claude-config/plugins ]; then
    CONTAINER_PLUGINS="$HOME/.claude/plugins"
    mkdir -p "$CONTAINER_PLUGINS"

    # Copy plugin cache (the actual plugin files)
    if [ -d /host-claude-config/plugins/cache ]; then
        cp -r /host-claude-config/plugins/cache "$CONTAINER_PLUGINS/" 2>/dev/null || true
    fi

    # Copy and rewrite installed_plugins.json — replace host home path with container home path
    if [ -f /host-claude-config/plugins/installed_plugins.json ]; then
        # Detect the host's home directory from the install paths in the JSON
        HOST_HOME=$(jq -r '.plugins[][0].installPath // empty' /host-claude-config/plugins/installed_plugins.json 2>/dev/null | head -1 | sed 's|/.claude/.*||')
        if [ -n "$HOST_HOME" ]; then
            sed "s|$HOST_HOME|$HOME|g" /host-claude-config/plugins/installed_plugins.json > "$CONTAINER_PLUGINS/installed_plugins.json"
        else
            cp /host-claude-config/plugins/installed_plugins.json "$CONTAINER_PLUGINS/"
        fi
    fi

    # Copy other plugin config files
    for f in config.json known_marketplaces.json blocklist.json; do
        if [ -f "/host-claude-config/plugins/$f" ]; then
            cp "/host-claude-config/plugins/$f" "$CONTAINER_PLUGINS/" 2>/dev/null || true
        fi
    done
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
    # We run `tail -f /dev/null` in the background instead of using `exec` so that
    # THIS shell remains PID 1. This is important because:
    #   1. The EXIT/SIGTERM traps (save_credentials) need the shell alive to fire
    #   2. When Docker stops the container, it sends SIGTERM to PID 1
    #   3. The shell catches SIGTERM, saves credentials, then exits cleanly
    #
    # Previously `exec tail` replaced the shell entirely, so the EXIT trap was lost
    # and credentials were never saved back to the shared volume.

    # Catch SIGTERM/SIGINT (sent by `docker stop`) to save credentials before exiting.
    # save_credentials is idempotent, so calling it from both SIGTERM and EXIT is safe.
    trap 'save_credentials; exit 0' SIGTERM SIGINT

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
