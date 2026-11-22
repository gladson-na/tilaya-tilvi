"""The talking agent: Sarvam chat model for the answer, Sarvam Bulbul for the voice."""
import json
import os
import re

import requests

CHAT_URL = "https://api.sarvam.ai/v1/chat/completions"
TTS_URL = "https://api.sarvam.ai/text-to-speech"
CHAT_MODELS = ["sarvam-105b-conversations", "sarvam-105b"]
SPEECH_LANGS = {"hi-IN", "bn-IN", "ta-IN", "te-IN", "kn-IN", "ml-IN", "mr-IN", "gu-IN", "pa-IN", "od-IN", "en-IN"}

LANG_NAMES = {"hi-IN": "Hindi", "bn-IN": "Bengali", "ta-IN": "Tamil", "te-IN": "Telugu", "kn-IN": "Kannada",
              "ml-IN": "Malayalam", "mr-IN": "Marathi", "gu-IN": "Gujarati", "pa-IN": "Punjabi",
              "od-IN": "Odia", "en-IN": "English"}


class TalkError(Exception):
    pass


def _key(api_key=None):
    k = api_key or os.environ.get("SARVAM_API_KEY")
    if not k:
        raise TalkError("no SARVAM_API_KEY")
    return k


def system_prompt(lang: str) -> str:
    name = LANG_NAMES.get(lang, "the user's language")
    return (f"You are Tilda, a friendly voice assistant talking with someone out loud. Reply in {name}, "
            "in the same script the person uses. Keep answers to one to three short sentences, plain speech, "
            "You are a woman, so use feminine forms of speech where the language has them. no lists, no markdown, no emojis. If you are not sure, say so briefly. Ask at most one question back.")


def clean(text: str) -> str:
    text = re.sub(r"<think>.*?</think>", "", text or "", flags=re.S)
    text = re.sub(r"[*_#`>]+", "", text)
    return re.sub(r"\s+", " ", text).strip()


def reply(messages, lang: str, api_key=None) -> str:
    key = _key(api_key)
    turns = [{"role": m["role"], "content": str(m["content"])[:1500]}
             for m in (messages or []) if m.get("role") in ("user", "assistant")][-12:]
    if not turns:
        raise TalkError("nothing to answer")
    last = None
    for model in CHAT_MODELS:
        r = requests.post(
            CHAT_URL,
            headers={"api-subscription-key": key, "Content-Type": "application/json"},
            json={"model": model, "messages": [{"role": "system", "content": system_prompt(lang)}] + turns,
                  "temperature": 0.4, "max_tokens": 300, "reasoning_effort": None},
            timeout=40,
        )
        if r.status_code == 200:
            try:
                out = clean(r.json()["choices"][0]["message"]["content"])
            except (KeyError, IndexError, ValueError):
                last = "unexpected answer shape"
                continue
            if out:
                return out
            last = "empty answer"
        else:
            last = f"sarvam chat http {r.status_code}: {r.text[:200]}"
    raise TalkError(last or "no answer")


def speak(text: str, lang: str, speaker: str = None, api_key=None) -> str:
    """Returns base64 WAV audio."""
    key = _key(api_key)
    text = (text or "").strip()[:1500]
    if not text:
        raise TalkError("nothing to say")
    speaker = speaker or os.environ.get("TILDA_VOICE", "priya")
    code = lang if lang in SPEECH_LANGS else "en-IN"
    r = requests.post(
        TTS_URL,
        headers={"api-subscription-key": key, "Content-Type": "application/json"},
        json={"text": text, "target_language_code": code, "speaker": speaker, "model": "bulbul:v3"},
        timeout=30,
    )
    if r.status_code != 200:
        raise TalkError(f"sarvam tts http {r.status_code}: {r.text[:200]}")
    audios = r.json().get("audios") or []
    if not audios:
        raise TalkError("no audio returned")
    return "".join(audios)


_END = re.compile(r"(?<=[.!?\u0964\u0965])\s+")


def stream_turn(messages, lang: str, api_key=None):
    """Yields {"text", "audio"} one sentence at a time, so Tilda starts talking after the first sentence."""
    key = _key(api_key)
    turns = [{"role": m["role"], "content": str(m["content"])[:1500]}
             for m in (messages or []) if m.get("role") in ("user", "assistant")][-12:]
    if not turns:
        raise TalkError("nothing to answer")
    r = requests.post(
        CHAT_URL,
        headers={"api-subscription-key": key, "Content-Type": "application/json"},
        json={"model": CHAT_MODELS[0], "messages": [{"role": "system", "content": system_prompt(lang)}] + turns,
              "temperature": 0.4, "max_tokens": 300, "reasoning_effort": None, "stream": True},
        timeout=40, stream=True,
    )
    if r.status_code != 200:
        raise TalkError(f"sarvam chat http {r.status_code}: {r.text[:200]}")
    buf, sent = "", 0

    def out(text):
        text = clean(text)
        if not text:
            return None
        try:
            return {"text": text, "audio": speak(text, lang, api_key=key)}
        except TalkError as e:
            return {"text": text, "error": str(e)}

    for raw in r.iter_lines(decode_unicode=True):
        if not raw or not raw.startswith("data:"):
            continue
        data = raw[5:].strip()
        if data == "[DONE]":
            break
        try:
            buf += json.loads(data)["choices"][0]["delta"].get("content") or ""
        except (KeyError, IndexError, ValueError):
            continue
        parts = _END.split(buf)
        for sent_text in parts[:-1]:
            if len(sent_text) >= 12 or sent:
                item = out(sent_text)
                if item:
                    sent += 1
                    yield item
            else:
                parts[-1] = sent_text + " " + parts[-1]
        buf = parts[-1]
    item = out(buf)
    if item:
        yield item
