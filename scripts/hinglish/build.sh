#!/bin/bash
# Builds the Hinglish speech model Murmur for Windows dictates with: Oriserve's Whisper-Hindi2Hinglish-Apex (Apache 2.0,
# Whisper large-v3-turbo fine-tuned on Indian Hindi, written in English letters; the Mac app runs it through WhisperKit)
# in sherpa-onnx's Whisper format, int8, as the Parakeet models are. Every input is pinned (Oriserve's weights, sherpa-
# onnx's export script, the Python packages); the result is checked against what the same weights write in PyTorch.
#
#   scripts/hinglish/build.sh <work folder> <out folder>
#
# <out folder> gets encoder.int8.onnx, decoder.int8.onnx, tokens.txt, manifest.json (each file's size and SHA-256,
# which `murmur-engine download-speech-model --model hinglish` checks downloads against) and the model's license. The
# Hinglish model workflow (.github/workflows/hinglish-model.yml) runs it and publishes the folder as a release. Needs
# Python 3.12 or 3.13, curl, and about 8 GB of memory and 15 GB of disk.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mkdir -p "$1" && cd "$1" && pwd)
out=$(mkdir -p "$2" && cd "$2" && pwd)

REVISION=f3214eed20b4e4d4144e739982d911f87b9cb223   # Oriserve/Whisper-Hindi2Hinglish-Apex
MODEL=https://huggingface.co/Oriserve/Whisper-Hindi2Hinglish-Apex/resolve/$REVISION
SHERPA=11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf     # sherpa-onnx v1.13.8, whose export script this patches
SAMPLE_A=663eb653-d6b5-4fda-b5f2-9ef98adc0a61_0_1098400_1118688.wav
SAMPLE_B=c0637211-7384-4abc-af69-5aacf7549824_1_2417088_2444224.wav

fetch() {   # fetch <url> <file> <sha256>
  [[ -f $2 ]] && echo "$3  $2" | sha256sum -c --quiet - 2> /dev/null && return
  curl -fL --retry 3 -o "$2" "$1"
  echo "$3  $2" | sha256sum -c -
}

cd "$work"
mkdir -p apex/audios
fetch "$MODEL/model.safetensors" apex/model.safetensors 5560830fe8fa09b8cdf1b5926d0cc39a2586eadaad685d809e156432c4ebca80
fetch "$MODEL/config.json" apex/config.json 14209b98fb68fc127201bbfebd57cc9f834b0f1a0d0d463a561c8051800af9f4
fetch "$MODEL/convert_hf2openai.json" apex/convert_hf2openai.json 401b522f2461ac0de492a239d2bbb0a1e9469b385ee47c11d233e71474b41831
fetch "$MODEL/audios/$SAMPLE_A" "apex/audios/$SAMPLE_A" 4c553f6b9e5984167dea3d1058ea4bf4c2bfa2ceee948a025c41a12b011f290e
fetch "$MODEL/audios/$SAMPLE_B" "apex/audios/$SAMPLE_B" a0a9c8cad6964edc55dd5333217379254474f575aba2b79b2ab5f027ca07fb47
fetch "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$SHERPA/scripts/whisper/export-onnx.py" export-onnx.py \
  5e0ddabfac8330ee9aecaba4c1b4286d1cd9f88df4cd30e54706b011bf976e45

if [[ ! -x venv/bin/python ]]; then
  python3 -m venv venv
  venv/bin/pip install -q --index-url https://download.pytorch.org/whl/cpu torch==2.14.1
  venv/bin/pip install -q openai-whisper==20250625 onnx==1.23.2 onnxscript onnxruntime==1.31.0 safetensors==0.8.0 \
    soundfile==0.14.0 sherpa-onnx==1.13.8
fi

# Hugging Face's weights → an OpenAI Whisper checkpoint → sherpa-onnx's ONNX (float32), each step in a process of its
# own so the memory goes back between them; then int8, one model at a time.
mkdir -p export
cd export
../venv/bin/python "$here/convert-hf-to-openai.py" ../apex large-hinglish-apex.pt
cp ../export-onnx.py export-apex.py
../venv/bin/python "$here/patch-export.py" export-apex.py
../venv/bin/python export-apex.py --model large-hinglish-apex 2>&1 | grep -v "Warning\|warn(" | tail -5
rm -f large-hinglish-apex.pt onnx__* audioEncoder.* textDecoder.*
# Both with 8-bit weights only, the arithmetic in float32: any 8-bit arithmetic changes what Apex writes, and
# differently on different processors (quantize-weights.py says how).
for part in encoder decoder; do
  ../venv/bin/python "$here/quantize-weights.py" "large-hinglish-apex-$part.onnx" "$out/$part.int8.onnx" 2>&1 \
    | grep -v "^WARNING\|INFO"
done
cp large-hinglish-apex-tokens.txt "$out/tokens.txt"
cd ..

# What the same weights write in PyTorch, near enough.
venv/bin/python "$here/check.py" "$out" apex/audios

curl -fsSL -o "$out/LICENSE-Oriserve-Apache-2.0.txt" https://www.apache.org/licenses/LICENSE-2.0.txt
cat > "$out/README.txt" <<TEXT
Murmur's Hinglish speech model: Oriserve's Whisper-Hindi2Hinglish-Apex
(https://huggingface.co/Oriserve/Whisper-Hindi2Hinglish-Apex, revision $REVISION), licensed under the Apache License 2.0
(LICENSE-Oriserve-Apache-2.0.txt), converted to sherpa-onnx's Whisper format (int8) by Murmur's scripts/hinglish/build.sh
with sherpa-onnx's export script (https://github.com/k2-fsa/sherpa-onnx, commit $SHERPA, Apache License 2.0).
The weights are Oriserve's, unchanged apart from the conversion and the int8 quantisation.
TEXT
python3 - "$out" <<'PY'
import hashlib, json, sys
from pathlib import Path
out = Path(sys.argv[1])
files = []
for name in ["tokens.txt", "decoder.int8.onnx", "encoder.int8.onnx"]:
    digest = hashlib.sha256()
    with open(out / name, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    files.append({"name": name, "bytes": (out / name).stat().st_size, "sha256": digest.hexdigest()})
(out / "manifest.json").write_text(json.dumps({"model": "whisper-hinglish-apex-int8", "files": files}, indent=2) + "\n")
print(json.dumps(files, indent=2))
PY
ls -la "$out"
