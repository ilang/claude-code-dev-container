---
name: check-upstream
description: Check for upstream Anthropic devcontainer updates, analyze changes, and selectively apply them
user-invocable: true
---

# Check Upstream Anthropic Updates

This project is based on Anthropic's official devcontainer reference at:
https://github.com/anthropics/claude-code/tree/main/.devcontainer

Our files have diverged from upstream (native installer, output formatting, comments, custom scripts). This skill helps you intelligently sync by analyzing what changed upstream and selectively applying relevant updates.

## Upstream files we track

These three files originate from Anthropic's repo:
- `Dockerfile` — container image definition
- `init-firewall.sh` — firewall setup script
- `devcontainer.json` — VS Code devcontainer config

## Steps

### 1. Read the last synced version

Read `.upstream-version` in the project root. It contains a git commit SHA.

### 2. Get the current upstream version

Fetch the latest commit SHA from the Anthropic repo:
```
curl -s https://api.github.com/repos/anthropics/claude-code/commits/main | jq -r '.sha'
```

If the SHA matches `.upstream-version`, tell the user "Already up to date" and stop.

### 3. Fetch upstream files

For each tracked file, fetch the current upstream version:
```
curl -sL https://raw.githubusercontent.com/anthropics/claude-code/main/.devcontainer/Dockerfile
curl -sL https://raw.githubusercontent.com/anthropics/claude-code/main/.devcontainer/init-firewall.sh
curl -sL https://raw.githubusercontent.com/anthropics/claude-code/main/.devcontainer/devcontainer.json
```

### 4. Compare and analyze

For each file, diff the upstream version against our local version. For each meaningful difference:

1. **Explain** what changed in plain language
2. **Categorize** it:
   - **Upstream improvement** — new feature, security fix, or bug fix from Anthropic
   - **Our customization** — something we intentionally changed (don't revert)
   - **Cosmetic** — comment changes, formatting, etc. (usually skip)
3. **Recommend** whether to apply it or skip it, with reasoning

Important distinctions to watch for:
- We use the **native installer** (`curl install.sh`), not npm. Don't revert to npm.
- We have **custom output formatting** in init-firewall.sh (summaries, dedup). Don't revert to per-IP logging.
- We have **extensive comments** in all files. Don't remove them.
- We added **entrypoint.sh, allow-domain.sh, CLAUDE.md** — these are entirely ours.

### 5. Ask for approval

Present a summary table of all changes with your recommendation:

| File | Change | Category | Recommendation |
|------|--------|----------|----------------|
| Dockerfile | Added new apt package X | Upstream improvement | Apply |
| Dockerfile | Changed npm install to ... | Our customization | Skip |
| init-firewall.sh | Added new domain Y | Upstream improvement | Apply |
| ... | ... | ... | ... |

Ask the user: "Which changes would you like to apply?"

### 6. Apply approved changes

For each approved change, carefully merge it into the local file:
- **Do NOT overwrite the entire file** — apply individual changes
- Preserve our comments, formatting, and customizations
- Use the Edit tool for targeted modifications

### 7. Update the version tracker

After applying changes, update `.upstream-version` with the new upstream SHA:
```
echo "<new-sha>" > .upstream-version
```

### 8. Rebuild if needed

If the Dockerfile was modified, remind the user to rebuild:
```
docker build -t claude-sandbox .
claude-sandbox --new  # to pick up the new image
```

Commit the changes with a message describing what was synced from upstream.
