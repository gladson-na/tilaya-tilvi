"""Speech engines. Each one takes a WAV file path and a language code and returns text.

Layer order (see router.py): Sarvam -> IndicConformer -> Whisper -> Vosk.
Heavy libraries are imported only when an engine is actually used, so a missing
library or model just makes that layer fail and the router moves on.
"""
import os
from dataclasses import dataclass


@dataclass
class Result:
    text: str
    engine: str
    confidence: float | None = None


class EngineError(Exception):
    pass


class Engine:
    name = "base"
    langs: set[str] | None = None  # None = accepts any language code
    accepts_hints = False  # True = transcribe(wav, lang, hints) can use the user's personal word list

    def supports(self, lang: str) -> bool:
        return self.langs is None or lang in self.langs

    def transcribe(self, wav_path: str, lang: str) -> Result:  # pragma: no cover
        raise NotImplementedError


class SarvamEngine(Engine):
    """Layer 1. Paid API (free credits). Needs SARVAM_API_KEY."""
    name = "sarvam"
    url = "https://api.sarvam.ai/speech-to-text"

    def __init__(self, api_key: str | None = None, model: str = "saaras:v3", mode: str = "codemix"):  # mode "translit" = Roman letters
        self.api_key = api_key or os.environ.get("SARVAM_API_KEY")
        self.model, self.mode = model, mode

    def transcribe(self, wav_path, lang):
        if not self.api_key:
            raise EngineError("no SARVAM_API_KEY")
        import requests
        with open(wav_path, "rb") as f:
            r = requests.post(
                self.url,
                headers={"api-subscription-key": self.api_key},
                files={"file": f},
                data={"model": self.model, "mode": self.mode, "language_code": lang},
                timeout=30,
            )
        if r.status_code != 200:
            raise EngineError(f"sarvam http {r.status_code}: {r.text[:240]}")
        return Result(r.json().get("transcript", ""), self.name)


class IndicConformerEngine(Engine):
    """Layer 2. AI4Bharat open model (MIT). Runs locally; first use downloads the model."""
    name = "indic-conformer"
    langs = {f"{c}-IN" for c in
             "as bn brx doi gu hi kn kok ks mai ml mni mr ne or pa sa sat sd ta te ur".split()} | {"od-IN"}

    def __init__(self, repo: str = "ai4bharat/indic-conformer-600m-multilingual"):
        self.repo, self._model = repo, None

    def transcribe(self, wav_path, lang):
        try:
            import torch, torchaudio
            from transformers import AutoModel
        except ImportError as e:
            raise EngineError(f"missing library: {e.name}")
        if self._model is None:
            self._model = AutoModel.from_pretrained(self.repo, trust_remote_code=True)
        wav, sr = torchaudio.load(wav_path)
        wav = torch.mean(wav, dim=0, keepdim=True)
        if sr != 16000:
            wav = torchaudio.transforms.Resample(sr, 16000)(wav)
        code = lang.split("-")[0].replace("od", "or")
        return Result(str(self._model(wav, code, "ctc")), self.name)


class WhisperEngine(Engine):
    """Layer 3 and 4 (different sizes). Open Whisper through faster-whisper."""

    accepts_hints = True

    def __init__(self, size: str = "large-v3", name: str = "whisper-large"):
        self.size, self.name, self._model = size, name, None

    def transcribe(self, wav_path, lang, hints=""):
        try:
            from faster_whisper import WhisperModel
        except ImportError:
            raise EngineError("faster-whisper not installed")
        if self._model is None:
            self._model = WhisperModel(self.size, compute_type="int8")
        code = lang.split("-")[0].replace("od", "or")
        # Whisper reads the initial prompt as "text that came just before", so the user's own
        # names and words become more likely. Used for this request only, never stored.
        segs, info = self._model.transcribe(wav_path, language=None if lang == "unknown" else code,
                                            initial_prompt=hints or None)
        return Result(" ".join(s.text.strip() for s in segs), self.name, getattr(info, "language_probability", None))


class VoskEngine(Engine):
    """Last resort. Small, offline, only a few Indian languages (needs a model folder per language)."""
    name = "vosk"
    langs = {"hi-IN", "te-IN", "gu-IN", "en-IN"}

    def __init__(self, model_dirs: dict[str, str] | None = None):
        self.model_dirs = model_dirs or {}

    def transcribe(self, wav_path, lang):
        try:
            import json, wave
            from vosk import KaldiRecognizer, Model
        except ImportError as e:
            raise EngineError(f"missing library: {e.name}")
        path = self.model_dirs.get(lang)
        if not path:
            raise EngineError(f"no vosk model for {lang}")
        wf = wave.open(wav_path, "rb")
        rec = KaldiRecognizer(Model(path), wf.getframerate())
        while data := wf.readframes(4000):
            rec.AcceptWaveform(data)
        return Result(json.loads(rec.FinalResult()).get("text", ""), self.name)


def default_chain() -> list[Engine]:
    return [
        SarvamEngine(),
        IndicConformerEngine(),
        WhisperEngine("large-v3", "whisper-large"),
        WhisperEngine("small", "whisper-small"),
        VoskEngine(),
    ]
