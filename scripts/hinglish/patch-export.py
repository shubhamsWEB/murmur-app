#!/usr/bin/env python3
"""sherpa-onnx's Whisper export script (scripts/whisper/export-onnx.py, v1.13.8), taught one more model: Oriserve's
Hinglish Apex as an OpenAI checkpoint (convert-hf-to-openai.py → ./large-hinglish-apex.pt). The name has "large" in it,
so the script saves its 2 GB+ files with external data as it does for the large models; it has 128 mel bins as
large-v3 and turbo do. And it's exported with PyTorch's TorchScript exporter, as sherpa-onnx's own exports are (newer
PyTorch defaults to its dynamo exporter, whose graphs sherpa-onnx's script wasn't written for). Once the encoder is
exported its weights are let go (the decoder's export only needs what the encoder computed), so the 2.5 GB encoder
can be re-saved with its metadata in 7-8 GB of memory; and it stops before quantising (quantize.py does that after,
one model per process, for the same reason). Nothing else changes.

    patch-export.py export-onnx.py
"""
import sys
from pathlib import Path

path = Path(sys.argv[1])
script = path.read_text()
edits = [
    ('"large", "large-v3", "turbo", # these three have feature dim 128',
     '"large", "large-v3", "turbo", "large-hinglish-apex", # these have feature dim 128'),
    ('def load_model(name: str):\n',
     'def load_model(name: str):\n    if name == "large-hinglish-apex":\n'
     '        return whisper.load_model("./large-hinglish-apex.pt")\n'),
    ('    print(f"encoder_meta_data: {encoder_meta_data}")\n',
     '    print(f"encoder_meta_data: {encoder_meta_data}")\n'
     '    del encoder\n    model.encoder = None\n    import gc\n    gc.collect()\n'),
    ('        "large-v3",\n        "turbo",\n    ):\n        n_mels = 128',
     '        "large-v3",\n        "turbo",\n        "large-hinglish-apex",\n    ):\n        n_mels = 128'),
]
for old, new in edits:
    if script.count(old) != 1:
        sys.exit(f"patch-export: the script changed, no single {old!r}")
    script = script.replace(old, new)
exports = script.count("opset_version=opset_version,")
if exports != 2:
    sys.exit(f"patch-export: expected the encoder's and decoder's export, found {exports}")
script = script.replace("opset_version=opset_version,", "opset_version=opset_version, dynamo=False,")
quantize = '    # Generate int8 quantization models'
if script.count(quantize) != 1:
    sys.exit("patch-export: the script's quantisation step moved")
script = script[:script.index(quantize)] + "    return\n\n" + script[script.index(quantize):]
path.write_text(script)
print(f"{path}: patched for large-hinglish-apex")
