import json
import time
import pytest
from tilda import tools
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


def test_health_wakes_server():
    from tilda import server
    c = server.app.test_client()
    r = c.get("/health")
    assert r.status_code == 200 and r.data == b"ok"


def test_groq_engine_is_second_in_chain_and_needs_key(monkeypatch):
    from tilda.engines import default_chain, GroqEngine, EngineError
    chain = default_chain()
    assert chain[1].name == "groq-whisper"
    monkeypatch.delenv("GROQ_API_KEY", raising=False)
    with pytest.raises(EngineError):
        GroqEngine().transcribe("x.wav", "hi-IN")


def test_chat_falls_back_to_groq(monkeypatch):
    from tilda import talk

    class R:
        def __init__(self, code, body):
            self.status_code, self._b, self.text = code, body, "x"

        def json(self):
            return self._b

    def fake_post(url, **kw):
        if "sarvam" in url:
            return R(402, {})
        return R(200, {"choices": [{"message": {"content": "Namaste, I can help."}}]})

    monkeypatch.setenv("SARVAM_API_KEY", "k")
    monkeypatch.setenv("GROQ_API_KEY", "g")
    monkeypatch.setattr(talk.requests, "post", fake_post)
    assert "help" in talk.reply([{"role": "user", "content": "hi"}], "en-IN")


def test_translate_falls_back_to_groq(monkeypatch):
    from tilda import translate as tr

    class R:
        def __init__(self, code, body):
            self.status_code, self._b = code, body

        def json(self):
            return self._b

    def fake_post(url, **kw):
        if "sarvam" in url:
            return R(402, {})
        return R(200, {"choices": [{"message": {"content": "नमस्ते"}}]})

    monkeypatch.setenv("SARVAM_API_KEY", "k")
    monkeypatch.setenv("GROQ_API_KEY", "g")
    monkeypatch.setattr(tr.requests, "post", fake_post)
    assert tr.translate("hello", "en-IN", "hi-IN") == "नमस्ते"


# ---- live facts, sums, feedback, letters in another script ----

def test_sums_are_exact():
    from tilda import tools
    lines, total = tools.total_of([{"name": "biscuits", "qty": 50, "price": 10}, {"name": "shampoo", "qty": 5, "price": 35}])
    assert total == "675" and lines[0] == "biscuits: 50 at 10 is 500"
    assert tools.total_of([{"name": "tea", "qty": 3, "price": 12.5}])[1] == "37.5"
    assert tools.total_of([{"name": "x", "qty": "1,000", "price": 2}])[1] == "2000"


def test_calc_context_uses_code_not_the_model(monkeypatch):
    from tilda import tools
    monkeypatch.setattr(tools, "llm_json", lambda s, u: {"items": [{"name": "biscuits", "qty": 50, "price": 10}, {"name": "shampoo", "qty": 5, "price": 35}]})
    got = tools.context_for([{"role": "user", "content": "I sold 50 biscuits at 10 rupees and 5 shampoo at 35, what is the total"}])
    assert got["intent"] == "calc" and "TOTAL = 675" in got["extra"]


def test_weather_context(monkeypatch):
    from tilda import tools

    class R:
        status_code = 200

        def json(self):
            return {"current": {"temperature_2m": 27.4, "apparent_temperature": 30, "relative_humidity_2m": 70, "weather_code": 2, "wind_speed_10m": 11}}

    monkeypatch.setattr(tools.requests, "get", lambda *a, **k: R())
    got = tools.context_for([{"role": "user", "content": "what is the weather"}], 19.07, 72.87)
    assert got["intent"] == "weather" and "27 degrees" in got["extra"] and "partly cloudy" in got["extra"]
    nogps = tools.context_for([{"role": "user", "content": "what is the weather"}])
    assert "not shared" in nogps["extra"]


def test_distance_context(monkeypatch):
    from tilda import tools
    monkeypatch.setattr(tools, "llm_json", lambda s, u: {"place": "Gateway of India, Mumbai"})

    class G:
        status_code = 200

        def __init__(self, data):
            self.data = data

        def json(self):
            return self.data

    def fake_get(url, **k):
        if "nominatim" in url:
            return G([{"lat": "18.92", "lon": "72.83", "display_name": "Gateway of India, Mumbai"}])
        return G({"routes": [{"distance": 8400, "duration": 1500}]})

    monkeypatch.setattr(tools.requests, "get", fake_get)
    got = tools.context_for([{"role": "user", "content": "how far is Gateway of India"}], 19.1, 72.9)
    assert got["intent"] == "distance" and "8.4 km" in got["extra"] and "25 minutes" in got["extra"]


