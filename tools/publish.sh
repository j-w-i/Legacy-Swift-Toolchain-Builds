#!/bin/bash
# Package the from-source toolchain build outputs, create a GitHub release, upload both assets, and
# refresh release-manifest.json locally. Publishing the release also triggers the repository workflow,
# which regenerates and commits the manifest, so the kit's "latest" resolves the new build.
#
# Usage: tools/publish.sh --build-root BUILD_ROOT [--tag TAG] [--repo OWNER/REPO] [--notes-file FILE]
#
#   --build-root   LEGACY_BUILD_ROOT used by build-all.sh (contains out/ with the two toolchains)
#   --tag          release tag (default: v<UTC date>-<UTC time>, e.g. v2026.10.26-1327)
#   --repo         owner/repo (default: j-w-i/Legacy-Swift-Toolchain-Builds)
#   --notes-file   release notes; defaults to a short generated description
#
# Environment: GITHUB_TOKEN with repo scope (falls back to `gh auth token`), python3, tar, shasum, curl.
# Network calls use the system curl so the platform trust store applies.
set -euo pipefail

REPO="${PUBLISH_REPOSITORY:-j-w-i/Legacy-Swift-Toolchain-Builds}"
BUILD_ROOT=""
TAG="v$(date -u +%Y.%m.%d-%H%M)"
NOTES_FILE=""
COMPILER_DIR=swift-5.10.1-ios5.xctoolchain
RUNTIME_DIR=swift-5.1.5-ios6-runtime.xctoolchain
COMPILER_ASSET="$COMPILER_DIR.tar.gz"
RUNTIME_ASSET="$RUNTIME_DIR.tar.gz"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CURL=/usr/bin/curl

die() { echo "publish: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --build-root) BUILD_ROOT="${2:?--build-root needs a value}"; shift 2 ;;
    --tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --notes-file) NOTES_FILE="${2:?--notes-file needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$BUILD_ROOT" ] || die "pass --build-root <LEGACY_BUILD_ROOT>"
OUT="$BUILD_ROOT/out"
[ -d "$OUT/$COMPILER_DIR" ] || die "missing $OUT/$COMPILER_DIR; run build-all.sh first"

TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then TOKEN="$(gh auth token)"; fi
[ -n "$TOKEN" ] || die "set GITHUB_TOKEN (repo scope) or authenticate the gh CLI"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "packaging $COMPILER_ASSET"
tar -czf "$STAGE/$COMPILER_ASSET" -C "$OUT" "$COMPILER_DIR"
if [ -s "$OUT/$RUNTIME_ASSET" ]; then
  cp "$OUT/$RUNTIME_ASSET" "$STAGE/$RUNTIME_ASSET"
else
  [ -d "$OUT/$RUNTIME_DIR" ] || die "missing both $OUT/$RUNTIME_ASSET and $OUT/$RUNTIME_DIR"
  echo "packaging $RUNTIME_ASSET"
  tar -czf "$STAGE/$RUNTIME_ASSET" -C "$OUT" "$RUNTIME_DIR"
fi

# Refuse to publish something the kit would reject: exactly one .xctoolchain root per archive.
for asset in "$COMPILER_ASSET" "$RUNTIME_ASSET"; do
  roots="$(tar tzf "$STAGE/$asset" | cut -d/ -f1 | sort -u)"
  [ "$(printf '%s\n' "$roots" | wc -l | tr -d ' ')" = "1" ] || die "$asset must contain exactly one top-level entry"
  case "$roots" in *.xctoolchain) ;; *) die "$asset top-level entry is not a .xctoolchain" ;; esac
done
echo "archive sizes:"
du -h "$STAGE/$COMPILER_ASSET" "$STAGE/$RUNTIME_ASSET" | sed 's/^/  /'

SHAS="$(cd "$STAGE" && shasum -a 256 "$COMPILER_ASSET" "$RUNTIME_ASSET")"
printf '%s\n' "$SHAS" | sed 's/^/  /'

BODY="From-source build of the dual iOS 5/6 Swift toolchains.

- $COMPILER_ASSET: Swift 5.10.1 compiler and source-built iOS stdlib (armv7/armv7s/arm64) with the opt-in iOS 5 resource tree.
- $RUNTIME_ASSET: from-source Swift 5.1.5 runtime for the iOS 6 guide route (no __atomic_* imports).

