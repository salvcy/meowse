#!/bin/zsh
# Point the Homebrew tap at the latest GitHub release.
#
#   scripts/tap.sh
#
# release.sh --publish runs this. A tap that falls behind still installs: it
# fetches the version it names, and the app updates itself from there.
set -euo pipefail

VERSION=$(gh api repos/salvcy/meowse/releases/latest --jq '.tag_name[1:]')
# The checksum of what people download, not of a local build.
SHA=$(curl -fsSL "https://github.com/salvcy/meowse/releases/download/v$VERSION/Meowse.zip" | shasum -a 256 | cut -d' ' -f1)

TAP=$(mktemp -d)
trap 'rm -rf "$TAP"' EXIT
git clone -q --depth 1 https://github.com/salvcy/homebrew-tap.git "$TAP"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/meowse.rb"
if git -C "$TAP" diff --quiet; then
  echo "Tap already at $VERSION."; exit 0
fi
git -C "$TAP" commit -qam "Meowse $VERSION"
git -C "$TAP" push -q
echo "Tap updated to $VERSION."
