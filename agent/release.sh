#!/bin/zsh
# Build release artifacts for all supported targets into dist/.
# Produces: per-target binaries + tar.gz, macOS .pkg (universal), Linux .deb
#           (if dpkg-deb available), offline install.sh, SHA256SUMS.
# Usage: ./release.sh [version]   (defaults to the version in src banner)
set -e
cd "$(dirname "$0")"

# 版本单一事实源：src/util/version.zig（banner、/version、--version 都引用它）
VERSION=$(rg -o 'pub const version = "[0-9.]+"' src/util/version.zig | head -1 | rg -o '[0-9.]+')
if [ -z "${VERSION:-}" ]; then
  echo "✗ cannot read version from src/util/version.zig"
  echo "  expected: pub const version = \"X.Y.Z\";"
  exit 1
fi
# 防呆：显式传参必须与源码一致 → 拒绝"目录 vX、程序自报 vY"
if [ -n "${1:-}" ] && [ "$1" != "$VERSION" ]; then
  echo "✗ version mismatch: src/util/version.zig='$VERSION' arg='$1'"
  echo "  bump src/util/version.zig, then rerun (or omit the argument)"
  exit 1
fi
OUT="dist/ziv-v$VERSION"
rm -rf "dist"
mkdir -p "$OUT"

targets=(
  "aarch64-macos"
  "x86_64-macos"
  "x86_64-linux-musl"
  "aarch64-linux-musl"
)

for t in "${targets[@]}"; do
  echo "── building $t (ReleaseFast)…"
  zig build -Doptimize=ReleaseFast -Dstrip=true -Dtarget="$t"
  cp zig-out/bin/ziv "$OUT/ziv-$t"
done

# ── tar.gz per target (standard CLI-tool release form)
for t in "${targets[@]}"; do
  tar -czf "$OUT/ziv-$VERSION-$t.tar.gz" -C "$OUT" "ziv-$t"
done

# ── macOS .pkg installer (universal arm64+x86_64, installs to /usr/local/bin/ziv)
if command -v lipo >/dev/null && command -v pkgbuild >/dev/null; then
  STAGE=$(mktemp -d)
  mkdir -p "$STAGE/usr/local/bin"
  lipo -create "$OUT/ziv-aarch64-macos" "$OUT/ziv-x86_64-macos" -output "$STAGE/usr/local/bin/ziv"
  pkgbuild --root "$STAGE" \
    --identifier "com.ziv.ziv" \
    --version "$VERSION" \
    --install-location "/" \
    --ownership recommended \
    "$OUT/ziv-$VERSION-macos.pkg"
  rm -rf "$STAGE"
else
  echo "⚠ lipo/pkgbuild not found — skip .pkg"
fi

# ── Linux .deb packages (static binaries, no runtime deps; needs dpkg-deb on build host)
if command -v dpkg-deb >/dev/null; then
  for pair in "x86_64-linux-musl amd64" "aarch64-linux-musl arm64"; do
    t=${pair%% *}; arch=${pair##* }
    STAGE=$(mktemp -d)
    mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/local/bin"
    cp "$OUT/ziv-$t" "$STAGE/usr/local/bin/ziv"
    cat > "$STAGE/DEBIAN/control" <<EOF
Package: ziv
Version: $VERSION
Section: utils
Priority: optional
Architecture: $arch
Maintainer: ieav <ieav@local>
Description: Ziv - self-learning agent CLI in Zig
 Multi-LLM agent (Claude/OpenAI/Ollama) with memory, knowledge graph,
 tool loop, permissions, MCP and skills. Statically linked, no deps.
EOF
    dpkg-deb --build --root-owner-group "$STAGE" "$OUT/ziv_${VERSION}-1_${arch}.deb"
    rm -rf "$STAGE"
  done
else
  echo "⚠ dpkg-deb not found — skip .deb (brew install dpkg to enable)"
fi

# ── offline installer (installs the right binary from this folder)
cat > "$OUT/install.sh" <<'EOF'
#!/bin/sh
# Install ziv from this dist folder.
# Usage: ./install.sh [prefix]        install (default /usr/local, falls back to ~/.local)
#        ./install.sh uninstall [prefix]
set -e
cd "$(dirname "$0")"

if [ "$1" = "uninstall" ]; then
  DID=0
  for d in "${2:-/usr/local}/bin" "$HOME/.local/bin"; do
    if [ -f "$d/ziv" ]; then rm -f "$d/ziv"; echo "removed: $d/ziv"; DID=1; fi
  done
  [ "$DID" = 1 ] || echo "ziv binary not found under ${2:-/usr/local}/bin or ~/.local/bin"
  echo "config/data left behind (manual cleanup if unwanted):"
  echo "  ~/.config/ziv/              settings.json, mcp.json, skills/"
  echo "  .ziv/ in each working dir   memory.db, checkpoints/"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  BIN=ziv-aarch64-macos ;;
  Darwin-x86_64) BIN=ziv-x86_64-macos ;;
  Darwin-i386)   BIN=ziv-x86_64-macos ;;
  Linux-x86_64)  BIN=ziv-x86_64-linux-musl ;;
  Linux-aarch64) BIN=ziv-aarch64-linux-musl ;;
  *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
[ -f "$BIN" ] || { echo "missing $BIN in $(pwd)"; exit 1; }
PREFIX="${1:-/usr/local}"
BIN_DIR="$PREFIX/bin"
# 目录已存在时 mkdir -p 也能成功，必须再验 [ -w ] 才是真权限检查
if ! { mkdir -p "$BIN_DIR" 2>/dev/null && [ -w "$BIN_DIR" ]; }; then
  if [ $# -gt 0 ]; then
    echo "no write access to $BIN_DIR (explicit prefix, aborting)" >&2
    exit 1
  fi
  echo "no write access to $BIN_DIR — falling back to ~/.local"
  PREFIX="$HOME/.local"
  BIN_DIR="$PREFIX/bin"
  mkdir -p "$BIN_DIR"
fi
# tmp+mv 原子替换：旧版运行中也可安全覆盖升级，中断不会留下残缺二进制
TMP="$BIN_DIR/.ziv.$$"
trap 'rm -f "$TMP"' EXIT
cp "$BIN" "$TMP"
chmod 0755 "$TMP"
mv -f "$TMP" "$BIN_DIR/ziv"
trap - EXIT
echo "installed: $BIN_DIR/ziv  (data dir .ziv/ is created per working directory)"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: add $BIN_DIR to PATH" ;; esac
EOF
chmod +x "$OUT/install.sh"

# ── checksums (all artifacts in $OUT; dotfiles like .DS_Store excluded by glob)
# POSIX-portable: the old `for f in *(N)` used a zsh-only glob qualifier and
# crashed the script at this line when run via sh/bash (everything before it
# happened to be portable, so only the checksum step died).
cd "$OUT"
rm -f SHA256SUMS.txt
for f in *; do
  [ "$f" = "SHA256SUMS.txt" ] && continue
  shasum -a 256 "$f"
done > SHA256SUMS.txt
cd - >/dev/null

echo "── done:"
ls -lh "$OUT"
