#!/bin/bash
# Download the toolchains described by a release manifest.
#
# Usage: tools/download.sh [--manifest URL_OR_FILE] [--output DIR] [--no-extract]
#
#   --manifest   manifest to read (default: the stable "latest release" manifest of this repository)
#   --output     destination directory (default: ./toolchains)
#   --no-extract leave the downloaded archives as-is
#
# Each toolchain entry is resolved as described by the manifest: an explicit HTTPS `url`, or a GitHub
# release (`repository`, `tag` where "latest" means the newest release, and the exact `asset` name).
# Every download is verified against the entry's SHA-256 before extraction. Works against the public
# repository without credentials; set GITHUB_TOKEN for a private repository or higher API rate limits.
# Network calls use the system curl so the platform trust store applies.
set -euo pipefail

MANIFEST="https://github.com/j-w-i/Legacy-Swift-Toolchain-Builds/releases/latest/download/release-manifest.json"
OUTPUT="./toolchains"
EXTRACT=1
CURL=/usr/bin/curl

die() { echo "download: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:?--manifest needs a value}"; shift 2 ;;
    --output) OUTPUT="${2:?--output needs a value}"; shift 2 ;;
    --no-extract) EXTRACT=0; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MANIFEST_FILE="$TMP/manifest.json"
case "$MANIFEST" in
  https://*) "$CURL" -fsSL --retry 3 --retry-all-errors -o "$MANIFEST_FILE" "$MANIFEST" || die "could not fetch manifest: $MANIFEST" ;;
  *) [ -f "$MANIFEST" ] || die "manifest file not found: $MANIFEST"; cp "$MANIFEST" "$MANIFEST_FILE" ;;
esac

mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd -P)"

GITHUB_TOKEN="${GITHUB_TOKEN:-}" /usr/bin/python3 - "$MANIFEST_FILE" "$OUTPUT" "$EXTRACT" "$TMP" <<'PY'
import hashlib, json, os, shutil, subprocess, sys, tarfile, zipfile

manifest_path, output, extract, tmp = sys.argv[1:5]
token = os.environ.get("GITHUB_TOKEN", "")
CURL = "/usr/bin/curl"
AUTH = ["-H", "Authorization: token " + token] if token else []

def run(arguments, capture=False):
    result = subprocess.run(arguments, text=True, capture_output=capture, timeout=1800)
    if result.returncode != 0:
        raise SystemExit("download: command failed (%d): %s" % (result.returncode, " ".join(arguments)))
    return result.stdout if capture else None

def get_json(url):
    return json.loads(run([CURL, "-fsSL", "--retry", "3", "--retry-all-errors", *AUTH, url], capture=True))

def download(url, destination):
    run([CURL, "-fsSL", "--retry", "3", "--retry-all-errors", *AUTH, "-o", destination, url])

manifest = json.load(open(manifest_path))
if manifest.get("schemaVersion") != 1 or not isinstance(manifest.get("toolchains"), dict):
    raise SystemExit("download: manifest must be schemaVersion 1 with a toolchains dictionary")
if not manifest["toolchains"]:
    raise SystemExit("download: manifest has no toolchains")

verified = True
for version, entry in sorted(manifest["toolchains"].items()):
    expected = str(entry.get("sha256", "")).lower()
    fmt = entry.get("format", "tar.gz")
    if fmt not in ("zip", "tar.gz", "pkg"):
        raise SystemExit("download: %s has unsupported format %r" % (version, fmt))
    github = entry.get("github")
    direct = entry.get("url")
    if bool(github) == bool(direct):
        raise SystemExit("download: %s must use exactly one of url or github" % version)

    if github:
        repository = github.get("repository")
        tag = github.get("tag")
        asset = github.get("asset")
        route = "latest" if tag == "latest" else "tags/" + str(tag)
        release = get_json("https://api.github.com/repos/%s/releases/%s" % (repository, route))
        matches = [a for a in release.get("assets", []) if a.get("name") == asset]
        if len(matches) != 1:
            raise SystemExit("download: release %s does not contain exactly one asset named %s" % (release.get("tag_name"), asset))
        url = matches[0]["browser_download_url"]
    else:
        url = direct
        asset = os.path.basename(url.split("?")[0]) or version

    archive = os.path.join(tmp, asset)
    print("== Swift %s: %s" % (version, url))
    download(url, archive)
    digest = hashlib.sha256()
    with open(archive, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    actual = digest.hexdigest()
    if actual != expected:
        print("   SHA-256 MISMATCH: expected %s, got %s - not extracted" % (expected, actual), file=sys.stderr)
        verified = False
        continue
    print("   sha256 ok: " + actual)

    base = asset
    for suffix in (".tar.gz", ".tgz", ".zip", ".pkg"):
        if base.endswith(suffix):
            base = base[: -len(suffix)]
            break
    else:
        base = os.path.splitext(base)[0]
    if not extract:
        shutil.move(archive, os.path.join(output, asset))
        print("   saved " + os.path.join(output, asset))
        continue
    if fmt == "pkg":
        shutil.move(archive, os.path.join(output, asset))
        print("   saved " + os.path.join(output, asset) + " (pkg is not extracted; import it in the kit)")
        continue
    staging = os.path.join(tmp, "extract-" + version)
    os.makedirs(staging, exist_ok=True)
    if fmt == "tar.gz":
        with tarfile.open(archive, "r:gz") as bundle:
            bundle.extractall(staging)
    else:
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(staging)
    roots = os.listdir(staging)
    if len(roots) != 1 or not roots[0].endswith(".xctoolchain"):
        raise SystemExit("download: %s archive does not contain exactly one .xctoolchain root" % version)
    target = os.path.join(output, roots[0])
    if os.path.exists(target):
        shutil.rmtree(target)
    shutil.move(os.path.join(staging, roots[0]), target)
    print("   extracted " + target)

if not verified:
    raise SystemExit("download: one or more archives failed verification")
PY

echo
echo "Toolchains in $OUTPUT:"
ls -1 "$OUTPUT" | sed 's/^/  /'
echo
echo "Use them in the kit as local imports (the .xctoolchain folders), or point the kit at the manifest URL instead."
