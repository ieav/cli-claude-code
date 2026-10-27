#!/bin/zsh
# Build release artifacts for all supported targets into dist/.
# Usage: ./release.sh [version]   (defaults to the version in src banner)
set -e
cd "$(dirname "$0")"

VERSION="${1:-$(rg -o 'Ziv v[0-9.]+' src/repl.zig | head -1 | rg -o '[0-9.]+')}"
OUT="dist/ziv-v$VERSION"
rm -rf "dist"
 mkdir -p "$OUT"

targets=(
  "aarch64-macos"
  "x86_64-macos"
  "x86_64-linux-musl"
  "aarch64-linux-musl"
)

for t in $targets; do
  echo "── building $t (ReleaseFast)…"
  zig build -Doptimize=ReleaseFast -Dstrip=true -Dtarget="$t"
  cp zig-out/bin/ziv "$OUT/ziv-$t"
done

echo "── checksums…"
cd "$OUT"
shasum -a 256 ziv-* > SHA256SUMS.txt
cd - >/dev/null

echo "── done:"
ls -lh "$OUT"
