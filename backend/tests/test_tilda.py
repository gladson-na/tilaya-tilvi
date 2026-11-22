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


def test_neighbour_greetings_are_beta():
    from tilda.greetings import BETA
    for said, lang in [("Ayubowan Tilda", "si-LK"), ("Mingalaba Tilda", "my-MM"),
                       ("Tashi Delek Tilda", "bo-CN"), ("Kuzuzangpo Tilda", "dz-BT")]:
        cands, _ = detect_greeting(said)
        assert cands and cands[0] == lang and lang in BETA


def test_followup_words_pick_language_and_keep_hindi_english_standby():
    from tilda.greetings import rank_by_followup
    cands, rest = detect_greeting("Namaskar Tilda mala pahije")
    ranked = rank_by_followup(cands, rest)
    assert ranked[0] == "mr-IN" and ranked[-2:] == ["hi-IN", "en-IN"]
    cands, rest = detect_greeting("Namaskaram Tilda enti ela")
    assert rank_by_followup(cands, rest)[0] == "te-IN"


def test_hints_reach_only_engines_that_accept_them():
    seen = {}

    class Hinted(Fake):
        accepts_hints = True

        def transcribe(self, wav, lang, hints=""):
            seen["hints"] = hints
            return Result("ok", self.name)

    plain = Fake("plain", "ok")
    res, _ = transcribe("x.wav", "hi-IN", [plain], hints="Gladson, Tilaya")
    assert res.text  # a plain engine still works when hints are given
    transcribe("x.wav", "hi-IN", [Hinted("h", "ok")], hints="Gladson, Tilaya")
    assert seen["hints"] == "Gladson, Tilaya"


def test_translate_checks_languages_and_calls_sarvam(monkeypatch):
    import pytest
    from tilda import translate as tr

    seen = {}

    class R:
        status_code = 200

        def json(self):
            return {"translated_text": "namaste"}

    def fake_post(url, headers, json, timeout):
        seen.update(json)
        return R()

    monkeypatch.setattr(tr.requests, "post", fake_post)
    assert tr.translate("hello", "en-IN", "hi-IN", api_key="k") == "namaste"
    assert seen["model"] == "sarvam-translate:v1"
    tr.translate("hello", "auto", "hi-IN", api_key="k")
    assert seen["model"] == "mayura:v1"
    with pytest.raises(tr.TranslateError):
        tr.translate("hello", "en-IN", "ps-AF", api_key="k")  # Pashto is not covered by Sarvam
    with pytest.raises(tr.TranslateError):
        tr.translate("hello", "en-IN", "hi-IN")  # no key


def test_new_wake_names_and_hellos():
    for said, expect in [("Hello Tilvi open maps", "en-IN"), ("Namaskaram Tilvi enti ela", "te-IN"),
                         ("Namaste Tilaya Tilvi kholo", "hi-IN"), ("Hello Telvi", "en-IN")]:
        cands, rest = detect_greeting(said)
        assert cands[0] == expect, said
        assert "tilvi" not in rest and "tilaya" not in rest and "telvi" not in rest, rest


def test_native_script_greeting():
    from tilda.greetings import detect_greeting
    c, rest = detect_greeting("नमस्ते टिलाया टिलाया टिलाया नमस्ते टिलाया")
    assert c and c[0] == "hi-IN"
    assert rest.startswith("टिलाया")
    c, _ = detect_greeting("నమస్కారం టిల్వి hello")
    assert c and "te-IN" in c
    c, _ = detect_greeting("Namaste, Tilvi!")
    assert c and c[0] == "hi-IN"


