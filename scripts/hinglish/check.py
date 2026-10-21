#!/usr/bin/env python3
"""Checks a Hinglish model folder (encoder, decoder, tokens.txt) with sherpa-onnx: Oriserve's own sample recordings,
transcribed as Murmur runs them (language "en", greedy), must come out as the same weights write them in PyTorch
(OpenAI's whisper package, greedy, language "en", float32), near enough: the int8 quantisation may change a letter.
Prints each one and how long it took.

    check.py <folder> <samples folder> [--encoder encoder.int8.onnx] [--decoder decoder.int8.onnx]
"""
import argparse
import difflib
import time
from pathlib import Path

import sherpa_onnx
import soundfile

# Recordings from Oriserve/Whisper-Hindi2Hinglish-Apex's repository, and what the converted weights write for them in
# PyTorch (the first is also what Oriserve's model card shows; the second, "Haan haan, dekhe hain." there, comes out as
# below from these weights in PyTorch too, so it's the decoding, not the conversion).
EXPECTED = {
    "663eb653-d6b5-4fda-b5f2-9ef98adc0a61_0_1098400_1118688.wav": "Aap pandrah log hain.",
    "c0637211-7384-4abc-af69-5aacf7549824_1_2417088_2444224.wav": "Haan haan, dekhen.",
}


def read(path):
    samples, rate = soundfile.read(str(path), dtype="float32", always_2d=True)   # Oriserve's are 32-bit float WAVs
    return samples.mean(axis=1), rate


def words(text):
    return "".join(c for c in text.lower() if c.isalnum() or c == " ").split()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("folder")
    parser.add_argument("samples")
    parser.add_argument("--encoder", default="encoder.int8.onnx")
    parser.add_argument("--decoder", default="decoder.int8.onnx")
    parser.add_argument("--language", default="en")
    args = parser.parse_args()
    folder = Path(args.folder)
    started = time.time()
    recognizer = sherpa_onnx.OfflineRecognizer.from_whisper(
        encoder=str(folder / args.encoder), decoder=str(folder / args.decoder), tokens=str(folder / "tokens.txt"),
        language=args.language, task="transcribe", num_threads=4)
    print(f"loaded in {time.time() - started:.1f} s")
    worst = 1.0
    for name, expected in EXPECTED.items():
        samples, rate = read(Path(args.samples) / name)
        stream = recognizer.create_stream()
        stream.accept_waveform(rate, samples)
        started = time.time()
        recognizer.decode_stream(stream)
        text = stream.result.text.strip()
        score = difflib.SequenceMatcher(None, words(text), words(expected)).ratio()
        worst = min(worst, score)
        print(f"{len(samples) / rate:.1f} s in {time.time() - started:.2f} s, {score:.2f}: {text!r} (expected {expected!r})")
    if worst < 0.8:
        raise SystemExit(f"the model doesn't write what Oriserve's does (worst match {worst:.2f})")
    print("ok")


if __name__ == "__main__":
    main()