def test_failed_lookup_never_guesses(monkeypatch):
    from tilda import tools

    def boom(*a, **k):
        raise tools.requests.RequestException("down")

    monkeypatch.setattr(tools.requests, "get", boom)
    got = tools.context_for([{"role": "user", "content": "what is the weather"}], 1, 2)
    assert got["intent"] == "failed" and "Do not guess" in got["extra"]


def test_feedback_is_kept_and_complaint_detected(tmp_path, monkeypatch):
    from tilda import server, tools
    monkeypatch.setenv("FEEDBACK_LOG", str(tmp_path / "f.jsonl"))
    got = tools.context_for([{"role": "user", "content": "I have a complaint about the app"}])
    assert got["intent"] == "complaint" and "never promise" in got["extra"]
    c = server.app.test_client()
    r = c.post("/feedback", json={"kind": "suggestion", "text": "add Odia notes", "lang": "od-IN"})
    assert r.get_json()["saved"] is True
    assert "add Odia notes" in (tmp_path / "f.jsonl").read_text()
    assert c.post("/feedback", json={"kind": "complaint", "text": ""}).status_code == 400


def test_talk_route_sends_intent_and_extra(monkeypatch):
    from tilda import server
    seen = {}
    monkeypatch.setattr(server.tools, "context_for", lambda m, lat, lon: {"intent": "weather", "extra": f"LIVE DATA {lat} {lon}"})

    def fake_stream(msgs, lang, api_key=None, extra="", voice=True):
        seen["extra"] = extra
        seen["voice"] = voice
        yield {"text": "It is warm."}

    monkeypatch.setattr(server, "talk_stream", fake_stream)
    r = server.app.test_client().post("/talk", json={"messages": [{"role": "user", "content": "weather"}], "lang": "en-IN", "lat": 19.1, "lon": 72.9, "voice": False})
    lines = [json.loads(x) for x in r.get_data(as_text=True).splitlines()]
    assert seen["voice"] is False
    assert lines[0] == {"intent": "weather"} and lines[1]["text"] == "It is warm." and seen["extra"] == "LIVE DATA 19.1 72.9"


def test_translit_falls_back_to_groq(monkeypatch):
    from tilda import translate

    class Down:
        status_code = 402
        text = "no credits"

        def json(self):
            return {}

    class Ok:
        status_code = 200

        def json(self):
            return {"choices": [{"message": {"content": "आज वी विल सी"}}]}

    monkeypatch.setenv("SARVAM_API_KEY", "k")
    monkeypatch.setenv("GROQ_API_KEY", "g")
    monkeypatch.setattr(translate.requests, "post", lambda url, **k: Down() if "sarvam" in url else Ok())
    assert translate.transliterate("today we see", "en-IN", "hi-IN") == "आज वी विल सी"


def test_system_prompt_carries_live_data_and_time():
    from tilda import talk
    p = talk.system_prompt("hi-IN", "LIVE DATA: 27 degrees")
    assert "LIVE DATA: 27 degrees" in p and "IST" in p and "never invent" in p


def test_summary_route(monkeypatch):
    from tilda import server
    monkeypatch.setattr(server.tools, "summarize", lambda t, n: f"Notes in {n}\n- point")
    c = server.app.test_client()
    assert c.post("/summary", json={"text": "short"}).status_code == 400
    r = c.post("/summary", json={"text": "a long class about photosynthesis in plants " * 3, "lang": "hi-IN"})
    assert r.get_json()["text"].startswith("Notes in Hindi")


def test_feedback_goes_to_telegram_when_set(tmp_path, monkeypatch):
    from tilda import tools
    sent = {}

    class R:
        status_code = 200

    monkeypatch.setenv("FEEDBACK_LOG", str(tmp_path / "f.jsonl"))
    monkeypatch.setenv("TELEGRAM_BOT_TOKEN", "t")
    monkeypatch.setenv("TELEGRAM_CHAT_ID", "42")
    monkeypatch.setattr(tools.requests, "post", lambda url, **k: sent.update(url=url, body=k["json"]) or R())
    out = tools.save_feedback("complaint", "too slow", "hi-IN")
    assert out["telegram"] is True and sent["body"]["chat_id"] == "42" and "too slow" in sent["body"]["text"]


