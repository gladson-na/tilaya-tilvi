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


def translate(text: str, source: str, target: str, api_key: str | None = None) -> str:
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
