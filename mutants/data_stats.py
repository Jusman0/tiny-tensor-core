"""
Two facts about the test images that explain the planted-bug results
(mutants/run_mutants.sh prints this into its report):

  - the largest |acc1|, the layer-1 accumulator: planted bug 02 (16-bit
    accumulators) breaks only if it goes past what 16 bits can hold
  - how close the top two logits come: planted bug 04 (argmax keeps the
    LAST maximum) only changes the digit when two logits tie for the top

Both are computed with the golden model's own integer arithmetic
(model/golden.py), over the first N images and over all 10,000.

Run from the repo root:  python3 mutants/data_stats.py 300
"""

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "model"))
import golden  # noqa: E402  (the integer model the RTL must match)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    q, x, labels = golden.load()
    w1, w2 = q["W1q"].astype(np.int64), q["W2q"].astype(np.int64)
    m1, b1q, b2q = golden.integer_params(q)
    h, acc2, pred = golden.run_integer(x, w1, w2, m1, b1q, b2q)

    acc1 = np.abs(x @ w1.T).max(axis=1)        # largest |acc1| in each image
    top2 = np.sort(acc2 + b2q, axis=1)[:, -2:]  # the RTL compares acc2 + B2q
    gap = top2[:, 1] - top2[:, 0]               # 0 means a tie for the top

    for name, sel in ((f"first {n} images", slice(0, n)), (f"all {len(x)} images", slice(None))):
        print(f"{name}: largest |acc1| = {acc1[sel].max():,} "
              f"(a signed 16-bit register holds up to 32,767); "
              f"top-two logit ties: {int((gap[sel] == 0).sum())}, "
              f"smallest gap between the top two logits: {gap[sel].min()}")


if __name__ == "__main__":
    main()
