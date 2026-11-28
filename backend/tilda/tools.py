"""Live facts for the talking agent: weather, distance, exact shop sums, and complaints or suggestions.

The language model never does the arithmetic and never guesses the weather. It only picks out the
numbers or the place; plain code (or a free public service) gives the facts, and the model then says them.
"""
import datetime
import json
import logging
import os
import re
from fractions import Fraction

import requests

from . import groq

UA = {"User-Agent": "TildaHackathon/1.0 (voice assistant demo)"}
GROQ_URL = "https://api.groq.com/openai/v1/chat/completions"
SARVAM_CHAT = "https://api.sarvam.ai/v1/chat/completions"
log = logging.getLogger("tilda")

WEATHER_RE = re.compile(
    r"weather|temperature|raining|rain\b|humid|मौसम|बारिश|तापमान|गर्मी|ठंड|ପାଗ|ଆବହାଓ|వాతావరణ|வானிலை|ಹವಾಮಾನ|കാലാവസ്ഥ|আবহাওয়া|હવામાન|ਮੌਸਮ",
    re.I)
DISTANCE_RE = re.compile(
    r"how far|distance|far is|far from|how long (?:to|will it take)|time to reach|how do i reach|kitna door|कितनी दूर|कितना दूर|दूरी|"
    r"कितने किलोमीटर|कितनी देर|ଦୂର|দূর|దూరం|தூரம்|ದೂರ|ദൂരം|અંતર|ਦੂਰੀ", re.I)
CALC_RE = re.compile(
    r"total|sum\b|add up|calculate|how much|sold|sale|बेचा|बेची|कुल|जोड़|हिसाब|कितना|rupee|\brs\b|₹|रुपये|रुपए|कितने", re.I)
NUMWORDS_RE = re.compile(
    r"\b(one|two|three|four|five|six|seven|eight|nine|ten|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand)\b|"
    r"एक|दो|तीन|चार|पाँच|पांच|छह|सात|आठ|नौ|दस|बीस|तीस|चालीस|पचास|साठ|सत्तर|अस्सी|नब्बे|सौ|हज़ार|हजार", re.I)
FEEDBACK_RE = re.compile(
    r"complain|suggestion|feedback|शिकायत|सुझाव|ଅଭିଯୋଗ|ପରାମର୍ଶ|ఫిర్యాదు|సూచన|புகார்|ಸಲಹೆ|ದೂರು|പരാതി|অভিযোগ|পরামর্শ|ફરિયાદ|ਸ਼ਿਕਾਇਤ|ਸੁਝਾਅ", re.I)
COMPLAINT_RE = re.compile(r"complain|शिकायत|ଅଭିଯୋଗ|ఫిర్యాదు|புகார்|ದೂರು|പരാതി|অভিযোগ|ફરિયાદ|ਸ਼ਿਕਾਇਤ", re.I)

WMO = {0: "clear sky", 1: "mostly clear", 2: "partly cloudy", 3: "overcast", 45: "foggy", 48: "foggy",
       51: "light drizzle", 53: "drizzle", 55: "heavy drizzle", 56: "freezing drizzle", 57: "freezing drizzle",
       61: "light rain", 63: "rain", 65: "heavy rain", 66: "freezing rain", 67: "freezing rain",
       71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains", 80: "light rain showers",
       81: "rain showers", 82: "heavy rain showers", 85: "snow showers", 86: "snow showers",
       95: "a thunderstorm", 96: "a thunderstorm with hail", 99: "a thunderstorm with hail"}


LIVE_RE = re.compile(
    r"\b(today|tonight|tomorrow|latest|news|price|rate of|cost of|score|current|currently|right now|who won|who is the|when is|"
    r"open now|train|flight|bus timing|schedule|result|stock|petrol|diesel|gold|exchange rate|trending|how long|how much time|travel time)\b|"
    r"आज|कल|ताज़ा|ताजा|खबर|समाचार|भाव|दाम|कीमत|स्कोर|नतीजा|रिज़ल्ट|ट्रेन|फ्लाइट|कितना समय|कितनी देर|कब है|ଆଜି|ଖବର|ଦାମ", re.I)


