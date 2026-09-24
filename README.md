# bb-intel-build

Unofficial Intel (x86_64) builds of [get-bb/bb](https://github.com/get-bb/bb)
desktop. Upstream ships arm64-only on purpose (PR #1627); the codebase is
arch-agnostic, so a small patch is enough.

## How it works

`.github/workflows/build-x64.yml` runs on `macos-26-intel`:

1. resolves the latest stable `desktop-v*` upstream release (or a tag given via
   workflow_dispatch);
2. clones upstream at that tag, applies `bb-intel-local.patch`;
3. `pnpm install` → `pnpm --filter @bb/desktop dist:x64`;
4. verifies the Electron executable and every darwin native addon
   (`better-sqlite3`, `node-pty`, `@parcel/watcher`, `fs-native-extensions`)
   is Mach-O x86_64, and loads better-sqlite3/node-pty under packaged Electron;
5. publishes a `x64-<tag>` release here with the dmg/zip + SHA256SUMS.

Cron runs twice a day; a build happens only when a new `desktop-v*` tag appears
and no `x64-<tag>` release exists yet.

## Install

Download `bb-*-x64.dmg` (or the `.zip`) from Releases, install, then:

```sh
xattr -dr com.apple.quarantine /Applications/bb.app
```

Builds are unsigned (no Developer ID). Auto-update is disabled inside the
build — the upstream feed only ships arm64, which cannot launch on Intel.
Updating = downloading the next `x64-*` release.

## Manual trigger

Actions → "Build bb desktop for Intel Mac" → Run workflow → optional `tag`
(e.g. `desktop-v0.43.4`) / `force` to rebuild.

## Local build (no CI)

```sh
./scripts/build-x64.sh desktop-v0.43.4
# artifacts: $BB_INTEL_WORKDIR/bb/apps/desktop/release/ (or /tmp/bb-intel-*)
```

Requires Node ≥22.19 and corepack (pnpm 9.15 is pinned by upstream's
packageManager field).
