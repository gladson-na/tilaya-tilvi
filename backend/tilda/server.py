"""Tiny test server. Run:  python -m tilda.server   (demo mode: TILDA_FAKE=1)

Flow: browser records -> POST /transcribe -> ffmpeg makes a 16 kHz WAV ->
1) quick first pass in Roman letters to catch a greeting -> 2) real pass in the greeted language.
"""
import os
import subprocess
import tempfile

from .agent import interpret
from flask import Flask, jsonify, request, send_from_directory

from .engines import Engine, EngineError, Result, SarvamEngine, WhisperEngine, default_chain
from .greetings import BETA, GREETINGS, detect_greeting, rank_by_followup
from .router import AllEnginesFailed, transcribe
from .translate import TranslateError, translate

app = Flask(__name__, static_folder="static")


class _Demo(Engine):
    """Fake engines so the page can be tried before any key or model exists."""

    def __init__(self, name, fail):
        self.name, self.fail = name, fail

    def transcribe(self, wav, lang):
        if self.fail:
            raise EngineError("demo failure")
        return Result(f"(demo text, language {lang})", self.name)


def chains():
    if os.environ.get("TILDA_FAKE"):
        demo = [_Demo("demo-sarvam", True), _Demo("demo-conformer", False)]
        return demo, demo
    # first pass uses Roman letters so greetings like "namaskaram" can be matched
    return [SarvamEngine(mode="translit"), WhisperEngine("small", "whisper-small")], default_chain()


@app.get("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


@app.post("/act")
def act():
    return jsonify(interpret((request.get_json(silent=True) or {}).get("text", "")))


@app.post("/translate")
def do_translate():
    j = request.get_json(silent=True) or {}
    text, source, target = j.get("text", ""), j.get("source", "auto"), j.get("target", "en-IN")
    if os.environ.get("TILDA_FAKE"):
        return jsonify(text=f"(demo translation to {target}) {text}", target=target)
    try:
        return jsonify(text=translate(text, source, target), target=target)
    except TranslateError as e:
        return jsonify(error=str(e)), 502


@app.get("/languages")
def languages():
    return jsonify(sorted(GREETINGS))


@app.get("/beta")
def beta():
    return jsonify(sorted(BETA))


def to_wav(raw: bytes) -> str:
    src = tempfile.NamedTemporaryFile(suffix=".webm", delete=False)
    src.write(raw)
    src.close()
    out = src.name + ".wav"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src.name, "-ar", "16000", "-ac", "1", out], check=True)
    os.unlink(src.name)
    return out


@app.post("/transcribe")
def do_transcribe():
    raw = request.files["audio"].read()
    forced = request.form.get("lang", "auto")  # "auto" = greeting then auto-detect
    hints = request.form.get("hints", "")[:400]  # optional personal word list, used for this request only
    wav = to_wav(raw)
    first_chain, main_chain = chains()
    log, greeting_langs, said = [], None, ""
    try:
        if forced == "auto":
            try:
                first, first_log = transcribe(wav, "unknown", first_chain, timeout=8)
                said = first.text
                greeting_langs, rest = detect_greeting(said)
                if greeting_langs:
                    greeting_langs = rank_by_followup(greeting_langs, rest)
            except AllEnginesFailed as e:
                first_log = e.attempts
            log += [("first pass: " + a, b) for a, b in first_log]
        langs = [forced] if forced != "auto" else (greeting_langs or ["unknown"])
        err = None
        for lang in langs:
            try:
                res, main_log = transcribe(wav, lang, main_chain, timeout=8, hints=hints)
                log += main_log
                return jsonify(text=res.text, engine=res.engine, language=lang,
                               greeting_found=bool(greeting_langs), heard_first=said, log=log,
                               action=interpret(res.text))
            except AllEnginesFailed as e:
                log += e.attempts
                err = e
        return jsonify(error="every engine failed", log=log), 502
    finally:
        os.unlink(wav)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8000)))
