import time
import pytest
from tilda.engines import Engine, EngineError, Result
from tilda.greetings import detect_greeting
from tilda.router import AllEnginesFailed, transcribe, transcribe_with_greeting


class Fake(Engine):
    def __init__(self, name, behaviour, langs=None):
        self.name, self.behaviour, self.langs = name, behaviour, langs

    def transcribe(self, wav, lang):
        if self.behaviour == "error":
            raise EngineError("boom")
        if self.behaviour == "slow":
            time.sleep(1)
        if self.behaviour == "empty":
            return Result("", self.name)
        return Result(f"text from {self.name} in {lang}", self.name)


def test_goes_down_the_chain():
    chain = [Fake("a", "error"), Fake("b", "slow"), Fake("c", "empty"), Fake("d", "ok")]
    res, log = transcribe("x.wav", "te-IN", chain, timeout=0.2)
    assert res.engine == "d"
    assert [o for _, o in log][:3] == ["error: boom", "timeout", "empty"]


def test_skips_unsupported_language():
    chain = [Fake("a", "ok", langs={"hi-IN"}), Fake("b", "ok")]
    res, log = transcribe("x.wav", "te-IN", chain)
    assert res.engine == "b" and log[0][1].startswith("skipped")


def test_all_fail():
    with pytest.raises(AllEnginesFailed):
        transcribe("x.wav", "hi-IN", [Fake("a", "error"), Fake("b", "error")])


@pytest.mark.parametrize("said,lang", [
    ("Namaskaram Tilda please remind me", "te-IN"),
    ("namaskaram tilda", "te-IN"),
    ("Vanakkam Tilda", "ta-IN"),
    ("Namaste Tilda open maps", "hi-IN"),
    ("Sat Sri Akal Tilda", "pa-IN"),
    ("namaskaaram tilda", "te-IN"),  # different spelling
])
def test_greeting_picks_language(said, lang):
    cands, _ = detect_greeting(said)
    assert cands and cands[0] == lang


def test_greeting_strips_name_and_keeps_rest():
    _, rest = detect_greeting("Namaste Tilda open maps")
    assert rest == "open maps"


def test_no_greeting_means_auto_detect():
    assert detect_greeting("open maps please")[0] is None
    res, log, lang = transcribe_with_greeting("x.wav", "open maps please", [Fake("a", "ok")])
    assert lang == "unknown"


def test_shared_greeting_tries_next_language():
    # "namaste" is shared; Hindi first. If every engine fails for hi-IN, try the next candidate.
    class OnlyNepali(Fake):
        def transcribe(self, wav, lang):
            if lang != "ne-IN":
                raise EngineError("no")
            return Result("ok", self.name)
    res, log, lang = transcribe_with_greeting("x.wav", "namaste tilda", [OnlyNepali("n", "ok")])
    assert lang == "ne-IN"


def test_server_demo_mode(monkeypatch, tmp_path):
    import subprocess, io
    monkeypatch.setenv("TILDA_FAKE", "1")
    wav = tmp_path / "t.webm"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", str(wav)], check=True)
    from tilda.server import app
    c = app.test_client()
    r = c.post("/transcribe", data={"audio": (io.BytesIO(wav.read_bytes()), "a.webm"), "lang": "te-IN"})
    j = r.get_json()
    assert r.status_code == 200 and j["engine"] == "demo-conformer" and j["language"] == "te-IN"
    assert j["log"][0][1].startswith("error")
    assert c.get("/").status_code == 200


def test_agent_actions():
    from tilda.agent import interpret
    assert interpret("Volume up")["action"] == "volume_up"
    assert interpret("awaz kam karo")["action"] == "volume_down"
    assert interpret("open YouTube")["action"] == "open_app"
    assert interpret("youtube kholo")["args"]["app"] == "youtube"
    assert interpret("search cheap flights to Pune")["args"]["query"] == "cheap flights to pune"
    assert interpret("blah blah")["action"] == "none"
    assert interpret("")["action"] == "none"


def test_agent_asks_before_spending_or_sending():
    from tilda.agent import interpret
    assert interpret("book a train to Pune")["needs_yes"] is True
    assert interpret("send message to Raj")["needs_yes"] is True
    assert interpret("open maps")["needs_yes"] is False


def test_agent_ignores_unsafe_llm_answer():
    from tilda.agent import interpret
    r = interpret("volume up", llm=lambda t: {"action": "delete_everything"})
    assert r["action"] == "volume_up"