NEARBY_RE = re.compile(
    r"\b(near me|nearby|nearest|closest|close to me|around here|around me|in my area|my location|hospital|clinic|pharmacy|chemist|doctor|restaurant|hotel|hostel|atm|bank|petrol pump|police|"
    r"bus stop|station|supermarket|shop|temple|church|mosque|school|college)\b|"
    r"पास में|नज़दीक|नजदीक|आसपास|अस्पताल|दवाई की दुकान|ਨੇੜੇ|ਹਸਪਤਾਲ|ସମୀପ|ହସ୍ପିଟାଲ|దగ్గర|ఆసుపత్రి|அருகில்|மருத்துவமனை|ಹತ್ತಿರ|ಆಸ್ಪತ್ರೆ|അടുത്ത|ആശുപത്രി|কাছে|হাসপাতাল|નજીક|હોસ્પિટલ", re.I)
# a question: so Tilda looks it up live instead of answering from memory
INFO_RE = re.compile(
    r"\?|\b(what|which|who|where|when|why|how|tell me|find|show me|search|look up|best|price|cost|open|timing|address|phone number|contact)\b|"
    r"क्या|कहाँ|कहां|कब|कौन|कैसे|कौनसा|बताओ|बताइए|ढूंढ|ଏଠାରେ|କେଉଁ|ఎక్కడ|ఏది|எங்கே|எது|ಎಲ್ಲಿ|ಯಾವುದು|എവിടെ|কোথায়|ક્યાં|ਕਿੱਥੇ", re.I)


class ToolError(Exception):
    pass


def now_text() -> str:
    ist = datetime.timezone(datetime.timedelta(hours=5, minutes=30))
    return datetime.datetime.now(ist).strftime("%A %d %B %Y, %I:%M %p IST")


def _first_json(text: str) -> dict:
    m = re.search(r"\{.*\}", text or "", re.S)
    if not m:
        raise ToolError("no json in answer")
    try:
        return json.loads(m.group(0))
    except ValueError as e:
        raise ToolError(f"bad json: {e}")


def llm_json(system: str, user: str) -> dict:
    """One small, exact question to a language model: Groq first (fast), Sarvam if Groq is not available."""
    msgs = [{"role": "system", "content": system + " Reply with JSON only."}, {"role": "user", "content": user[:1200]}]
    if os.environ.get("GROQ_API_KEY"):
        try:
            return _first_json(groq.chat(msgs, max_tokens=300, temperature=0, json_mode=True, timeout=15))
        except (groq.GroqError, ToolError):
            pass
    skey = os.environ.get("SARVAM_API_KEY")
    if skey:
        try:
            r = requests.post(SARVAM_CHAT, headers={"api-subscription-key": skey},
                              json={"model": "sarvam-105b-conversations", "temperature": 0, "max_tokens": 300,
                                    "reasoning_effort": None, "messages": msgs}, timeout=20)
            if r.status_code == 200:
                return _first_json(r.json()["choices"][0]["message"]["content"])
        except (requests.RequestException, KeyError, IndexError, ValueError, ToolError):
            pass
    raise ToolError("no language model could read that")


def _num(x) -> Fraction:
    try:
        return Fraction(str(x).replace(",", "").strip())
    except (ValueError, ZeroDivisionError):
        raise ToolError(f"not a number: {x!r}")


def _fmt(f: Fraction) -> str:
    if f.denominator == 1:
        return str(f.numerator)
    return f"{float(f):.2f}".rstrip("0").rstrip(".")


def total_of(items) -> tuple:
    """Exact sums. items: [{name, qty, price}] -> (lines, total as text)."""
    lines, total = [], Fraction(0)
    for it in items or []:
        qty, price = _num(it.get("qty", 1)), _num(it.get("price", 0))
        line = qty * price
        total += line
        lines.append(f"{str(it.get('name', 'item')).strip()}: {_fmt(qty)} at {_fmt(price)} is {_fmt(line)}")
    return lines, _fmt(total)


def calculate(text: str) -> str:
    j = llm_json('Read a shopkeeper\'s sale list. JSON: {"items":[{"name":"...","qty":number,"price":number}]}. '
                 "qty is how many were sold. price is the price of ONE unit in rupees. If only a line total is given, "
                 "set price = line total / qty. Write numbers as digits. Skip anything that is not an item.", text)
    items = j.get("items") or []
    if not items:
        raise ToolError("no items found")
    lines, total = total_of(items)
    return ("EXACT SUMS, worked out by code. Say each line and the total in the user's language, using exactly these numbers: "
            + "; ".join(lines) + f". TOTAL = {total} rupees.")


