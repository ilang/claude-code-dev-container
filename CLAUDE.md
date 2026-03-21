# Devcontainer Rules

You are running inside a secure container with a locked-down firewall. Most external sites are blocked by default.

## Blocked network requests

When a network request fails because a domain is blocked by the firewall, present the user with these options:

> I need access to **<domain>** to <brief reason>.
>
> How would you like to proceed?
> 1. **Always allow** — add to `.allowed-domains` so it's available on future restarts too
> 2. **Allow for this session** — temporary access, resets when the container restarts
> 3. **Skip** — I'll find another way

If the user chooses **1 (Always allow)**:
- Run `sudo allow-domain.sh <domain>`
- Append the domain to `/workspace/.allowed-domains` (create the file if it doesn't exist)

If the user chooses **2 (Allow for this session)**:
- Run `sudo allow-domain.sh <domain>`

If the user chooses **3 (Skip)**:
- Do not attempt to access the domain. Find an alternative approach or skip the task.

## Installing packages

Do NOT use `sudo apt-get` directly — it is not allowed. Use the wrapper script instead:

```
sudo install-package.sh <package1> [package2] ...
```

Examples:
- `sudo install-package.sh python3`
- `sudo install-package.sh openjdk-17-jdk maven`

The wrapper validates package names and rejects flags. If `--no-install` mode is active, the script will be unavailable.
