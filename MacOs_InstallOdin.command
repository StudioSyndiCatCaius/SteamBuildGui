#!/bin/bash
# Installs what's needed to build SteamBuildGui on macOS:
#   - Xcode Command Line Tools (clang + linker)
#   - Homebrew (if missing)
#   - The Odin compiler (includes vendor:raylib)
set -e

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Installing Xcode Command Line Tools (a system dialog will open)..."
    xcode-select --install || true
    echo "Re-run this script once the Command Line Tools have finished installing."
    read -n 1 -s -r -p "Press any key to close..."
    exit 0
fi

for p in /opt/homebrew/bin /usr/local/bin; do
    [ -x "$p/brew" ] && export PATH="$p:$PATH"
done
if ! command -v brew >/dev/null 2>&1; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    for p in /opt/homebrew/bin /usr/local/bin; do
        [ -x "$p/brew" ] && export PATH="$p:$PATH"
    done
fi

if command -v odin >/dev/null 2>&1; then
    echo "Odin already installed: $(odin version)"
    echo "Updating..."
    brew upgrade odin || true
else
    echo "Installing Odin..."
    brew install odin
fi

odin version
echo "Done. Now run MacOs_Build.command."
read -n 1 -s -r -p "Press any key to close..."
