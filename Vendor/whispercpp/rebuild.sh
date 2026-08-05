#!/bin/bash
# Rebuilds Vendor/whispercpp from upstream whisper.cpp.
#
# The archive is checked in because whisper.cpp ships no SPM manifest, and the
# community one (ggerganov/whisper.spm) disables Metal — its maintainer could not
# get ggml-metal.m through SwiftPM, and Metal is the reason to use whisper.cpp here
# rather than WhisperKit. GGML_METAL_EMBED_LIBRARY puts the shader inside the
# archive, so there is no .metallib to ship next to the binary.
set -euo pipefail
COMMIT="${1:-306c88f}"
DEST="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

git clone https://github.com/ggml-org/whisper.cpp "$WORK/src"
git -C "$WORK/src" checkout "$COMMIT"
cmake -S "$WORK/src" -B "$WORK/b" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF
cmake --build "$WORK/b" -j --config Release

# One archive rather than seven, because SwiftPM links a systemLibrary by a single
# -l name and the split between ggml's backends is upstream's business, not ours.
libtool -static -o "$DEST/lib/libwhispercpp.a" $(find "$WORK/b" -name '*.a')
cp "$WORK/src/include/whisper.h" "$DEST/include/"
cp "$WORK/src/ggml/include/"{ggml,ggml-alloc,ggml-backend,ggml-cpu,ggml-metal}.h "$DEST/include/"
echo "$COMMIT" > "$DEST/UPSTREAM_COMMIT"
echo "rebuilt from whisper.cpp @ $COMMIT"
