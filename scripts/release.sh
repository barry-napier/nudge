#!/usr/bin/env bash
# Builds a release of Nudge: signed with Developer ID, notarized by Apple,
# packed in a DMG, signed for Sparkle updates, with an appcast and a
# Homebrew cask. Nothing is published unless you pass --publish.
#
#   ./scripts/release.sh 0.1.0                   build everything locally
#   ./scripts/release.sh 0.1.0 --skip-notarize   local test, no Apple upload
#   ./scripts/release.sh 0.1.0 --publish         also create the GitHub release
#
# One-time setup for notarization (stores your login in the keychain):
#   xcrun notarytool store-credentials nudge-notary \
#     --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh VERSION [--skip-notarize] [--publish]}"
shift
NOTARIZE=1
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) NOTARIZE=0 ;;
    --publish) PUBLISH=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done
if [[ $PUBLISH == 1 && $NOTARIZE == 0 ]]; then
  echo "error: never publish a build that Apple has not notarized." >&2
  exit 1
fi

REPO="barry-napier/nudge"
NOTARY_PROFILE="nudge-notary"
SPARKLE_ACCOUNT="com.barrynapier.nudge"
BUILD_NUMBER=$(git rev-list --count HEAD)
OUT="build/release/$VERSION"
APP="$OUT/export/Nudge.app"
DMG="$OUT/Nudge-$VERSION.dmg"
SPARKLE_BIN="build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
step() { printf '\n==> %s\n' "$*"; }

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: commit your changes first, so the release matches a commit." >&2
  exit 1
fi
[[ -f Config/Local.xcconfig ]] || { echo "error: run scripts/build.sh once first." >&2; exit 1; }
TEAM_ID=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig | tr -d ' ')
if [[ $NOTARIZE == 1 ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "error: no notarization login saved. Run this once, then try again:" >&2
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id YOUR_APPLE_ID --team-id $TEAM_ID" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

step "Archiving Nudge $VERSION (build $BUILD_NUMBER)"
command -v xcodegen >/dev/null && xcodegen generate --quiet
xcodebuild -project Nudge.xcodeproj -scheme Nudge -configuration Release \
  -derivedDataPath build/DerivedData -archivePath "$OUT/Nudge.xcarchive" \
  -destination "generic/platform=macOS" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet archive

step "Exporting with Developer ID"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Nudge.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" -quiet

step "Checking the signature"
codesign --verify --deep --strict --verbose=1 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime" >/dev/null \
  || { echo "error: not signed with Developer ID and the hardened runtime." >&2; exit 1; }
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "error: release build still has the debugging entitlement." >&2; exit 1
fi

if [[ $NOTARIZE == 1 ]]; then
  step "Notarizing the app (this can take a few minutes)"
  ditto -c -k --keepParent "$APP" "$OUT/Nudge.zip"
  xcrun notarytool submit "$OUT/Nudge.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

step "Making the DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Nudge.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Nudge" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
codesign --sign "Developer ID Application" --timestamp "$DMG"

if [[ $NOTARIZE == 1 ]]; then
  step "Notarizing the DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  step "Checking that Gatekeeper accepts it"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
  spctl --assess --type execute --verbose "$APP"
fi

step "Signing for Sparkle updates"
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")
DMG_URL="https://github.com/$REPO/releases/download/v$VERSION/Nudge-$VERSION.dmg"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Nudge</title>
    <item>
      <title>Nudge $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="$DMG_URL" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

step "Writing the Homebrew cask"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
cat > packaging/homebrew/nudge.rb <<RUBY
cask "nudge" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/Nudge-#{version}.dmg"
  name "Nudge"
  desc "Private, on-device writing assistant for any text field"
  homepage "https://github.com/$REPO"

  depends_on macos: ">= :tahoe"
  depends_on arch: :arm64

  app "Nudge.app"

  zap trash: [
    "~/Library/Application Support/Nudge",
    "~/Library/Logs/Nudge",
    "~/Library/Preferences/com.barrynapier.nudge.plist",
  ]
end
RUBY

echo
echo "Done: $DMG"
echo "      $OUT/appcast.xml"
echo "      packaging/homebrew/nudge.rb"

if [[ $PUBLISH == 1 ]]; then
  step "Publishing v$VERSION on GitHub"
  git push origin HEAD
  git tag -a "v$VERSION" -m "Nudge $VERSION"
  git push origin "v$VERSION"
  gh release create "v$VERSION" "$DMG" "$OUT/appcast.xml" --repo "$REPO" \
    --title "Nudge $VERSION" --notes "Download Nudge-$VERSION.dmg, open it, and drag Nudge to Applications."
else
  echo
  echo "Not published. To publish: ./scripts/release.sh $VERSION --publish"
fi
