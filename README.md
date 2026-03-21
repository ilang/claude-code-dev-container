# Claude Code Dev Container

> **Note:** This is a community project, not an official Anthropic product. Based on Anthropic's [reference devcontainer](https://code.claude.com/docs/en/devcontainer) with additional security hardening and features.

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with `--dangerously-skip-permissions` **safely** inside a locked-down Docker container.

## The problem

`--dangerously-skip-permissions` lets Claude Code work autonomously — no permission prompts for file edits, shell commands, or network requests. This is great for productivity, but risky: a prompt injection (e.g., from a malicious dependency or untrusted file) could tell Claude to exfiltrate code, download malware, or access arbitrary websites.

## Existing solutions

Anthropic's [official devcontainer](https://code.claude.com/docs/en/devcontainer) runs Claude inside a Docker container with security measures:

- **Filesystem isolation** — Claude can only access the project files mounted into the container, not your entire system
- **Network firewall** — iptables-based deny-by-default policy restricts outbound traffic to whitelisted domains (GitHub, npm, Anthropic API)
- **Non-root user** — Claude runs as an unprivileged user inside the container

However, it has limitations:

- **All-or-nothing firewall** — domains are whitelisted at build time. If Claude needs a new site (docs, Stack Overflow, a package registry), you're stuck — rebuild the container or go without.
- **Requires a devcontainer-compatible IDE** — designed for VS Code, JetBrains, GitHub Codespaces, or similar tools that support the devcontainer spec. No standalone Docker CLI workflow for terminal-only users.
- **No standalone persistent containers** — without VS Code, there's no built-in way to run persistent containers from the command line. If you use a different editor, you'd need to manage Docker manually.

## This project

A Docker-based sandbox with a **managed firewall**. Domains are locked down by default. When Claude needs a blocked site, it asks you in the chat before opening it. For untrusted code, `--locked` mode disables all runtime domain additions — only pre-approved domains in `.allowed-domains` are reachable.

**Additional features:**
- **Persistent containers** — tools, history, and firewall rules survive between sessions
- **Per-project allowed domains** — `.allowed-domains` file auto-loads on startup
- **Host config sync** — git identity, SSH agent, Claude plugins, and statusline
- **Cross-platform** — macOS, Linux, and Windows
- **VS Code integration** — optional [Dev Container approach](README-vscode.md) with `/ide` command

## Quick start

```bash
# 1. Build the image (one-time)
git clone https://github.com/ilang/claude-code-dev-container
cd claude-code-dev-container
docker build -t claude-sandbox .
sudo ln -s "$(pwd)/claude-sandbox" /usr/local/bin/claude-sandbox

# 2. Run from any project folder
cd /path/to/your/project
claude-sandbox
```

That's it. Claude starts in a secure container with the firewall active.

<details>
<summary>Windows setup</summary>

```cmd
git clone https://github.com/ilang/claude-code-dev-container
cd claude-code-dev-container
docker build -t claude-sandbox .
```

Add the repo folder to your system PATH:
1. Search for "Environment Variables" in Windows Settings
2. Edit `Path` under User variables
3. Add the path to this repo

Then from any project folder:
```cmd
cd C:\path\to\your\project
claude-sandbox
```

</details>

## Two approaches

This repo supports two ways to run Claude Code in a container:

| | Docker CLI (this document) | [VS Code Dev Container](README-vscode.md) |
|---|---|---|
| **How it works** | Build the image once, run `claude-sandbox` from any project | Clone this repo as `.devcontainer/` inside your project |
| **Your IDE** | Stays native on your machine | Moves into the container |
| **`/ide` command** | No | Yes |
| **Setup per project** | None — same image works for any project | Clone `.devcontainer/` into each project |
| **Best for** | Keep your existing IDE, just want Claude in a sandbox | Full VS Code + Claude integration |

## Usage

### Flags

| Flag | What it does |
|------|-------------|
| (none) | Start or reattach to persistent container for current directory |
| `--new` | Remove existing container and create a fresh one |
| `--temp` | Ephemeral container (deleted on exit, no persistence) |
| `--open-network` | No firewall — full internet access (use with trusted code only) |
| `--locked` | Whitelist only — no runtime domain additions |
| `--no-install` | Disable package installation (`sudo install-package.sh`) |
| `--relogin` | Re-authenticate Claude (logs in on host, syncs credentials) |
| `--list` | Show all claude-sandbox containers and their status |
| `--stop` | Stop the current project's container |
| `--rm` | Remove the current project's container |
| `--rm-all` | Remove ALL claude-sandbox containers |
| `-h` | Show help |

