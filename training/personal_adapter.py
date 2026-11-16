"""Level 3, first step: train a small PRIVATE add-on (LoRA adapter) for Whisper from one person's
own reviewed recordings. The result is a small file that belongs to that person only.

STATUS: written and ready, NOT yet run on real data. It needs a GPU machine (a free Colab or Kaggle
GPU is enough for whisper-small) and about 60 minutes of the person's reviewed speech.

Input folder (copied by the person from their phone, or from their own cloud):
    personal_data/manifest.jsonl     one line per piece: {"audio": "audio/<file>.wav", "text": "...", "seconds": 8.0}
    personal_data/audio/*.wav        16 kHz mono recordings

Run:
    pip install transformers peft datasets accelerate soundfile librosa
    python personal_adapter.py --data personal_data --out my_adapter --lang te

Use: load whisper-small, then PeftModel.from_pretrained(model, "my_adapter"). Nothing here is shared;
the adapter is only as private as the place the person stores it.
"""
import argparse
import json
from pathlib import Path


def load_pairs(data: Path):
    rows = [json.loads(l) for l in (data / "manifest.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    total = sum(r.get("seconds", 0) for r in rows)
    return rows, total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--lang", default="hi", help="Whisper language code, e.g. te, hi, ta")
    ap.add_argument("--base", default="openai/whisper-small")
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--min-minutes", type=float, default=20.0)
    args = ap.parse_args()

    data = Path(args.data)
    rows, total = load_pairs(data)
    if total / 60 < args.min_minutes:
        raise SystemExit(f"Only {total / 60:.1f} min of reviewed speech; need at least {args.min_minutes}. Collect more first.")

    import librosa
    import torch
    from peft import LoraConfig, get_peft_model
    from transformers import (Seq2SeqTrainer, Seq2SeqTrainingArguments, WhisperForConditionalGeneration,
                              WhisperProcessor)

    proc = WhisperProcessor.from_pretrained(args.base, language=args.lang, task="transcribe")
    model = WhisperForConditionalGeneration.from_pretrained(args.base)
    model = get_peft_model(model, LoraConfig(r=16, lora_alpha=32, lora_dropout=0.05,
                                             target_modules=["q_proj", "v_proj"]))
    model.print_trainable_parameters()

    class Pairs(torch.utils.data.Dataset):
        def __len__(self):
            return len(rows)

        def __getitem__(self, i):
            r = rows[i]
            wav, _ = librosa.load(data / r["audio"], sr=16000)
            feats = proc.feature_extractor(wav, sampling_rate=16000).input_features[0]
            labels = proc.tokenizer(r["text"]).input_ids
            return {"input_features": feats, "labels": labels}

    def collate(batch):
        feats = torch.tensor([b["input_features"] for b in batch])
        longest = max(len(b["labels"]) for b in batch)
        labels = torch.full((len(batch), longest), -100)
        for i, b in enumerate(batch):
            labels[i, : len(b["labels"])] = torch.tensor(b["labels"])
        return {"input_features": feats, "labels": labels}

    trainer = Seq2SeqTrainer(
        model=model,
        args=Seq2SeqTrainingArguments(output_dir=args.out, per_device_train_batch_size=8, learning_rate=1e-4,
                                      num_train_epochs=args.epochs, fp16=torch.cuda.is_available(),
                                      remove_unused_columns=False, label_names=["labels"], logging_steps=10,
                                      save_strategy="no", report_to=[]),
        train_dataset=Pairs(),
        data_collator=collate,
    )
    trainer.train()
    model.save_pretrained(args.out)
    print("Saved private adapter to", args.out)


if __name__ == "__main__":
    main()
