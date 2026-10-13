# tiny-tensor-core

[![tests](https://github.com/Jusman0/tiny-tensor-core/actions/workflows/test.yml/badge.svg)](https://github.com/Jusman0/tiny-tensor-core/actions/workflows/test.yml)

My [TinyML MNIST network](https://github.com/Jusman0/tinyml-mnist-uno) running entirely in hardware: 32 parallel multiply-accumulate lanes, integer-only requantization between layers, and an argmax that outputs the digit. It's written in Verilog and checked bit-exact against a Python golden model on all 10,000 MNIST test images.

| | |
|---|---|
| All 10,000 MNIST test images | hidden activations, layer-2 accumulators and predicted digit **bit-exact** on **10,000 / 10,000** |
| Accuracy | **96.48%**, the same as the Arduino's float version of the network, emulated in NumPy on all 10,000 images (the UNO itself ran 5). Not one prediction differs. |
| Clocks per image | **273**. The Arduino UNO takes about 491,000 (30.7 ms at 16 MHz). |
| Placed and routed on an ECP5-45F FPGA | **~50 MHz** post-route estimate (nextpnr-ecp5, out-of-context, median of 3 seeds = 51.6 MHz; logs in [`synth/reports/`](synth/reports/)), so about 5.5 µs of compute per image |
| ECP5-45F resources | 3,125 LUT4s, 586 carry cells, 44 DSP multipliers, 9 block RAMs (LUT count from an older Yosys; Yosys 0.69 gives 2,785 LUT4s) |

## How it works

```
                    pixel x[i] (broadcast)
                            │
  w1 ROM[i] ──┬──────┬──────┼──── ... ──────┐        one pixel per clock,
  (32 bytes)  ▼      ▼      ▼               ▼        196 clocks
           [MAC 0][MAC 1][MAC 2]  ...  [MAC 31]       32 int8 x uint7 lanes
              │      │      │               │
              └──────┴── select neuron j ───┘
                            ▼
              requantize: (acc*M1 + B1q + round) >> 24      3-stage pipeline,
              then ReLU / clamp to 0..127                    one neuron per clock
                            ▼
                     hidden h[0..31]
                            │  (broadcast, one per clock)
              w2 ROM ──► [MAC 0] ... [MAC 9]                 32 clocks
                            ▼
              argmax of acc2[k] + B2q[k]  ──►  digit 0-9     10 clocks
```

| Phase | Clocks | Work |
|---|---|---|
| Layer 1 | 196 + 1 | 6,272 MACs, 32 per clock |
| Requantize | 32 | 32 fixed-point multiplies |
| Layer 2 | 32 + 1 | 320 MACs, 10 per clock |
| Argmax | 10 | bias add and compare |
| Done | 1 | |
| **Total** | **273** | |

Weights live in on-chip ROM, loaded from `rom/*.hex`. The 196 pixels go in through a simple write port, then `start`, and `done` pulses with the digit.

## Integer-only requantization

The Arduino version rescales between layers with floats: `h = round((acc * S1 + b1) / SH)`. Hardware accelerators avoid floating point there, so this replaces it with one fixed-point multiply and a shift:

```
h = clamp((acc * M1 + B1q + 2^23) >> 24, 0, 127)

M1  = round(S1 / SH * 2^24) = 31,942     one multiplier shared by every neuron
B1q = round(b1 / SH * 2^24)              bias in the same fixed-point units
```

The clamp at 0 is the ReLU. Layer 2 needs no rescaling at all: every logit is multiplied by the same positive S2, which can't change which one is largest, so the hardware just compares `acc2 + round(b2 / S2)`.

The cost, measured over all 10,000 test images ([`model/golden.py`](model/golden.py)): 19 of 320,000 hidden activations come out 1 different from the float version, and **0 of 10,000 predictions change**.

## What synthesis taught me

The first version simulated perfectly but was far too big for the FPGA I had in mind. Each fix is in the code with a comment:

- **Size the math, not the expression.** `wire [63:0] sum = acc * M1 + ...` makes synthesis build a 64×64 multiplier. The product only needs 24 + 17 = 41 bits.
- **`acc_all[24*idx +: 24]` is a barrel shifter.** It reads like an array lookup, but because 24 isn't a power of two it synthesizes into wide shifters. An explicit multiplexer (a `for` loop comparing `idx == k`) is much smaller.
- **Use what the data guarantees.** Pixels and post-ReLU activations are always 0 to 127, so each lane only needs an 8×7 multiplier, not a signed 8×8. That's 201 instead of 337 LUTs per lane on an iCE40, about 40% smaller.
- **Find the critical path, then pipeline it.** Place-and-route showed the requantizer (select neuron → 24×17 multiply → add → shift → clamp) capping the whole design at 33 to 37 MHz. Splitting it into three pipeline stages raised the clock to ~50 MHz and added **zero** clocks per image, because layer 2 reads each activation about 30 clocks after it's written.
- **Pick the FPGA for the design.** Without hardware multipliers, an iCE40 needs 10,766 LUTs, more than the 7,680 on an HX8K. An ECP5 maps the 42 lane multipliers onto its DSP blocks and uses only 3,125 LUTs. (These LUT counts are from the committed `synth/*_stat.txt`, made with an older Yosys whose version wasn't recorded. Yosys 0.69 gives 2,785 on the ECP5, with the same DSP, block RAM, carry and flip-flop counts: see [`synth/reports/`](synth/reports/).)

## Verification

For every image, the testbench checks three things against the golden model, bit for bit: all 32 hidden activations, all 10 layer-2 accumulators, and the predicted digit. It also tallies accuracy against the true labels.

| Planted bug (first 300 images) | Accuracy | Caught? |
|---|---|---|
| Accumulator base left unsigned (negative products zero-extended) | 11.3% | yes |
| 16-bit accumulators instead of 24 | 81.0% | yes |
| Rounding term missing from requantization | 98.3%, the same as the correct design | **yes**: internal values differ on 300 / 300 images, the predicted digit on only 1 / 300 |
| Argmax keeps the last maximum on ties (`>=`) | 98.3% | no |

The rounding bug is why the testbench compares internal values rather than just accuracy or the digit: the broken design scored exactly as well on these images, and its predicted digit differed from the golden model on only 1 of the 300. The tie-breaking bug isn't caught because no image in all 10,000 has two equal top scores (the closest gap is 1), so the data can't exercise it. A directed test with forced ties would.

The data pipeline is checked too. [`model/prepare_mnist.py`](model/prepare_mnist.py) rebuilds the 14×14 dataset from the original MNIST files (checksums verified), and its first five images are byte-identical to the test images in the Arduino project.

## Run it

Needs [Icarus Verilog](https://steveicarus.github.io/iverilog/) (`brew install icarus-verilog`) and Python 3 with NumPy (if NumPy is in a virtualenv, add `PYTHON=path/to/venv/bin/python` to the make command). Yosys and nextpnr (in the [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)) are only for synthesis.

```bash
make test        # 1,000 images, about 15 s on an Apple M2; ends with ALL TESTS PASSED
make test-full   # all 10,000 images, about 2.5 minutes on an M2 (what CI runs)
make synth       # resource reports for ECP5, Gowin and iCE40
make timing      # place and route on an ECP5-45F, max clock frequency
```

```
image 0: label 7, predicted 7, 273 clocks
...
images run            : 10000
hidden activations    : 10000/10000 images bit-exact
layer-2 accumulators  : 10000/10000 images bit-exact
predicted digit       : 10000/10000 match the golden model
accuracy vs labels    : 9648/10000 = 96.48%
clocks per image      : 273 (min) to 273 (max)
PASS
```

## Layout

```
rtl/mac_lane.v            one int8 x uint7 multiply-accumulate lane
rtl/tensor_core.v         lanes, ROMs, requantizer, argmax, control FSM
tb/tb_tensor_core.v       bit-exact checks on every image
model/golden.py           integer-only golden model, writes rom/ and sim/
model/prepare_mnist.py    rebuilds data/ from the original MNIST files
model/tinyml_weights_int8.npz   trained weights from tinyml-mnist-uno
data/mnist_test_14x14.npz       MNIST test set, 14x14, quantized to 0..127
rom/                      weights, biases and M1 for the hardware
synth/                    Yosys scripts and ECP5 place-and-route
synth/reports/            nextpnr logs and tool versions behind the ~50 MHz
```

MNIST is by Yann LeCun, Corinna Cortes and Christopher Burges.

## Series

Each project computes the same neural-network operation, the weighted sum, one step closer to a GPU:

1. [analog-neuron](https://github.com/Jusman0/analog-neuron): with resistors
2. [tinyml-mnist-uno](https://github.com/Jusman0/tinyml-mnist-uno): in int8 on an 8-bit CPU, one MAC at a time
3. [dp4a-unit](https://github.com/Jusman0/dp4a-unit): as dedicated hardware, four MACs per clock
4. **tiny-tensor-core**: the whole network in hardware, 32 MACs per clock
5. next: on a real FPGA next to the Arduino, with the UNO as host CPU and this as its accelerator
