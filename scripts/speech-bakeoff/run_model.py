"""Runs one speech model over every clip and writes results/<model>.json: {clip: {"text", "seconds"}}.
Usage: run_model.py <model> <clips dir> <results dir>. One model per process, so memory is freed between models."""
import gc, json, os, sys, time

import numpy as np
import soundfile as sf
import torch

torch.set_num_threads(os.cpu_count() or 2)


def load_audio(path):
    audio, sr = sf.read(path, dtype="float32", always_2d=True)
    audio = audio.mean(axis=1)
    if sr != 16000:
        import librosa
        audio = librosa.resample(audio, orig_sr=sr, target_sr=16000)
    return audio


def whisper_runner(repo, dtype, prefix, greedy_only=False):
    """prefix: the decoder's start tokens after <|startoftranscript|>, e.g. ["<|en|>", "<|transcribe|>"]."""
    from transformers import WhisperForConditionalGeneration, WhisperProcessor
    processor = WhisperProcessor.from_pretrained(repo)
    model = WhisperForConditionalGeneration.from_pretrained(repo, torch_dtype=dtype).eval()
    tk = processor.tokenizer
    ids = [tk.convert_tokens_to_ids(t) for t in prefix + ["<|notimestamps|>"]]
    forced = [(i + 1, t) for i, t in enumerate(ids)]

    sot = tk.convert_tokens_to_ids("<|startoftranscript|>")
    eos = tk.convert_tokens_to_ids("<|endoftext|>")

    def greedy(feats):
        # Plain greedy decoding from a fixed prefix (Tara's <|mixedcode|> token isn't something generate() can force).
        enc = model.model.encoder(feats)
        seq = torch.tensor([[sot] + ids])
        past, out = None, []
        for _ in range(220):
            o = model(encoder_outputs=enc, decoder_input_ids=seq if past is None else seq[:, -1:],
                      past_key_values=past, use_cache=True)
            past = o.past_key_values
            nxt = int(o.logits[0, -1].float().argmax())
            if nxt == eos:
                break
            out.append(nxt)
            seq = torch.cat([seq, torch.tensor([[nxt]])], dim=1)
        return out

    def run(path):
        feats = processor(load_audio(path), sampling_rate=16000, return_tensors="pt").input_features.to(dtype)
        with torch.inference_mode():
            if greedy_only:
                return tk.decode(greedy(feats), skip_special_tokens=True).strip()
            out = model.generate(input_features=feats, forced_decoder_ids=forced, max_new_tokens=220,
                                 num_beams=1, do_sample=False)
        return tk.decode(out[0], skip_special_tokens=True).strip()
    return run


def srota():
    from qwen_asr import Qwen3ASRModel
    model = Qwen3ASRModel.from_pretrained("moorlee/qwen3-asr-0.6b-hinglish", dtype=torch.float32, device_map="cpu")

    def run(path):
        return model.transcribe(audio=path, language=None)[0].text.strip()
    return run


def flex(mode):
    from huggingface_hub import snapshot_download
    folder = snapshot_download("konradjr007/indic-transcribe-flex-onnx", ignore_patterns=["nemo/*", "*.png"])
    sys.path.insert(0, folder)
    from indic_transcribe import IndicTranscribe
    asr = IndicTranscribe.from_pretrained(folder)

    def run(path):
        out = asr(path, lang="hi", mode=mode)
        return (out if isinstance(out, str) else getattr(out, "text", str(out))).strip()
    return run


def vaani():
    import onnx_asr
    model = onnx_asr.load_model("OpenVoiceOS/artpark-iisc-vaani-fastconformer-multi-onnx", quantization="int8")

    def run(path):
        return str(model.recognize(load_audio(path), sample_rate=16000)).strip()
    return run


MODELS = {
    "apex": lambda: whisper_runner("Oriserve/Whisper-Hindi2Hinglish-Apex", torch.float32, ["<|en|>", "<|transcribe|>"]),
    "prime": lambda: whisper_runner("Oriserve/Whisper-Hindi2Hinglish-Prime", torch.bfloat16, ["<|en|>", "<|transcribe|>"]),
    "tara": lambda: whisper_runner("Trelis/tara", torch.bfloat16, ["<|hi|>", "<|mixedcode|>", "<|transcribe|>"], greedy_only=True),
    "zero": lambda: whisper_runner("shunyalabs/zero-stt-hinglish", torch.float32, ["<|hi|>", "<|transcribe|>"]),
    "srota": srota,
    "flex_roman": lambda: flex("romanized"),
    "flex_mixed": lambda: flex("mixed"),
    "vaani": vaani,
}


def main():
    name, clips, results = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(results, exist_ok=True)
    out_path = os.path.join(results, f"{name}.json")
    done = json.load(open(out_path)) if os.path.exists(out_path) else {}
    files = sorted(f for f in os.listdir(clips) if f.lower().endswith(".wav"))
    todo = [f for f in files if f not in done]
    if not todo:
        print(name, "nothing to do"); return
    started = time.time()
    run = MODELS[name]()
    print(f"{name}: loaded in {time.time() - started:.0f} s", flush=True)
    for f in todo:
        t = time.time()
        try:
            text = run(os.path.join(clips, f))
        except Exception as e:  # keep going: one bad clip shouldn't lose the rest
            text = f"[error: {e}]"
        done[f] = {"text": text, "seconds": round(time.time() - t, 2)}
        print(f"  {f}: {done[f]['seconds']} s · {text[:90]}", flush=True)
        json.dump(done, open(out_path, "w"), ensure_ascii=False, indent=1)
    del run; gc.collect()


if __name__ == "__main__":
    main()
