# Private personal model (level 3)

Goal: the app learns how one person speaks (accent, name pronunciations, language mixing) and the result
stays theirs. Nothing is uploaded to a shared model.

## Where it stands
1. DONE, correction memory: heard -> meant swaps, stored on the phone.
2. DONE, personal word list: optional hint sent with each recording, never stored by the server.
3. STARTED, data collection: with "Train a private model of my voice" switched on, every session the person
   reviews is kept on their phone with its corrected text (`personal_data/manifest.jsonl`).
4. WRITTEN, NOT RUN: `personal_adapter.py` trains a small private Whisper add-on from that folder.
5. NEXT: load the adapter in the server for that person only (or on the phone), measure word error rate
   before and after on held-out recordings, then show the numbers.

## Honest limits
- Needs about an hour of reviewed speech before the add-on is worth training.
- Training needs a GPU (free Colab/Kaggle is enough for whisper-small), not the phone.
- Sarvam's hosted engine cannot be adapted this way; only the open Whisper path can.
