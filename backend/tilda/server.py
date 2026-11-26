"""Tiny test server. Run:  python -m tilda.server   (demo mode: TILDA_FAKE=1)

Flow: browser records -> POST /transcribe -> ffmpeg makes a 16 kHz WAV ->
1) quick first pass in Roman letters to catch a greeting -> 2) real pass in the greeted language.
"""
import json
import os
import subprocess
import tempfile
import time
from collections import OrderedDict, defaultdict, deque

from .agent import interpret
from flask import Flask, Response, jsonify, request, send_from_directory

from .engines import Engine, EngineError, Result, SarvamEngine, WhisperEngine, default_chain
from .greetings import BETA, GREETINGS, detect_greeting, rank_by_followup
from .router import AllEnginesFailed, transcribe
from .talk import TalkError, reply as talk_reply, speak as talk_speak, stream_turn as talk_stream
from . import tools
from .translate import TranslateError, translate, transliterate

app = Flask(__name__, static_folder="static")

# Protect the paid speech credits: a per-address rate limit, a daily cap, and a duplicate-upload cache.
_HITS = defaultdict(deque)
_DAY = {"day": "", "n": 0}
_DONE = OrderedDict()  # piece id -> finished answer, so a retried upload is not billed twice


@app.before_request
def _guard():
    if request.method != "POST":
        return None
    ip = (request.headers.get("X-Forwarded-For", request.remote_addr or "?")).split(",")[0].strip()
    now = time.time()
    q = _HITS[ip]
    while q and now - q[0] > 60:
        q.popleft()
    if len(q) >= int(os.environ.get("TILDA_RATE_PER_MIN", "40")):
        return jsonify(error="too many requests, slow down"), 429
    q.append(now)
    day = time.strftime("%Y-%m-%d", time.gmtime())
    if _DAY["day"] != day:
        _DAY.update(day=day, n=0)
    _DAY["n"] += 1
    if _DAY["n"] > int(os.environ.get("TILDA_DAILY_CAP", "3000")):
        return jsonify(error="daily limit reached"), 429
    return None


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


@app.get("/health")
def health():
    return "ok"


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


@app.post("/chat")
def do_chat():
    j = request.get_json(silent=True) or {}
    msgs, lang = j.get("messages", []), j.get("lang", "en-IN")
    if os.environ.get("TILDA_FAKE"):
        return jsonify(reply="(demo reply) " + (msgs[-1]["content"] if msgs else ""))
    try:
        return jsonify(reply=talk_reply(msgs, lang))
    except TalkError as e:
        app.logger.error("chat failed: %s", e)
        return jsonify(error=str(e)), 502
    except Exception as e:  # network problems must not crash the worker
        app.logger.error("chat crashed: %s", e)
        return jsonify(error="chat unavailable"), 502


@app.post("/talk")
def talk_route():
    """Streams the answer sentence by sentence, each with its voice, as one JSON object per line."""
    j = request.get_json(silent=True) or {}
    msgs, lang = j.get("messages", []), j.get("lang", "en-IN")

    def num(v):
        try:
            return float(v)
        except (TypeError, ValueError):
            return None

    lat, lon = num(j.get("lat")), num(j.get("lon"))

    def gen():
        try:
            if os.environ.get("TILDA_FAKE"):
                yield json.dumps({"text": talk_reply(msgs, lang)}) + "\n"
                return
            ctx = tools.context_for(msgs, lat, lon)
            if ctx["intent"]:
                yield json.dumps({"intent": ctx["intent"]}) + "\n"
            for item in talk_stream(msgs, lang, extra=ctx["extra"], voice=j.get("voice") is not False):
                yield json.dumps(item) + "\n"
        except TalkError as e:
            yield json.dumps({"error": str(e)}) + "\n"
        except Exception as e:  # a failing lookup must never leave the person in silence
            app.logger.error("talk crashed: %s", e)
            yield json.dumps({"error": "talk unavailable"}) + "\n"

    return Response(gen(), mimetype="application/x-ndjson", headers={"X-Accel-Buffering": "no", "Cache-Control": "no-cache"})


@app.post("/feedback")
def feedback():
    j = request.get_json(silent=True) or {}
    kind, text = j.get("kind", "suggestion"), str(j.get("text", "")).strip()[:2000]
    if kind not in ("complaint", "suggestion") or not text:
        return jsonify(error="say what the complaint or suggestion is"), 400
    return jsonify(tools.save_feedback(kind, text, str(j.get("lang", ""))[:12], str(j.get("who", ""))[:60]))


@app.post("/summary")
def do_summary():
    j = request.get_json(silent=True) or {}
    text, lang = str(j.get("text", "")).strip(), j.get("lang", "en-IN")
    if len(text) < 20:
        return jsonify(error="not enough words to summarise yet"), 400
    if os.environ.get("TILDA_FAKE"):
        return jsonify(text="Notes\n- (demo) " + text[:80])
    try:
        from .translate import NAMES
        return jsonify(text=tools.summarize(text, NAMES.get(lang, "English")))
    except tools.ToolError as e:
        return jsonify(error=str(e)), 502


