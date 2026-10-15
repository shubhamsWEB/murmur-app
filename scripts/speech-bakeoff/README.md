# Speech bake-off

Compares the open Hinglish and Hindi speech models on the same recordings, so Murmur can pick one.

1. In Murmur: Settings › Dictation › Keep recordings. Dictate normally; each clip lands in Documents/Murmur Recordings.
2. `pip install -r requirements.txt`, then `./run_all.sh ~/Documents/Murmur\ Recordings results`.
3. Open `results/report.html`: listen to each clip and tick the best transcript. The table keeps count.

Models: Oriserve Hindi2Hinglish Apex and Prime (in Murmur), Trelis Tara, Srota (Qwen3-ASR Hinglish),
Bodhan Indic-Transcribe Flex (romanized and mixed), Shunya Zero STT Hinglish, IISc Vaani FastConformer.
Text in Devanagari is put into English letters by `romanize.py`, so every model is read the same way.
