"""Text translation between Indian languages and English (healthcare, shops, anywhere two people share no language).

Uses Sarvam's translate API. The 22 official languages work through sarvam-translate. When the source
language is unknown ("auto") we use mayura, which can detect it. Needs SARVAM_API_KEY.
"""
import os

import requests

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


def groq_translate(text: str, source: str, target: str) -> str:
    """Backup when Sarvam is down: open Llama on Groq's free tier."""
    key = os.environ.get("GROQ_API_KEY")
    if not key:
        raise TranslateError("no GROQ_API_KEY")
    src = f"from {NAMES[source]} " if source in NAMES else ""
    prompt = f"Translate the user's text {src}into {NAMES.get(target, target)}. Reply with the translation only."
    r = requests.post("https://api.groq.com/openai/v1/chat/completions", headers={"Authorization": f"Bearer {key}"},
                      json={"model": "llama-3.3-70b-versatile", "temperature": 0.1, "max_tokens": 600,
                            "messages": [{"role": "system", "content": prompt}, {"role": "user", "content": text[:1000]}]},
                      timeout=25)
    if r.status_code != 200:
        raise TranslateError(f"groq http {r.status_code}")
    return (r.json()["choices"][0]["message"]["content"] or "").strip()


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
    r = requests.post(
        URL,
        headers={"api-subscription-key": key, "Content-Type": "application/json"},
        json={"input": text[:1000], "source_language_code": source, "target_language_code": target, "model": model},
        timeout=20,
    )
    if r.status_code != 200:
        raise TranslateError(f"sarvam http {r.status_code}")
    return r.json().get("translated_text", "")
