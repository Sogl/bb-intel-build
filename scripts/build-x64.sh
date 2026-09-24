#!/usr/bin/env bash
# Clone upstream bb at a desktop-v* tag, apply the Intel patch, build the
# x86_64 desktop app, and verify every darwin native addon is x86_64.
#
# Usage: scripts/build-x64.sh <desktop-vX.Y.Z>
# Output: <work>/bb/apps/desktop/release/{bb-*-x64.dmg,bb-*-x64.zip}
set -euo pipefail

TAG="${1:?usage: build-x64.sh <desktop-vX.Y.Z>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_FILE="$REPO_ROOT/bb-intel-local.patch"
[ -f "$PATCH_FILE" ] || { echo "missing $PATCH_FILE"; exit 1; }

WORK="${BB_INTEL_WORKDIR:-$(mktemp -d /tmp/bb-intel-XXXX)}"
mkdir -p "$WORK"
cd "$WORK"
echo "::group::Clone upstream at $TAG"
rm -rf bb
git clone --depth 1 --branch "$TAG" https://github.com/get-bb/bb bb
cd bb
echo "::endgroup::"

echo "::group::Apply bb-intel-local.patch"
git apply --check "$PATCH_FILE"
git apply "$PATCH_FILE"
git status --short
echo "::endgroup::"

echo "::group::pnpm install"
corepack enable
pnpm --version
node --version
pnpm install
echo "::endgroup::"

echo "::group::Build x64 desktop app ($TAG)"
cd apps/desktop
# Deterministic unsigned build: no keychain probing, no notarization.
CSC_IDENTITY_AUTO_DISCOVERY=false pnpm run dist:x64
echo "::endgroup::"

APP="release/mac/bb.app"
echo "::group::Verify x86_64 binaries"
file "$APP/Contents/MacOS/bb"
file "$APP/Contents/MacOS/bb" | grep -q "x86_64" \
  || { echo "FAIL: Electron executable is not x86_64"; exit 1; }

REQUIRED_NODES=(
  "node_modules/better-sqlite3/prebuilds/darwin-x64.node"
  "node_modules/node-pty/prebuilds/darwin-x64/pty.node"
  "node_modules/node-pty/prebuilds/darwin-x64/spawn-helper"
  "node_modules/@parcel/watcher-darwin-x64/watcher.node"
  "node_modules/fs-native-extensions/prebuilds/darwin-x64/fs-native-extensions.node"
)
UNPACKED="$(cd "$APP/Contents/Resources/app.asar.unpacked" && pwd)"
for rel in "${REQUIRED_NODES[@]}"; do
  f="$UNPACKED/$rel"
  [ -f "$f" ] || { echo "FAIL: missing $rel"; exit 1; }
  file "$f"
  file "$f" | grep -q "x86_64" || { echo "FAIL: $rel is not x86_64"; exit 1; }
done

# Functional check: load better-sqlite3 + node-pty under the packaged Electron.
export ELECTRON_RUN_AS_NODE=1
"$APP/Contents/MacOS/bb" -e "
  const Database = require('$UNPACKED/node_modules/better-sqlite3');
  const db = new Database(':memory:');
  if (db.prepare('SELECT 1 AS v').get().v !== 1) throw new Error('sqlite fail');
  db.close();
  const pty = require('$UNPACKED/node_modules/node-pty');
  const p = pty.spawn('/bin/echo', ['ok'], {name:'xterm',cols:80,rows:24,cwd:'/tmp'});
  p.onExit(({exitCode}) => process.exit(exitCode === 0 ? 0 : 1));
  setTimeout(() => process.exit(1), 10000);
"
echo "Native addon verification passed."
echo "::endgroup::"

echo "::group::Ad-hoc code sign"
# electron-builder ships the bundle unsigned (identity: null). An ad-hoc
# signature is not a Gatekeeper bypass — downloads still need `xattr -dr` —
# but a validly signed bundle avoids syspolicyd provenance-tracking every exec
# in the app's process tree (server, host-daemon, watcher, pty helpers).
# Same entitlements as upstream (jit, unsigned-exec-mem, lib-validation off).
codesign --deep --force --options runtime \
  --entitlements build/entitlements.mac.plist \
  --sign - "$APP"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Signature=adhoc|TeamIdentifier"
echo "::endgroup::"

echo "::group::Repack signed artifacts"
# The dmg/zip electron-builder produced contain the unsigned app; rebuild them
# from the signed bundle so both artifacts carry the ad-hoc signature.
VER="$(node -p "require('./package.json').version")"
rm -f release/*-x64.zip release/*-x64.dmg release/*.blockmap
ditto -c -k --sequesterRsrc --keepParent "$APP" "release/bb-${VER}-x64.zip"
DMG_STAGE="$(mktemp -d /tmp/bb-dmg-XXXX)"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "bb ${VER}" -srcfolder "$DMG_STAGE" -ov -format UDZO \
  "release/bb-${VER}-x64.dmg"
rm -rf "$DMG_STAGE"
echo "::endgroup::"

echo "::group::Artifacts"
ls -lh release/*.dmg release/*.zip
( cd release && shasum -a 256 *.dmg *.zip | tee SHA256SUMS.txt )
echo "BB_INTEL_RELEASE_DIR=$(cd release && pwd)"
echo "::endgroup::"
