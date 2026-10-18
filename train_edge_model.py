"""Train a compact AeroWash edge segmentation model from reviewed image/mask pairs.

Dataset layout (masks are binary PNG, white=edge, black=background):
  ~/AeroWashVision/dataset/edge_training/images/*.jpg
  ~/AeroWashVision/dataset/edge_training/masks/<same-stem>.png

Only use reviewed/corrected masks for meaningful training. Auto-Canny masks are
pseudo-labels and mostly teach the network to imitate Canny, not understand objects.
"""
import argparse
import random
from pathlib import Path

import numpy as np
from PIL import Image
import torch
from torch import nn
from torch.utils.data import Dataset, DataLoader, random_split


class PairDataset(Dataset):
    def __init__(self, root, size=320):
        self.images = root / "images"
        self.masks = root / "masks"
        self.size = size
        self.pairs = []
        for image in sorted(self.images.glob("*")):
            if image.suffix.lower() not in {".jpg", ".jpeg", ".png"}:
                continue
            mask = self.masks / (image.stem + ".png")
            if mask.exists():
                self.pairs.append((image, mask))
        if not self.pairs:
            raise RuntimeError(
                f"No paired training data found. Add reviewed image/mask pairs to {self.images} and {self.masks}. "
                "Mask PNGs must have the same filename stem and white edges on black."
            )

    def __len__(self):
        return len(self.pairs)

    def __getitem__(self, index):
        image_path, mask_path = self.pairs[index]
        image = Image.open(image_path).convert("RGB").resize((self.size, self.size), Image.Resampling.BILINEAR)
        mask = Image.open(mask_path).convert("L").resize((self.size, self.size), Image.Resampling.NEAREST)
        x = np.asarray(image, dtype=np.float32) / 255.0
        y = (np.asarray(mask, dtype=np.float32) >= 128).astype(np.float32)
        x = torch.from_numpy(x.transpose(2, 0, 1).copy())
        y = torch.from_numpy(y[None, :, :].copy())
        return x, y


class TinyEdgeNet(nn.Module):
    def __init__(self):
        super().__init__()
        def block(cin, cout):
            return nn.Sequential(
                nn.Conv2d(cin, cout, 3, padding=1), nn.BatchNorm2d(cout), nn.ReLU(inplace=True),
                nn.Conv2d(cout, cout, 3, padding=1), nn.BatchNorm2d(cout), nn.ReLU(inplace=True),
            )
        self.enc1 = block(3, 16)
        self.enc2 = block(16, 32)
        self.enc3 = block(32, 64)
        self.pool = nn.MaxPool2d(2)
        self.up2 = nn.ConvTranspose2d(64, 32, 2, stride=2)
        self.dec2 = block(64, 32)
        self.up1 = nn.ConvTranspose2d(32, 16, 2, stride=2)
        self.dec1 = block(32, 16)
        self.out = nn.Conv2d(16, 1, 1)

    def forward(self, x):
        a = self.enc1(x)
        b = self.enc2(self.pool(a))
        c = self.enc3(self.pool(b))
        d = self.dec2(torch.cat([self.up2(c), b], dim=1))
        e = self.dec1(torch.cat([self.up1(d), a], dim=1))
        return self.out(e)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default=str(Path.home() / "AeroWashVision" / "dataset" / "edge_training"))
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--size", type=int, default=320)
    parser.add_argument("--output", default=str(Path.home() / "AeroWashVision" / "models" / "aerowash_edges.pt"))
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()
    if args.epochs < 1 or args.batch_size < 1 or args.size < 64 or args.size % 4:
        raise SystemExit("epochs/batch-size must be positive and size must be >=64 and divisible by 4.")
    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = torch.device("mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu")
    dataset = PairDataset(Path(args.data), args.size)
    if len(dataset) < 10:
        print(f"WARNING: only {len(dataset)} reviewed pairs; results will likely overfit. Aim for 100+ varied pairs.")
    if len(dataset) >= 10:
        val_count = max(1, int(len(dataset) * 0.15))
        train_count = len(dataset) - val_count
        train_ds, val_ds = random_split(dataset, [train_count, val_count], generator=torch.Generator().manual_seed(args.seed))
    else:
        train_ds, val_ds = dataset, None
    train_loader = DataLoader(train_ds, batch_size=args.batch_size, shuffle=True, num_workers=0)
    val_loader = DataLoader(val_ds, batch_size=args.batch_size, shuffle=False, num_workers=0) if val_ds else None
    model = TinyEdgeNet().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-3)
    criterion = nn.BCEWithLogitsLoss()
    print(f"Pairs: {len(dataset)} | device: {device} | train: {len(train_ds)} | validation: {len(val_ds) if val_ds else 0}")
    for epoch in range(1, args.epochs + 1):
        model.train()
        train_loss = 0.0
        for x, y in train_loader:
            x, y = x.to(device), y.to(device)
            optimizer.zero_grad(set_to_none=True)
            logits = model(x)
            loss = criterion(logits, y)
            loss.backward()
            optimizer.step()
            train_loss += loss.item() * x.size(0)
        train_loss /= len(train_ds)
        val_loss = None
        if val_loader:
            model.eval()
            total = 0.0
            with torch.no_grad():
                for x, y in val_loader:
                    x, y = x.to(device), y.to(device)
                    total += criterion(model(x), y).item() * x.size(0)
            val_loss = total / len(val_ds)
        print(f"Epoch {epoch:03d}/{args.epochs} train_loss={train_loss:.4f}" + (f" val_loss={val_loss:.4f}" if val_loss is not None else ""))
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    torch.save({"model_state_dict": model.cpu().state_dict(), "model": "TinyEdgeNet", "size": args.size, "classes": {"background": 0, "edge": 1}, "training_pairs": len(dataset)}, output)
    print(f"Saved model: {output}")
    print("Training finished. Validate on separate real images before using this model for drone navigation or cleaning.")


if __name__ == "__main__":
    main()
