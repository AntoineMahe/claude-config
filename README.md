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

- **`settings.json`** — shows the deny rules it would add and asks for confirmation before modifying anything (pass `--yes` to skip the prompt, e.g. for non-interactive runs). The merge deduplicates and preserves your other settings. Requires [`jq`](https://jqlang.github.io/jq/). Creates a `.bak` backup before modifying.
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
  the profile explicitly `deny`s the rootful docker and podman sockets:
  rootful container commands must be run by the human, outside confined
  sessions.

  The supported way to get in-session containers is a **rootless Docker
  daemon owned by a dedicated service account**, whose socket the profile
  allows. Container "root" maps to that unprivileged account, so
  `--privileged` or `-v /:/host` yield at most its rights, and because the
  account is not the developer, containers cannot read `~/.ssh` and friends
  even through a bind mount. The allow rule is inert on machines without
  the socket.

  Because that socket is bound inside rootlesskit's private mount
  namespace, its path is "disconnected" from this namespace and AppArmor
  would deny the connect before consulting any rule; the profile therefore
  carries the `attach_disconnected` flag (as `docker-default` does), which
  mediates such paths as if rooted at `/`. Deny rules and the default deny
  for unmatched paths still apply to them.

  See [Rootless Docker setup](#rootless-docker-setup) below.

  There is no supported variant that allows the rootful socket. A
  `docker-allowed` branch used to exist for that and was **deleted in
  September 2026**: it granted root-equivalence to anything running under
  this profile, which is the one thing the profile is for, and the rootless
  path above replaces it without the trade-off. If you genuinely need it,
  add the rule in `/etc/apparmor.d/local/claude-code` on that machine —
  a local, deliberate exception rather than a branch that drifts.

- **Nix.** `/nix/store` is outside `@{HOME}` and outside every path covered
  by the base `ix` rules (`/usr/bin`, `/bin`, `/opt`, ...), so both
  profiles carry explicit rules for it: `/nix/store/** ix,` to exec
  Nix-installed binaries, and `/nix/var/nix/daemon-socket/socket rw,` for
  the multi-user daemon socket (same reasoning as the docker/podman socket
  rules above — reads already work via the blanket `/** r,`, only exec and
  the socket needed adding). Because Nix store paths are content-addressed
  hashes, the profile's own `deny /usr/bin/sudo x,`-style rules can't catch
  a nixpkgs-provided `sudo`/`su`/`pkexec`/`apparmor_parser` — both profiles
  mirror those denies under `/nix/store/*/bin/...` and `/nix/store/*/sbin/...`
  to close that gap. Installing Nix itself still requires `sudo` and must be
  run outside a Claude Code / pi session (`Bash(sudo:*)` is denied by
  `settings.json`, and the AppArmor profile blocks `sudo` at the kernel
  level too) — after installing, reload the profile
  (`sudo apparmor_parser -r /etc/apparmor.d/claude-code`) and restart the
  session to pick it up.

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

## Rootless Docker setup

This is the configuration the profile's container-socket allow rule expects.
It is written to be reusable: **every name here is a local choice**, and the
profile does not hard-code any of them.

### What you are building, and why

A second Docker daemon, owned by a service account that is **not** your user.
Containers it starts have their "root" mapped into that account's subordinate
uid range, so the worst a container escape reaches is an unprivileged account
with no access to your home directory. That is what makes allowing this socket
a different proposition from allowing `/var/run/docker.sock`, where membership
of the `docker` group is root-equivalent.

### 1. The service account

```
sudo adduser --disabled-password --gecos "" --home /srv/<account> <account>
```

`adduser` allocates the subordinate uid/gid ranges in `/etc/subuid` and
`/etc/subgid` for you; confirm with `grep <account> /etc/sub[ug]id`. Without a
range, rootlesskit cannot start.

Pick the home directory outside `/home`. A service account cannot traverse a
`drwxr-x---` home directory, so anything it must read — compose files, bind
mounts — has to live somewhere it can reach.

```
sudo loginctl enable-linger <account>
```

**Not optional.** Without linger the account's systemd user manager, and with
it the daemon, stops when the last session for that account ends.

### 2. A group so you can reach the socket

```
sudo addgroup --system <group>
```

```
sudo adduser <youruser> <group>
```

```
sudo adduser <account> <group>
```

Use the two-argument `adduser` form, or `usermod -aG`. Never `usermod -G`
without `-a`: it *replaces* the supplementary group list, which can drop your
own account out of `sudo` in one stroke.

Group membership is fixed at login. After this, log out and back in — and note
that on GNOME, opening a new terminal window is **not** a new login, because
every window inherits the credentials `gnome-terminal-server` acquired when the
session started.

### 3. Install the daemon as that account

```
sudo -u <account> env HOME=/srv/<account> XDG_RUNTIME_DIR=/run/user/$(id -u <account>) dockerd-rootless-setuptool.sh install
```

The `sudo` here switches identity only. The daemon it installs is unprivileged;
nothing about this grants it extra rights.

### 4. Put the socket somewhere reachable

By default the daemon listens on `/run/user/<uid>/docker.sock`. That directory
is mode `0700` and owned by the service account, so **your user cannot reach it
no matter what the AppArmor profile permits**. The fix is a stable path outside
the runtime directory.

Add to the daemon's own `daemon.json` (at `/srv/<account>/.config/docker/`):

```json
{
  "hosts": ["unix:///srv/<account>/docker.sock"]
}
```

then make the directory traversable and the socket group-writable:

```
sudo chown <account>:<group> /srv/<account>
```

```
sudo chmod 750 /srv/<account>
```

The socket itself is recreated on every daemon start, so set its group through
the daemon rather than with a one-off `chmod`:

```
sudo -u <account> mkdir -p /srv/<account>/.config/systemd/user/docker.service.d
```

with a drop-in that runs `chgrp <group>` and `chmod 660` on the socket after
start (`ExecStartPost=`). A one-off `chmod` is lost at the next restart, which
is the kind of failure that looks intermittent.

### 5. Point the profile at it

If your directory is one of the defaults in `@{CLAUDE_DOCKER_DIRS}`
(`/srv/claude-docker`, `/srv/docker`), nothing to do. Otherwise:

```
sudo mkdir -p /etc/apparmor.d/tunables/claude-code.d
```

```
echo '@{CLAUDE_DOCKER_DIRS}+=/srv/<account>' | sudo tee /etc/apparmor.d/tunables/claude-code.d/local
```

```
sudo apparmor_parser -r /etc/apparmor.d/claude-code
```

`+=` extends the defaults; a plain `=` replaces them and silently drops the
paths that were working.

### 6. Select it

```
docker context create <name> --docker host=unix:///srv/<account>/docker.sock
```

```
docker context use <name>
```

Or set `DOCKER_HOST=unix:///srv/<account>/docker.sock` per session.

### 7. Verify

```
docker info --format '{{.DockerRootDir}} {{.SecurityOptions}}'
```

`SecurityOptions` must contain `rootless`. If `DockerRootDir` is
`/var/lib/docker` you are talking to the rootful daemon and none of the above
is in effect — check this **every time** before running anything that writes,
because restoring volumes into the wrong daemon fails silently: they are
created, they are simply invisible to the stacks that need them.

```
journalctl -k --since '5 min ago' | grep DENIED
```

Run a container from inside a confined Claude Code session; an AppArmor denial
on the socket path shows up here. If you see one naming a path that looks
correct, the usual cause is a missing `attach_disconnected` on the profile.

### Limitations, so they are not discovered later

- **No privileged containers and no host devices.** GPU access is possible but
  needs `no-cgroups = true` in `/etc/nvidia-container-runtime/config.toml`,
  which is a host-wide setting affecting the rootful daemon too.
- **Ports below 1024 need a capability**, not a sysctl:
  `sudo setcap cap_net_bind_service=ep /usr/bin/rootlesskit`. A Docker package
  upgrade replaces that binary and drops the capability, after which a
  container that binds 80 fails with no obvious cause. `getcap` is the check.
- **`network_mode: host`** is rootlesskit's namespace, not the real host.
- **A separate image store.** Images pulled by the rootful daemon are not
  visible here, and vice versa.
- **Bind mounts reach only what the service account can read**, which is the
  point, and which is why compose trees belong somewhere both accounts share.