### Persistent containers

The first time you run `claude-sandbox`, it creates a named container for your project directory. When you exit Claude, the container **stays running**. Next time:

- Container running → **instant reattach** (no setup, no waiting)
- Container stopped → restarts (~15 sec for firewall rebuild)
- Container removed → creates a new one

This means tools you install (`sudo install-package.sh python3`, `npm install -g`), and any files you create all persist between sessions. Note: session-only domain additions (option 2 in the chat prompt) are lost on restart — only domains added to `.allowed-domains` (option 1) survive.

**Switching flags (macOS/Linux):** You can change `--open-network`, `--locked`, and `--no-install` on existing containers — the container will automatically restart with the new settings. For example, switching from default to open-network:

```bash
claude-sandbox --open-network    # restarts with firewall disabled
claude-sandbox                   # restarts with firewall re-enabled
```

Note: switching from `--open-network` to a firewalled mode requires `--new` because open-network containers lack the kernel capabilities needed for iptables.

### Managing containers

```bash
claude-sandbox --list     # see all containers and their status
claude-sandbox --stop     # stop this project's container
claude-sandbox --rm       # remove completely
claude-sandbox --new      # fresh container (e.g., after image rebuild)
```

### Monorepo / sibling folders

If your project has sibling folders that depend on each other, run `claude-sandbox` from the **parent directory** with a subfolder argument:

```bash
cd /path/to/monorepo
claude-sandbox my-subproject
```

Example structure:

```
monorepo/                        ← run claude-sandbox from here
├── .allowed-domains             ← put this at the mounted root
├── my-subproject/               ← pass this as the subfolder argument
├── shared-lib/
├── backend/
└── frontend/
```

Claude starts in `/workspace/my-subproject` and can access all sibling folders at `/workspace/`.

## Network modes

| Mode | Firewall | `.allowed-domains` | Runtime approval (`allow-domain.sh`) |
|---|---|---|---|
| Default | Active | Loaded | Yes (chat-based, advisory) |
| `--locked` | Active | Loaded | Disabled |
| `--open-network` | Off | N/A | Not needed |

In all modes, Anthropic API (`api.anthropic.com`) and authentication (`claude.ai`) are always reachable.

```bash
claude-sandbox                  # default: firewall + interactive approval
claude-sandbox --locked         # whitelist only, no runtime additions
claude-sandbox --open-network   # no firewall (trusted code only)
```

## Domain management

### Pre-approved domains (`.allowed-domains`)

The first time you run `claude-sandbox` in a project, it automatically creates a `.allowed-domains` file with sensible defaults (GitHub, npm, VS Code services). Edit it to add or remove domains:

```
# .allowed-domains
registry.npmjs.org
github.com
api.github.com
stackoverflow.com        # add your own
docs.python.org          # add your own
```

These are loaded on container startup. In `--locked` mode, these are the **only** domains allowed (besides Anthropic API). Remove lines you don't need for a tighter security posture.

### Runtime domain approval

When Claude hits a blocked domain, it asks you in the chat:

> I need access to **stackoverflow.com** to look up API docs.
>
> 1. **Always allow** — adds to `.allowed-domains` for future restarts
> 2. **Allow for this session** — temporary, resets on restart
> 3. **Skip** — find another way

If you approve, Claude runs `sudo allow-domain.sh <domain>` to open it. This is advisory (relies on Claude following CLAUDE.md instructions). For untrusted code, use `--locked` mode which disables runtime additions entirely.

### Re-authentication

If your login token expires, use `--relogin` to re-authenticate on the host (which has unrestricted network) and sync the credentials to your containers:

```bash
claude-sandbox --relogin
```

This runs `claude --login` on your host machine, then copies the credentials to the shared Docker volume. All containers pick them up on the next session.

## Security model

This setup is designed for running `claude --dangerously-skip-permissions` safely:

| Layer | What it does | Enforced by | Bypassable by prompt injection? |
|---|---|---|---|
| **Firewall** | Blocks outbound traffic to non-whitelisted domains | Linux kernel (iptables) | No |
| **DNS blocking** | DNS blocked for Claude; approved domains resolved via /etc/hosts | Linux kernel (iptables + uid match) | No |
| **Limited sudo** | Only specific scripts can run as root (no raw `apt-get`) | Linux sudoers | No |
| **Container isolation** | Claude can only access mounted volumes (project, config, plugins) | Docker | No |
| **`--locked` mode** | Disables runtime domain additions entirely | Lock file (root-owned) | No |
| **Domain approval (default mode)** | Claude asks before opening domains | CLAUDE.md instructions | Yes (advisory) |

