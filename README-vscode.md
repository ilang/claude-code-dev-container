# Claude Code Dev Container — VS Code approach

Use this approach when you want the **`/ide` command** and full VS Code integration inside the container. Claude Code can apply diffs visually in the editor, navigate to files, and use VS Code features directly.

For the Docker CLI approach (persistent containers, no `/ide`), see [README.md](README.md).

## How this differs from the Docker CLI approach

| | Docker CLI ([README.md](README.md)) | VS Code Dev Container (this document) |
|---|---|---|
| **How it works** | Build the image once, then `claude-sandbox` manages persistent containers per project | Clone this repo as `.devcontainer/` inside your project, then VS Code opens the project inside the container |
| **Your IDE** | Stays native on your machine | Moves into the container |
| **`/ide` command** | No | Yes |
| **Container lifecycle** | Persistent by default (`--temp` for ephemeral) | Managed by VS Code (long-lived while the window is open) |
| **Setup per project** | None — same image works for any project | Clone `.devcontainer/` into each project |
| **Parallel sessions** | Multiple terminals attach to same container | Multiple terminals inside VS Code |
| **Best for** | Keep your existing IDE setup, just want Claude in a sandbox | Full VS Code + Claude integration |

## What VS Code Dev Containers does

VS Code's Dev Containers extension moves your **entire IDE** inside the container:
- **Terminal** → runs inside the container
- **File explorer** → reads files from inside the container
- **Extensions** (ESLint, Prettier, GitLens) → run inside the container
- **Language servers** → run inside the container
- **Your machine** → just renders the VS Code UI

**Key difference from Docker CLI:** Instead of building the image separately and running `claude-sandbox`, you clone this repo as a `.devcontainer/` folder inside your project. VS Code detects that folder and handles building, starting, and connecting to the container automatically.

## Prerequisites

- [Docker](https://www.docker.com/products/docker-desktop/)
- [VS Code](https://code.visualstudio.com/)
- [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)

## Setup

### 1. Clone this repo as `.devcontainer` inside your project

```bash
cd /path/to/your/project
git clone https://github.com/ilang/claude-code-dev-container .devcontainer
```

Your project should look like:

```
your-project/
├── .devcontainer/              ← this repo, cloned here
│   ├── devcontainer.json       ← VS Code reads this to configure the container
│   ├── Dockerfile              ← defines the container image
│   ├── CLAUDE.md               ← rules baked into the container (domain approval)
│   ├── init-firewall.sh        ← firewall setup (runs on container start)
│   ├── allow-domain.sh         ← adds domains to firewall (called by Claude after chat approval)
│   └── entrypoint.sh           ← container startup script
├── .allowed-domains            ← optional: extra domains to allow per project
└── ... your project files
```

### 2. Open in VS Code

```bash
code /path/to/your/project
```

VS Code detects `.devcontainer/` and shows a prompt: **"Reopen in Container"**. Click it.

Or use the Command Palette: `Cmd+Shift+P` → `Dev Containers: Reopen in Container`

First time takes a few minutes (building the Docker image + setting up the firewall). Subsequent opens are faster.

### 3. Start Claude

Open a terminal inside VS Code (`Cmd+backtick`) and run:

```bash
claude --dangerously-skip-permissions
```

The `/ide` command now works — Claude can interact with VS Code directly (apply diffs, navigate files, etc.).

### Connecting from an external terminal

You can also attach to the running container from any terminal:

```bash
# Find the container name
docker ps

# Attach to it
docker exec -it <container-name> zsh
```

Note: `/ide` only works from terminals inside VS Code. External terminals can run Claude but won't have the visual diff integration.

### Update

```bash
cd /path/to/your/project/.devcontainer
git pull
```

Then rebuild: `Cmd+Shift+P` → `Dev Containers: Rebuild Container`

## Monorepo / sibling folders

If your project has sibling folders that depend on each other, open the **parent directory** in VS Code so everything is accessible inside the container:

```
monorepo/                        ← open THIS in VS Code
├── .devcontainer/               ← clone this repo here
├── .allowed-domains             ← optional
├── my-subproject/               ← navigate here inside the container
├── shared-lib/
├── backend/
└── frontend/
```

```bash
cd /path/to/monorepo
git clone https://github.com/ilang/claude-code-dev-container .devcontainer
code .
```

Inside the container terminal, navigate to your subproject before starting Claude:

```bash
cd /workspace/my-subproject
claude --dangerously-skip-permissions
```

**Trade-off:** Opening the parent directory means VS Code treats the monorepo root as the project root. Your IDE-specific tooling (e.g., Gradle, Java extensions) may need configuration to point to the right subproject. If this is a problem, use the [Docker CLI approach](README.md) instead — your IDE stays native and works as-is.

## Per-project allowed domains

Create a `.allowed-domains` file in your project root (the folder you open in VS Code):

```
# .allowed-domains
# One domain per line. Lines starting with # are comments.

stackoverflow.com
docs.oracle.com
pypi.org
```

These are loaded automatically when the container starts.

## Dynamic domain access

When Claude needs a blocked domain, it asks you in the chat before opening it:

> I need access to **stackoverflow.com** to look up API docs.
>
> 1. **Always allow** — adds to `.allowed-domains` for future restarts
> 2. **Allow for this session** — temporary, resets on restart
> 3. **Skip** — find another way

This is advisory (relies on Claude following CLAUDE.md instructions).

**Limitation:** The VS Code approach does not support `--locked`, `--open-network`, or `--no-install` flags. It always runs in default mode (firewall + chat-based approval). For untrusted code, use the [Docker CLI approach](README.md) with `--locked` instead.

## Volume naming: VS Code vs Docker CLI

If you use both approaches, be aware that they store data differently:

- **Docker CLI** — uses **global** volumes (`claude-code-config`, `claude-code-history`). All your projects share the same Claude settings and shell history.
- **VS Code** — uses **per-project** volumes (`claude-code-config-<id>`, `claude-code-bashhistory-<id>`). Each project has its own isolated settings and history.

Login credentials (`claude-code-json`) are global in both approaches, so you won't need to re-authenticate when switching between them.

## Comparison table

| Feature | Docker CLI | VS Code Dev Container |
|---|---|---|
| `/ide` command | No | Yes |
| Claude applies diffs in editor | No | Yes |
| VS Code extensions in container | No | Yes (ESLint, Prettier, GitLens) |
| Persistent containers | Yes (default) | Yes (managed by VS Code) |
| Your IDE stays native | Yes | No — IDE moves into container |
| IDE tooling (Java, Gradle, etc.) | Native, already configured | Needs setup inside container |
| Multiple parallel sessions | `claude-sandbox` from multiple terminals | Multiple terminals in VS Code |
| Container management | `--list`, `--stop`, `--rm`, `--new` | VS Code handles it |
| Works on Windows | Yes (`.bat` included) | Yes |
