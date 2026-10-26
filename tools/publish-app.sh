#!/bin/bash
# Publish a built Legacy Swift Development Kit .app as a public download.
#
# The app lives in the (private) kit source repository, so its own releases are not reachable without
# credentials. This script publishes the packaged app to the public distribution repository under a
# fixed tag, so the URL stays stable across builds:
#
#   https://github.com/j-w-i/Legacy-Swift-Toolchain-Builds/releases/download/app-latest/Legacy-Swift-Development-Kit.app.zip
#
# Usage: tools/publish-app.sh --app "/path/to/Legacy Swift Development Kit.app" [--repo OWNER/REPO] [--tag app-latest]
#
# Environment: GITHUB_TOKEN with repo scope (falls back to `gh auth token`). The app is ad-hoc signed by
# build.sh; it is not Developer ID signed or notarized, so Gatekeeper requires a one-time user approval.
set -euo pipefail

APP=""
REPO="${PUBLISH_REPOSITORY:-j-w-i/Legacy-Swift-Toolchain-Builds}"
TAG="app-latest"
ASSET="Legacy-Swift-Development-Kit.app.zip"
CURL=/usr/bin/curl
git_credential_ready=0

die() { echo "publish-app: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:?--app needs a value}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$APP" ] || die "pass --app \"/path/to/Legacy Swift Development Kit.app\""
[ -d "$APP" ] || die "app bundle not found: $APP"
[ -x "$APP/Contents/MacOS/LegacySwiftDevelopmentKit" ] || die "not a Legacy Swift Development Kit app: $APP"
codesign --verify --strict "$APP" >/dev/null 2>&1 || die "app signature does not verify (rebuild with ./build.sh)"

TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then TOKEN="$(gh auth token)"; fi
[ -n "$TOKEN" ] || die "set GITHUB_TOKEN (repo scope) or authenticate the gh CLI"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto -c -k --keepParent "$APP" "$STAGE/$ASSET"
DIGEST="$(shasum -a 256 "$STAGE/$ASSET" | cut -d' ' -f1)"
SIZE="$(du -h "$STAGE/$ASSET" | cut -f1 | tr -d ' ')"
echo "packaged $ASSET ($SIZE) sha256=$DIGEST"

api() { # method path [data-file]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    "$CURL" -sS -X "$method" -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" --data-binary @"$body" "https://api.github.com$path"
  else
    "$CURL" -sS -X "$method" -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" "https://api.github.com$path"
  fi
}

# Resolve or create the fixed app release.
RELEASE="$("$CURL" -sSL -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/releases/tags/$TAG" 2>/dev/null || true)"
if printf '%s' "$RELEASE" | /usr/bin/python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('id') else 1)" 2>/dev/null; then
  RELEASE_ID="$(printf '%s' "$RELEASE" | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")"
  echo "using existing release $TAG ($RELEASE_ID)"
else
  BODY="{\"tag_name\":\"$TAG\",\"name\":\"Legacy Swift Development Kit (latest app)\",\"body\":\"Ad-hoc signed build of the Legacy Swift Development Kit (macOS 12+). Not notarized. See the README for requirements and the toolchain manifest URL.\",\"draft\":false,\"prerelease\":false}"
  printf '%s' "$BODY" > "$STAGE/release.json"
  RESULT="$(api POST "/repos/$REPO/releases" "$STAGE/release.json")"
  RELEASE_ID="$(printf '%s' "$RESULT" | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")"
  [ -n "$RELEASE_ID" ] || die "could not create the $TAG release: $RESULT"
  echo "created release $TAG ($RELEASE_ID)"
fi

# Replace the previous app asset (the API cannot overwrite; delete then upload the new build).
ASSET_ID="$("$CURL" -sSL -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/releases/$RELEASE_ID/assets" | /usr/bin/python3 -c "
import json,sys
assets = json.load(sys.stdin)
print(next((a['id'] for a in assets if a.get('name') == '$ASSET'), ''))")"
if [ -n "$ASSET_ID" ]; then
  api DELETE "/repos/$REPO/releases/assets/$ASSET_ID" >/dev/null
  echo "removed previous $ASSET ($ASSET_ID)"
fi

STATUS="$("$CURL" -sS -o "$STAGE/upload.json" -w '%{http_code}' --retry 2 -X POST \
  -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/zip" --data-binary @"$STAGE/$ASSET" \
  "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$ASSET")"
if [ "$STATUS" != "201" ]; then
  echo "upload failed (HTTP $STATUS):" >&2
  cat "$STAGE/upload.json" >&2
  die "the app was not published"
fi

echo
echo "Published $(basename "$APP")"
echo "  https://github.com/$REPO/releases/download/$TAG/$ASSET"
echo "  sha256 $DIGEST"
echo "Gatekeeper (ad-hoc signed, not notarized): right-click the app and choose Open, or"
echo "  xattr -dr com.apple.quarantine \"/Applications/Legacy Swift Development Kit.app\""
