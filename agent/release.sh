#!/bin/zsh
# Build release artifacts for all supported targets into dist/.
# Produces: per-target binaries + tar.gz, macOS .pkg (universal), Linux .deb
#           (if dpkg-deb available), offline install.sh, SHA256SUMS.
# Usage: ./release.sh [version]   (defaults to the version in src banner)
set -e
cd "$(dirname "$0")"

REPL_V=$(rg -o 'Ziv v[0-9.]+' src/repl.zig | head -1 | rg -o '[0-9.]+')
MAIN_V=$(rg -o 'Agent v[0-9.]+' src/main.zig | head -1 | rg -o '[0-9.]+')
VERSION="${1:-$REPL_V}"
# 防呆：两处版本串不一致、或显式传参与 banner 不符 → 拒绝构建，避免"目录 vX、程序自报 vY"
if [ "$REPL_V" != "$MAIN_V" ] || { [ -n "${1:-}" ] && [ "$1" != "$REPL_V" ]; }; then
  echo "✗ version mismatch: repl.zig='$REPL_V' main.zig='$MAIN_V' arg='${1:-none}'"
  echo "  bump BOTH version strings, then rerun:"
  echo "    src/main.zig:110  startup banner   (Agent vX.Y.Z)"
  echo "    src/repl.zig:713  /version output  (Ziv vX.Y.Z — release.sh reads this)"
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
cd "$OUT"
files=()
for f in *(N); do [[ "$f" == SHA256SUMS.txt ]] || files+=("$f"); done
shasum -a 256 "${files[@]}" > SHA256SUMS.txt
cd - >/dev/null

echo "── done:"
ls -lh "$OUT"