def weather_backup(lat: float, lon: float, why) -> str:
    """The main weather service said no (usually too many requests from one server); wttr.in is the second source."""
    try:
        r = requests.get(f"https://wttr.in/{lat:.3f},{lon:.3f}", headers=UA, timeout=8, params={"format": "j1"})
        c = r.json()["current_condition"][0]
        return (f"Current weather at the user's location: {c['temp_C']} degrees Celsius (feels like {c['FeelsLikeC']}), "
                f"{str(c['weatherDesc'][0]['value']).lower()}, humidity {c['humidity']} percent, wind {c['windspeedKmph']} km per hour.")
    except (requests.RequestException, KeyError, IndexError, ValueError, TypeError):
        raise ToolError(f"weather http {why}")


def weather(lat: float, lon: float) -> str:
    r = requests.get("https://api.open-meteo.com/v1/forecast", headers=UA, timeout=8, params={
        "latitude": lat, "longitude": lon, "timezone": "auto",
        "current": "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"})
    if r.status_code != 200:
        return weather_backup(lat, lon, r.status_code)
    c = r.json().get("current") or {}
    if "temperature_2m" not in c:
        raise ToolError("no weather data")
    return (f"Current weather at the user's location: {round(c['temperature_2m'])} degrees Celsius "
            f"(feels like {round(c.get('apparent_temperature', c['temperature_2m']))}), "
            f"{WMO.get(c.get('weather_code'), 'mixed')}, humidity {round(c.get('relative_humidity_2m', 0))} percent, "
            f"wind {round(c.get('wind_speed_10m', 0))} km per hour.")


def geocode(place: str):
    r = requests.get("https://nominatim.openstreetmap.org/search", headers=UA, timeout=8,
                     params={"q": place, "format": "json", "limit": 1})
    if r.status_code != 200 or not r.json():
        raise ToolError(f"could not find {place}")
    j = r.json()[0]
    return float(j["lat"]), float(j["lon"]), j.get("display_name", place).split(",")[0]


def distance(lat: float, lon: float, text: str) -> str:
    try:
        place = str(llm_json('Find the destination the user asks the distance or time to. JSON: {"place":"..."}. Write the place in '
                             'English with its city, like "Gateway of India, Mumbai". Empty string if there is none.', text).get("place", "")).strip()
    except ToolError:
        m = re.search(r"(?:how far is|distance (?:to|from here to)|how long (?:to reach|to get to|to)|reach|to)\s+(.+?)(?:\s+from\s+(?:here|me|my\b.*|where i am))?\s*[?.!]*$", text.strip(), re.I)
        place = m.group(1).strip() if m else ""
    if not place:
        raise ToolError("no destination named")
    dlat, dlon, name = geocode(place)
    r = requests.get(f"https://router.project-osrm.org/route/v1/driving/{lon},{lat};{dlon},{dlat}",
                     headers=UA, timeout=10, params={"overview": "false"})
    if r.status_code != 200 or not r.json().get("routes"):
        raise ToolError("no route found")
    rt = r.json()["routes"][0]
    km, mins = rt["distance"] / 1000, max(1, round(rt["duration"] / 60))
    return f"Road distance from the user's location to {name}: about {km:.1f} km, around {mins} minutes by car."


CAMERA_RE = re.compile(
    r"\b(read|scan|translate|capture)\s+(this|that|it)\b|\b(open|start|use)\s+(the\s+)?camera\b|\btake\s+(a\s+)?(photo|picture|pic)\b"
    r"|\bwhat does (this|that) say\b|यह पढ़|ये पढ़|कैमरा खोल|కెమెరా", re.I)

_AREAS: dict = {}


