"""EmbeddingGemma 2 (Murmur's own model) + a small classifier, for Murmur's System 1: dictation or which command.
Embeds with llama-server (same GGUF and llama.cpp tag as Murmur), trains on train.py, tests on test.py."""
import json, re, statistics, sys, time
from collections import Counter, defaultdict

import numpy as np
import requests
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import StratifiedKFold, cross_val_predict

from train import TRAIN
from test import TEST

URL = "http://127.0.0.1:8099/embedding"


def embed(texts, prefix):
    out, times = [], []
    for t in texts:
        start = time.time()
        r = requests.post(URL, json={"content": prefix + t}, timeout=60).json()
        times.append(time.time() - start)
        v = np.array(r[0]["embedding"] if isinstance(r, list) else r["embedding"], dtype=np.float32)
        v = v.reshape(-1, v.shape[-1]).mean(axis=0) if v.ndim > 1 else v
        out.append(v / np.linalg.norm(v))
    return np.stack(out), times


def lang(text):
    if re.search(r"[ऀ-ॿ]", text): return "hindi"
    hinglish = r"\b(karo|kar do|kholo|khol|bhejo|bhej|dhundo|dikhao|batao|bolo|mera|meri|mujhe|ko|ka|ki|ke|hai|hain|kya|nahi|main|aaj|kal|yaar|bhai|pe|wala|wali|chalao|band|badhao|padh|dekh|yaad|rakh|kahan|kitni|kitna|bacha|bachi|sasta|saare)\b"
    return "hinglish" if re.search(hinglish, text.lower()) else "english"


def report(name, y_true, y_pred, texts):
    y_true, y_pred = list(y_true), list(y_pred)
    acc = np.mean([a == b for a, b in zip(y_true, y_pred)])
    binary = np.mean([(a == "dictation") == (b == "dictation") for a, b in zip(y_true, y_pred)])
    print(f"\n== {name}: {len(y_true)} sentences · exact kind {acc:.1%} · command-vs-dictation {binary:.1%}")
    by = defaultdict(list)
    for a, b, t in zip(y_true, y_pred, texts):
        by[lang(t)].append((a == b, (a == "dictation") == (b == "dictation")))
    for l, rows in sorted(by.items()):
        print(f"   {l:9s} n={len(rows):3d}  kind {np.mean([r[0] for r in rows]):.1%}  cmd/dict {np.mean([r[1] for r in rows]):.1%}")
    return acc, binary


def main():
    prefixes = {"classification": "task: classification | query: ", "search": "task: search result | query: ", "none": ""}
    ytr = [l for l, _ in TRAIN]; xtr_text = [t for _, t in TRAIN]
    yte = [l for l, _ in TEST]; xte_text = [t for _, t in TEST]
    best = None
    for pname, prefix in prefixes.items():
        Xtr, _ = embed(xtr_text, prefix)
        # Pick the prompt and C on the training set only (5-fold), never on the test set.
        for C in [1, 4, 16, 64]:
            clf = LogisticRegression(C=C, max_iter=4000)
            pred = cross_val_predict(clf, Xtr, ytr, cv=StratifiedKFold(5, shuffle=True, random_state=0))
            acc = np.mean([a == b for a, b in zip(ytr, pred)])
            print(f"cv  prompt={pname:15s} C={C:3d}  kind {acc:.1%}")
            if best is None or acc > best[0]:
                best = (acc, pname, prefix, C, Xtr)
    acc, pname, prefix, C, Xtr = best
    print(f"\nChosen on training data only: prompt '{pname}', C={C} (cv {acc:.1%})")
    Xte, times = embed(xte_text, prefix)
    clf = LogisticRegression(C=C, max_iter=4000).fit(Xtr, ytr)
    proba = clf.predict_proba(Xte)
    pred = clf.classes_[proba.argmax(1)]
    report("EmbeddingGemma 2 + logistic regression (held-out test)", yte, pred, xte_text)

    # Confidence: how many it would decide alone, and how right those are (the rest go to the big model).
    conf = proba.max(1)
    print("\n   confidence ≥  decides alone   right when it decides")
    for th in [0.0, 0.4, 0.5, 0.6, 0.7, 0.8]:
        mask = conf >= th
        right = np.mean([a == b for a, b, m in zip(yte, pred, mask) if m]) if mask.any() else float("nan")
        print(f"   {th:4.1f}           {mask.mean():6.1%}          {right:6.1%}")
    # Command vs dictation with a calibrated margin on P(dictation).
    di = list(clf.classes_).index("dictation")
    pd = proba[:, di]
    print("\n   P(dictation) decides alone when outside [lo, hi]; else asks the big model")
    for lo, hi in [(0.5, 0.5), (0.3, 0.7), (0.2, 0.8), (0.1, 0.9)]:
        decided = (pd <= lo) | (pd >= hi)
        right = np.mean([((p >= hi) == (y == "dictation")) for p, y, d in zip(pd, yte, decided) if d])
        print(f"   [{lo:.1f}, {hi:.1f}]  decides {decided.mean():6.1%}  right {right:6.1%}")

    print("\n   Mistakes (true → predicted, confidence):")
    for t, y, p, c in zip(xte_text, yte, pred, conf):
        if y != p:
            print(f"   {y:12s} → {p:12s} {c:.2f}  {t}")
    print(f"\nEmbedding time on this machine (2 CPU cores, no GPU): median {statistics.median(times)*1000:.0f} ms, "
          f"p90 {sorted(times)[int(len(times)*0.9)]*1000:.0f} ms per sentence (includes HTTP)")
    json.dump({"pred": list(pred), "conf": conf.tolist(), "prompt": pname, "C": C}, open("results.json", "w"))


if __name__ == "__main__":
    main()
