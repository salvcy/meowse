#!/bin/zsh
# Update Resources/Localizable.xcstrings with every string the app shows.
#
#   scripts/strings.sh
#
# The compiler lists each String(localized:) and SwiftUI text literal it
# sees; xcstringstool merges them into the catalog, keeping translations and
# marking strings the code no longer uses as stale. Translate in Xcode (open
# the catalog) or any editor that reads .xcstrings, then run scripts/build.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

CATALOG=Resources/Localizable.xcstrings
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A build of its own, so the extraction flags never touch .build.
swift build -c debug --scratch-path "$WORK/build" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings"

[[ -f $CATALOG ]] || echo '{"sourceLanguage":"en","strings":{},"version":"1.0"}' > "$CATALOG"
xcrun xcstringstool sync "$CATALOG" --stringsdata "$WORK"/strings/*.stringsdata
echo "Updated $CATALOG ($(plutil -extract strings raw -o - "$CATALOG" | wc -l | tr -d ' ') strings)"