def place_name(lat: float, lon: float) -> str:
    """The area name for a position (OpenStreetMap), or an empty string. Never raises."""
    key = (round(lat, 2), round(lon, 2))
    if key in _AREAS:
        return _AREAS[key]
    name = ""
    try:
        r = requests.get("https://nominatim.openstreetmap.org/reverse", headers=UA, timeout=4,
                         params={"format": "jsonv2", "lat": lat, "lon": lon, "zoom": 14})
        if r.status_code == 200:
            name = str(r.json().get("display_name", ""))[:160]
    except (requests.RequestException, ValueError):
        pass
    if len(_AREAS) > 500:
        _AREAS.clear()
    _AREAS[key] = name
    return name


LAST_ERR: dict = {}


def note_err(kind: str, e) -> None:
    LAST_ERR[kind] = f"{now_text()}: {type(e).__name__}: {e}"[:300]


def web_answer(question: str, lang_name: str = "English", where: str = "") -> str:
    """A short, checked answer from the live web (Groq's browser search on gpt-oss). Raises ToolError when it cannot."""
    if not os.environ.get("GROQ_API_KEY"):
        raise ToolError("key not set: add GROQ_API_KEY for live answers")
    msgs = [{"role": "system", "content": "Answer from a web search in at most three short sentences, plain words, no links, no markdown. "
             "Give the date or time of the information when it matters. If you cannot find it, say so. Today is " + now_text() + "." + where},
            {"role": "user", "content": question}]
    try:
        return groq.chat(msgs, groq.WEB_MODELS, max_tokens=350, temperature=0.1, tools=[{"type": "browser_search"}], timeout=30)
    except groq.GroqError as e:
        note_err("web", e)
    # live search failed: answer from what the model knows, and say so, rather than giving up
    try:
        plain = [{"role": "system", "content": "Answer in at most three short sentences, plain words, no links, no markdown. "
                  "Live search is down, so say that this is from general knowledge and may be out of date, and give a typical figure or range if you know one. "
                  "If you do not know, say so. Today is " + now_text() + "." + where}, {"role": "user", "content": question}]
        return groq.chat(plain, groq.TEXT_MODELS, max_tokens=250, temperature=0.1, timeout=20)
    except groq.GroqError as e:
        note_err("web_plain", e)
        raise ToolError("web search failed (" + str(e) + ")")


_TAIL_RE = re.compile(r"(?:(?<=[.!?।॥])|\s)\s*(?:hello|hi|hey|bye|thank you|thanks|thanks for watching|नमस्ते|हेलो|धन्यवाद|शुक्रिया)\s*[.!?।]*\s*$", re.I)


def clean_tail(text: str) -> str:
    """Speech engines invent a closing 'Hello' or 'Thank you' on trailing silence. Drops one such word after a full sentence."""
    t = (text or "").strip()
    m = _TAIL_RE.search(t)
    if not m:
        return t
    head = t[:m.start()].rstrip()
    if len(head.split()) >= 6 and head[-1:] in ".!?।॥":
        return head
    return t


def clean_label(text: str) -> str:
    """Photo readers sometimes loop ("*No Added" three times). Keeps each real line once and drops empty paragraphs."""
    seen, out = set(), []
    for para in re.split(r"\n\s*\n", text or ""):
        keep = []
        for line in (l.strip() for l in para.split("\n")):
            key = re.sub(r"\W+", "", line).lower()
            if not key:
                continue
            if len(key) >= 6:
                if key in seen:
                    continue
                seen.add(key)
            keep.append(line)
        if keep:
            out.append("\n".join(keep))
    return "\n\n".join(out)


_PALM_RE = re.compile(r"palm\s*(?:oil|olein|kernel)|palmolein|पाम", re.I)
_INGR_RE = re.compile(r"ingredients?|contains?|सामग्री|साहित्य", re.I)


def label_facts(original: str) -> str:
    """One plain fact about the label, only when the ingredients are really in the photo. No opinions."""
    if not _INGR_RE.search(original or ""):
        return ""
    if _PALM_RE.search(original):
        return "Palm oil: listed in the ingredients."
    return "Palm oil: not listed in the ingredients that could be read."


def _faithful(original: str, target_lang: str, lang_name: str) -> str:
    """Translates the exact label text paragraph by paragraph, so words like 'vegetarian' cannot drift. Empty on failure."""
    from .translate import translate, TranslateError
    from concurrent.futures import ThreadPoolExecutor
    paras = [p for p in re.split(r"\n\s*\n", original) if p.strip()]
    if not paras:
        return ""

    def one(p):
        return translate(p.replace("\n", ". "), "auto", target_lang).strip()
    try:
        with ThreadPoolExecutor(max_workers=4) as ex:
            return "\n\n".join(ex.map(one, paras)).strip()
    except (TranslateError, Exception) as e:  # any failure: the caller falls back to the reader's own translation
        log.warning("faithful translate failed: %s", e)
        return ""


