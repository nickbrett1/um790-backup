#!/usr/bin/env bash
# Install the PINNED restic binary into the image.
#
# Why a pinned tarball and not apt: bookworm ships restic 0.14, and the design
# needs >= 0.19 semantics (and `check --read-data-subset`). Why not install it
# from the entrypoint at run time: the CI smoke gate runs the image with
# `--dry-run` on every push, and a 25 MB download there makes the gate slow and
# network-dependent. Installing at build time keeps the gate offline and cheap.
#
# VERSION AND CHECKSUM ARE PINNED TOGETHER. Never track "latest". The archive is
# verified against the release's own SHA256SUMS before it is unpacked.
set -euo pipefail

VERSION="0.18.1"
INSTALL_DIR="${RESTIC_INSTALL_DIR:-/usr/local/bin}"
BIN="$INSTALL_DIR/restic"

if [ -x "$BIN" ] && [ "$("$BIN" version 2>/dev/null | awk '{print $2}')" = "$VERSION" ]; then
  echo "INFO: restic $VERSION already installed at $BIN"
  exit 0
fi

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64 | Linux/amd64) ASSET="restic_${VERSION}_linux_amd64" ;;
  Linux/aarch64 | Linux/arm64) ASSET="restic_${VERSION}_linux_arm64" ;;
  *)
    echo "ERROR: no pinned restic $VERSION asset for $(uname -s)/$(uname -m)." >&2
    echo "ERROR: add the asset here rather than falling back to latest." >&2
    exit 1
    ;;
esac

# restic publishes one compressed binary per platform, not a tarball.
BASE_URL="https://github.com/restic/restic/releases/download/v${VERSION}"

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    echo "ERROR: neither curl nor wget is available; cannot download restic." >&2
    exit 1
  fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR:?}"' EXIT

echo "INFO: Downloading restic $VERSION ($ASSET)..."
fetch "${BASE_URL}/${ASSET}.bz2" "$TMP_DIR/restic.bz2"
fetch "${BASE_URL}/SHA256SUMS" "$TMP_DIR/SHA256SUMS"

# Restrict the manifest to our asset: it lists every platform, so checking the
# whole file would fail on the ones we did not download.
if ! grep -E "  ${ASSET}\.bz2\$" "$TMP_DIR/SHA256SUMS" > "$TMP_DIR/CHECKSUM"; then
  echo "ERROR: ${ASSET}.bz2 is not listed in this release's SHA256SUMS." >&2
  exit 1
fi

# The manifest names files by basename, so verify from inside TMP_DIR.
if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$TMP_DIR" && mv restic.bz2 "${ASSET}.bz2" && sha256sum -c CHECKSUM ) >/dev/null
elif command -v shasum >/dev/null 2>&1; then
  ( cd "$TMP_DIR" && mv restic.bz2 "${ASSET}.bz2" && shasum -a 256 -c CHECKSUM ) >/dev/null
else
  echo "ERROR: no sha256 tool (sha256sum or shasum); refusing to install an unverified binary." >&2
  exit 1
fi

# bzip2 is not in debian:bookworm-slim; the Dockerfile installs it alongside this.
bunzip2 -c "$TMP_DIR/${ASSET}.bz2" > "$TMP_DIR/restic"
mkdir -p "$INSTALL_DIR"
install -m 0755 "$TMP_DIR/restic" "$BIN"

echo "INFO: Installed $("$BIN" version)"
