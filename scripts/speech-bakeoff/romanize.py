"""Devanagari → casual Roman Hinglish ("मैं कल मीटिंग में आऊँगा" → "main kal meeting mein aaunga").

Rule-based: consonants carry an inherent 'a' that Hindi drops at the end of a word and in the middle of
V C a C V (schwa deletion); long vowels are doubled in the middle of a word and shortened at the end, the
way people type Hinglish. A short list of very common words that the rules get wrong is spelled directly.
Latin words in mixed-script text pass through unchanged.
"""
import re

CONS = {
    "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n",
    "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "n",
    "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n",
    "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
    "प": "p", "फ": "f", "ब": "b", "भ": "bh", "म": "m",
    "य": "y", "र": "r", "ल": "l", "व": "v", "श": "sh", "ष": "sh", "स": "s", "ह": "h",
    "ळ": "l", "क़": "q", "ख़": "kh", "ग़": "g", "ज़": "z", "ड़": "d", "ढ़": "dh", "फ़": "f", "य़": "y", "ऱ": "r",
}
NUKTA_BASE = {"क": "क़", "ख": "ख़", "ग": "ग़", "ज": "ज़", "ड": "ड़", "ढ": "ढ़", "फ": "फ़", "य": "य़", "र": "ऱ"}
VOWELS = {"अ": "a", "आ": "aa", "इ": "i", "ई": "ee", "उ": "u", "ऊ": "oo", "ऋ": "ri", "ए": "e", "ऐ": "ai",
          "ओ": "o", "औ": "au", "ऑ": "o", "ऍ": "e"}
MATRAS = {"ा": "aa", "ि": "i", "ी": "ee", "ु": "u", "ू": "oo", "ृ": "ri", "े": "e", "ै": "ai", "ो": "o",
          "ौ": "au", "ॉ": "o", "ॅ": "e"}
HALANT, NUKTA, ANUSVARA, CHANDRA, VISARGA = "्", "़", "ं", "ँ", "ः"
DIGITS = str.maketrans("०१२३४५६७८९", "0123456789")

# Very common words the rules spell differently from how people type them.
WORDS = {
    "में": "mein", "मैं": "main", "हैं": "hain", "है": "hai", "नहीं": "nahi", "नही": "nahi", "हूँ": "hoon", "हूं": "hoon",
    "क्या": "kya", "ये": "ye", "यह": "yeh", "वो": "wo", "वह": "woh", "और": "aur", "भी": "bhi", "तो": "to",
    "ही": "hi", "जी": "ji", "की": "ki", "कि": "ki", "थी": "thi", "थीं": "thi", "दी": "di", "ली": "li",
    "क्यों": "kyun", "क्यूँ": "kyun", "यहाँ": "yahan", "वहाँ": "wahan", "कहाँ": "kahan", "यहां": "yahan",
    "वहां": "wahan", "कहां": "kahan", "हाँ": "haan", "हां": "haan", "मुझे": "mujhe", "तुम्हें": "tumhe",
    "उन्हें": "unhe", "इन्हें": "inhe", "वाला": "wala", "वाली": "wali", "वाले": "wale", "अभी": "abhi",
    "सभी": "sabhi", "कभी": "kabhi", "जब": "jab", "अब": "ab", "सब": "sab", "कब": "kab", "रहा": "raha",
    "रही": "rahi", "रहे": "rahe", "कहा": "kaha", "आप": "aap", "हम": "hum", "तुम": "tum", "ठीक": "theek",
    "बहुत": "bahut", "मत": "mat", "पर": "par", "कर": "kar", "घर": "ghar", "अगर": "agar", "मगर": "magar",
    "लेकिन": "lekin", "बोलो": "bolo", "करो": "karo", "करना": "karna", "करें": "karein", "हों": "hon",
    "क्योंकि": "kyunki", "ऑफिस": "office", "ऑफ़िस": "office", "ओके": "okay", "प्लीज़": "please", "प्लीज": "please",
    "थैंक": "thank", "यू": "you", "मैसेज": "message", "कॉल": "call", "फ़ोन": "phone", "फोन": "phone",
    "ईमेल": "email", "मेल": "mail", "व्हाट्सएप": "WhatsApp", "व्हाट्सऐप": "WhatsApp",
}

DEVANAGARI = re.compile(r"[ऀ-ॿ]+")


def _units(word):
    """Splits a word into (consonant, vowel) units: vowel is a matra key, '' for inherent a, HALANT for none,
    or ('V', letter) for an independent vowel. Also returns trailing nasal marks per unit."""
    units = []
    i = 0
    chars = list(word)
    while i < len(chars):
        c = chars[i]
        if i + 1 < len(chars) and chars[i + 1] == NUKTA and c in NUKTA_BASE:
            c = NUKTA_BASE[c]
            i += 1
        if c in CONS:
            unit = {"c": CONS[c], "v": None, "n": ""}
            if i + 1 < len(chars) and chars[i + 1] in MATRAS:
                unit["v"] = MATRAS[chars[i + 1]]; i += 1
            elif i + 1 < len(chars) and chars[i + 1] == HALANT:
                unit["v"] = ""; i += 1
            else:
                unit["v"] = "a"; unit["schwa"] = True
            units.append(unit)
        elif c in VOWELS:
            v = VOWELS[c]
            if c == "ए" and units and units[-1]["v"]:
                v = "ye"  # चलिए → chaliye
            units.append({"c": "", "v": v, "n": ""})
        elif c in (ANUSVARA, CHANDRA):
            if units:
                units[-1]["n"] = "n"
        elif c == VISARGA:
            if units:
                units[-1]["n"] += "h"
        else:
            units.append({"c": c, "v": "", "n": ""})
        i += 1
    return units


def _word(word):
    if word in WORDS:
        return WORDS[word]
    units = _units(word)
    # Schwa deletion: word-final, and V C a C V in the middle (right to left).
    if units and units[-1].get("schwa") and len(units) > 1:
        units[-1]["v"] = ""
    for k in range(len(units) - 2, 0, -1):
        u = units[k]
        if not u.get("schwa") or u["n"]:
            continue
        prev, nxt = units[k - 1], units[k + 1]
        if prev["v"] and nxt["c"] and nxt["v"]:
            u["v"] = ""
    out = []
    last = len(units) - 1
    for k, u in enumerate(units):
        v = u["v"]
        if u["n"] == "n" and v in ("oo", "ee"):  # nasal long vowels read short: आऊँगा → aaunga
            v = "i" if v == "ee" else "u"
        if k == last:  # long vowels read short at the end of a word, the way people type them
            v = {"aa": "a", "ee": "i", "oo": "u"}.get(v, v)
            if u["n"] and v in ("e",):
                v = "ein"[:-1]
        out.append(u["c"] + v + u["n"])
    text = "".join(out)
    text = text.replace("aaaa", "aa")
    return text


def romanize(text):
    text = text.translate(DIGITS).replace("।", ".").replace("॥", ".")
    return DEVANAGARI.sub(lambda m: _word(m.group(0)), text)


if __name__ == "__main__":
    for s in ["मैं कल मीटिंग में आऊँगा", "मेरा favourite festival Diwali है", "समझना", "करना", "दिल्ली",
              "बात", "आज", "रामायण", "लड़का", "पढ़ाई", "मैंने कल पांच बजे तीन फाइलें अपलोड कीं", "जाऊँगा",
              "हिंदी", "गाना", "सुनो", "दोस्तों", "चलिए", "बताइए", "इसलिए", "कमरा", "अंदर", "नमस्ते", "भारत"]:
        print(s, "→", romanize(s))
