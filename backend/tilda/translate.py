"""Text translation between Indian languages and English (healthcare, shops, anywhere two people share no language).

Uses Sarvam's translate API. The 22 official languages work through sarvam-translate. When the source
language is unknown ("auto") we use mayura, which can detect it. Needs SARVAM_API_KEY.
"""
import os

import requests

from . import groq

URL = "https://api.sarvam.ai/translate"
# Sarvam covers the 22 official languages plus English. The neighbour-country languages are NOT covered.
SUPPORTED = {
    "en-IN", "hi-IN", "te-IN", "ta-IN", "kn-IN", "ml-IN", "mr-IN", "gu-IN", "bn-IN", "pa-IN", "od-IN",
    "as-IN", "ur-IN", "ne-IN", "kok-IN", "mai-IN", "doi-IN", "ks-IN", "sd-IN", "sa-IN", "sat-IN",
    "mni-IN", "brx-IN",
}


class TranslateError(Exception):
    pass


NAMES = {"en-IN": "English", "hi-IN": "Hindi", "te-IN": "Telugu", "ta-IN": "Tamil", "kn-IN": "Kannada",
         "ml-IN": "Malayalam", "mr-IN": "Marathi", "gu-IN": "Gujarati", "bn-IN": "Bengali", "pa-IN": "Punjabi",
         "od-IN": "Odia", "as-IN": "Assamese", "ur-IN": "Urdu", "ne-IN": "Nepali"}


def _pieces(text: str, size: int = 900) -> list:
    """Cuts long text at sentence ends so every piece fits the translation engines."""
    from .tools import _split
    return _split(text, size) or [text]


def groq_translate(text: str, source: str, target: str) -> str:
    """Backup when Sarvam is down: Groq's open models."""
    if not os.environ.get("GROQ_API_KEY"):
        raise TranslateError("no GROQ_API_KEY")
    src = f"from {NAMES[source]} " if source in NAMES else ""
    prompt = f"Translate the user's text {src}into {NAMES.get(target, target)}. Reply with the translation only."
    out = []
    for piece in _pieces(text):
        try:
            out.append(groq.chat([{"role": "system", "content": prompt}, {"role": "user", "content": piece}],
                                 max_tokens=700, temperature=0.1, timeout=25))
        except groq.GroqError as e:
            raise TranslateError(f"groq: {e}")
    return " ".join(out).strip()


def translate(text: str, source: str, target: str, api_key: str | None = None) -> str:
    try:
        return sarvam_translate(text, source, target, api_key)
    except TranslateError as sarvam_err:
        if str(sarvam_err).startswith("translation to") or str(sarvam_err).startswith("translation from"):
            raise
        try:
            return groq_translate(text, source, target)
        except TranslateError as e:
            raise TranslateError(f"{sarvam_err}; backup: {e}")


def sarvam_translate(text: str, source: str, target: str, api_key: str | None = None) -> str:
    text = (text or "").strip()
    if not text:
        return ""
    if target not in SUPPORTED:
        raise TranslateError(f"translation to {target} is not supported yet")
    if source != "auto" and source not in SUPPORTED:
        raise TranslateError(f"translation from {source} is not supported yet")
    key = api_key or os.environ.get("SARVAM_API_KEY")
    if not key:
        raise TranslateError("no SARVAM_API_KEY")
    model = "mayura:v1" if source == "auto" else "sarvam-translate:v1"
    out = []
    for piece in _pieces(text):
        try:
            r = requests.post(
                URL,
                headers={"api-subscription-key": key, "Content-Type": "application/json"},
                json={"input": piece, "source_language_code": source, "target_language_code": target, "model": model},
                timeout=20,
            )
        except requests.RequestException as e:
            raise TranslateError(f"sarvam network: {type(e).__name__}")
        if r.status_code != 200:
            raise TranslateError(f"sarvam http {r.status_code}")
        out.append(r.json().get("translated_text", ""))
    return " ".join(x for x in out if x).strip()


def groq_translit(text: str, target: str) -> str:
    if not os.environ.get("GROQ_API_KEY"):
        raise TranslateError("no GROQ_API_KEY")
    prompt = (f"Write the user's text in {NAMES.get(target, target)} script, exactly as it sounds. Do not translate: keep the "
              f"same words, spelling foreign words the way {NAMES.get(target, target)} speakers write them. If it is already in "
              "that script, return it unchanged. Reply with the result only.")
    out = []
    for piece in _pieces(text):
        try:
            out.append(groq.chat([{"role": "system", "content": prompt}, {"role": "user", "content": piece}],
                                 max_tokens=700, temperature=0.1, timeout=25))
        except groq.GroqError as e:
            raise TranslateError(f"groq: {e}")
    return " ".join(out).strip()


def transliterate(text: str, source: str, target: str, api_key: str | None = None) -> str:
    """Same words, written in another script (English speech in Hindi letters). Sarvam first, Groq as backup."""
    text = (text or "").strip()
    if not text:
        return ""
    key = api_key or os.environ.get("SARVAM_API_KEY")
    err = "no SARVAM_API_KEY"
    if key and target in SUPPORTED:
        try:
            r = requests.post("https://api.sarvam.ai/transliterate",
                              headers={"api-subscription-key": key, "Content-Type": "application/json"},
                              json={"input": text[:1000], "source_language_code": source if source in SUPPORTED else "auto",
                                    "target_language_code": target}, timeout=15)
            if r.status_code == 200 and r.json().get("transliterated_text"):
                return r.json()["transliterated_text"]
            err = f"sarvam http {r.status_code}"
        except requests.RequestException as e:
            err = f"sarvam {e.__class__.__name__}"
    try:
        return groq_translit(text, target)
    except TranslateError as e:
        raise TranslateError(f"{err}; backup: {e}")
