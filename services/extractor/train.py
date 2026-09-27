"""Fine-tune RF-DETR on the synthetic spreadsheet dataset (PRD §6.3).

Run on Modal with a GPU (see modal_train() below) or locally with CUDA:

    python extractor/train.py --dataset synth/output --epochs 8 --out extractor/runs/cells

The dataset must be in COCO format as produced by synth/generate_synthetic_tables.py
and split into train/valid/test folders (rfdetr expects <dataset>/{train,valid,test}/_annotations.coco.json).
`split_dataset()` does that split. NOTE: this script has not been run inside this
repository yet (no GPU available while it was written); treat it as the scaffold
to launch on Modal, then record cell mAP@0.5 in the README table.
"""

from __future__ import annotations

import argparse
import json
import random
import shutil
from pathlib import Path


def split_dataset(source: Path, destination: Path, seed: int = 0, valid_share: float = 0.1, test_share: float = 0.1) -> None:
    coco = json.loads((source / "annotations.json").read_text())
    images = coco["images"]
    random.Random(seed).shuffle(images)
    valid_count = int(len(images) * valid_share)
    test_count = int(len(images) * test_share)
    splits = {
        "valid": images[:valid_count],
        "test": images[valid_count:valid_count + test_count],
        "train": images[valid_count + test_count:],
    }
    for split_name, split_images in splits.items():
        split_dir = destination / split_name
        split_dir.mkdir(parents=True, exist_ok=True)
        image_ids = {image["id"] for image in split_images}
        for image in split_images:
            shutil.copy(source / "images" / image["file_name"], split_dir / image["file_name"])
        (split_dir / "_annotations.coco.json").write_text(json.dumps({
            "images": split_images,
            "annotations": [a for a in coco["annotations"] if a["image_id"] in image_ids],
            "categories": coco["categories"],
        }))
        print(f"{split_name}: {len(split_images)} images")


def train(dataset_dir: Path, output_dir: Path, epochs: int, batch_size: int) -> None:
    from rfdetr import RFDETRBase  # type: ignore

    model = RFDETRBase()
    model.train(
        dataset_dir=str(dataset_dir),
        epochs=epochs,
        batch_size=batch_size,
        grad_accum_steps=max(1, 16 // batch_size),
        lr=1e-4,
        output_dir=str(output_dir),
        resolution=1120,
    )
    print(f"weights written under {output_dir}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, required=True, help="folder with images/ and annotations.json")
    parser.add_argument("--out", type=Path, default=Path("extractor/runs/cells"))
    parser.add_argument("--epochs", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=8)
    args = parser.parse_args()

    split_dir = args.out / "dataset"
    split_dataset(args.dataset, split_dir)
    train(split_dir, args.out, args.epochs, args.batch_size)


if __name__ == "__main__":
    main()
