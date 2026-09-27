"""Fine-tune a biomedical encoder for clinical span tagging on a Modal GPU.

    cd services && modal run --detach ner/train_ner.py

Labels: CHEMICAL (drugs), DISEASE (conditions) from BC5CDR, plus DOSE and FREQ
from synthetic medication-list lines built from the RxNorm lexicon
("metformin 1000 mg PO BID", "warfarin 5 mg daily"). Reports entity-level F1
per class on the held-out BC5CDR test split and a synthetic held-out set,
exports ONNX, and stores everything in the `sounder-ner` volume:

    /models/sounder-ner/{model,onnx}/  and  metrics.json
"""

import json
import random

import modal

BASE_MODEL = "microsoft/BiomedNLP-BiomedBERT-base-uncased-abstract"
LABELS = ["O", "B-CHEMICAL", "I-CHEMICAL", "B-DISEASE", "I-DISEASE", "B-DOSE", "I-DOSE", "B-FREQ", "I-FREQ"]

image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install("torch", "transformers>=4.44", "datasets", "seqeval", "accelerate", "onnx", "onnxruntime", "optimum[exporters]", "numpy<2")
    .add_local_dir("clinical/data", remote_path="/root/clinical/data")
)
app = modal.App("sounder-ner", image=image)
volume = modal.Volume.from_name("sounder-ner", create_if_missing=True)


def synthetic_med_lines(count: int, seed: int) -> list[tuple[list[str], list[str]]]:
    """Med-list lines with word-level BIO tags for CHEMICAL / DOSE / FREQ."""
    rng = random.Random(seed)
    lexicon = json.load(open("/root/clinical/data/drug_lexicon.json"))["names"]
    curated = [name for name, rxcui in lexicon.items() if rxcui]  # resolved generics read like real med lists
    frequencies = [["daily"], ["BID"], ["TID"], ["QID"], ["once", "daily"], ["twice", "daily"], ["nightly"], ["q12h"], ["q8h"], ["weekly"], ["PRN"]]
    routes = ["PO", "IV", "SC", "", "", ""]
    units = ["mg", "mg", "mg", "mcg", "g", "units", "mL"]
    examples = []
    for _ in range(count):
        drug = rng.choice(curated).split()
        dose = [str(rng.choice([5, 10, 20, 25, 40, 50, 75, 100, 200, 250, 500, 850, 1000]))]
        unit = rng.choice(units)
        dose_tokens = dose + [unit] if rng.random() < 0.7 else [dose[0] + unit]
        route = rng.choice(routes)
        frequency = rng.choice(frequencies)
        tokens, tags = [], []
        for index, token in enumerate(drug):
            tokens.append(token); tags.append("B-CHEMICAL" if index == 0 else "I-CHEMICAL")
        for index, token in enumerate(dose_tokens):
            tokens.append(token); tags.append("B-DOSE" if index == 0 else "I-DOSE")
        if route:
            tokens.append(route); tags.append("O")
        for index, token in enumerate(frequency):
            tokens.append(token); tags.append("B-FREQ" if index == 0 else "I-FREQ")
        if rng.random() < 0.4:
            filler = rng.choice([["for", "hypertension"], ["-", "hold", "if", "SBP", "<", "100"], ["with", "food"], ["started", "today"]])
            tokens += filler; tags += ["O"] * len(filler)
        examples.append((tokens, tags))
    return examples


