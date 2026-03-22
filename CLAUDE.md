# Claude Code Dev Container

A Docker-based sandbox for running Claude Code with `--dangerously-skip-permissions` safely. See [README.md](README.md) for full usage docs and security model.

## Building and testing

```bash
# Build the image
docker build -t claude-sandbox .

# Test with an ephemeral container (deleted on exit)
claude-sandbox --temp

# Test with a persistent container (stays running)
claude-sandbox --new

# Iterate: rebuild image, then recreate container
docker build -t claude-sandbox . && claude-sandbox --new
```

When changing firewall scripts, always test both default and `--locked` modes. When changing the entrypoint, test both persistent and `--temp` modes.

## Architecture

The system has three layers: the host script, the container startup, and the runtime scripts.

**Host → Container creation:**
`claude-sandbox` (or `claude-sandbox.bat` on Windows) → `docker run` → `entrypoint.sh`

**Container startup chain:**
`entrypoint.sh` → credential symlink → host config sync → `init-firewall.sh` → `load_allowed_domains()` → optionally `lock-network.sh` → `block-dns.sh` → ready sentinel

**Runtime (called by Claude during a session):**
`allow-domain.sh` — whitelist a domain (blocked in `--locked` mode)
`install-package.sh` — safe `apt-get` wrapper (blocked in `--no-install` mode)

### Key scripts

| Script | Runs as | Purpose |
|--------|---------|---------|
| `claude-sandbox` | Host user | Container lifecycle: create, attach, stop, remove, flag switching |
| `entrypoint.sh` | node (container) | Startup orchestration: credentials, config sync, firewall, readiness |
| `init-firewall.sh` | root (sudo) | Default-deny iptables firewall + ipset allowlist + verification |
| `allow-domain.sh` | root (sudo) | Resolve domain → IPs, add to ipset + /etc/hosts, audit log |
| `block-dns.sh` | root (sudo) | Block DNS for node user (UID 1000) to prevent DNS tunneling |
| `lock-network.sh` | root (sudo) | Create root-owned lock file (can only lock, never unlock) |
| `install-package.sh` | root (sudo) | Validate package names (no flags), then `apt-get install` |

## Security invariants

These must never break. If a change violates any of these, it's a bug:

- **Default-deny firewall** — all outbound traffic blocked unless explicitly whitelisted
- **DNS blocking** — node user (UID 1000) cannot make DNS queries; approved domains use /etc/hosts
- **Limited sudo** — only 5 specific scripts in sudoers, no raw `apt-get` or shell access
- **Non-root execution** — Claude runs as `node` (UID 1000), never root
- **Lock file integrity** — `lock-network.sh` can only create `/etc/claude-sandbox-locked`, never remove it
- **Input validation** — `allow-domain.sh` validates IPs from DNS; `install-package.sh` rejects flags and special characters; `claude-sandbox` validates subfolder names
- **Audit logging** — all domain additions logged to `/var/log/firewall-changes.log`

## Container paths

| Path | Purpose |
|------|---------|
| `/workspace` | Mounted project directory from host |
| `/home/node/.claude` | Claude Code config (persisted volume) |
| `/home/node/.claude-json` | Shared credential volume (symlinked to `~/.claude.json`) |
| `/home/node/.sandbox-config` | Current effective flags (written by entrypoint.sh) |
| `/commandhistory` | Persistent shell history (volume) |
| `/host-claude-config/` | Host config mounted read-only (memory only) |
| `/etc/claude-sandbox-locked` | Lock file for `--locked` mode (root-owned) |
| `/etc/claude-sandbox-no-install` | Flag file for `--no-install` mode |
| `/var/log/firewall-changes.log` | Audit log of domain additions |
| `/tmp/.claude-sandbox-ready` | Readiness sentinel (polled by host script) |

## Conventions

- **Shell scripts are heavily commented** — every iptables rule, Docker flag, and design decision is explained inline. Maintain this style.
- **Security-first defaults** — default-deny, whitelist-only, non-root. New features should not weaken the security posture.
- **Cross-platform** — `claude-sandbox` (bash) for macOS/Linux, `claude-sandbox.bat` for Windows. Keep both in sync.
- **`container-CLAUDE.md`** is the runtime instructions baked into the container image (tells Claude how to handle blocked domains and package installation). The Dockerfile copies it to `/home/node/.claude/CLAUDE.md`.

## Upstream sync

This project tracks Anthropic's [official devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer). The `.upstream-version` file records the last synced commit SHA. Use the `/check-upstream` skill to fetch, diff, and selectively apply upstream changes.
