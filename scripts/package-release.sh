#!/bin/bash
# Package a built app for GitHub Releases.
# Usage: scripts/package-release.sh v1.0.0 [unsigned|signed]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-}"
MODE="${2:-unsigned}"
APP="$ROOT/dist/Meridian.app"
OUT="$ROOT/dist/release"

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
    echo "tag must look like v1.0.0 or v1.0.0-beta.1" >&2
    exit 1
}
[[ "$MODE" == "unsigned" || "$MODE" == "signed" ]] || {
    echo "mode must be unsigned or signed" >&2
    exit 1
}
[[ -d "$APP" ]] || {
    echo "build dist/Meridian.app first" >&2
    exit 1
}

VERSION="${TAG#v}"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" == "$PLIST_VERSION" ]] || {
    echo "tag version $VERSION does not match Info.plist version $PLIST_VERSION" >&2
    exit 1
}

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Meridian")"
[[ "$ARCHS" == "arm64" ]] || {
    echo "release packaging currently expects arm64, got: $ARCHS" >&2
    exit 1
}

codesign --verify --strict --deep "$APP"
SIGNATURE_INFO="$(codesign -dvv "$APP" 2>&1 || true)"
if [[ "$MODE" == "unsigned" ]]; then
    grep -q 'Signature=adhoc' <<<"$SIGNATURE_INFO" || {
        echo "unsigned mode requires an ad-hoc signed app; rebuild with MERIDIAN_SIGN_IDENTITY=-" >&2
        exit 1
    }
else
    grep -q 'Authority=Developer ID Application:' <<<"$SIGNATURE_INFO" || {
        echo "signed mode requires Developer ID Application" >&2
        exit 1
    }
fi

mkdir -p "$OUT"
ZIP_NAME="Meridian-${VERSION}-macOS-arm64-${MODE}.zip"
NOTES="$OUT/RELEASE_NOTES.md"
if [[ "$MODE" == "unsigned" ]]; then
    NOTES_TEMPLATE="$ROOT/docs/RELEASE_NOTES_UNSIGNED.md"
else
    NOTES_TEMPLATE="$ROOT/docs/RELEASE_NOTES_SIGNED.md"
fi
sed "s/{{VERSION}}/$VERSION/g" "$NOTES_TEMPLATE" > "$NOTES"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP_NAME"

(
    cd "$OUT"
    shasum -a 256 "$ZIP_NAME" > SHA256SUMS
)

echo "packaged $OUT/$ZIP_NAME"
echo "checksum $OUT/SHA256SUMS"
