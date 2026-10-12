#!/bin/bash
# Builds a signed, notarized installer package for GitHub Releases.
#
#   Scripts/release.sh            # → dist/PDF-to-EPUB-<version>.pkg
#
# The package installs pdf2epub to /usr/local/bin and the "Convert to EPUB" Quick Action
# for the user who runs the installer. Requires (one-time setup, see README):
#   - "Developer ID Application" and "Developer ID Installer" certificates in the keychain
#   - notarytool credentials: xcrun notarytool store-credentials pdf2epub-notary …
#
# Override with APP_IDENTITY, INSTALLER_IDENTITY, NOTARY_PROFILE, BUNDLE_ID.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

APP_IDENTITY="${APP_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-$(security find-identity -v | sed -n 's/.*"\(Developer ID Installer[^"]*\)".*/\1/p' | head -1)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-pdf2epub-notary}"
BUNDLE_ID="${BUNDLE_ID:-io.github.pdf2epub}"
[ -n "$APP_IDENTITY" ] || { echo "No Developer ID Application certificate found." >&2; exit 1; }
[ -n "$INSTALLER_IDENTITY" ] || { echo "No Developer ID Installer certificate found." >&2; exit 1; }

echo "==> Building"
swift build -c release --arch arm64
BIN=".build/arm64-apple-macosx/release/pdf2epub"
VERSION="$("$BIN" --version)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
root="$work/root"
support="$root/Library/Application Support/PDF to EPUB"
mkdir -p "$root/usr/local/bin" "$support" "$work/scripts" "$work/resources"

echo "==> Signing pdf2epub $VERSION with: $APP_IDENTITY"
cp "$BIN" "$root/usr/local/bin/pdf2epub"
codesign --force --timestamp --options runtime --identifier "$BUNDLE_ID" \
  --sign "$APP_IDENTITY" "$root/usr/local/bin/pdf2epub"
codesign --verify --strict --verbose=1 "$root/usr/local/bin/pdf2epub"

# The Quick Action lives in Application Support; postinstall copies it into the
# installing user's ~/Library/Services, where Finder looks for Quick Actions.
Scripts/make-quick-action.sh "$support" >/dev/null

cat > "$work/scripts/postinstall" <<'POST'
#!/bin/bash
# Runs as root. Install the Quick Action for the user at the console.
user="$(stat -f %Su /dev/console)"
[ -n "$user" ] && [ "$user" != "root" ] || exit 0
home="$(dscl . -read "/Users/$user" NFSHomeDirectory | awk '{print $2}')"
src="/Library/Application Support/PDF to EPUB/Convert to EPUB.workflow"
dest="$home/Library/Services"
sudo -u "$user" mkdir -p "$dest"
rm -rf "$dest/Convert to EPUB.workflow"
sudo -u "$user" cp -R "$src" "$dest/"
sudo -u "$user" /System/Library/CoreServices/pbs -update 2>/dev/null || true
exit 0
POST
chmod +x "$work/scripts/postinstall"

echo "==> Packaging"
pkgbuild --root "$root" --identifier "$BUNDLE_ID" --version "$VERSION" \
  --scripts "$work/scripts" --install-location / "$work/component.pkg" >/dev/null

cp LICENSE "$work/resources/LICENSE.txt"
cat > "$work/resources/welcome.html" <<'HTML'
<html><body style="font-family: -apple-system; font-size: 13px">
<p><b>PDF to EPUB</b> turns PDF books into ebooks that read well on e-readers.</p>
<p>After installing, right-click any PDF in Finder and choose
<b>Quick Actions → Convert to EPUB</b>. The book appears next to the PDF, and a
notification tells you when it's done. Big scanned books can take a few minutes.</p>
<p>Requires macOS 26 or later on an Apple Silicon Mac. With Apple Intelligence turned on,
conversions also get an on-device proofreading pass.</p>
</body></html>
HTML
cat > "$work/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>PDF to EPUB</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <license file="LICENSE.txt"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <domains enable_localSystem="true" enable_currentUserHome="false" enable_anywhere="false"/>
    <!-- Check the running system up front with a clear message. (A <volume-check> instead
         just grays out the destination with no explanation when it fails.) -->
    <installation-check script="checkSystem()"/>
    <script><![CDATA[
    function checkSystem() {
        if (system.compareVersions(system.version.ProductVersion, '26.0') < 0) {
            my.result.title = 'macOS 26 or later required';
            my.result.message = 'PDF to EPUB needs macOS 26 (Tahoe) or later. This Mac has macOS ' + system.version.ProductVersion + '.';
            my.result.type = 'Fatal';
            return false;
        }
        return true;
    }
    ]]></script>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" title="PDF to EPUB"><pkg-ref id="$BUNDLE_ID"/></choice>
    <pkg-ref id="$BUNDLE_ID" version="$VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML

mkdir -p dist
out="dist/PDF-to-EPUB-$VERSION.pkg"
productbuild --distribution "$work/distribution.xml" --resources "$work/resources" \
  --package-path "$work" --sign "$INSTALLER_IDENTITY" --timestamp "$out" >/dev/null

echo "==> Notarizing (usually a minute or two)"
xcrun notarytool submit "$out" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$out"

echo "==> Checking"
spctl --assess --type install --verbose=2 "$out"
shasum -a 256 "$out"
echo "Done: $out"