The firewall, DNS blocking, sudo, container isolation, and `--locked` mode are OS-enforced. Domain approval in default mode relies on Claude's instruction-following — for untrusted code, use `--locked` mode instead. Domain additions via `allow-domain.sh` are logged to `/var/log/firewall-changes.log` for audit.

## Firewall details

The firewall has two layers of whitelisted domains:

**Always allowed** (hardcoded, cannot be removed):
- Anthropic API (`api.anthropic.com`) — Claude's backend
- Authentication (`claude.ai`) — login
- Sentry, Statsig — Claude Code telemetry

**Configurable** (via `.allowed-domains` in your project):
- GitHub, npm, VS Code services — included in the example file, removable
- Any additional domains you add

Everything else is blocked.

**Known limitation:** The Docker host's local network (`/24` subnet) is allowed without restriction. This is needed for Docker's internal communication but means Claude can access services running on your host machine (e.g., local databases, web servers, or other containers). If you run sensitive services locally, be aware of this.

## Syncing with upstream Anthropic

This repo is based on Anthropic's [official devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer). To check for upstream updates, run `/check-upstream` in a Claude session — it fetches the latest files, analyzes changes, and asks which to apply.

## Host config sync

The `claude-sandbox` script automatically shares from your host machine (read-only):

- **Git config** (`~/.gitconfig`) — your name, email, aliases
- **SSH agent** — forwarded so `git push/pull` works over SSH without exposing private keys
- **Claude plugins** — synced from `~/.claude/plugins/`
- **User memory** — your preferences and feedback from `~/.claude/memory/`
- **Statusline** — your custom statusline script and settings
- **Login credentials** — shared via a Docker volume so you don't re-authenticate per container

**Not shared** (intentionally, for security):

- **Session history** — conversations stay separate between host and container (different file paths make them incompatible)
- **Project memory** — Claude's learned context about specific projects stays on the host. Sharing it would expose cross-project information to containers running untrusted code.

## Repository files

```
claude-code-dev-container/
├── claude-sandbox          # Main script (macOS/Linux) — manages container lifecycle
├── claude-sandbox.bat      # Windows equivalent
├── Dockerfile              # Defines the container image (Node.js + Claude + firewall tools)
├── entrypoint.sh           # Runs on container start (firewall, domains, credentials, statusline)
├── init-firewall.sh        # Sets up iptables firewall with domain whitelist
├── allow-domain.sh         # Opens one domain at runtime (called by Claude after chat approval)
├── lock-network.sh         # Creates the lock file for --locked mode (can only lock, never unlock)
├── block-dns.sh            # Blocks DNS for the node user (anti-tunneling)
├── install-package.sh      # Safe apt-get wrapper (validates package names, no flags)
├── CLAUDE.md               # Rules baked into the image (tells Claude to use allow-domain.sh)
├── devcontainer.json       # VS Code Dev Containers config (for the VS Code approach)
├── .upstream-version       # Tracks which Anthropic commit we last synced from
├── allowed-domains.default # Default whitelist, auto-copied to projects as .allowed-domains
├── .claude/skills/         # Claude skills (e.g., /check-upstream)
├── README.md               # This file (Docker CLI approach)
├── README-vscode.md        # VS Code Dev Containers approach
└── LICENSE                 # MIT
```

## Updating Claude Code

Claude Code auto-updates inside **persistent containers** — it checks for new versions on startup and downloads them. The update domains (`downloads.claude.ai`, `storage.googleapis.com`) are in the essential whitelist.

If the image gets stale (e.g., you built it months ago), rebuild to get a fresh base:

```bash
docker build --no-cache -t claude-sandbox .
claude-sandbox --new
```

`--no-cache` forces Docker to re-run the installer instead of using the cached old version.

## Customization

- **Add tools to the image** — edit `Dockerfile` (e.g., add a JDK for Java projects), then `docker build` and `claude-sandbox --new`
- **Allow more domains by default** — add them to `init-firewall.sh` (all projects) or `.allowed-domains` (per project)
- **Change VS Code extensions** — edit `devcontainer.json` → `customizations.vscode.extensions`

## License

MIT
