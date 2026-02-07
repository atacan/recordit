#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PRODUCT_NAME="record"
GITHUB_USER="atacan"
GITHUB_REPO="record"
TAP_REPO="homebrew-tap"
SOURCE_FILE="Sources/record/record.swift"

# ─────────────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────────────
FORMULA_ONLY=false

if [[ "${1:-}" == "--formula-only" ]]; then
    FORMULA_ONLY=true
    shift
fi

VERSION="${1:?Usage: ./release.sh [--formula-only] <version>}"
TAG="v${VERSION}"
ARCHIVE_DIR="$SCRIPT_DIR/.build/release/archives"
PLATFORMS="macos-arm64 macos-amd64"

echo "=== Releasing ${PRODUCT_NAME} ${TAG} ==="

# ─────────────────────────────────────────────────────────────────
# Pre-flight checks (skip for --formula-only)
# ─────────────────────────────────────────────────────────────────
if [[ "$FORMULA_ONLY" == false ]]; then
    command -v gh >/dev/null || { echo "Error: gh CLI required"; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "Error: gh not authenticated"; exit 1; }
    [[ -z "$(git status --porcelain)" ]] || { echo "Error: Working tree dirty"; exit 1; }
    ! git rev-parse "$TAG" >/dev/null 2>&1 || { echo "Error: Tag $TAG already exists"; exit 1; }
fi

# ─────────────────────────────────────────────────────────────────
# Full release path
# ─────────────────────────────────────────────────────────────────
if [[ "$FORMULA_ONLY" == false ]]; then
    echo ""
    echo "==> Updating version to ${VERSION}..."
    sed -i '' 's/^let appVersion = ".*"/let appVersion = "'"$VERSION"'"/' "$SOURCE_FILE"
    grep "let appVersion" "$SOURCE_FILE"

    echo ""
    echo "==> Building..."
    ./build-macos.sh

    echo ""
    echo "==> Creating archives..."
    rm -rf "$ARCHIVE_DIR"
    mkdir -p "$ARCHIVE_DIR"
    for platform in $PLATFORMS; do
        tmpdir="$(mktemp -d)"
        cp ".build/release/${PRODUCT_NAME}-${platform#macos-}" "$tmpdir/${PRODUCT_NAME}"
        tar -czf "$ARCHIVE_DIR/${PRODUCT_NAME}-${VERSION}-${platform}.tar.gz" -C "$tmpdir" "$PRODUCT_NAME"
        rm -rf "$tmpdir"
    done

    echo ""
    echo "==> Committing and tagging..."
    git add "$SOURCE_FILE"
    git commit -m "Release ${TAG}"
    git tag -a "$TAG" -m "Release ${TAG}"
    git push origin main "$TAG"

    echo ""
    echo "==> Creating GitHub release..."
    gh release create "$TAG" "$ARCHIVE_DIR"/*.tar.gz \
        --repo "${GITHUB_USER}/${GITHUB_REPO}" \
        --title "$TAG" \
        --generate-notes
fi

# ─────────────────────────────────────────────────────────────────
# Formula generation (both paths)
# ─────────────────────────────────────────────────────────────────

# For --formula-only, download archives from existing release
if [[ "$FORMULA_ONLY" == true ]]; then
    rm -rf "$ARCHIVE_DIR"
    mkdir -p "$ARCHIVE_DIR"
    gh release download "$TAG" --repo "${GITHUB_USER}/${GITHUB_REPO}" --dir "$ARCHIVE_DIR"
fi

echo ""
echo "==> Computing checksums..."
SHA_ARM64="$(shasum -a 256 "$ARCHIVE_DIR/${PRODUCT_NAME}-${VERSION}-macos-arm64.tar.gz" | awk '{print $1}')"
SHA_AMD64="$(shasum -a 256 "$ARCHIVE_DIR/${PRODUCT_NAME}-${VERSION}-macos-amd64.tar.gz" | awk '{print $1}')"
echo "  arm64:  $SHA_ARM64"
echo "  amd64:  $SHA_AMD64"

echo ""
echo "==> Updating Homebrew formula..."
TAP_DIR="/tmp/${TAP_REPO}"
if [[ -d "$TAP_DIR" ]]; then
    git -C "$TAP_DIR" fetch origin
    git -C "$TAP_DIR" reset --hard origin/main
else
    gh repo clone "${GITHUB_USER}/${TAP_REPO}" "$TAP_DIR"
fi

mkdir -p "$TAP_DIR/Formula"

cat > "$TAP_DIR/Formula/${PRODUCT_NAME}.rb" << EOF
class Record < Formula
  desc "Record audio, screen, or camera output from the terminal"
  homepage "https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
  version "${VERSION}"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/${GITHUB_USER}/${GITHUB_REPO}/releases/download/${TAG}/${PRODUCT_NAME}-${VERSION}-macos-arm64.tar.gz"
      sha256 "${SHA_ARM64}"
    end
    on_intel do
      url "https://github.com/${GITHUB_USER}/${GITHUB_REPO}/releases/download/${TAG}/${PRODUCT_NAME}-${VERSION}-macos-amd64.tar.gz"
      sha256 "${SHA_AMD64}"
    end
  end

  def install
    bin.install "${PRODUCT_NAME}"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/${PRODUCT_NAME} --version")
  end
end
EOF

git -C "$TAP_DIR" add "Formula/${PRODUCT_NAME}.rb"
git -C "$TAP_DIR" commit -m "${PRODUCT_NAME} ${VERSION}"
git -C "$TAP_DIR" push origin main

echo ""
echo "=== Release ${TAG} complete ==="
echo "Install with: brew install ${GITHUB_USER}/tap/${PRODUCT_NAME}"
