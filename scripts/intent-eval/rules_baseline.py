"""Murmur's current rules (IntentClassifier + QuickCommands patterns, copied from the source), without the model:
each sentence is command, dictation, or "would ask the model". Focus is taken as unknown (not a text field)."""
import json, re

R = json.load(open("rules.json"))


def clean(t):
    s = t.lower().strip()
    s = re.sub(r"[.!?,;:]+$", "", s)
    s = re.sub(r"^(please |can you |could you )+", "", s)
    return re.sub(r"\s+", " ", s)


def wake(s):
    first = s.split(" ")[0] if s else ""
    return first in {"murmur", "marmar", "murmer", "mermer", "marmur"}


def decide(text):
    s = clean(text)
    def has(p): return re.search(p, s) is not None
    if has(R["somethingToRemember"]): return "command"
    if has(R["messageToSend"]) or has(R["messageRequest"]): return "command"
    if len(s.split()) <= 14 and any(re.search(p, s) for p in R["quick"]): return "command"
    if has(R["chain"]): return "command"
    if wake(s): return "command"
    if has(R["aboutTheScreen"]): return "command"
    hinglish = has(R["hinglishInstruction"])
    if hinglish and has(R["macThings"]): return "command"
    first = s.split(" ")[0] if s else ""
    mentions = has(R["aboutTheMac"])
    if mentions and (first in R["openers"] or first in R["questions"]): return "command"
    if first in R["openers"] or mentions or hinglish: return "ask model"
    return "dictation"
