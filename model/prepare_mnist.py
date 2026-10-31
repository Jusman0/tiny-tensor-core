"""
Rebuild data/mnist_test_14x14.npz from the original MNIST test set.

Same preprocessing as tinyml-mnist-uno: pixels / 255, 2x2 average pool to
14x14, round(x * 127) clipped to 0..127. The first five images are
byte-identical to the test images in that project's weights.h. The .npz is
committed; this script checks it against the source.

Run from the repo root:  python3 model/prepare_mnist.py
"""

import gzip
import hashlib
import urllib.request
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
BASE = "https://raw.githubusercontent.com/fgnt/mnist/master/"
FILES = {   # official MNIST checksums
    "t10k-images-idx3-ubyte.gz": "9fb629c4189551a2d022fa330f9573f3",
    "t10k-labels-idx1-ubyte.gz": "ec29112dd5afa0611ce80d1b7f02629c",
}


def fetch(name):
    raw = urllib.request.urlopen(BASE + name).read()
    assert hashlib.md5(raw).hexdigest() == FILES[name], f"checksum mismatch: {name}"
    return gzip.decompress(raw)


def main():
    img = np.frombuffer(fetch("t10k-images-idx3-ubyte.gz"), np.uint8, offset=16)
    lab = np.frombuffer(fetch("t10k-labels-idx1-ubyte.gz"), np.uint8, offset=8)
    x = img.reshape(-1, 28, 28).astype(np.float32) / np.float32(255)
    pooled = x.reshape(-1, 14, 2, 14, 2).sum(axis=(2, 4), dtype=np.float32) / np.float32(4)
    xq = np.round(pooled.reshape(-1, 196) * np.float32(127)).clip(0, 127).astype(np.uint8)
    out = ROOT / "data" / "mnist_test_14x14.npz"
    out.parent.mkdir(exist_ok=True)
    np.savez_compressed(out, x=xq, labels=lab)
    print(f"wrote {out}: {xq.shape[0]} images")


if __name__ == "__main__":
    main()
