"""Fallback router: try engines in order; on error, timeout or empty text, go to the next."""
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutTimeout

from .engines import Engine, Result, default_chain
from .greetings import detect_greeting

_pool = ThreadPoolExecutor(max_workers=4)


class AllEnginesFailed(Exception):
    def __init__(self, attempts):
        super().__init__("every engine failed")
        self.attempts = attempts


def transcribe(wav_path: str, lang: str, chain: list[Engine] | None = None, timeout: float = 8.0):
    """Return (Result, attempts). attempts is a list of (engine, outcome) for the demo log."""
    attempts = []
    for eng in chain or default_chain():
        if not eng.supports(lang):
            attempts.append((eng.name, "skipped: language not supported"))
            continue
        fut = _pool.submit(eng.transcribe, wav_path, lang)
        try:
            res: Result = fut.result(timeout=timeout)
        except FutTimeout:
            attempts.append((eng.name, "timeout"))
            continue
        except Exception as e:  # any failure means: try the next layer
            attempts.append((eng.name, f"error: {e}"))
            continue
        if not res.text.strip():
            attempts.append((eng.name, "empty"))
            continue
        attempts.append((eng.name, "ok"))
        return res, attempts
    raise AllEnginesFailed(attempts)


def transcribe_with_greeting(wav_path: str, first_words: str, chain=None, timeout: float = 8.0):
    """first_words: quick text of the opening seconds (from any engine) used to spot the greeting.

    Greeting found  -> use its language(s), most likely first.
    No greeting     -> language "unknown" (auto-detect, supported by Sarvam and Whisper).
    """
    candidates, _ = detect_greeting(first_words)
    langs = candidates or ["unknown"]
    last = None
    for lang in langs:
        try:
            return transcribe(wav_path, lang, chain, timeout) + (lang,)
        except AllEnginesFailed as e:
            last = e
    raise last