def read_image(image_b64: str, lang_name: str, lang: str = "en-IN") -> dict:
    """Reads the text in a photo and translates it. Returns {"original": ..., "text": translation in lang_name, "facts": ...}."""
    if not os.environ.get("GROQ_API_KEY"):
        raise ToolError("key not set: add GROQ_API_KEY to read photos")
    prompt = (f"Read all the text you can see in this photo (a sign, a medicine strip, a food label, a bill, a board, a page). "
              f"Reply with JSON only: {{\"original\": the text exactly as written, \"translation\": that text translated into {lang_name}, "
              "written the way a person would say it out loud, short and clear}. If a medicine or label has numbers, keep them exact. "
              "Never repeat a line, and never invent words. If a line is cut off, curved, blurry or too small, write only the words you can truly read "
              "and then [unclear]. Do not guess. "
              "Put the headline or title first, on its own line. Separate each paragraph with a blank line, and keep the same paragraphs in the translation. "
              "If there is no readable text, use empty strings.")
    msgs = [{"role": "user", "content": [
        {"type": "text", "text": prompt},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + image_b64}}]}]
    try:
        out = groq.chat(msgs, groq.VISION_MODELS, max_tokens=3500, temperature=0.1, json_mode=True, timeout=60)
        j = _first_json(out)
    except (groq.GroqError, ToolError) as e:
        raise ToolError("could not read the photo just now (" + str(e) + ")")
    original = clean_label(str(j.get("original") or ""))
    text = clean_label(str(j.get("translation") or ""))
    if original and not lang.startswith("en"):
        text = _faithful(original, lang, lang_name) or text
    elif original and lang.startswith("en") and sum(c.isascii() for c in original) < 0.9 * len(original):
        text = _faithful(original, lang, lang_name) or text
    elif original and lang.startswith("en"):
        text = original
    facts = label_facts(original)
    if facts and not lang.startswith("en"):
        from .translate import translate, TranslateError
        try:
            facts = translate(facts, "en-IN", lang).strip() or facts
        except (TranslateError, Exception):
            pass
    if facts:
        text = (text + "\n\n" + facts).strip()
    return {"original": original, "text": text, "facts": facts}


def product_answer(question: str, label: str, lang_name: str, where: str = "") -> str:
    """Answers a question about a product seen in a photo, from the web. Facts only, no health opinions."""
    if not os.environ.get("GROQ_API_KEY"):
        raise ToolError("key not set: add GROQ_API_KEY for product answers")
    sys = ("The user photographed a product and asks about it. The label text (it may be partly misread) is below. "
           "Find the product on the web and answer in " + lang_name + ", at most four short sentences, plain words, no links, no markdown. "
           "State facts only: what is listed, where you found a price and roughly what it is (say 'around'), and that prices change. "
           "Never say a product or ingredient is harmful, safe, toxic or poisonous, and give no medical advice. "
           "If you cannot confirm something, say you could not confirm it. Today is " + now_text() + "." + where +
           "\nLABEL TEXT:\n" + (label or "")[:900])
    msgs = [{"role": "system", "content": sys}, {"role": "user", "content": question}]
    try:
        return groq.chat(msgs, groq.WEB_MODELS, max_tokens=450, temperature=0.1, tools=[{"type": "browser_search"}], timeout=40)
    except groq.GroqError as e:
        raise ToolError("web search failed (" + str(e) + ")")


def _is_sum(text: str) -> bool:
    """A sum to work out (two or more numbers), not a question that happens to say 'how much'."""
    return bool(CALC_RE.search(text)) and (len(re.findall(r"\d+", text)) >= 2 or len(NUMWORDS_RE.findall(text)) >= 2)