Produced by j-w-i/Swift-5.10.1-for-iOS-5-6 utils/legacy-ios5-mac/build-all.sh. Device execution remains unverified; iOS 5 is statically qualified."
if [ -n "$NOTES_FILE" ]; then BODY="$(cat "$NOTES_FILE")"; fi

/usr/bin/python3 - "$TAG" "$BODY" > "$STAGE/release-body.json" <<'JSON'
import json, sys
tag, body = sys.argv[1], sys.argv[2]
print(json.dumps({"tag_name": tag, "name": tag, "body": body, "draft": True, "prerelease": False}))
JSON

echo "creating release $TAG in $REPO"
STATUS="$("$CURL" -sS -o "$STAGE/release.json" -w '%{http_code}' -X POST \
  -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" --data-binary @"$STAGE/release-body.json" \
  "https://api.github.com/repos/$REPO/releases")"
if [ "$STATUS" != "201" ]; then
  echo "release creation failed (HTTP $STATUS):" >&2
  cat "$STAGE/release.json" >&2
  die "nothing was published"
fi
RELEASE_ID="$(/usr/bin/python3 -c "import json;print(json.load(open('$STAGE/release.json'))['id'])")"
[ -n "$RELEASE_ID" ] || die "release creation returned no id"
echo "release id $RELEASE_ID"

for asset in "$COMPILER_ASSET" "$RUNTIME_ASSET"; do
  echo "uploading $asset ($(du -h "$STAGE/$asset" | cut -f1 | tr -d ' '))"
  STATUS="$("$CURL" -sS -o "$STAGE/upload.json" -w '%{http_code}' --retry 2 -X POST \
    -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/gzip" --data-binary @"$STAGE/$asset" \
    "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$asset")"
  if [ "$STATUS" != "201" ]; then
    echo "upload of $asset failed (HTTP $STATUS):" >&2
    cat "$STAGE/upload.json" >&2
    die "release $TAG exists but its assets are incomplete; delete it and retry"
  fi
done

echo "refreshing release-manifest.json from the packaged archives"
"$HERE/make-manifest.sh" --assets "$STAGE" --output "$HERE/../release-manifest.json"

# The stable manifest URL is https://github.com/<repo>/releases/latest/download/release-manifest.json,
# which GitHub redirects to the newest release's asset. Attach it before publishing so a just-published
# release never lacks its manifest.
echo "uploading release-manifest.json"
STATUS="$("$CURL" -sS -o "$STAGE/upload.json" -w '%{http_code}' --retry 2 -X POST \
  -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" --data-binary @"$HERE/../release-manifest.json" \
  "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=release-manifest.json")"
if [ "$STATUS" != "201" ]; then
  echo "upload of release-manifest.json failed (HTTP $STATUS):" >&2
  cat "$STAGE/upload.json" >&2
  die "release $TAG is a draft without its manifest; delete it and retry"
fi

# Publish only once every asset is attached: a release published before its assets exist makes the
# manifest workflow run with nothing to hash. Create it as a draft, upload, then publish.
echo "publishing release $RELEASE_ID"
STATUS="$("$CURL" -sS -o "$STAGE/publish.json" -w '%{http_code}' -X PATCH \
  -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" --data-binary '{"draft":false}' \
  "https://api.github.com/repos/$REPO/releases/$RELEASE_ID")"
if [ "$STATUS" != "200" ]; then
  echo "publishing the release failed (HTTP $STATUS):" >&2
  cat "$STAGE/publish.json" >&2
  die "release $TAG is still a draft with its assets; publish it manually or delete it and retry"
fi

echo
echo "Published $TAG"
echo "  manifest (stable): https://github.com/$REPO/releases/latest/download/release-manifest.json"
echo "  manifest (committed copy): https://raw.githubusercontent.com/$REPO/main/release-manifest.json"
echo "  release:  https://github.com/$REPO/releases/tag/$TAG"
echo "The release also triggers .github/workflows/manifest.yml. Commit and push the updated manifest:"
echo "  git add release-manifest.json && git commit -m 'Update release manifest for $TAG' && git push"
