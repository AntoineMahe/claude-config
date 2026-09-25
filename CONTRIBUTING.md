# Contributing

A small repo with an outsized failure mode: it installs a kernel-enforced
AppArmor profile. A wrong rule does not produce a stack trace, it produces a
tool that stops working for no visible reason. The branch model below exists to
keep that away from people who did not write it.

## Branches

| Branch | Meaning |
|---|---|
| `main` | **Tested. Install from here.** This is what a stranger gets by cloning |
| `develop` | Integration. Everything merged here is intended for `main` |
| `feature/*` | Cut from `develop`, merged back into `develop` |
| `hotfix/*` | Cut from `main`, merged into **both** `main` and `develop`. Only for defects already present in `main` |

**`develop` is not a parking lot.** Merging into it is a commitment to ship, so
anything uncertain stays on its own branch. A long-lived branch used to run an
idea on a real machine for a week before deciding is fine and encouraged — that
is what the branch is for. It just does not enter `develop` until the answer is
yes.

## Promotion to `main`

`develop` merges into `main` once it has run for **a working week on the
heavy-use machine** with no new AppArmor denials.

The condition names a machine deliberately. Profile gaps do not show up in
review, they show up under load: an agent session reaching for a binary nobody
anticipated, at a path nobody checked. A machine doing eight hours a day of
agent work finds them; a machine doing one hour a week does not. Reading the
diff is not a substitute, and a week of real use is worth more than any amount
of it.

## Merging

Use `--no-ff` for feature merges, so a feature stays visible as a unit in
history rather than being flattened into unrelated commits.

## What earns extra scrutiny

**Loosening versus tightening.** A tightening that is wrong breaks a tool
loudly, someone notices within minutes and backs it out. A loosening that is
wrong removes protection silently and is never noticed at all. Allow rules
deserve more review than deny rules, not less.

**Rules that name a path.** Two failure shapes, both quiet:

- A rule for a path that does not exist on this machine is *inert*. That is
  usually fine and sometimes the design (the rootless Docker socket rule is
  deliberately harmless where there is no socket) — but it must be intended,
  not assumed.
- **A profile whose attach path matches nothing loads cleanly and confines
  nothing**, and `aa-status` lists it either way. Check the attach path exists
  before believing a profile is doing anything. The `pi` profile attaches at
  `@{HOME}/.local/share/pi-node/*/bin/pi`; if pi moves, confinement silently
  stops.

**Distro assumptions.** Ubuntu 25.10 replaced GNU coreutils with the Rust
`uutils` build, moving `ls`, `cat`, `head`, `sort` and friends to symlinks into
`/usr/lib/cargo/bin/coreutils/`. AppArmor matches the *resolved* target, so
`/usr/bin/** ix,` stopped covering them and every coreutil was denied while
`grep`, `sed` and `awk` kept working. The result read as random permission
errors rather than as a profile gap, and it shipped unnoticed. Expect this class
of breakage to recur: a binary moving out from under a glob costs nothing to
write and is expensive to diagnose.

## Verifying a change

```
sudo apparmor_parser -Q apparmor/<name>
```

Syntax only, no effect on the running system. Then install and reload:

```
sudo ./install.sh --apparmor=<name>
```

Restart the confined tool — a running process keeps the profile it started
with.

```
sudo aa-status
```

```
journalctl -k | grep DENIED
```

**An empty denial log does not prove nothing was denied.** AppArmor `deny` rules
are silent unless written `audit deny`. Verify a rule works by doing the thing
it permits and watching it succeed, not by looking for the absence of an error.

## Identity

Commits published here use the maintainer's personal address. Before a first
push from a new machine:

```
git log --format='%ae %ce' | sort -u
```

Fix unpushed commits with `git commit --amend --reset-author`. Published history
is left alone: a force-push does not remove objects from GitHub, so a rewrite
costs disruption and achieves little.