@app.post("/translit")
def do_translit():
    j = request.get_json(silent=True) or {}
    text, source, target = j.get("text", ""), j.get("source", "auto"), j.get("target", "hi-IN")
    if os.environ.get("TILDA_FAKE"):
        return jsonify(text=f"(demo letters in {target}) {text}", target=target)
    try:
        return jsonify(text=transliterate(text, source, target), target=target)
    except TranslateError as e:
        return jsonify(error=str(e)), 502


@app.post("/speak")
def do_speak():
    j = request.get_json(silent=True) or {}
    if os.environ.get("TILDA_FAKE"):
        return jsonify(error="no voice in demo mode"), 503
    try:
        audio = talk_speak(j.get("text", ""), j.get("lang", "en-IN"))
        if j.get("pan") in ("l", "r"):  # earbud mode: the voice plays in one ear only
            audio = pan_audio(audio, j["pan"])
        return jsonify(audio=audio)
    except TalkError as e:
        app.logger.error("speak failed: %s", e)
        return jsonify(error=str(e)), 502
    except Exception as e:
        app.logger.error("speak crashed: %s", e)
        return jsonify(error="voice unavailable"), 502


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
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src.name,
                    "-af", "highpass=f=90,afftdn=nr=12:nf=-30,dynaudnorm=f=150:g=7",  # cut traffic rumble and hiss, even out loudness
                    "-ar", "16000", "-ac", "1", out], check=True)
    os.unlink(src.name)
    return out


def pan_audio(b64: str, side: str) -> str:
    """Stereo mp3 with the voice in the left or right ear only. Falls back to the plain audio if ffmpeg fails."""
    import base64
    src = tempfile.NamedTemporaryFile(suffix=".bin", delete=False)
    src.write(base64.b64decode(b64))
    src.close()
    out = src.name + ".mp3"
    pan = "pan=stereo|c0=c0|c1=0*c0" if side == "l" else "pan=stereo|c0=0*c0|c1=c0"
    try:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src.name, "-af", pan, "-b:a", "32k", out],
                       check=True, timeout=20)
        with open(out, "rb") as f:
            return base64.b64encode(f.read()).decode()
    except Exception:
        return b64
    finally:
        for f in (src.name, out):
            try:
                os.unlink(f)
            except OSError:
                pass


@app.post("/transcribe")
def do_transcribe():
    piece = request.form.get("piece", "")
    if piece and piece in _DONE:
        return jsonify(_DONE[piece])
    raw = request.files["audio"].read()
    forced = request.form.get("lang", "auto")  # "auto" = greeting then auto-detect
    mine = [x for x in request.form.get("mine", "").split(",") if x][:12]  # the user's own languages
    hints = request.form.get("hints", "")[:400]  # optional personal word list, used for this request only
    wav = to_wav(raw)
    first_chain, main_chain = chains()
    log, greeting_langs, said = [], None, ""
    try:
        if forced == "auto" and request.form.get("fast") != "1":  # fast: long notes skip the greeting check
            try:
                first, first_log = transcribe(wav, "unknown", first_chain, timeout=8)
                said = first.text
                greeting_langs, rest = detect_greeting(said)
                if greeting_langs:
                    # Standby set: greeting languages the user really speaks. If none match, keep all.
                    own = [l for l in greeting_langs if l in mine]
                    ranked = rank_by_followup(own or greeting_langs, rest)
                    # the standby languages go first; Hindi and English stay only as last resorts
                    greeting_langs = ranked
                    # Still several? The engine's own guess on the words after the name breaks the tie.
                    heard = getattr(first, "language", None)
                    if heard in greeting_langs:
                        greeting_langs = [heard] + [l for l in greeting_langs if l != heard]
            except AllEnginesFailed as e:
                first_log = e.attempts
            log += [("first pass: " + a, b) for a, b in first_log]
        langs = [forced] if forced != "auto" else (greeting_langs or ["unknown"])
        err = None
        for lang in langs:
            try:
                res, main_log = transcribe(wav, lang, main_chain, timeout=8, hints=hints)
                log += main_log
                if lang == "unknown" and mine and res.language not in mine:
                    # auto-detect picked a language the user does not speak: use their first one
                    lang = mine[0]
                    res, main_log = transcribe(wav, lang, main_chain, timeout=8, hints=hints)
                    log += main_log
                answer = dict(text=res.text, engine=res.engine, language=lang,
                              greeting_found=bool(greeting_langs), heard_first=said, log=log,
                              action=interpret(res.text))
                if piece:
                    _DONE[piece] = answer
                    while len(_DONE) > 200:
                        _DONE.popitem(last=False)
                return jsonify(answer)
            except AllEnginesFailed as e:
                log += e.attempts
                err = e
        app.logger.error("every engine failed: %s", log)
        return jsonify(error="every engine failed", log=log), 502
    finally:
        os.unlink(wav)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8000)))
