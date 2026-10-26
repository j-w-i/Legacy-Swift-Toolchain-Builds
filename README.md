# Legacy Swift Toolchain Builds

Release assets and the **release manifest** for the dual **iOS 5 / iOS 6 Swift toolchains** used by
[Legacy-Swift-Development-Kit](https://github.com/j-w-i/Legacy-Swift-Development-Kit).

Everything here is produced by the from-source pipeline in
[Swift-5.10.1-for-iOS-5-6](https://github.com/j-w-i/Swift-5.10.1-for-iOS-5-6)
(`utils/legacy-ios5-mac/build-all.sh`). No prebuilt stdlib package is downloaded: the Swift 5.10.1 iOS
standard library (armv7/armv7s/arm64), the Swift 5.10.1 compiler, compiler-rt builtins, the Swift 5.1.5
runtime (with `atomic.c` linked in) and the legacy overlays are all compiled in that pipeline.

## Assets in each release

| Asset | What it is |
|---|---|
| `swift-5.10.1-ios5.xctoolchain.tar.gz` | The complete toolchain: Swift 5.10.1 compiler/driver/frontend and clang (from source), the source-built iOS stdlib as default resources (14 fat dylibs, armv7+armv7s+arm64; 16 modules incl. `_Concurrency`), and `usr/lib/swift_ios5` with the source-built Swift 5.1.5 runtime plus rebuilt legacy overlays (47 dylibs). Includes `ios5-assembly-receipt.json`; host binaries are ad-hoc signed. |
| `swift-5.1.5-ios6-runtime.xctoolchain.tar.gz` | Runtime-only Swift 5.1.5 toolchain for the iOS 6 guide route: 42 armv7 dylibs whose `___atomic_store`/`___atomic_load`/`___atomic_compare_exchange` symbols are defined **inside** the dylibs (`nm -u` shows zero `__atomic_*` imports), so they load on iOS 6.1.x. |
| `release-manifest.json` | The manifest the kit consumes, attached to every release and also committed to `main`. Its entries use `"tag": "latest"`, so the kit always resolves the newest release. |

Both archives contain exactly one `.xctoolchain` folder with no absolute or escaping symlinks, so the kit's
local import and its GitHub download path both accept them.

## Use it in the kit

1. Open **Legacy Swift Development Kit** → sources.
2. Set the manifest URL to
   `https://github.com/j-w-i/Legacy-Swift-Toolchain-Builds/releases/latest/download/release-manifest.json`
   This stable URL always redirects to the manifest attached to the newest release, so it never serves a
   stale hash after a new build is published. (The committed copy at
   `https://raw.githubusercontent.com/j-w-i/Legacy-Swift-Toolchain-Builds/main/release-manifest.json`
   is equivalent, but raw.githubusercontent.com caches for a few minutes.) You can also choose a local copy
   of `release-manifest.json`.
3. Select your Xcode 13.4.1 source and click **Install Environment**. The kit downloads both assets from
   the newest release, verifies each SHA-256 from the manifest before extracting, imports both toolchains,
   and then runs the iOS 5 qualification automatically.

Alternatively import the two archives as local sources if you do not want the kit to reach the network.
Requirements are the kit's: macOS 12+, an Xcode 13.4.1 `.app`/`.xip` source for the environment, and about
64 GiB free while staging.

## Manifest

```json
{
  "schemaVersion": 1,
  "toolchains": {
    "5.10.1": {
      "github": {
        "repository": "j-w-i/Legacy-Swift-Toolchain-Builds",
        "tag": "latest",
        "asset": "swift-5.10.1-ios5.xctoolchain.tar.gz"
      },
      "format": "tar.gz",
      "sha256": "<64 hex digits>"
    },
    "5.1.5": {
      "github": {
        "repository": "j-w-i/Legacy-Swift-Toolchain-Builds",
        "tag": "latest",
        "asset": "swift-5.1.5-ios6-runtime.xctoolchain.tar.gz"
      },
      "format": "tar.gz",
      "sha256": "<64 hex digits>"
    }
  }
}
```

`release-manifest.json` is regenerated automatically and attached to every release. `.github/workflows/manifest.yml` runs
whenever a release is published (or manually via **Actions → release manifest → Run workflow**), hashes the
assets of the latest release, rewrites the manifest, and commits it if anything changed. Because the
manifest points at `"tag": "latest"`, publishing a new release makes the kit pick it up without any other
edit; the workflow only has to refresh the two SHA-256 values (and re-attach the manifest asset).

## Publish a new build

From a machine that just ran the from-source pipeline:

```bash
# LEGACY_BUILD_ROOT is the build root passed to build-all.sh
GITHUB_TOKEN=<token with repo scope> \
  tools/publish.sh --build-root "$LEGACY_BUILD_ROOT"
```

`publish.sh` packages `out/swift-5.10.1-ios5.xctoolchain` and
`out/swift-5.1.5-ios6-runtime.xctoolchain`, creates a release tagged `v<UTC date and time>`, uploads both
assets, adds `release-manifest.json`, and only then publishes the release (a draft is used so a release is
never visible before its assets). Publishing also triggers the workflow, which re-hashes the assets,
re-attaches the manifest and commits the updated copy, so new builds become the kit's `latest`
automatically.

You can also do it by hand: create a release on GitHub, attach the two assets with these exact names,
publish it (`gh release create <tag> swift-5.10.1-ios5.xctoolchain.tar.gz
swift-5.1.5-ios6-runtime.xctoolchain.tar.gz`), and let the workflow update the manifest.

`tools/make-manifest.sh --latest` can always be run locally to recompute the manifest from the current
release (`gh` CLI, or `GITHUB_TOKEN`, required to download the assets).

## Notes and limitations

- **Shipped runtime is Swift 5.1.5 on purpose.** 5.10.1 provides the compiler and compile-time module tree;
  the dylibs packaged into apps are the from-source 5.1.5 ones, which is what runs on iOS 5/6.
- **Device execution is recorded as `pending`.** The iOS 5 path is statically qualified (class marking;
  iOS 5.0 `LC_UNIXTHREAD` executable without `LC_MAIN`; default 7.0 `LC_MAIN` link; import closure; host
  signatures) and the iOS 6 runtime is known to trap if it imports C11 atomics, which these dylibs do not.
  Only a real iOS 5.1.1 / 6.1.6 device run proves launch.
- **Not the stock swift.org 5.1.5 package.** Do not substitute it: the stock dylibs import
  `___atomic_store` from libSystem and fail in dyld on iOS 6.
- Building these takes about an hour on a 14-core Apple Silicon Mac and needs Xcode 13.4.1 plus the pinned
  theos SDKs. See the toolchain repository's `LEGACY-IOS5-BUILD.md` for the full procedure and the recorded
  fresh-clone proof.
