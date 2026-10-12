#!/bin/bash
# Builds a shareable zip: the binary, the Quick Action, and a double-click installer.
# The result is for Apple Silicon Macs on macOS 26 or later.
#
#   Scripts/package.sh            # → dist/PDF-to-EPUB.zip
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release
stage="dist/PDF to EPUB"
rm -rf dist
mkdir -p "$stage"
cp .build/release/pdf2epub "$stage/pdf2epub"
codesign -s - -f "$stage/pdf2epub"
Scripts/make-quick-action.sh "$stage" >/dev/null

cat > "$stage/Install.command" <<'INSTALL'
#!/bin/bash
# Double-click to install. Puts pdf2epub in ~/bin and adds the Finder Quick Action.
cd "$(dirname "$0")" || exit 1
mkdir -p "$HOME/bin" "$HOME/Library/Services"
cp pdf2epub "$HOME/bin/pdf2epub"
rm -rf "$HOME/Library/Services/Convert to EPUB.workflow"
cp -R "Convert to EPUB.workflow" "$HOME/Library/Services/"
# Files that arrive by download or AirDrop are quarantined; these are ours.
xattr -dr com.apple.quarantine "$HOME/bin/pdf2epub" "$HOME/Library/Services/Convert to EPUB.workflow" 2>/dev/null
/System/Library/CoreServices/pbs -update 2>/dev/null
osascript -e 'display dialog "PDF to EPUB is installed.

In Finder, right-click any PDF and choose Quick Actions → Convert to EPUB. The book appears next to the PDF." buttons {"OK"} default button 1 with title "PDF to EPUB"' >/dev/null
INSTALL
chmod +x "$stage/Install.command"

cat > "$stage/Read Me.txt" <<'README'
PDF to EPUB

Turns PDF books into ebooks that read well on small e-readers.

To install: double-click "Install.command". If macOS says it can't check it for
malicious software, right-click it, choose Open, then Open again.

To use: in Finder, right-click a PDF and choose Quick Actions → Convert to EPUB.
The EPUB appears next to the PDF; you'll get a notification when it's done.
Big scanned books can take a few minutes.

Needs macOS 26 or later on an Apple Silicon Mac. With Apple Intelligence turned on,
conversions also get a proofreading pass; without it they still work.
README

(cd dist && ditto -c -k --keepParent "PDF to EPUB" "PDF-to-EPUB.zip")
echo "wrote dist/PDF-to-EPUB.zip"
