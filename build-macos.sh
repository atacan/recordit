#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PRODUCT_NAME="record"
OUTPUT_DIR="$SCRIPT_DIR/.build/release"
mkdir -p "$OUTPUT_DIR"

BINARY_ARM64="$OUTPUT_DIR/${PRODUCT_NAME}-arm64"
BINARY_AMD64="$OUTPUT_DIR/${PRODUCT_NAME}-amd64"

echo "==> Building for arm64..."
swift build -c release --arch arm64
cp "$(swift build -c release --arch arm64 --show-bin-path)/${PRODUCT_NAME}" "$BINARY_ARM64"

echo ""
echo "==> Building for x86_64..."
swift build -c release --arch x86_64
cp "$(swift build -c release --arch x86_64 --show-bin-path)/${PRODUCT_NAME}" "$BINARY_AMD64"

echo ""
echo "==> Stripping debug symbols..."
strip "$BINARY_ARM64" "$BINARY_AMD64"

echo ""
echo "==> Verifying binaries..."
for bin in "$BINARY_ARM64" "$BINARY_AMD64"; do
    name="$(basename "$bin")"
    size="$(du -h "$bin" | cut -f1)"
    arch="$(lipo -archs "$bin")"
    echo "  $name: $size  [$arch]"
done

echo ""
echo "==> Testing arm64 binary..."
"$BINARY_ARM64" --version

echo ""
echo "==> Build complete."
echo "  $BINARY_ARM64"
echo "  $BINARY_AMD64"
