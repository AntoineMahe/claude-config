#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Claude Code settings ---
CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR"

# settings.json — merge deny rules into existing config
SETTINGS_DEST="$CLAUDE_DIR/settings.json"
SETTINGS_SRC="$SCRIPT_DIR/settings.json"

if [[ -f "$SETTINGS_DEST" ]]; then
    if command -v jq &>/dev/null; then
        echo "Merging deny rules into existing $SETTINGS_DEST"
        # Merge: combine deny arrays (deduplicate), preserve all other user settings
        MERGED=$(jq -s '
            .[0] as $existing | .[1] as $new |
            $existing * {
                permissions: {
                    deny: (($existing.permissions.deny // []) + ($new.permissions.deny // []) | unique)
                }
            }
        ' "$SETTINGS_DEST" "$SETTINGS_SRC")
        cp "$SETTINGS_DEST" "$SETTINGS_DEST.bak"
        echo "  Backed up original -> $SETTINGS_DEST.bak"
        printf '%s\n' "$MERGED" > "$SETTINGS_DEST"
        echo "  Merged deny rules into settings.json"
    else
        echo "jq not found — cannot merge settings safely."
        echo "  Install jq:  sudo apt install jq"
        echo "  Then re-run this script."
        echo "  (Or manually add the deny rules from $SETTINGS_SRC to $SETTINGS_DEST)"
        exit 1
    fi
else
    cp "$SETTINGS_SRC" "$SETTINGS_DEST"
    echo "Installed settings.json -> $SETTINGS_DEST"
fi

# --- AppArmor profile (requires sudo) ---
APPARMOR_DEST="/etc/apparmor.d/claude-code"
LOCAL_OVERRIDES="/etc/apparmor.d/local/claude-code"

if command -v apparmor_parser &>/dev/null; then
    echo ""
    echo "Installing AppArmor profile (requires sudo)..."
    sudo cp "$SCRIPT_DIR/apparmor/claude-code" "$APPARMOR_DEST"
    echo "Installed AppArmor profile -> $APPARMOR_DEST"

    # Create local overrides file if it doesn't exist
    if [[ ! -f "$LOCAL_OVERRIDES" ]]; then
        sudo mkdir -p /etc/apparmor.d/local
        sudo tee "$LOCAL_OVERRIDES" > /dev/null <<'EOF'
# Per-machine deny rules for Claude Code
# These are included by the main profile via: include if exists <local/claude-code>
#
# Examples (uncomment/adapt as needed):
# deny @{HOME}/Documents/finances/** rwlk,
# deny @{HOME}/private/** rwlk,
# deny @{HOME}/.config/some-app/** rwlk,
EOF
        echo "Created local overrides template -> $LOCAL_OVERRIDES"
        echo "  Edit this file to add per-machine deny rules."
    else
        echo "Local overrides already exist at $LOCAL_OVERRIDES — not overwriting."
    fi

    sudo apparmor_parser -r "$APPARMOR_DEST"
    echo "AppArmor profile loaded (enforce mode)."
    echo "  Restart Claude Code for it to take effect."
    echo "  Debug: journalctl -k | grep DENIED"
    echo "  Disable: sudo aa-complain $APPARMOR_DEST"
else
    echo ""
    echo "AppArmor not available — skipping profile install."
    echo "  Install with: sudo apt install apparmor apparmor-utils"
fi
