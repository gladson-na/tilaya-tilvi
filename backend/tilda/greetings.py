"""Greeting -> language table. Say "<greeting> <name>" and the app knows the language.

Every entry is UNVERIFIED: a native speaker must check each one before the demo.
Sarvam codes other than the 11 big languages are assumed and must be checked
against Sarvam's docs when we have the key.
"""
import difflib
import re

WAKE_NAME = "tilda"  # placeholder name, change in one place

# language code (BCP-47 style, Sarvam-like) -> greetings in Roman letters
GREETINGS = {
    "te-IN": ["namaskaram"],
    "hi-IN": ["namaste", "ram ram", "pranam"],  # "ram ram" is a Haryanvi/Hindi-belt greeting
    "ta-IN": ["vanakkam"],
    "kn-IN": ["namaskara"],
    "ml-IN": ["namaskaram"],
    "mr-IN": ["namaskar"],
    "gu-IN": ["kem cho", "namaste"],
    "bn-IN": ["nomoskar", "namaskar"],
    "od-IN": ["namaskar"],
    "pa-IN": ["sat sri akal", "sasriakal"],
    "as-IN": ["nomoskar"],
    "ur-IN": ["assalam alaikum", "adaab"],
    "ne-IN": ["namaste"],
    "kok-IN": ["namaskar", "dev borem dis dium"],
    "mai-IN": ["pranam"],
    "doi-IN": ["namaste"],
    "ks-IN": ["adaab", "salaam"],
    "sd-IN": ["salaam", "adaab"],
    "sa-IN": ["namo namah", "namaste"],
    "sat-IN": ["johar"],
    "mni-IN": ["khurumjari"],
    "brx-IN": ["khulumbai"],
    "en-IN": ["hello", "hey", "hi"],
}

# When a greeting is shared by several languages we try them in this order.
PRIORITY = ["hi-IN", "te-IN", "ta-IN", "kn-IN", "ml-IN", "mr-IN", "bn-IN", "gu-IN", "pa-IN", "od-IN"]


def _norm(text: str) -> str:
    return re.sub(r"[^a-z ]", "", text.lower()).strip()


def _build_index():
    idx = {}
    for lang, words in GREETINGS.items():
        for w in words:
            idx.setdefault(_norm(w), []).append(lang)
    for w in idx:
        idx[w].sort(key=lambda l: PRIORITY.index(l) if l in PRIORITY else 99)
    return idx


INDEX = _build_index()


def detect_greeting(text: str, name: str = WAKE_NAME, cutoff: float = 0.8):
    """Return (candidate_languages, rest_of_text) or (None, text).

    Matching is fuzzy so different spellings of the same sound still work.
    Only looks at the start of the text.
    """
    words = _norm(text).split()
    if not words:
        return None, text
    # try the longest greeting first (up to 4 words)
    for n in (4, 3, 2, 1):
        head = " ".join(words[:n])
        match = difflib.get_close_matches(head, INDEX.keys(), n=1, cutoff=cutoff)
        if match:
            rest = words[n:]
            if rest and difflib.SequenceMatcher(None, rest[0], name).ratio() >= 0.7:
                rest = rest[1:]
            return INDEX[match[0]], " ".join(rest)
    return None, text
