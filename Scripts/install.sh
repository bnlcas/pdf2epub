#!/bin/bash
# Builds pdf2epub, installs it to ~/bin, and adds the Finder Quick Action "Convert to EPUB".
#
#   Scripts/install.sh            # install
#   PREFIX=/usr/local/bin Scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PREFIX="${PREFIX:-$HOME/bin}"
SERVICES="${SERVICES:-$HOME/Library/Services}"

# The macOS 26 SDK ships with Xcode; the standalone Command Line Tools may be older.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release
mkdir -p "$PREFIX" "$SERVICES"
cp .build/release/pdf2epub "$PREFIX/pdf2epub"
codesign -s - -f "$PREFIX/pdf2epub"
Scripts/make-quick-action.sh "$SERVICES" >/dev/null
/System/Library/CoreServices/pbs -update 2>/dev/null || true

echo "Installed $PREFIX/pdf2epub"
echo "Installed Quick Action: right-click a PDF in Finder → Quick Actions → Convert to EPUB"
case ":$PATH:" in *":$PREFIX:"*) ;; *) echo "Note: $PREFIX is not on your PATH (the Quick Action doesn't need it).";; esac