@app.function(gpu="A10G", timeout=60 * 60, volumes={"/models": volume})
def train(epochs: int = 2, synthetic_count: int = 6000):
    import numpy as np
    import torch
    from datasets import Dataset, load_dataset
    from seqeval.metrics import classification_report, f1_score
    from transformers import (AutoModelForTokenClassification, AutoTokenizer, DataCollatorForTokenClassification,
                              Trainer, TrainingArguments)

    label_to_id = {label: index for index, label in enumerate(LABELS)}

    # BC5CDR from tner: tags 0..4 = O, B-Chemical, B-Disease, I-Disease, I-Chemical (see dataset card)
    bc5 = load_dataset("tner/bc5cdr")
    tner_names = bc5["train"].features["tags"].feature.names if hasattr(bc5["train"].features["tags"], "feature") else None
    tner_map = {"O": "O", "B-Chemical": "B-CHEMICAL", "I-Chemical": "I-CHEMICAL", "B-Disease": "B-DISEASE", "I-Disease": "I-DISEASE"}

    def convert_bc5(split):
        rows = []
        for record in split:
            tags = []
            for tag in record["tags"]:
                name = tner_names[tag] if tner_names else {0: "O", 1: "B-Chemical", 2: "B-Disease", 3: "I-Disease", 4: "I-Chemical"}[tag]
                tags.append(tner_map[name])
            rows.append({"tokens": record["tokens"], "tags": tags})
        return rows

    train_rows = convert_bc5(bc5["train"]) + [{"tokens": t, "tags": g} for t, g in synthetic_med_lines(synthetic_count, seed=1)]
    valid_rows = convert_bc5(bc5["validation"])
    test_bc5_rows = convert_bc5(bc5["test"])
    test_synth_rows = [{"tokens": t, "tags": g} for t, g in synthetic_med_lines(800, seed=2)]
    random.Random(0).shuffle(train_rows)
    print(f"train {len(train_rows)} sentences (bc5cdr + {synthetic_count} synthetic), valid {len(valid_rows)}, test bc5 {len(test_bc5_rows)}, test synthetic {len(test_synth_rows)}")

    tokenizer = AutoTokenizer.from_pretrained(BASE_MODEL)

    def encode(batch):
        encoded = tokenizer(batch["tokens"], is_split_into_words=True, truncation=True, max_length=128)
        all_labels = []
        for row_index, tags in enumerate(batch["tags"]):
            word_ids = encoded.word_ids(batch_index=row_index)
            previous_word = None
            labels = []
            for word_id in word_ids:
                if word_id is None:
                    labels.append(-100)
                elif word_id != previous_word:
                    labels.append(label_to_id[tags[word_id]])
                else:
                    labels.append(-100)  # only the first sub-token carries the label
                previous_word = word_id
            all_labels.append(labels)
        encoded["labels"] = all_labels
        return encoded

    def to_dataset(rows):
        return Dataset.from_list(rows).map(encode, batched=True, remove_columns=["tokens", "tags"])

    train_ds, valid_ds = to_dataset(train_rows), to_dataset(valid_rows)
    test_bc5_ds, test_synth_ds = to_dataset(test_bc5_rows), to_dataset(test_synth_rows)

    model = AutoModelForTokenClassification.from_pretrained(BASE_MODEL, num_labels=len(LABELS),
                                                            id2label=dict(enumerate(LABELS)), label2id=label_to_id)

    def compute_metrics(prediction):
        logits, labels = prediction
        predictions = np.argmax(logits, axis=-1)
        true_tags, pred_tags = [], []
        for pred_row, label_row in zip(predictions, labels):
            true_tags.append([LABELS[l] for p, l in zip(pred_row, label_row) if l != -100])
            pred_tags.append([LABELS[p] for p, l in zip(pred_row, label_row) if l != -100])
        return {"f1": f1_score(true_tags, pred_tags), "report": classification_report(true_tags, pred_tags, digits=3)}

    arguments = TrainingArguments(
        output_dir="/models/sounder-ner/checkpoints", per_device_train_batch_size=32, per_device_eval_batch_size=64,
        learning_rate=3e-5, num_train_epochs=epochs, warmup_ratio=0.06, weight_decay=0.01, fp16=torch.cuda.is_available(),
        eval_strategy="epoch", save_strategy="no", logging_steps=50, report_to=[],
    )
    trainer = Trainer(model=model, args=arguments, train_dataset=train_ds, eval_dataset=valid_ds,
                      data_collator=DataCollatorForTokenClassification(tokenizer), compute_metrics=lambda p: {"f1": compute_metrics(p)["f1"]})
    import time
    started = time.time()
    trainer.train()
    train_seconds = time.time() - started

    metrics = {"base_model": BASE_MODEL, "epochs": epochs, "train_sentences": len(train_rows), "train_seconds": round(train_seconds, 1)}
    for name, dataset in [("bc5cdr_test", test_bc5_ds), ("synthetic_medlines_test", test_synth_ds)]:
        prediction = trainer.predict(dataset)
        scored = compute_metrics((prediction.predictions, prediction.label_ids))
        metrics[name] = {"entity_f1": round(scored["f1"], 4), "report": scored["report"]}
        print(f"== {name}: entity F1 {scored['f1']:.4f}\n{scored['report']}")

    trainer.save_model("/models/sounder-ner/model")
    tokenizer.save_pretrained("/models/sounder-ner/model")

    # ONNX export for on-device inference (onnxruntime / Core ML conversion).
    try:
        from optimum.exporters.onnx import main_export
        main_export(model_name_or_path="/models/sounder-ner/model", output="/models/sounder-ner/onnx", task="token-classification")
        metrics["onnx"] = "/models/sounder-ner/onnx/model.onnx"
    except Exception as error:  # export is best-effort; the PyTorch weights are the deliverable
        metrics["onnx_error"] = str(error)[:300]

    json.dump(metrics, open("/models/sounder-ner/metrics.json", "w"), indent=2)
    volume.commit()
    print(json.dumps({k: v for k, v in metrics.items() if k not in ("bc5cdr_test", "synthetic_medlines_test")}, indent=2))
    return metrics


@app.function(volumes={"/models": volume}, timeout=300)
def predict(text: str = "Warfarin 5 mg PO daily for atrial fibrillation; metformin 1000 mg BID; eGFR 38") -> list[dict]:
    """Sanity check on a med-list line after training."""
    import torch
    from transformers import AutoModelForTokenClassification, AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained("/models/sounder-ner/model")
    model = AutoModelForTokenClassification.from_pretrained("/models/sounder-ner/model")
    words = text.replace(";", " ;").split()
    encoded = tokenizer(words, is_split_into_words=True, return_tensors="pt", truncation=True)
    with torch.no_grad():
        predictions = model(**encoded).logits.argmax(-1)[0].tolist()
    spans, previous_word = [], None
    for token_index, word_id in enumerate(encoded.word_ids()):
        if word_id is None or word_id == previous_word:
            continue
        previous_word = word_id
        spans.append({"word": words[word_id], "tag": LABELS[predictions[token_index]]})
    print(spans)
    return spans


@app.local_entrypoint()
def main(epochs: int = 2):
    metrics = train.remote(epochs=epochs)
    print("bc5cdr F1:", metrics["bc5cdr_test"]["entity_f1"], "| synthetic F1:", metrics["synthetic_medlines_test"]["entity_f1"])
