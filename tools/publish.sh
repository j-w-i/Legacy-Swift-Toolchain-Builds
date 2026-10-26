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
# Environment: GITHUB_TOKEN with repo scope (falls back to `gh auth token`), python3, tar, shasum.
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

# Refuse to publish a non-relocatable archive: exactly one .xctoolchain root and no absolute symlinks.
for asset in "$COMPILER_ASSET" "$RUNTIME_ASSET"; do
  listing="$(tar tzf "$STAGE/$asset")"
  roots="$(printf '%s\n' "$listing" | cut -d/ -f1 | sort -u)"
  [ "$(printf '%s\n' "$roots" | wc -l | tr -d ' ')" = "1" ] || die "$asset must contain exactly one top-level entry"
  case "$roots" in *.xctoolchain) ;; *) die "$asset top-level entry is not a .xctoolchain" ;; esac
done
echo "archive sizes: $(du -h "$STAGE/$COMPILER_ASSET" "$STAGE/$RUNTIME_ASSET" | awk '{printf "%s %s  ", $1, $2}')"

SHAS="$(cd "$STAGE" && shasum -a 256 "$COMPILER_ASSET" "$RUNTIME_ASSET")"
printf '%s\n' "$SHAS"

BODY="From-source build of the dual iOS 5/6 Swift toolchains.

- $COMPILER_ASSET: Swift 5.10.1 compiler and source-built iOS stdlib (armv7/armv7s/arm64) with the opt-in iOS 5 resource tree.
- $RUNTIME_ASSET: from-source Swift 5.1.5 runtime for the iOS 6 guide route (no __atomic_* imports).

Produced by j-w-i/Swift-5.10.1-for-iOS-5-6 utils/legacy-ios5-mac/build-all.sh. Device execution remains unverified; iOS 5 is statically qualified."
if [ -n "$NOTES_FILE" ]; then BODY="$(cat "$NOTES_FILE")"; fi

echo "creating release $TAG in $REPO"
python3 - "$REPO" "$TAG" "$BODY" "$TOKEN" > "$STAGE/release.json" <<'PY'
import json, sys, urllib.request
repo, tag, body, token = sys.argv[1:5]
request = urllib.request.Request(
    "https://api.github.com/repos/%s/releases" % repo,
    data=json.dumps({"tag_name": tag, "name": tag, "body": body, "draft": False, "prerelease": False}).encode(),
    headers={"Authorization": "token " + token, "Accept": "application/vnd.github+json",
             "Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request) as response:
    print(response.read().decode())
PY
RELEASE_ID="$(python3 -c "import json;print(json.load(open('$STAGE/release.json'))['id'])")"
[ -n "$RELEASE_ID" ] || die "release creation failed"
echo "release id $RELEASE_ID; uploading assets"

for asset in "$COMPILER_ASSET" "$RUNTIME_ASSET"; do
  file="$STAGE/$asset"
  echo "uploading $asset ($(du -h "$file" | cut -f1))"
  python3 - "$REPO" "$RELEASE_ID" "$file" "$asset" "$TOKEN" <<'PY'
import os, sys, urllib.request
repo, release_id, path, name, token = sys.argv[1:6]
size = os.path.getsize(path)
headers = {"Authorization": "token " + token, "Content-Type": "application/gzip",
           "Content-Length": str(size), "Accept": "application/vnd.github+json"}
request = urllib.request.Request(
    "https://uploads.github.com/repos/%s/releases/%s/assets?name=%s" % (repo, release_id, name),
    headers=headers, method="POST")
# Stream the body instead of loading a multi-hundred-MB archive into memory.
with open(path, "rb") as payload:
    request.data = payload
    with urllib.request.urlopen(request) as response:
        print("  uploaded", name, str(response.status))
PY
done

echo "refreshing local manifest from the uploaded archives"
"$HERE/make-manifest.sh" --assets "$STAGE" --output "$HERE/../release-manifest.json" || {
  echo "publish: assets uploaded, but manifest refresh failed; run tools/make-manifest.sh --latest" >&2
  exit 1
}

echo
echo "Published $TAG."
echo "  manifest: https://raw.githubusercontent.com/$REPO/main/release-manifest.json"
echo "  release:  https://github.com/$REPO/releases/tag/$TAG"
echo "The release also triggers .github/workflows/manifest.yml, which commits the same manifest if it changed."
echo "Commit and push release-manifest.json so the kit's 'latest' sees the new hashes:"
echo "  git add release-manifest.json && git commit -m 'Update release manifest for $TAG' && git push"
