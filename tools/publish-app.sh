#!/bin/bash
# Update only the app asset on the newest release, leaving the toolchains and manifest untouched.
# Use this for app-only changes; toolchain rebuilds go through tools/publish.sh.
#
# Usage: tools/publish-app.sh --app "/path/to/Legacy Swift Development Kit.app" [--repo OWNER/REPO]
#
# The release must already contain both toolchain assets and release-manifest.json, so a wrong "latest"
# release is never targeted. The URL stays stable:
#   https://github.com/<repo>/releases/latest/download/Legacy-Swift-Development-Kit.app.zip
#
# Environment: GITHUB_TOKEN with repo scope (falls back to `gh auth token`).
set -euo pipefail

APP=""
REPO="${PUBLISH_REPOSITORY:-j-w-i/Legacy-Swift-Toolchain-Builds}"
APP_ASSET="Legacy-Swift-Development-Kit.app.zip"
CURL=/usr/bin/curl

die() { echo "publish-app: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:?--app needs a value}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$APP" ] || die "pass --app \"/path/to/Legacy Swift Development Kit.app\""
[ -x "$APP/Contents/MacOS/LegacySwiftDevelopmentKit" ] || die "not a Legacy Swift Development Kit app: $APP"
codesign --verify --strict "$APP" >/dev/null 2>&1 || die "app signature does not verify (rebuild with ./build.sh)"

TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then TOKEN="$(gh auth token)"; fi
[ -n "$TOKEN" ] || die "set GITHUB_TOKEN (repo scope) or authenticate the gh CLI"

api() { "$CURL" -sSL -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" "$1"; }

RELEASE="$(api "https://api.github.com/repos/$REPO/releases/latest")"
RELEASE_ID="$(printf '%s' "$RELEASE" | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin).get('id',''))")"
[ -n "$RELEASE_ID" ] || die "no published release found in $REPO"
TAG="$(printf '%s' "$RELEASE" | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin).get('tag_name',''))")"
NAMES="$(printf '%s' "$RELEASE" | /usr/bin/python3 -c "import json,sys;print('\n'.join(a['name'] for a in json.load(sys.stdin).get('assets',[])))")"
for required in swift-5.10.1-ios5.xctoolchain.tar.gz swift-5.1.5-ios6-runtime.xctoolchain.tar.gz release-manifest.json; do
  printf '%s\n' "$NAMES" | grep -qx "$required" || die "latest release $TAG lacks $required; refusing to treat it as a distribution release"
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto -c -k --keepParent "$APP" "$STAGE/$APP_ASSET"
DIGEST="$(shasum -a 256 "$STAGE/$APP_ASSET" | cut -d' ' -f1)"
echo "packaged $APP_ASSET ($(du -h "$STAGE/$APP_ASSET" | cut -f1 | tr -d ' ')) sha256=$DIGEST"

PREVIOUS="$(printf '%s' "$RELEASE" | /usr/bin/python3 -c "
import json, sys
print(next((a['id'] for a in json.load(sys.stdin).get('assets', []) if a.get('name') == '$APP_ASSET'), ''))")"
if [ -n "$PREVIOUS" ]; then
  STATUS="$("$CURL" -sS -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: token $TOKEN" "https://api.github.com/repos/$REPO/releases/assets/$PREVIOUS")"
  [ "$STATUS" = "204" ] || die "could not remove the previous app asset (HTTP $STATUS)"
  echo "removed the previous app asset"
fi

STATUS="$("$CURL" -sS -o "$STAGE/upload.json" -w '%{http_code}' --retry 2 -X POST \
  -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/zip" --data-binary @"$STAGE/$APP_ASSET" \
  "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$APP_ASSET")"
if [ "$STATUS" != "201" ]; then
  echo "upload failed (HTTP $STATUS):" >&2
  cat "$STAGE/upload.json" >&2
  die "the app was not updated"
fi

echo
echo "Updated the app in release $TAG"
echo "  https://github.com/$REPO/releases/latest/download/$APP_ASSET"
echo "  sha256 $DIGEST"
echo "Gatekeeper (ad-hoc signed, not notarized): right-click -> Open, or"
echo "  xattr -dr com.apple.quarantine \"/Applications/Legacy Swift Development Kit.app\""