def context_for(messages, lat=None, lon=None) -> dict:
    """What Tilda should know before she answers: {"extra": text for the model, "intent": name or None}."""
    last = ""
    for m in reversed(messages or []):
        if m.get("role") == "user":
            last = str(m.get("content", ""))
            break
    if not last:
        return {"extra": "", "intent": None}
    try:
        if CAMERA_RE.search(last):
            return {"intent": "camera", "extra": "The user wants to read something with the camera. Reply with one short friendly line like 'Opening the camera.' and nothing else."}
        if FEEDBACK_RE.search(last):
            kind = "complaint" if COMPLAINT_RE.search(last) else "suggestion"
            return {"intent": kind, "extra": (
                f"The user is giving a {kind}. If they have not said what it is yet, ask them to say it. Otherwise: "
                + ("apologise warmly for the trouble, " if kind == "complaint" else "thank them warmly, ")
                + "say the team will look into it, and never promise a fix or a date. Then ask if you may send it to the team.")}
        if DISTANCE_RE.search(last):
            if lat is None or lon is None:
                return {"intent": "distance", "extra": "LIVE DATA: the user's location is not shared, so you cannot work out the distance. Say that, and ask which area they are in."}
            return {"intent": "distance", "extra": "LIVE DATA: " + distance(lat, lon, last)}
        if WEATHER_RE.search(last):
            if lat is None or lon is None:
                return {"intent": "weather", "extra": "LIVE DATA: the user's location is not shared, so you cannot check the weather. Say that, and ask which area they are in."}
            return {"intent": "weather", "extra": "LIVE DATA: " + weather(lat, lon)}
        if (LIVE_RE.search(last) or NEARBY_RE.search(last) or (INFO_RE.search(last) and len(last.split()) >= 3)) and not _is_sum(last):
            where = ""
            if lat is not None and lon is not None:
                where = (f" The user's phone is at latitude {lat:.4f}, longitude {lon:.4f}"
                         + (f" ({place_name(lat, lon)})" if place_name(lat, lon) else "") + ". Use it for anything near me, nearest or closest.")
            # a short follow-up ("I am at Mira Road") only makes sense with the question before it
            users = [str(m.get("content", "")) for m in (messages or []) if m.get("role") == "user"][-3:]
            q = " ".join(users) if len(last.split()) < 10 else last
            ask_area = "" if where else " If the answer depends on where the user is and you do not know, ask which area they are in."
            return {"intent": "live", "extra": "LIVE DATA (from the web): " + web_answer(q, where=where) +
                    " Say this in your own words, briefly, and say it is from the web." + ask_area}
        if CALC_RE.search(last) and (len(re.findall(r"\d+", last)) >= 2 or len(NUMWORDS_RE.findall(last)) >= 2):
            return {"intent": "calc", "extra": "LIVE DATA: " + calculate(last)}
    except (ToolError, requests.RequestException) as e:
        log.warning("tool failed: %s", e)
        note_err("context", e)
        return {"intent": "failed", "extra": "LIVE DATA: the lookup failed just now. Say you could not check it right now and offer to try again. Do not guess."}
    return {"intent": None, "extra": ""}


