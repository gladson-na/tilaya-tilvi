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
    gkey = os.environ.get("GROQ_API_KEY")
    if gkey:
        try:
            r = requests.post(GROQ_URL, headers={"Authorization": f"Bearer {gkey}"},
                              json={"model": "llama-3.3-70b-versatile", "temperature": 0, "max_tokens": 300,
                                    "response_format": {"type": "json_object"}, "messages": msgs}, timeout=15)
            if r.status_code == 200:
                return _first_json(r.json()["choices"][0]["message"]["content"])
        except (requests.RequestException, KeyError, IndexError, ValueError, ToolError):
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


def weather(lat: float, lon: float) -> str:
    r = requests.get("https://api.open-meteo.com/v1/forecast", headers=UA, timeout=8, params={
        "latitude": lat, "longitude": lon, "timezone": "auto",
        "current": "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"})
    if r.status_code != 200:
        raise ToolError(f"weather http {r.status_code}")
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
    place = str(llm_json('Find the destination the user asks the distance or time to. JSON: {"place":"..."}. Write the place in '
                         'English with its city, like "Gateway of India, Mumbai". Empty string if there is none.', text).get("place", "")).strip()
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
        if FEEDBACK_RE.search(last):
            kind = "complaint" if COMPLAINT_RE.search(last) else "suggestion"
            return {"intent": kind, "extra": (
                f"The user is giving a {kind}. If they have not said what it is yet, ask them to say it. Otherwise: "
                + ("apologise warmly for the trouble, " if kind == "complaint" else "thank them warmly, ")
                + "say the team will look into it, and never promise a fix or a date. Then ask if you may send it to the team.")}
        if DISTANCE_RE.search(last):
            if lat is None or lon is None:
                return {"intent": "distance", "extra": "LIVE DATA: the user's location is not shared, so you cannot work out the distance. Say that, and ask them to allow location for Tilda."}
            return {"intent": "distance", "extra": "LIVE DATA: " + distance(lat, lon, last)}
        if WEATHER_RE.search(last):
            if lat is None or lon is None:
                return {"intent": "weather", "extra": "LIVE DATA: the user's location is not shared, so you cannot check the weather. Say that, and ask them to allow location for Tilda."}
            return {"intent": "weather", "extra": "LIVE DATA: " + weather(lat, lon)}
        if CALC_RE.search(last) and (len(re.findall(r"\d+", last)) >= 2 or len(NUMWORDS_RE.findall(last)) >= 2):
            return {"intent": "calc", "extra": "LIVE DATA: " + calculate(last)}
    except (ToolError, requests.RequestException) as e:
        log.warning("tool failed: %s", e)
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
    return {"saved": True, "emailed": _email(rec)}


def _email(rec: dict) -> bool:
    key, to = os.environ.get("BREVO_API_KEY"), os.environ.get("FEEDBACK_TO")
    if not key or not to:
        return False
    try:
        r = requests.post("https://api.brevo.com/v3/smtp/email", headers={"api-key": key}, timeout=15, json={
            "sender": {"email": os.environ.get("FEEDBACK_FROM", to), "name": "Tilda"},
            "to": [{"email": to}],
            "subject": f"Tilda {rec['kind']} ({rec['lang'] or 'language unknown'})",
            "textContent": f"{rec['kind'].title()} received {rec['time']}\nLanguage: {rec['lang']}\n\n{rec['text']}"})
        return r.status_code in (200, 201)
    except requests.RequestException:
        return False
