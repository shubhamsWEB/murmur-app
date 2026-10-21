#!/usr/bin/env python3
"""Oriserve's Whisper-Hindi2Hinglish-Apex (Hugging Face transformers weights) → an OpenAI Whisper checkpoint, which
sherpa-onnx's export script (scripts/whisper/export-onnx.py) turns into its ONNX files. The weight names are renamed with
the mapping Oriserve publish beside the model (convert_hf2openai.json); the shapes come from its config.json.

    convert-hf-to-openai.py <model folder> <out.pt>
"""
import json
import re
import sys
from pathlib import Path

import torch
from safetensors.torch import load_file


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    folder, out = Path(sys.argv[1]), Path(sys.argv[2])
    config = json.loads((folder / "config.json").read_text())
    mapping = [(re.compile(pattern), target)
               for pattern, target in json.loads((folder / "convert_hf2openai.json").read_text()).items()]

    weights = load_file(str(folder / "model.safetensors"))
    state = {}
    for name, tensor in weights.items():
        if name == "proj_out.weight":   # the output projection is the token embedding, tied (OpenAI's has no copy)
            continue
        name = name.removeprefix("model.")
        for pattern, target in mapping:
            if pattern.match(name):
                name = pattern.sub(target, name)
                break
        else:
            sys.exit(f"no mapping for {name}")
        state[name] = tensor.to(torch.float16)

    dims = {
        "n_mels": config["num_mel_bins"],
        "n_vocab": config["vocab_size"],
        "n_audio_ctx": config["max_source_positions"],
        "n_audio_state": config["d_model"],
        "n_audio_head": config["encoder_attention_heads"],
        "n_audio_layer": config["encoder_layers"],
        "n_text_ctx": config["max_target_positions"],
        "n_text_state": config["d_model"],
        "n_text_head": config["decoder_attention_heads"],
        "n_text_layer": config["decoder_layers"],
    }
    torch.save({"dims": dims, "model_state_dict": state}, out)
    print(f"{out}: {len(state)} tensors, {dims}")


if __name__ == "__main__":
    main()
