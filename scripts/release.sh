#!/bin/zsh
# Package a release that the in-app updater can install.
#
#   scripts/release.sh 1.2.0             # bump version, build, write dist/Meowse.zip
#   scripts/release.sh 1.2.0 --publish   # also commit, tag, push and create the GitHub release
#
# Set NOTES_FILE to a Markdown file to use as the release notes (shown in the
# in-app updater); otherwise GitHub generates them.
#
# Releases must be signed with the same team as the installed app, or the
# updater refuses them. Downloads must also be signed with a Developer ID
# certificate and notarized, or Gatekeeper blocks them. Notarization uses the
# notarytool keychain profile in NOTARY_PROFILE (default "meowse"), created once with
#   xcrun notarytool store-credentials meowse
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-}
PUBLISH=0
[[ ${2:-} == --publish ]] && PUBLISH=1
[[ $VERSION =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { echo "usage: scripts/release.sh <version, e.g. 1.2.0> [--publish]"; exit 2; }

NOTARY_PROFILE=${NOTARY_PROFILE:-meowse}
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')
if [[ -z $IDENTITY ]]; then
  echo "No Developer ID Application certificate; Gatekeeper would block the download."
  echo "Create one in Xcode → Settings → Accounts → Manage Certificates."; exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "No notarization credentials in keychain profile \"$NOTARY_PROFILE\"."
  echo "Run: xcrun notarytool store-credentials $NOTARY_PROFILE"; exit 1
fi

PLIST=Resources/Info.plist
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $PLIST)
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $PLIST) + 1 ))
if (( PUBLISH )) && [[ -n $(git status --porcelain) ]]; then
  echo "Commit or stash your changes first."; exit 1
fi
if (( PUBLISH )) && [[ $(git branch --show-current) != main ]]; then
  echo "Publish from main; --publish pushes the current branch to the public repository."; exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" $PLIST
echo "Version $CURRENT → $VERSION (build $BUILD)"

swift test
SIGN_IDENTITY=$IDENTITY TIMESTAMP=1 scripts/build.sh

SIGNATURE=$(codesign -dv build/Meowse.app 2>&1)
TEAM=$(echo "$SIGNATURE" | awk -F= '/^TeamIdentifier=/ { print $2 }')
if [[ -z $TEAM || $TEAM == "not set" ]]; then
  echo "build/Meowse.app has no signing team; the updater would reject it."; exit 1
fi
if ! echo "$SIGNATURE" | grep -q '^Timestamp='; then
  echo "build/Meowse.app has no secure timestamp; it would stop verifying when the certificate expires."; exit 1
fi

# Apple notarizes the archive; the stapled ticket lets the first launch pass
# Gatekeeper offline.
mkdir -p dist
rm -f dist/Meowse.zip
ditto -c -k --keepParent build/Meowse.app dist/Meowse.zip
xcrun notarytool submit dist/Meowse.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple build/Meowse.app
if ! spctl --assess --type execute build/Meowse.app; then
  echo "Gatekeeper rejects build/Meowse.app."; exit 1
fi
rm -f dist/Meowse.zip
ditto -c -k --keepParent build/Meowse.app dist/Meowse.zip
rm -rf build/Meowse.app  # the archive is the release; installed copies update themselves
echo "dist/Meowse.zip  sha256 $(shasum -a 256 dist/Meowse.zip | cut -d' ' -f1)  team $TEAM"

if (( PUBLISH )); then
  git add $PLIST
  git commit -m "Release $VERSION"
  git tag "v$VERSION"
  git push origin HEAD "v$VERSION"
  if [[ -n ${NOTES_FILE:-} ]]; then
    gh release create "v$VERSION" dist/Meowse.zip --title "Meowse $VERSION" --notes-file "$NOTES_FILE"
  else
    gh release create "v$VERSION" dist/Meowse.zip --title "Meowse $VERSION" --generate-notes
  fi
  scripts/tap.sh || echo "Homebrew tap not updated; run scripts/tap.sh."
else
  echo "Not published. Re-run with --publish, or attach dist/Meowse.zip to a v$VERSION GitHub release."
fi
