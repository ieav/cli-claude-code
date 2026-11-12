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
