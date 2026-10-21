#!/bin/bash
# Windows: dictation's speech runtime, sherpa-onnx 1.13.8 with ONNX Runtime 1.28.2, as the static /MT library its
# authors build without text to speech (the sherpa-onnx crate's own download is the build with it, which links in
# espeak-ng: GPL-3.0, not something an MIT app can carry). → Vendor/sherpa-onnx/lib (out of git), and
# shell/.cargo/config.toml (out of git), which has Cargo link Murmur.exe with it in place of the sherpa-onnx-sys crate's
# build script (its `links` key). Does nothing when it's there. scripts/package-windows.sh runs it.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=sherpa-onnx-v1.13.8-win-x64-static-MT-Release-no-tts-lib
# csukuangfj2/sherpa-onnx-libs on Hugging Face, sherpa-onnx's own mirror, as it was on 11 September 2026: the build of the
# v1.13.8 release itself. The mirror's later uploads under the same name are builds of sherpa-onnx's development branch,
# whose C structs no longer match the sherpa-onnx 1.13.8 crate's (Murmur crashed loading the model with one).
REVISION=385f36e044e42502128f16297f14108e3850f2e4
SHA256=f0aa074ddc39553b30208b53e84c12275d09702911c9faa8d34fa932428e4641
RELEASE_COMMIT=11afbd00   # v1.13.8's commit, which sherpa-onnx records in its library
OUT=Vendor/sherpa-onnx
# Linked in this order (the sherpa-onnx-sys crate's list, without the text-to-speech libraries).
LIBS=(sherpa-onnx-c-api sherpa-onnx-core kaldi-decoder-core sherpa-onnx-kaldifst-core sherpa-onnx-fstfar sherpa-onnx-fst
      kaldi-native-fbank-core kissfft-float onnxruntime ssentencepiece_core)

if [[ "$(cat "$OUT/BUILD" 2>/dev/null)" != "$NAME $REVISION" ]]; then
  rm -rf "$OUT"
  mkdir -p "$OUT"
  echo "downloading $NAME"
  curl -fL --retry 3 -o "$OUT/lib.tar.bz2" \
    "https://huggingface.co/csukuangfj2/sherpa-onnx-libs/resolve/$REVISION/win64/1.13.8/$NAME.tar.bz2"
  echo "$SHA256  $OUT/lib.tar.bz2" | sha256sum -c -
  tar -xjf "$OUT/lib.tar.bz2" -C "$OUT" --strip-components 1
  rm "$OUT/lib.tar.bz2"
  for lib in "${LIBS[@]}"; do [[ -f "$OUT/lib/$lib.lib" ]] || { echo "no $lib.lib in $NAME" >&2; exit 1; }; done
  # No text to speech: nothing of espeak-ng or piper in it.
  if ls "$OUT/lib" | grep -Eqi 'espeak|piper|ucd'; then echo "$NAME has text-to-speech libraries" >&2; exit 1; fi
  # Built from the release the crate's bindings were made for, or its structs may not match them.
  grep -aq "$RELEASE_COMMIT" "$OUT/lib/sherpa-onnx-core.lib" ||
    { echo "$NAME wasn't built from sherpa-onnx v1.13.8 ($RELEASE_COMMIT)" >&2; exit 1; }
  echo "$NAME $REVISION" > "$OUT/BUILD"
fi

lib_dir=$(cd "$OUT/lib" && pwd)
command -v cygpath > /dev/null && lib_dir=$(cygpath -m "$lib_dir")
mkdir -p shell/.cargo
{
  echo "# Written by scripts/fetch-speech-runtime.sh: Murmur.exe links the speech runtime without text to speech."
  echo "[target.x86_64-pc-windows-msvc.sherpa-onnx]"
  echo "rustc-link-search = [\"native=$lib_dir\"]"
  printf 'rustc-link-lib = ['
  for i in "${!LIBS[@]}"; do printf '%s"static=%s"' "$([[ $i -gt 0 ]] && echo ', ')" "${LIBS[$i]}"; done
  echo ']'
} > shell/.cargo/config.toml
cat shell/.cargo/config.toml
