"""Greeting -> language table. Say "<greeting> <name>" and the app knows the language.

Every entry is UNVERIFIED: a native speaker must check each one before the demo.
Sarvam codes other than the 11 big languages are assumed and must be checked
against Sarvam's docs when we have the key.
"""
import difflib
import unicodedata

WAKE_NAME = "tilda"  # placeholder name, kept for old callers
# Any of these after the greeting counts as calling the assistant. Final name undecided.
WAKE_NAMES = ["tilda", "tilvi", "tilaya", "tilaya tilvi", "telvi", "tilvy", "thilvi"]

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
    # Neighbouring countries. BETA: thin training data, greetings unverified.
    "ur-PK": ["assalam alaikum", "adaab"],
    "ps-AF": ["salaam", "starey mashe"],
    "bo-CN": ["tashi delek"],
    "ne-NP": ["namaste"],
    "dz-BT": ["kuzuzangpo", "kuzu zangpo"],
    "si-LK": ["ayubowan"],
    "my-MM": ["mingalaba"],
    "bn-BD": ["assalamu alaikum", "nomoshkar"],
    "en-IN": ["hello", "hey", "hi", "hallo", "helo", "hai", "good morning", "good evening"],
}
# Extra hello words that also open a session in the language family they belong to.
GREETINGS["hi-IN"] += ["radhe radhe", "jai shri ram", "jai hind", "hello ji"]
GREETINGS["te-IN"] += ["namaskaram andi", "baagunnara"]
GREETINGS["ta-IN"] += ["vannakam", "vanakam"]
GREETINGS["pa-IN"] += ["sat shri akal"]
GREETINGS["bn-IN"] += ["nomoshkar"]

BETA = {"ur-PK", "ps-AF", "bo-CN", "ne-NP", "dz-BT", "si-LK", "my-MM", "bn-BD"}

# Always kept on standby after the specific candidates: people mix Hindi and English.
TAIL = ["hi-IN", "en-IN"]

# A few common Roman-letter words per language. The words after the greeting and the
# name vote for the language when the greeting is shared. UNVERIFIED, grow this list.
MARKERS = {
    "te-IN": "enti ela cheyyi naaku kavali undi ledu chesi cheppu",
    "hi-IN": "kya hai mujhe karo kholo chahiye nahi batao",
    "mr-IN": "kay ahe mala kara pahije sang",
    "gu-IN": "shu che mane joiye kem kholo",
    "bn-IN": "ki ami amar korbo koro ache lagbe",
    "od-IN": "kana mu mora kara achhi",
    "kn-IN": "yenu naanu beku maadi illa",
    "ml-IN": "enthu njan venam cheyyu illa",
    "ta-IN": "enna naan venum pannu illa",
    "pa-IN": "mainu chahida karo haiga",
    "ur-PK": "kya mujhe chahiye hai karo",
    "ne-NP": "ke malai chahincha garnus hunchha",
}

# When a greeting is shared by several languages we try them in this order.
PRIORITY = ["hi-IN", "te-IN", "ta-IN", "kn-IN", "ml-IN", "mr-IN", "bn-IN", "gu-IN", "pa-IN", "od-IN"]


def _norm(text: str) -> str:
    """Lowercase, drop punctuation and symbols, keep letters and marks of every script."""
    kept = "".join(c for c in text.lower() if c == " " or unicodedata.category(c)[0] in "LMN")
    return " ".join(kept.split())


# The same greetings and names as they come back in native script (Sarvam answers in it).
GREETINGS["hi-IN"] += ["नमस्ते", "राम राम", "प्रणाम", "जय हिंद", "हेलो", "हैलो"]
GREETINGS["mr-IN"] += ["नमस्कार"]
GREETINGS["ne-IN"] += ["नमस्ते"]
GREETINGS["te-IN"] += ["నమస్కారం", "నమస్కారము"]
GREETINGS["ta-IN"] += ["வணக்கம்"]
GREETINGS["kn-IN"] += ["ನಮಸ್ಕಾರ"]
GREETINGS["ml-IN"] += ["നമസ്കാരം"]
GREETINGS["bn-IN"] += ["নমস্কার", "নমস্তে"]
GREETINGS["gu-IN"] += ["નમસ્તે", "કેમ છો"]
GREETINGS["pa-IN"] += ["ਸਤ ਸ੍ਰੀ ਅਕਾਲ"]
GREETINGS["od-IN"] += ["ନମସ୍କାର"]
GREETINGS["ur-IN"] += ["السلام علیکم"]
WAKE_NAMES += ["टिलाया", "टिल्वी", "टिलवी", "तिलवी", "तिलाया", "टिल्डा", "तेलवी", "टिलाया टिल्वी",
               "టిల్వి", "டில்வி", "ಟಿಲ್ವಿ", "ടിൽവി", "টিলভি"]


def _build_index():
    idx = {}
    for lang, words in GREETINGS.items():
        for w in words:
            idx.setdefault(_norm(w), []).append(lang)
    for w in idx:
        idx[w].sort(key=lambda l: PRIORITY.index(l) if l in PRIORITY else 99)
    return idx


INDEX = _build_index()


def detect_greeting(text: str, name=None, cutoff: float = 0.8):
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
            names = [name] if name else WAKE_NAMES
            # longest name first so "tilaya tilvi" is dropped as one call
            for nm in sorted(names, key=lambda x: -len(x.split())):
                k = len(nm.split())
                if len(rest) >= k and difflib.SequenceMatcher(None, " ".join(rest[:k]), nm).ratio() >= 0.7:
                    rest = rest[k:]
                    break
            return INDEX[match[0]], " ".join(rest)
    return None, text


def rank_by_followup(candidates, rest: str):
    """Greeting gave several possible languages; the words after the name pick the best.

    Languages with more matching marker words go first, ties keep the original order.
    Hindi and English are always appended as the last standby (people code-mix).
    """
    words = set(_norm(rest).split())
    score = lambda l: len(words & set(MARKERS.get(l, "").split()))
    ranked = sorted(candidates, key=lambda l: -score(l))
    return ranked + [t for t in TAIL if t not in ranked]
