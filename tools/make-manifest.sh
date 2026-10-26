#!/bin/bash
# Regenerate release-manifest.json from the assets of a GitHub release.
#
# Usage: tools/make-manifest.sh [--latest | --tag TAG] [--assets DIR] [--output FILE]
#
#   --latest        hash the newest release's assets (default; matches "tag": "latest")
#   --tag TAG       hash a specific release's assets instead
#   --assets DIR    hash the two archives already present in DIR instead of downloading them
#   --output FILE   manifest path (default: release-manifest.json)
#
# Environment:
#   MANIFEST_REPOSITORY  owner/repo (default: j-w-i/Legacy-Swift-Toolchain-Builds)
#   GITHUB_TOKEN / GH_TOKEN  required to download release assets (gh CLI)
set -euo pipefail

REPO="${MANIFEST_REPOSITORY:-j-w-i/Legacy-Swift-Toolchain-Builds}"
COMPILER_ASSET=swift-5.10.1-ios5.xctoolchain.tar.gz
RUNTIME_ASSET=swift-5.1.5-ios6-runtime.xctoolchain.tar.gz
TAG=""
ASSETS_DIR=""
OUTPUT="release-manifest.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --latest) TAG=""; shift ;;
    --tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
    --assets) ASSETS_DIR="${2:?--assets needs a directory}"; shift 2 ;;
    --output) OUTPUT="${2:?--output needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "make-manifest: unknown argument: $1" >&2; exit 64 ;;
  esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -z "$ASSETS_DIR" ]; then
  command -v gh >/dev/null 2>&1 || { echo "make-manifest: gh CLI is required to download assets (or pass --assets DIR)" >&2; exit 1; }
  if [ -z "$TAG" ]; then
    TAG="$(gh release view --repo "$REPO" --json tagName --jq .tagName)"
  fi
  echo "hashing release $TAG assets from $REPO"
  gh release download "$TAG" --repo "$REPO" --dir "$TMP" --pattern "$COMPILER_ASSET" --pattern "$RUNTIME_ASSET"
  ASSETS_DIR="$TMP"
fi

for asset in "$COMPILER_ASSET" "$RUNTIME_ASSET"; do
  [ -s "$ASSETS_DIR/$asset" ] || { echo "make-manifest: missing $asset in $ASSETS_DIR" >&2; exit 1; }
done

/usr/bin/python3 - "$REPO" "$ASSETS_DIR" "$OUTPUT" <<'PY'
import hashlib, json, pathlib, sys
repo, assets, output = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
def sha256(name):
    digest = hashlib.sha256()
    with (assets / name).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()
manifest = {
    "schemaVersion": 1,
    "toolchains": {
        "5.10.1": {
            "github": {"repository": repo, "tag": "latest",
                       "asset": "swift-5.10.1-ios5.xctoolchain.tar.gz"},
            "format": "tar.gz",
            "sha256": sha256("swift-5.10.1-ios5.xctoolchain.tar.gz"),
        },
        "5.1.5": {
            "github": {"repository": repo, "tag": "latest",
                       "asset": "swift-5.1.5-ios6-runtime.xctoolchain.tar.gz"},
            "format": "tar.gz",
            "sha256": sha256("swift-5.1.5-ios6-runtime.xctoolchain.tar.gz"),
        },
    },
}
output.write_text(json.dumps(manifest, indent=2) + "\n")
print("wrote " + str(output))
for version, entry in manifest["toolchains"].items():
    print("  " + version + "  " + entry["sha256"] + "  " + entry["github"]["asset"])
PY
