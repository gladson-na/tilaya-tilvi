"""Every Groq chat call goes through here, so a retired model is changed in one place.

Groq shut down Llama 3.3 70B, Llama 3.1 8B, Llama 4 Scout/Maverick and the "compound" models in 2026.
Current models: gpt-oss (text, live web search) and Qwen 3.8 27B (text and photos).
"""
import os
import re
import time

import requests

URL = "https://api.groq.com/openai/v1/chat/completions"
TEXT_MODELS = ("openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.8-27b")
VISION_MODELS = ("qwen/qwen3.8-27b",)
WEB_MODELS = ("openai/gpt-oss-120b", "openai/gpt-oss-20b")


class GroqError(Exception):
    pass


def _body(model, messages, max_tokens, temperature, json_mode, tools, extras):
    b = {"model": model, "messages": messages, "temperature": temperature}
    if model.startswith("openai/gpt-oss"):
        # reasoning tokens count against the limit, so leave room for them
        b["max_completion_tokens"] = max_tokens + 1500
        if extras:
            b["reasoning_effort"] = "low"
    else:
        b["max_tokens"] = max_tokens
        if extras:
            b["reasoning_effort"] = "none"
    if tools:
        b["tools"] = tools
        b["tool_choice"] = "required"
    elif json_mode:
        b["response_format"] = {"type": "json_object"}
    return b


def chat(messages, models=TEXT_MODELS, *, max_tokens=400, temperature=0.3, json_mode=False, tools=None,
         timeout=25.0, key=None) -> str:
    """The first model that answers wins. Never raises anything but GroqError; never waits past `timeout` in total."""
    key = key or os.environ.get("GROQ_API_KEY")
    if not key:
        raise GroqError("no GROQ_API_KEY")
    end = time.monotonic() + timeout
    last = "no model answered"
    for model in models:
        for extras in (True, False):  # second try without the reasoning switch, in case a model rejects it
            left = end - time.monotonic()
            if left < 2:
                raise GroqError(last + " (out of time)")
            try:
                r = requests.post(URL, headers={"Authorization": f"Bearer {key}"}, timeout=left,
                                  json=_body(model, messages, max_tokens, temperature, json_mode, tools, extras))
            except requests.RequestException as e:
                last = f"{model}: {type(e).__name__}"
                break
            if r.status_code == 200:
                try:
                    out = (r.json()["choices"][0]["message"].get("content") or "")
                except (KeyError, IndexError, ValueError, AttributeError):
                    last = f"{model}: unexpected answer"
                    break
                out = re.sub(r"<think>.*?</think>", "", out, flags=re.S).strip()
                if out:
                    return out
                last = f"{model}: empty answer"
                break
            last = f"{model}: http {r.status_code}"
            if r.status_code != 400:
                break
    raise GroqError(last)
