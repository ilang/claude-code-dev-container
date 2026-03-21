# Start from the official Node.js 20 image (Debian-based).
# Claude Code is a Node.js app, so this gives us the runtime it needs.
FROM node:20

# Allow the user to pass their timezone at build time (e.g., "America/New_York").
# This ensures dates/times shown inside the container match the host machine.
ARG TZ
ENV TZ="$TZ"

# Install tools needed for development, shell experience, and the firewall.
#
# Development tools:
#   less        — pager for viewing long output (used by git, man, etc.)
#   git         — version control (Claude Code uses this heavily)
#   procps      — process utilities like `ps` and `top` for debugging
#   sudo        — lets the non-root "node" user run specific commands as root
#   fzf         — fuzzy finder for interactive searching in the terminal
#   zsh         — a nicer shell than the default bash (better autocomplete, etc.)
#   man-db      — manual pages so you can run `man <command>` to get help
#   unzip       — for extracting .zip files
#   gnupg2      — GPG encryption tools (needed for some git signing workflows)
#   gh          — GitHub CLI for creating PRs, issues, etc. from the command line
#   jq          — command-line JSON processor (used by scripts to parse API responses)
#   nano, vim   — text editors available inside the container
#
# Firewall / networking tools (used by init-firewall.sh and allow-domain.sh):
#   iptables    — Linux firewall; controls which network traffic is allowed/blocked
#   ipset       — efficient IP address set management; iptables checks IPs against these sets
#   iproute2    — networking utilities like `ip` (used to detect the host network)
#   dnsutils    — DNS lookup tools like `dig` (converts domain names → IP addresses)
#   aggregate   — merges overlapping IP ranges into compact CIDR blocks
#
# The cleanup at the end (apt-get clean, rm lists) shrinks the image size.
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# The Node.js base image comes with a non-root user called "node" (UID 1000).
# We need a place for globally-installed npm packages that this user can write to.
# By default, `npm install -g` writes to /usr/local which requires root.
# Creating a separate directory and giving "node" ownership avoids running as root.
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist command history across container restarts.
# Without this, every time the container stops and starts, you'd lose your
# command history (up-arrow recall). The /commandhistory directory gets
# mounted to a Docker volume (see claude-sandbox script), so history survives.
# PROMPT_COMMAND='history -a' tells bash to append each command to the history
# file immediately (not just when the shell exits), so nothing is lost on crashes.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Let tools and scripts detect that they're running inside a devcontainer
ENV DEVCONTAINER=true

# Create the key directories:
#   /workspace           — your project code gets mounted here from the host
#   /home/node/.claude   — Claude Code's config and settings (mounted to a volume for persistence)
#   /home/node/.claude-json — shared credential store (mounted to a volume shared across containers)
# chown ensures the non-root "node" user can read/write these directories.
RUN mkdir -p /workspace /home/node/.claude /home/node/.claude-json && \
  chown -R node:node /workspace /home/node/.claude /home/node/.claude-json

# Set the default working directory when entering the container
WORKDIR /workspace

# Install git-delta — a syntax-highlighting pager for git diffs.
# Makes `git diff` output much more readable with color-coded changes.
# We detect the CPU architecture (amd64 or arm64) to download the right binary.
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Switch from root to the unprivileged "node" user for security.
# Everything below runs as "node" unless we temporarily switch back to root.
# This means Claude Code can't accidentally damage system files.
USER node

# Tell npm to install global packages into our custom directory (not /usr/local).
# Add both npm's global bin and the user's local bin to PATH so installed tools are found.
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin:/home/node/.local/bin

# Use zsh as the default shell (better tab completion and plugins than bash)
ENV SHELL=/bin/zsh

# Set nano as the default text editor (simpler than vim for quick edits).
# EDITOR is used by git commit, VISUAL by programs that want a full-screen editor.
ENV EDITOR=nano
ENV VISUAL=nano

# Set up zsh with Oh My Zsh and the Powerlevel10k theme.
# This gives you a nice-looking terminal prompt with git status, directory info, etc.
#   -p git    — enables git aliases and tab completion in zsh
#   -p fzf    — enables fuzzy-finding integration (Ctrl+R for history search, etc.)
#   -a "..."  — adds custom lines to .zshrc (fzf keybindings, history persistence)
#   -x        — skips the default theme install (uses Powerlevel10k instead)
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# Install Claude Code itself using Anthropic's official installer script.
# This puts the `claude` command on the PATH via ~/.local/bin.
RUN curl -fsSL https://claude.ai/install.sh | bash

# Copy the CLAUDE.md rules file into the container. This file tells Claude Code
# how to behave inside the sandbox (e.g., how to handle blocked domains).
COPY CLAUDE.md /home/node/.claude/CLAUDE.md

# Copy our custom scripts into the container:
#   init-firewall.sh — sets up iptables rules to restrict network access
#   allow-domain.sh  — lets you whitelist additional domains at runtime
#   entrypoint.sh    — the startup script that runs when the container launches
COPY init-firewall.sh /usr/local/bin/
COPY allow-domain.sh /usr/local/bin/
COPY lock-network.sh /usr/local/bin/
COPY block-dns.sh /usr/local/bin/
COPY install-package.sh /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/

# Temporarily switch to root to set permissions.
# The firewall scripts need root privileges (iptables requires it), but we don't
# want the "node" user to have full root access. The sudoers rules below let "node"
# run ONLY specific scripts as root, without needing a password.
# chmod 0440 restricts the sudoers file itself so only root can read it (security requirement).
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/allow-domain.sh /usr/local/bin/lock-network.sh /usr/local/bin/block-dns.sh /usr/local/bin/install-package.sh /usr/local/bin/entrypoint.sh && \
  echo 'node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh ""' > /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/allow-domain.sh" >> /etc/sudoers.d/node-firewall && \
  echo 'node ALL=(root) NOPASSWD: /usr/local/bin/lock-network.sh ""' >> /etc/sudoers.d/node-firewall && \
  echo 'node ALL=(root) NOPASSWD: /usr/local/bin/block-dns.sh ""' >> /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/install-package.sh" >> /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall

# Switch back to the unprivileged "node" user for runtime safety
USER node

# ENTRYPOINT defines what runs when the container starts.
# Unlike CMD, it can't easily be overridden — this ensures the firewall always gets set up.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
