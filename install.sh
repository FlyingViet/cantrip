#!/bin/sh
# Cantrip installer — run from a cloned repo:  ./install.sh
# Idempotent: safe to re-run.
set -e
cd "$(dirname "$0")"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }

bold "✦ Installing Cantrip"

# 1. Xcode Command Line Tools (provides swift, git, codesign)
if ! xcode-select -p > /dev/null 2>&1; then
    bold "Xcode Command Line Tools are required. Launching installer…"
    xcode-select --install || true
    echo "Re-run ./install.sh after the tools finish installing."
    exit 1
fi
command -v swift > /dev/null || { echo "swift not found — install Xcode CLT first"; exit 1; }

# 2. Optional AI backends — report, don't block.
echo ""
bold "Checking AI backends (need at least one):"
if command -v claude > /dev/null 2>&1; then
    echo "  ✓ Claude Code CLI found"
else
    echo "  ✗ Claude Code CLI not found → npm install -g @anthropic-ai/claude-code"
    echo "    (then run \`claude\` once to log in) — https://code.claude.com"
fi
if command -v copilot > /dev/null 2>&1; then
    echo "  ✓ GitHub Copilot CLI found"
else
    echo "  ✗ Copilot CLI not found → npm install -g @github/copilot (optional)"
fi
if command -v codex > /dev/null 2>&1; then
    echo "  ✓ OpenAI Codex CLI found"
else
    echo "  ✗ Codex CLI not found → npm install -g @openai/codex (optional)"
fi
echo "  · Local models: any OpenAI-compatible server works (configure in-app)"

# 3. Build: creates the signing cert (one password dialog possible),
#    renders the icon, compiles, signs, bundles.
echo ""
bold "Building…"
make app

# 4. Shell alias for rebuilds.
ALIAS_LINE="alias cantrip='make -C $(pwd) run'"
if ! grep -qs "alias cantrip=" "$HOME/.zshrc"; then
    echo "$ALIAS_LINE" >> "$HOME/.zshrc"
    echo "Added \`cantrip\` alias to ~/.zshrc (rebuild + relaunch anytime)."
fi

# 5. Launch.
open Cantrip.app

echo ""
bold "✦ Done. Press ⌥Space."
echo ""
echo "First-run notes:"
echo "  • macOS will ask for permissions as features are used (mic, speech,"
echo "    location, calendar). Screen Recording must be enabled manually in"
echo "    System Settings → Privacy & Security, then relaunch."
echo "  • Open the gear in the panel to pick your backend & model, and to"
echo "    enable 'Act on my behalf' if you want it to run tasks for you."
echo "  • Tick 'Launch at login' in the gear so it's always available."