def save_feedback(kind: str, text: str, lang: str = "", who: str = "") -> dict:
    """Keeps every complaint or suggestion: in the server log, in a file, and by email when Brevo is set up."""
    rec = {"time": now_text(), "kind": kind, "lang": lang, "who": who, "text": text}
    log.warning("FEEDBACK %s", json.dumps(rec, ensure_ascii=False))
    try:
        with open(os.environ.get("FEEDBACK_LOG", "/tmp/tilda_feedback.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass
    why = {}
    return {"saved": True, "emailed": _email(rec, why), "telegram": _telegram(rec, why), "why": why}


def _email(rec: dict, why: dict | None = None) -> bool:
    key, to = os.environ.get("BREVO_API_KEY"), os.environ.get("FEEDBACK_TO")
    if not key or not to:
        if why is not None:
            why["email"] = "BREVO_API_KEY or FEEDBACK_TO missing"
        return False
    try:
        r = requests.post("https://api.brevo.com/v3/smtp/email", headers={"api-key": key}, timeout=15, json={
            "sender": {"email": os.environ.get("FEEDBACK_FROM", to), "name": "Tilda"},
            "to": [{"email": to}],
            "subject": f"Tilda {rec['kind']} ({rec['lang'] or 'language unknown'})",
            "textContent": f"{rec['kind'].title()} received {rec['time']}\nLanguage: {rec['lang']}\n\n{rec['text']}"})
        if why is not None and r.status_code not in (200, 201):
            why["email"] = f"{r.status_code} {r.text[:160]}"
        return r.status_code in (200, 201)
    except requests.RequestException as e:
        if why is not None:
            why["email"] = type(e).__name__
        return False


def _llm_text(msgs, max_tokens=900, temperature=0.2) -> str:
    """Groq first, Sarvam as backup. Raises ToolError when neither answers."""
    if os.environ.get("GROQ_API_KEY"):
        try:
            return groq.chat(msgs, max_tokens=max_tokens, temperature=temperature, timeout=40)
        except groq.GroqError:
            pass
    skey = os.environ.get("SARVAM_API_KEY")
    if skey:
        try:
            r = requests.post(SARVAM_CHAT, headers={"api-subscription-key": skey}, timeout=50,
                              json={"model": "sarvam-105b-conversations", "temperature": temperature, "max_tokens": max_tokens,
                                    "reasoning_effort": None, "messages": msgs})
            if r.status_code == 200:
                out = (r.json()["choices"][0]["message"]["content"] or "").strip()
                if out:
                    return out
        except (requests.RequestException, KeyError, IndexError, ValueError):
            pass
    raise ToolError("no summary engine answered")


def _split(text: str, size: int) -> list:
    """Cuts at sentence ends or spaces so no piece is longer than `size`."""
    parts, t = [], (text or "").strip()
    while len(t) > size:
        cut = max(t.rfind(c, 0, size) for c in (". ", "? ", "! ", "।", "\n"))
        if cut < size // 2:
            cut = t.rfind(" ", 0, size)
        if cut < size // 2:
            cut = size
        parts.append(t[:cut + 1].strip())
        t = t[cut + 1:].strip()
    if t:
        parts.append(t)
    return parts


def summarize(text: str, lang_name: str) -> str:
    """Short study notes from a transcript. Long ones are read in parts so the beginning is never dropped."""
    system = (f"You make study notes from a class or video transcript. Write in {lang_name}. A short title line, then 5 to 9 "
              "bullet points starting with '- ', then one line starting 'Remember:' with the single most important thing. "
              "Use only what the transcript says. Include action items (things someone has to do) as bullets starting 'To do:'. "
              "No markdown symbols other than the leading dashes.")
    text = (text or "").strip()
    if len(text) <= 12000:
        return _llm_text([{"role": "system", "content": system}, {"role": "user", "content": text}])
    parts = _split(text, 10000)[:8]
    part_sys = (f"Write in {lang_name}. These are the notes of one part of a longer talk. Give 5 to 8 bullet points starting with '- ', "
                "keeping every name, number, date and action item that was said. Use only what the text says. Plain text.")
    notes = [_llm_text([{"role": "system", "content": part_sys}, {"role": "user", "content": p}], max_tokens=700) for p in parts]
    return _llm_text([{"role": "system", "content": system},
                      {"role": "user", "content": "Notes of the whole talk, in order:\n\n" + "\n\n".join(notes)}])


def _telegram(rec: dict, why: dict | None = None) -> bool:
    """Free and instant: a message to your own Telegram when TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID are set."""
    tok, chat = "".join((os.environ.get("TELEGRAM_BOT_TOKEN") or "").split()).strip("\"'"), "".join((os.environ.get("TELEGRAM_CHAT_ID") or "").split())
    if not tok or not chat:
        if why is not None:
            why["telegram"] = "TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID missing"
        return False
    try:
        r = requests.post(f"https://api.telegram.org/bot{tok}/sendMessage", timeout=15,
                          json={"chat_id": chat, "text": f"Tilda {rec['kind']} ({rec['lang'] or '?'})\n\n{rec['text']}"})
        if why is not None and r.status_code != 200:
            head, _, rest = tok.partition(":")
            why["telegram"] = (f"{r.status_code} {r.text[:120]} | id={head[:12]} total_len={len(tok)} "
                               f"secret_len={len(rest)} colons={tok.count(':')} secret_alnum={rest.replace('_','').replace('-','').isalnum()}")
        return r.status_code == 200
    except requests.RequestException as e:
        if why is not None:
            why["telegram"] = type(e).__name__
        return False