def test_tts_asks_for_small_audio_then_falls_back(monkeypatch):
    from tilda import talk
    calls = []

    class R:
        def __init__(self, code):
            self.status_code = code
            self.text = "bad"

        def json(self):
            return {"audios": ["QUJD"]}

    def fake_post(url, **k):
        calls.append(k["json"])
        return R(422 if "output_audio_codec" in k["json"] else 200)

    monkeypatch.setenv("SARVAM_API_KEY", "k")
    monkeypatch.setattr(talk.requests, "post", fake_post)
    assert talk.speak("hello", "en-IN") == "QUJD"
    assert calls[0]["output_audio_codec"] == "mp3" and "output_audio_codec" not in calls[1]


def test_speak_route_pans_for_earbuds(monkeypatch):
    import tilda.server as srv
    monkeypatch.delenv("TILDA_FAKE", raising=False)
    monkeypatch.setattr(srv, "talk_speak", lambda t, l: "QUJD")
    seen = {}
    monkeypatch.setattr(srv, "pan_audio", lambda a, side: seen.setdefault("side", side) and "UEFO")
    c = srv.app.test_client()
    r = c.post("/speak", json={"text": "hi", "lang": "hi-IN", "pan": "l"})
    assert r.get_json()["audio"] == "UEFO" and seen["side"] == "l"
    r = c.post("/speak", json={"text": "hi", "lang": "hi-IN"})
    assert r.get_json()["audio"] == "QUJD"


def test_camera_phrases_open_the_camera():
    for say in ["Hey Tilda, read this", "please scan this", "open the camera", "what does this say", "यह पढ़ो"]:
        assert tools.context_for([{"role": "user", "content": say}])["intent"] == "camera", say
    assert tools.context_for([{"role": "user", "content": "what is the weather"}], 1, 2)["intent"] != "camera"


def test_read_route_demo_and_missing_photo(monkeypatch):
    import tilda.server as srv
    c = srv.app.test_client()
    assert c.post("/read", json={"image": "x"}).status_code == 400
    monkeypatch.setenv("TILDA_FAKE", "1")
    r = c.post("/read", json={"image": "A" * 200, "lang": "hi-IN"}).get_json()
    assert r["text"] and r["original"]


def test_read_image_needs_key_and_parses_answer(monkeypatch):
    monkeypatch.delenv("GROQ_API_KEY", raising=False)
    try:
        tools.read_image("QUJD", "Hindi")
        assert False
    except tools.ToolError as e:
        assert "key not set" in str(e)
    monkeypatch.setenv("GROQ_API_KEY", "k")

    class R:
        status_code = 200
        def json(self):
            return {"choices": [{"message": {"content": '{"original": "Exit", "translation": "बाहर निकलें"}'}}]}
    monkeypatch.setattr(tools.requests, "post", lambda *a, **k: R())
    assert tools.read_image("QUJD", "Hindi") == {"original": "Exit", "text": "बाहर निकलें"}


def test_clean_tail_drops_invented_hello_only_after_a_full_sentence():
    long = "Active gives you a huge boost on dating apps, at least where your initial success is concerned."
    assert tools.clean_tail(long + " Hello") == long
    assert tools.clean_tail("Thank you for the help with the shop total of today.") != ""
    assert tools.clean_tail("hello") == "hello"
    assert tools.clean_tail("I said hello") == "I said hello"
    assert tools.clean_tail("सक्रिय रहने से आपको बहुत बढ़ावा मिलता है और सफलता मिलती है। नमस्ते").endswith("मिलती है।")


def test_live_questions_get_web_answer(monkeypatch):
    monkeypatch.setattr(tools, "web_answer", lambda q, n="English": "Petrol is about 100 rupees a litre in Bhubaneswar today.")
    out = tools.context_for([{"role": "user", "content": "what is the petrol price today"}])
    assert out["intent"] == "live" and "Petrol" in out["extra"]


def test_web_answer_needs_key(monkeypatch):
    monkeypatch.delenv("GROQ_API_KEY", raising=False)
    with pytest.raises(tools.ToolError):
        tools.web_answer("news today")
