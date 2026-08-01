#!/usr/bin/env bash
# parrot installer (andredezzy fork).
#   curl -fsSL https://andredezzy.github.io/parrot/install.sh | sh
#
# Fetches the latest arm64 macOS binary from GitHub Releases, drops it in
# /usr/local/bin, and strips the quarantine xattr so Gatekeeper does not block
# the unsigned binary.
#
# macOS re-asks for Accessibility whenever a binary's signature changes, so
# every release means granting it again. `scripts/install-local.sh` in this
# repository builds from source and signs with a stable per-machine identity,
# which keeps the grant across updates — worth it if you update often.
#
# Apple Silicon only: transcription runs on the Apple Neural Engine.

set -euo pipefail

REPO="andredezzy/parrot"
BIN_NAME="parrot"
INSTALL_DIR="/usr/local/bin"
ASSET="parrot-macos-arm64.tar.gz"

red()   { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
dim()   { printf "\033[2m%s\033[0m\n" "$*"; }

if [ "$(uname -s)" != "Darwin" ]; then
    red "parrot is macOS-only (detected $(uname -s))"
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    red "parrot requires Apple Silicon (detected $ARCH)"
    red "the on-device inference engine uses the Apple Neural Engine, which Intel Macs don't have."
    exit 1
fi

for cmd in curl tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        red "missing dependency: $cmd"
        exit 1
    fi
done

dim "→ resolving latest release..."
TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -E '"tag_name"' \
    | head -1 \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')

if [ -z "${TAG:-}" ]; then
    red "couldn't determine latest release tag"
    exit 1
fi
dim "  ${TAG}"

URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

dim "→ downloading ${ASSET}..."
curl -fsSL "$URL" -o "$TMP/${ASSET}"

dim "→ extracting..."
tar -xzf "$TMP/${ASSET}" -C "$TMP"

if [ ! -f "$TMP/${BIN_NAME}" ]; then
    red "archive did not contain ${BIN_NAME}"
    exit 1
fi

chmod +x "$TMP/${BIN_NAME}"
xattr -d com.apple.quarantine "$TMP/${BIN_NAME}" 2>/dev/null || true

SUDO=""
if [ ! -w "$INSTALL_DIR" ]; then
    if [ ! -d "$INSTALL_DIR" ]; then
        dim "→ creating ${INSTALL_DIR} (sudo)..."
        sudo mkdir -p "$INSTALL_DIR"
    fi
    SUDO="sudo"
fi

dim "→ installing to ${INSTALL_DIR}/${BIN_NAME}..."
$SUDO mv "$TMP/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"
$SUDO chmod +x "${INSTALL_DIR}/${BIN_NAME}"

green "installed: ${INSTALL_DIR}/${BIN_NAME} (${TAG})"
echo
echo "  parrot setup                       # microphone + accessibility, downloads the model"
echo "  parrot install --launch-at-login   # optional — runs in the background on login"
echo
dim "Speaking a language other than English? Open the menu bar item and pick a"
dim "multilingual model — the default is English-only and scores near zero on"
dim "anything else."
