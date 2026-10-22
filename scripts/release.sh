#!/bin/zsh
# Builds, signs, notarizes and publishes a SuperMinimalTools release, which also updates the in-app update feed.
#
#   scripts/release.sh ReleaseNotes/<version>.html
#
# Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION first; the build number must grow with every release,
# since Sparkle compares it. The notes file is HTML: Sparkle shows it in the update window and it is also
# the GitHub release's description.
#
# The feed is the appcast.xml attached to the newest GitHub release (SUFeedURL in Config/Info.plist reads
# releases/latest/download/appcast.xml), so publishing the release is what offers the update. Needs, in the
# login keychain: the Developer ID certificate, the `notary` notarytool profile and the Sparkle EdDSA key
# from generate_keys. Also needs `gh` signed in.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTES=${1:?usage: scripts/release.sh ReleaseNotes/<version>.html}
IDENTITY="Developer ID Application: Tai Phan Van (K6GZTHQ9Z5)"
REPO=phanvantai/SuperMinimalTools
SPARKLE_BIN=.build/spm/artifacts/sparkle/Sparkle/bin
APP=.build/release/Build/Products/Release/SuperMinimalTools.app
OUT=.build/updates

echo "==> Building a universal Release"
rm -rf .build/release
xcodebuild -quiet -project SuperMinimalTools.xcodeproj -scheme SuperMinimalTools -configuration Release \
  -destination 'generic/platform=macOS' -clonedSourcePackagesDirPath .build/spm -derivedDataPath .build/release \
  -skipPackagePluginValidation -skipMacroValidation ONLY_ACTIVE_ARCH=NO "ARCHS=arm64 x86_64" \
  CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application" DEVELOPMENT_TEAM=K6GZTHQ9Z5 \
  PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO "OTHER_CODE_SIGN_FLAGS=--timestamp" build
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
TAG="v$VERSION"
echo "    SuperMinimalTools $VERSION ($BUILD)"
[[ $NOTES -ef ReleaseNotes/$VERSION.html ]] || { echo "error: $NOTES isn't ReleaseNotes/$VERSION.html" >&2; exit 1; }

# The feed's current build, so a forgotten CURRENT_PROJECT_VERSION bump stops here instead of shipping an
# update nobody is offered. Empty before the first release with a feed.
FEED_BUILD=$(curl -fsL "https://github.com/$REPO/releases/latest/download/appcast.xml" 2>/dev/null \
  | sed -n -E 's/.*<sparkle:version>([0-9]+)<.*/\1/p' | sort -n | tail -1 || true)
if [[ -n $FEED_BUILD ]] && (( BUILD <= FEED_BUILD )) && ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "error: build $BUILD isn't above the feed's $FEED_BUILD; raise CURRENT_PROJECT_VERSION" >&2
  exit 1
fi

echo "==> Signing Sparkle's helpers and the app"
# Sparkle's helpers arrive ad-hoc signed; notarization needs Developer ID on each, signed inside out.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; }
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Notarizing"
rm -rf "$OUT" && mkdir -p "$OUT"
ZIP="$OUT/SuperMinimalTools-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile notary --wait
xcrun stapler staple "$APP"
spctl --assess --type execute "$APP"
rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Generating the appcast"
# Only the new version goes in the feed: each zip lives under its own release tag, and Sparkle only needs
# the newest item. generate_appcast picks up the notes from the .html named like the zip.
cp "$NOTES" "$OUT/SuperMinimalTools-$VERSION.html"
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" "$OUT"
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$OUT/appcast.xml" \
  || { echo "error: appcast.xml doesn't list build $BUILD" >&2; exit 1; }

echo "==> Publishing"
# The same zip under a fixed name, so the README can link releases/latest/download/SuperMinimalTools.zip.
# It stays out of $OUT, where generate_appcast would list it as another update.
LATEST=$(mktemp -d)/SuperMinimalTools.zip
cp "$ZIP" "$LATEST"
ASSETS=("$ZIP" "$LATEST" "$OUT/appcast.xml")
# A release left by an earlier, interrupted run gets this run's files, so the zip always matches the
# signature in the appcast and the script can simply be run again.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "${ASSETS[@]}" --repo "$REPO" --clobber
  echo "    Replaced the files in the existing release"
else
  gh release create "$TAG" "${ASSETS[@]}" --repo "$REPO" --title "SuperMinimalTools $VERSION" \
    --notes-file "$NOTES" --target main --latest
fi
git tag "$TAG" 2>/dev/null || true

echo "==> Done: https://github.com/$REPO/releases/tag/$TAG"
shasum -a 256 "$ZIP"
