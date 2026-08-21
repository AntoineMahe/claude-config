#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: ./install.sh [--settings] [--apparmor] [--all] [-h|--help]

Components:
  --settings   Merge Claude Code deny rules into ~/.claude/settings.json
  --apparmor   Install and load the AppArmor profile (requires sudo)
  --all        Both (default when no component flag is given)

Options:
  --yes        Skip the confirmation prompt before modifying settings.json
               (required for non-interactive runs that include --settings)

The two layers are independent: settings.json is Claude's own (soft)
deny list, the AppArmor profile is the kernel-enforced (hard) boundary.
EOF
}

# Ask before touching the user's settings.json. Refuses (rather than
# assumes yes) when there is no terminal to ask on, unless --yes was given.
confirm() {
    local prompt="$1"
    if [[ $assume_yes -eq 1 ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        echo "  No terminal to confirm on — skipping. Re-run with --yes to proceed." >&2
        return 1
    fi
    local reply
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

install_settings() {
    local claude_dir="$HOME/.claude"
    local dest="$claude_dir/settings.json"
    local src="$SCRIPT_DIR/settings.json"

    mkdir -p "$claude_dir"

    if [[ -f "$dest" ]]; then
        if command -v jq &>/dev/null; then
            # Merge: combine deny arrays (deduplicate), preserve all other user settings
            local merged
            merged=$(jq -s '
                .[0] as $existing | .[1] as $new |
                $existing * {
                    permissions: {
                        deny: (($existing.permissions.deny // []) + ($new.permissions.deny // []) | unique)
                    }
                }
            ' "$dest" "$src")
            if [[ "$merged" == "$(jq . "$dest")" ]]; then
                echo "settings.json already contains all deny rules — nothing to do."
                return
            fi
            echo "Deny rules to add to $dest:"
            jq -r --slurpfile existing <(jq '.permissions.deny // []' "$dest") \
                '(.permissions.deny // []) - $existing[0] | .[] | "  + " + .' "$src"
            if ! confirm "Merge these deny rules into settings.json?"; then
                echo "  Skipped settings.json — left unmodified."
                return
            fi
            cp "$dest" "$dest.bak"
            echo "  Backed up original -> $dest.bak"
            printf '%s\n' "$merged" > "$dest"
            echo "  Merged deny rules into settings.json"
        else
            echo "jq not found — cannot merge settings safely."
            echo "  Install jq:  sudo apt install jq"
            echo "  Then re-run this script."
            echo "  (Or manually add the deny rules from $src to $dest)"
            exit 1
        fi
    else
        if confirm "No existing settings.json — install $src as $dest?"; then
            cp "$src" "$dest"
            echo "Installed settings.json -> $dest"
        else
            echo "  Skipped settings.json — not installed."
        fi
    fi
}

install_apparmor() {
    local dest="/etc/apparmor.d/claude-code"
    local local_overrides="/etc/apparmor.d/local/claude-code"

    if ! command -v apparmor_parser &>/dev/null; then
        echo "AppArmor not available — skipping profile install."
        echo "  Install with: sudo apt install apparmor apparmor-utils"
        return
    fi

    echo "Installing AppArmor profile (requires sudo)..."
    sudo cp "$SCRIPT_DIR/apparmor/claude-code" "$dest"
    echo "Installed AppArmor profile -> $dest"

    # Create local overrides file if it doesn't exist
    if [[ ! -f "$local_overrides" ]]; then
        sudo mkdir -p /etc/apparmor.d/local
        sudo tee "$local_overrides" > /dev/null <<'EOF'
# Per-machine deny rules for Claude Code
# These are included by the main profile via: include if exists <local/claude-code>
#
# Examples (uncomment/adapt as needed):
# deny @{HOME}/Documents/finances/** rwlk,
# deny @{HOME}/private/** rwlk,
# deny @{HOME}/.config/some-app/** rwlk,
EOF
        echo "Created local overrides template -> $local_overrides"
        echo "  Edit this file to add per-machine deny rules."
    else
        echo "Local overrides already exist at $local_overrides — not overwriting."
    fi

    sudo apparmor_parser -r "$dest"
    echo "AppArmor profile loaded (enforce mode)."
    echo "  Restart Claude Code for it to take effect."
    echo "  Debug: journalctl -k | grep DENIED"
    echo "  Disable: sudo aa-complain $dest"
}

do_settings=0
do_apparmor=0
assume_yes=0

for arg in "$@"; do
    case "$arg" in
        --settings) do_settings=1 ;;
        --apparmor) do_apparmor=1 ;;
        --all) do_settings=1; do_apparmor=1 ;;
        --yes) assume_yes=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

# Default: install both, as before
if [[ $do_settings -eq 0 && $do_apparmor -eq 0 ]]; then
    do_settings=1
    do_apparmor=1
fi

[[ $do_settings -eq 1 ]] && install_settings
if [[ $do_apparmor -eq 1 ]]; then
    [[ $do_settings -eq 1 ]] && echo ""
    install_apparmor
fi
