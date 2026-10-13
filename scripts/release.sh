#!/bin/zsh
# Publishes a release that installed copies pick up through Sparkle.
#   scripts/release.sh 0.2.0 ["release notes"]
# Needs: clean git tree on main, `gh` logged in, the Sparkle EdDSA private key in the login Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version> [notes]}"
NOTES="${2:-Terminaly $VERSION}"
TAG="v$VERSION"
REPO="drarekx/terminaly"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean"; exit 1; }
[[ "$(git branch --show-current)" == "main" ]] || { echo "release from main"; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "$TAG already exists"; exit 1; }

echo "$VERSION" > VERSION
git diff --quiet VERSION || git commit -m "Release $VERSION" VERSION
./scripts/bundle.sh release
BUILD="$(git rev-list --count HEAD)"

ZIP="build/Terminaly-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Terminaly.app "$ZIP"
cp "$ZIP" build/Terminaly.zip   # stable name for install.sh (releases/latest/download/Terminaly.zip)
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$ZIP")"   # sparkle:edSignature="…" length="…"

cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Terminaly</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Terminaly-$VERSION.zip"
                 type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML

git tag "$TAG"
git push origin main "$TAG"
gh release create "$TAG" "$ZIP" build/Terminaly.zip build/appcast.xml --repo "$REPO" --title "Terminaly $VERSION" --notes "$NOTES"
echo "Released $TAG (build $BUILD)"