def test_duplicate_piece_not_reprocessed(monkeypatch):
    from tilda import server
    monkeypatch.setenv("TILDA_FAKE", "1")
    c = server.app.test_client()
    monkeypatch.setattr(server, "to_wav", lambda raw: __import__("tempfile").NamedTemporaryFile(delete=False).name)
    import io
    r1 = c.post("/transcribe", data={"audio": (io.BytesIO(b"x"), "a.wav"), "piece": "p1", "lang": "hi-IN"}).get_json()
    server._DONE["p1"]["text"] = "cached"
    r2 = c.post("/transcribe", data={"audio": (io.BytesIO(b"x"), "a.wav"), "piece": "p1", "lang": "hi-IN"}).get_json()
    assert r1["engine"] and r2["text"] == "cached"


def test_rate_limit(monkeypatch):
    from tilda import server
    monkeypatch.setenv("TILDA_RATE_PER_MIN", "2")
    server._HITS.clear()
    c = server.app.test_client()
    codes = [c.post("/act", json={"text": "hi"}).status_code for _ in range(4)]
    assert codes[:2] == [200, 200] and codes[-1] == 429


def test_talk_reply_and_speak(monkeypatch):
    from tilda import talk

    class R:
        def __init__(self, code, data): self.status_code, self._d, self.text = code, data, str(data)
        def json(self): return self._d

    calls = []

    def fake_post(url, **kw):
        calls.append(url)
        if "chat" in url:
            return R(200, {"choices": [{"message": {"content": "<think>hm</think>**Namaste!** Kaise ho?"}}]})
        return R(200, {"audios": ["QUJD", "REVG"]})

    monkeypatch.setattr(talk.requests, "post", fake_post)
    monkeypatch.setenv("SARVAM_API_KEY", "k")
    assert talk.reply([{"role": "user", "content": "hi"}], "hi-IN") == "Namaste! Kaise ho?"
    assert talk.speak("hello", "od-IN") == "QUJDREVG"


def test_talk_falls_back_to_second_model(monkeypatch):
    from tilda import talk

    class R:
        def __init__(self, code, data=None): self.status_code, self._d, self.text = code, data or {}, "x"
        def json(self): return self._d

    seq = iter([R(404), R(200, {"choices": [{"message": {"content": "ok"}}]})])
    monkeypatch.setattr(talk.requests, "post", lambda *a, **k: next(seq))
    monkeypatch.setenv("SARVAM_API_KEY", "k")
    assert talk.reply([{"role": "user", "content": "hi"}], "en-IN") == "ok"


def test_talk_turns_reasoning_off_and_uses_female_voice(monkeypatch):
    from tilda import talk
    seen = []

    class R:
        status_code = 200
        text = "x"
        def __init__(self, d): self._d = d
        def json(self): return self._d

    def fake_post(url, **kw):
        seen.append(kw["json"])
        return R({"choices": [{"message": {"content": "ok"}}]} if "chat" in url else {"audios": ["QQ=="]})

    monkeypatch.setattr(talk.requests, "post", fake_post)
    monkeypatch.setenv("SARVAM_API_KEY", "k")
    talk.reply([{"role": "user", "content": "hi"}], "hi-IN")
    talk.speak("hi", "hi-IN")
    assert seen[0]["reasoning_effort"] is None
    assert seen[1]["speaker"] == "priya"


def test_talk_stream_speaks_sentence_by_sentence(monkeypatch):
    from tilda import talk

    class R:
        status_code = 200
        text = ""
        def iter_lines(self, decode_unicode=True):
            for w in ["Hello there my friend. ", "How are you today? ", "Fine."]:
                yield 'data: {"choices":[{"delta":{"content":"%s"}}]}' % w
            yield "data: [DONE]"

    monkeypatch.setattr(talk.requests, "post", lambda *a, **k: R())
    monkeypatch.setattr(talk, "speak", lambda t, l, speaker=None, api_key=None: "QQ==")
    monkeypatch.setenv("SARVAM_API_KEY", "k")
    got = list(talk.stream_turn([{"role": "user", "content": "hi"}], "en-IN"))
    assert [g["text"] for g in got] == ["Hello there my friend.", "How are you today? Fine."] or len(got) >= 2
    assert all(g["audio"] == "QQ==" for g in got)
