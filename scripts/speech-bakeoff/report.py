"""Builds one self-contained HTML page comparing every model on every clip (audio embedded).
Usage: report.py <clips dir> <results dir> <out.html> [title]"""
import base64, html, json, os, sys

from romanize import romanize, DEVANAGARI

MODELS = [
    # key, name, what it is, in Murmur now?
    ("apex", "Hinglish Apex", "Oriserve · Whisper large-v3-turbo · 0.8B · Apache-2.0", True),
    ("prime", "Hinglish Prime", "Oriserve · Whisper large-v3 · 1.55B · Apache-2.0", True),
    ("tara", "Tara", "Trelis · Whisper large-v3, mixed-code · 1.55B · Apache-2.0", False),
    ("srota", "Srota", "Qwen3-ASR-0.6B Hinglish fine-tune · Apache-2.0", False),
    ("flex_roman", "Indic-Transcribe Flex · romanized", "Bodhan AI · Canary 1.2B · Indic Open Model License", False),
    ("flex_mixed", "Indic-Transcribe Flex · mixed", "Same model, mixed script, then romanized", False),
    ("zero", "Zero STT Hinglish", "Shunya Labs · Whisper medium · 0.8B · OpenRAIL", False),
    ("vaani", "Vaani FastConformer", "IISc/ARTPARK · SraVaani's predecessor · Devanagari, then romanized", False),
]


def main():
    clips, results, out = sys.argv[1], sys.argv[2], sys.argv[3]
    title = sys.argv[4] if len(sys.argv) > 4 else "Hinglish speech models, side by side"
    data = {}
    for key, *_ in MODELS:
        p = os.path.join(results, f"{key}.json")
        if os.path.exists(p):
            data[key] = json.load(open(p))
    models = [m for m in MODELS if m[0] in data]
    files = sorted(f for f in os.listdir(clips) if f.lower().endswith(".wav"))
    import soundfile as sf
    durations = {f: sf.info(os.path.join(clips, f)).duration for f in files}

    # Speed: seconds to transcribe per second of audio, on this test machine (2 CPU cores, no GPU).
    speed = {}
    for key, *_ in models:
        t = sum(data[key][f]["seconds"] for f in files if f in data[key])
        a = sum(durations[f] for f in files if f in data[key])
        speed[key] = t / a if a else 0

    cards = []
    for f in files:
        audio = base64.b64encode(open(os.path.join(clips, f), "rb").read()).decode()
        rows = []
        for key, name, _, _ in models:
            r = data[key].get(f)
            if not r:
                continue
            raw = r["text"]
            roman = romanize(raw) if DEVANAGARI.search(raw) else raw
            original = f'<div class="orig">{html.escape(raw)}</div>' if roman != raw else ""
            rows.append(f'''<label class="row"><input type="radio" name="{html.escape(f)}" value="{key}">
<span class="model">{html.escape(name)}</span><span class="text">{html.escape(roman)}{original}</span></label>''')
        cards.append(f'''<section class="clip"><header><b>{html.escape(f)}</b><span>{durations[f]:.1f} s</span></header>
<audio controls preload="none" src="data:audio/wav;base64,{audio}"></audio>{"".join(rows)}</section>''')

    legend = "".join(
        f'<tr><td>{html.escape(n)}</td><td>{html.escape(d)}</td><td>{"Yes" if inapp else "Not yet"}</td>'
        f'<td>{speed[k]:.1f} s</td><td class="tally" data-k="{k}">0</td></tr>'
        for k, n, d, inapp in models)

    page = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hinglish model bake-off</title><style>
:root{{--bg:#f6f4f1;--card:#fff;--ink:#1b1b1f;--ink2:#5d5d66;--rule:#e4e0da;--accent:#0f6e68;--pick:#e7f3f2}}
@media (prefers-color-scheme:dark){{:root{{--bg:#151619;--card:#1e2024;--ink:#ecebe8;--ink2:#a2a2ab;--rule:#2f3238;--accent:#5cc8bf;--pick:#1d3634}}}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}
main{{max-width:980px;margin:0 auto;padding:28px 16px 60px}}h1{{font-size:24px;margin:0 0 6px}}p.lede{{color:var(--ink2);margin:0 0 20px}}
table{{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--rule);border-radius:10px;overflow:hidden;margin-bottom:26px;font-size:13.5px}}
th,td{{text-align:left;padding:8px 10px;border-bottom:1px solid var(--rule);vertical-align:top}}th{{color:var(--ink2);font-weight:600}}
td.tally{{font-weight:700;color:var(--accent);text-align:center}}
.clip{{background:var(--card);border:1px solid var(--rule);border-radius:10px;padding:14px;margin-bottom:16px}}
.clip header{{display:flex;justify-content:space-between;color:var(--ink2);font-size:13px;margin-bottom:8px}}.clip header b{{color:var(--ink)}}
audio{{width:100%;margin-bottom:8px}}
.row{{display:grid;grid-template-columns:22px 210px 1fr;gap:8px;padding:8px 6px;border-top:1px solid var(--rule);cursor:pointer;border-radius:6px}}
.row:has(input:checked){{background:var(--pick)}}.model{{color:var(--ink2);font-size:13px}}.text{{font-size:15.5px}}
.orig{{color:var(--ink2);font-size:12.5px;margin-top:2px}}
@media (max-width:640px){{.row{{grid-template-columns:22px 1fr}}.row .text{{grid-column:2}}.wide{{display:none}}}}
.scroll{{overflow-x:auto}}
</style></head><body><main>
<h1>{html.escape(title)}</h1>
<p class="lede">Listen to each clip and tick the transcript you'd want Murmur to type. The table keeps count. Text in grey is what the model wrote before it was put into English letters. “Time per second” is how long each model took per second of audio on a 2-core cloud test machine with no GPU. On your Mac every model is far faster, so compare these with each other only.</p>
<div class="scroll"><table><tr><th>Model</th><th class="wide">What it is</th><th>In Murmur</th><th>Time per second</th><th>Picked</th></tr>{legend}</table></div>
{"".join(cards)}
</main><script>
const KEY="hinglish-bakeoff-picks";let picks={{}};try{{picks=JSON.parse(localStorage.getItem(KEY)||"{{}}")}}catch(e){{}}
function tally(){{const c={{}};document.querySelectorAll("input:checked").forEach(i=>c[i.value]=(c[i.value]||0)+1);
document.querySelectorAll("td.tally").forEach(td=>td.textContent=c[td.dataset.k]||0)}}
document.querySelectorAll("input[type=radio]").forEach(i=>{{if(picks[i.name]===i.value)i.checked=true;
i.addEventListener("change",()=>{{picks[i.name]=i.value;try{{localStorage.setItem(KEY,JSON.stringify(picks))}}catch(e){{}};tally()}})}});tally();
</script></body></html>'''
    open(out, "w").write(page)
    print("wrote", out, f"{len(page)/1e6:.1f} MB")


if __name__ == "__main__":
    main()
