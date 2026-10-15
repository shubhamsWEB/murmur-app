#!/bin/bash
# Runs every candidate speech model over a folder of 16 kHz WAV clips (e.g. Documents/Murmur Recordings), then
# builds report.html to compare them side by side. Usage: scripts/speech-bakeoff/run_all.sh <clips> <results>
# Needs: pip install -r scripts/speech-bakeoff/requirements.txt (about 20 GB of models download on first run).
cd "$(dirname "$0")"
export HF_HUB_DISABLE_PROGRESS_BARS=1 TRANSFORMERS_VERBOSITY=error PYTHONWARNINGS=ignore
for m in ${MODELS:-apex prime tara zero srota flex_roman flex_mixed vaani}; do
  echo "=== $m $(date +%T)"; python run_model.py "$m" "$1" "$2" 2>&1 | grep -E "^  |loaded|Error|Traceback|nothing" | tail -40
done
python report.py "$1" "$2" "$2/report.html"
