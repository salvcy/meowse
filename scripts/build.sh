#!/bin/zsh
# Build Meowse.app (release, universal) into ./build.
#
#   scripts/build.sh                      # signs with your Apple Development identity if present
#   SIGN_IDENTITY="-" scripts/build.sh    # force ad-hoc
#   TIMESTAMP=1 scripts/build.sh          # add Apple's secure timestamp (needs network; releases)
#
# A stable identity keeps the Accessibility grant across rebuilds. With
# ad-hoc signing, macOS ties the grant to the exact binary, so every rebuild
# needs it granted again.
#
# Without a secure timestamp a signature is only valid while its certificate
# is, so the in-app updater would refuse a release once the certificate that
# signed it expires.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Meowse.app
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ { print $2; exit }')
fi
IDENTITY="${SIGN_IDENTITY:--}"
echo "Signing with: ${IDENTITY/#-/ad-hoc}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Meowse" "$APP/Contents/MacOS/Meowse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
strip -x "$APP/Contents/MacOS/Meowse"

# The Settings window is an app of its own inside this one, so everything it
# loads goes back to the system when it closes. Its Info.plist is Meowse's,
# renamed, so the versions always match.
HELPER="$APP/Contents/Helpers/Meowse Settings.app"
mkdir -p "$HELPER/Contents/MacOS" "$HELPER/Contents/Resources"
cp "$BIN/MeowseSettings" "$HELPER/Contents/MacOS/Meowse Settings"
cp Resources/Info.plist "$HELPER/Contents/Info.plist"
# It never shows a Dock icon, only list-sized ones (Activity Monitor,
# Finder), so it gets the app icon's 16 and 32 pt images: 10 KB, not 440.
ICONS=$(mktemp -d)
iconutil -c iconset Resources/AppIcon.icns -o "$ICONS/all.iconset"
mkdir "$ICONS/small.iconset"
cp "$ICONS"/all.iconset/icon_{16x16,32x32}{,@2x}.png "$ICONS/small.iconset/"
iconutil -c icns "$ICONS/small.iconset" -o "$HELPER/Contents/Resources/AppIcon.icns"
rm -rf "$ICONS"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier app.meowse.Meowse.Settings" \
  -c "Set :CFBundleExecutable 'Meowse Settings'" \
  -c "Set :CFBundleName 'Meowse Settings'" \
  -c "Set :CFBundleDisplayName 'Meowse Settings'" \
  -c "Delete :MeowseUpdateRepository" \
  "$HELPER/Contents/Info.plist"
strip -x "$HELPER/Contents/MacOS/Meowse Settings"

# Translations, from the catalog scripts/strings.sh keeps. Each language is a
# small binary table, read the first time a string is shown. English is the
# source text, so it has no table, but its folder lists it as a language.
# Both apps get them: the Settings app looks strings up in its own bundle.
STRINGS=$(mktemp -d)
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$STRINGS" --serialization-format binary
mkdir -p "$STRINGS/en.lproj"
for dir in "$APP/Contents/Resources" "$HELPER/Contents/Resources"; do
  cp -R "$STRINGS"/*.lproj "$dir/"
done
rm -rf "$STRINGS"

# The lid helper: a launchd daemon inside the app that macOS runs as root once
# an administrator allows it, and then only while Meowse keeps the Mac awake
# with the lid closed. It's named for the app, so a copy with another bundle
# identifier has its own.
APP_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist)
LID="$APP/Contents/MacOS/meowse-lid"
cp "$BIN/MeowseLid" "$LID"
strip -x "$LID"
mkdir -p "$APP/Contents/Library/LaunchDaemons"
/usr/libexec/PlistBuddy \
  -c "Add :Label string $APP_ID.lid" \
  -c "Add :BundleProgram string Contents/MacOS/meowse-lid" \
  -c "Add :MachServices dict" \
  -c "Add :MachServices:$APP_ID.lid bool true" \
  -c "Add :AssociatedBundleIdentifiers array" \
  -c "Add :AssociatedBundleIdentifiers:0 string $APP_ID" \
  -c "Add :RunAtLoad bool true" \
  -c "Add :KeepAlive dict" \
  -c "Add :KeepAlive:SuccessfulExit bool false" \
  "$APP/Contents/Library/LaunchDaemons/$APP_ID.lid.plist" >/dev/null

# Inside out: the helpers' signatures are sealed into Meowse's.
TS=--timestamp=none
[[ ${TIMESTAMP:-0} == 1 ]] && TS=--timestamp
codesign --force --options runtime $TS --sign "$IDENTITY" "$HELPER"
codesign --force --options runtime $TS --identifier "$APP_ID.lid" --sign "$IDENTITY" "$LID"
codesign --force --options runtime $TS --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
