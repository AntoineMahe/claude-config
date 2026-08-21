# claude-config

Hardening configuration for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — Anthropic's CLI agent.

Claude Code is a powerful dev tool with broad filesystem access. This repo provides two independent layers of protection for sensitive files:

1. **`settings.json`** — Claude Code's built-in permission deny rules. These tell Claude not to read/write certain paths. However, Claude *can* modify its own settings.
2. **`apparmor/claude-code`** — A kernel-enforced AppArmor profile. Claude cannot bypass or modify this, even if it tries. This is the hard boundary.

Both layers deny the same system-level secrets by default (SSH keys, GPG, keyrings, shell history, `.env` files). The AppArmor profile also blocks privilege escalation (`sudo`, `su`, `pkexec`, `apparmor_parser`).

This is a minimal baseline — you should audit your own setup and add application-specific deny rules (browser profiles, password managers, chat apps, etc.) via the per-machine customization described below.

## What's included

```
settings.json          # Claude Code permission deny rules (~/.claude/settings.json)
apparmor/claude-code   # AppArmor profile (enforce mode)
install.sh             # Installer — merges settings, installs AppArmor profile
```

## Installation

```bash
git clone <this-repo>
cd claude-config
./install.sh            # both layers (default)
./install.sh --settings # only merge settings.json deny rules
./install.sh --apparmor # only install/reload the AppArmor profile
```

The installer is safe to run on an existing Claude Code setup — it merges rather than overwrites:

- **`settings.json`** — merges deny rules into your existing config (deduplicates, preserves your other settings). Requires [`jq`](https://jqlang.github.io/jq/). Creates a `.bak` backup before modifying.
- **AppArmor profile** — installs to `/etc/apparmor.d/claude-code` (requires `sudo`)
- **Local overrides** — creates `/etc/apparmor.d/local/claude-code` template for per-machine deny rules (won't overwrite if it exists)

Restart Claude Code after installation for the AppArmor profile to take effect.

## Per-machine customization

Edit `/etc/apparmor.d/local/claude-code` to add deny rules specific to your machine:

```
# deny @{HOME}/Documents/finances/** rwlk,
# deny @{HOME}/private/** rwlk,
# deny @{HOME}/.config/some-app/** rwlk,
```

Then reload:

```bash
sudo apparmor_parser -r /etc/apparmor.d/claude-code
```

## Practical exec & socket access

The profile is `enforce`d on Claude *and* on every process Claude `exec`s
(`ix` = inherit-execute). That means dev tools running under Claude live inside
the same sandbox, which has two practical consequences worth calling out:

- **Ephemeral tool environments.** Tools like `pre-commit` build per-hook
  envs under `~/.cache/pre-commit/repo*/py_env-*/bin/`, `node_env-*/bin/`,
  etc., and exec binaries from there. Project `.venv`, `.tox`, and
  `node_modules/.bin` follow the same pattern. A narrow execute allowlist
  cannot anticipate these paths, so the profile permits `owner @{HOME}/** ix`
  — Claude can exec any file in HOME that your user owns. Combined with the
  `deny`s on `sudo`/`su`/`pkexec`/`aa-*`, this preserves the no-escalation
  guarantee while letting normal dev tooling work.

  *Caveat:* code trees outside HOME (e.g. `/srv/...`, `/mnt/...`) are not
  covered. Add a per-machine `owner /srv/myproj/** ix,` rule in
  `/etc/apparmor.d/local/claude-code` if you need it.

- **Container runtime sockets are denied.** For a user in the `docker`
  group, access to `docker.sock` is root-equivalent
  (`docker run --privileged -v /:/host` bypasses the entire profile), so
  the profile explicitly `deny`s the docker and podman sockets: container
  commands must be run by the human, outside confined sessions. If your
  workflow needs in-session containers and you accept the trade-off, use
  the `docker-allowed` branch, which allows the two socket nodes (only
  the sockets, not all of `/run`). Rootless podman is the safer long-term
  answer if this matters to you.

## Debugging

```bash
# Check if profile is loaded
sudo aa-status | grep claude

# Watch for denied access attempts
journalctl -k | grep DENIED

# Temporarily switch to complain mode (log but don't block)
sudo aa-complain /etc/apparmor.d/claude-code

# Switch back to enforce
sudo aa-enforce /etc/apparmor.d/claude-code
```

## Removing

```bash
# AppArmor
sudo apparmor_parser -R /etc/apparmor.d/claude-code
sudo rm /etc/apparmor.d/claude-code /etc/apparmor.d/local/claude-code

# To restore your previous settings (if you ran install.sh):
cp ~/.claude/settings.json.bak ~/.claude/settings.json
```

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed at `~/.local/share/claude/`
- [`jq`](https://jqlang.github.io/jq/) for merging settings (`sudo apt install jq`)
- AppArmor (`sudo apt install apparmor apparmor-utils`) — the profile is skipped if not available
- Linux (AppArmor is Linux-only; `settings.json` works on any OS)

## License

GPLv3 — see [LICENSE](LICENSE).
