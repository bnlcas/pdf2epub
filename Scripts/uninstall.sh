#!/bin/bash
# Removes pdf2epub and the "Convert to EPUB" Quick Action, however they were installed
# (the .pkg installer or Scripts/install.sh). Removing /usr/local/bin needs your password.
set -u
removed=0
for f in "$HOME/bin/pdf2epub" "$HOME/Library/Services/Convert to EPUB.workflow"; do
  if [ -e "$f" ]; then rm -rf "$f" && echo "removed $f" && removed=1; fi
done
for f in /usr/local/bin/pdf2epub "/Library/Application Support/PDF to EPUB"; do
  if [ -e "$f" ]; then sudo rm -rf "$f" && echo "removed $f" && removed=1; fi
done
if pkgutil --pkg-info io.github.pdf2epub >/dev/null 2>&1; then
  sudo pkgutil --forget io.github.pdf2epub >/dev/null && echo "forgot installer receipt io.github.pdf2epub"
fi
/System/Library/CoreServices/pbs -update 2>/dev/null || true
[ $removed -eq 1 ] && echo "pdf2epub is uninstalled." || echo "Nothing to remove."
