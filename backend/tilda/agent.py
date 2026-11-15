"""Turn what the person said into one safe action.

Rules first (works offline, no key). Pass `llm=` a function(text) -> dict to
let a language model decide instead; its answer is still checked against ALLOWED.
Anything that spends money or sends something out needs a yes first.
"""
import re

ALLOWED = {"volume_up", "volume_down", "open_app", "search", "draft_message",
           "plan_purchase", "none"}
NEEDS_YES = {"plan_purchase", "draft_message"}

# English plus Roman-letter Hindi for now; add more languages as we hear them.
_UP = r"(volume|awaz|aawaz|sound)\s*(up|badhao|badha|zyada|increase)|(increase|raise|louder)\b"
_DOWN = r"(volume|awaz|aawaz|sound)\s*(down|kam|kamm|decrease)|(decrease|lower|quieter)\b"
_OPEN = [r"^(?:open|launch|start)\s+(.+)$", r"^(.+?)\s+(?:kholo|kholiye|open karo|chalu karo)$"]
_SEARCH = [r"^(?:search|google|find)\s+(?:for\s+)?(.+)$", r"^(.+?)\s+(?:search karo|dhundho|khojo)$"]
_BUY = r"\b(buy|purchase|order|book|pay)\b|\b(kharido|book karo|order karo)\b"
_MSG = r"^(?:send (?:a )?message|message|text)\s+(.+)$"


def _clean(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower().rstrip(".!?"))


def interpret(text: str, llm=None) -> dict:
    """Returns {action, args, needs_yes, heard}. Never raises on odd input."""
    heard = text or ""
    t = _clean(heard)
    result = None
    if llm is not None:
        try:
            result = llm(heard)
        except Exception:
            result = None  # fall back to the rules
    if not isinstance(result, dict) or result.get("action") not in ALLOWED:
        result = _by_rules(t)
    action = result["action"]
    return {"action": action, "args": result.get("args", {}),
            "needs_yes": action in NEEDS_YES, "heard": heard}


def _by_rules(t: str) -> dict:
    if not t:
        return {"action": "none"}
    if re.search(_UP, t):
        return {"action": "volume_up"}
    if re.search(_DOWN, t):
        return {"action": "volume_down"}
    if re.search(_BUY, t):
        return {"action": "plan_purchase", "args": {"request": t}}
    m = re.match(_MSG, t)
    if m:
        return {"action": "draft_message", "args": {"request": m.group(1)}}
    for pat in _OPEN:
        m = re.match(pat, t)
        if m:
            return {"action": "open_app", "args": {"app": m.group(1)}}
    for pat in _SEARCH:
        m = re.match(pat, t)
        if m:
            return {"action": "search", "args": {"query": m.group(1)}}
    return {"action": "none"}
