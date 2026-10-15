# Intent test: EmbeddingGemma 2 as Murmur's System 1

Does a small classifier on Murmur's own embedding model (EmbeddingGemma 2, Q8 GGUF, llama.cpp b11461) tell
dictation from commands, and which command, better than the current rules?

- `train.py`: 256 labelled sentences (English, Hinglish, some Hindi). `test.py`: 138 held-out sentences, written
  separately, with real commands from Murmur's log.
- `rules_baseline.py`: the current IntentClassifier and QuickCommands patterns, without the model
  (needs `rules.json`, the patterns copied from the Swift source).
- `evaluate.py`: embeds with `llama-server -m embeddinggemma-2-Q8_0.gguf --embeddings --pooling mean --port 8099`,
  picks the prompt and regularisation on the training set only, then reports on the test set.

Results (15 Oct 2026, held-out test, command vs dictation):

| | right | wrong | needs the big model |
|---|---|---|---|
| Current rules | 67% | 12% | 21% |
| EmbeddingGemma classifier, decides when P(dictation) ≤ 0.3 or ≥ 0.7 | 80% | 2% | 18% |
| EmbeddingGemma classifier, always decides | 95% | 5% | 0% |

Which command (12 kinds): 85.5% on the test set. English 84.5%, Hinglish 86.5%. Embedding takes 39 ms per sentence
on 2 CPU cores with no GPU; less on a Mac's GPU.
