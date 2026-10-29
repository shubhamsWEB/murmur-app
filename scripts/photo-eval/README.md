# Photo search eval

Measures what photo search finds with the real model, before and after a change, on one index. The search's
`--old-search` switch turns off what photos gained on 2026-10-28 (their words: what they show and the text in them;
near misses; the small-group average), so one index answers both ways.

## Make it (once)

```bash
python3 scripts/photo-eval/make_photo_eval.py      # ~80 photos from Wikimedia Commons → ~/MurmurTestbed/photo-eval
```

The photos are saved as `p001.jpg`… so a file's name never gives the answer away; `evals/photos.local.json` (not in
git) says which photos each query should find.

## Mac

```bash
swift build -c release --product murmur-engine
E=.build/release/murmur-engine
$E index ~/MurmurTestbed/photo-eval --index /tmp/photo-eval-index
$E eval evals/photos.local.json --index /tmp/photo-eval-index --old-search   # before
$E eval evals/photos.local.json --index /tmp/photo-eval-index                # after
```

## Windows (PowerShell, with Murmur installed)

```powershell
$M = "$env:LOCALAPPDATA\Programs\Murmur"     # where the installer put Murmur.exe and murmur-engine.exe
$env:MURMUR_OCR = "$M\Murmur.exe"            # pictures' text, with Windows' own OCR
& "$M\murmur-engine.exe" index "$HOME\MurmurTestbed\photo-eval" --index "$env:TEMP\photo-eval-index"
& "$M\murmur-engine.exe" eval evals\photos.local.json --index "$env:TEMP\photo-eval-index" --old-search
& "$M\murmur-engine.exe" eval evals\photos.local.json --index "$env:TEMP\photo-eval-index"
```

## Documents mustn't get worse

On your own index, the same searches both ways; any line that differs is worth a look:

```bash
for q in "budget" "lease agreement" "invoice from october" "flight ticket" "meeting notes"; do
  diff <($E search "$q" -n 5 --old-search) <($E search "$q" -n 5) > /dev/null || echo "differs: $q"
done
```

One switch at a time: `--no-labels`, `--no-near-misses`, `--pooled-small-groups`.
