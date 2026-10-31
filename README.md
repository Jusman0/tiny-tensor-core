# tiny-tensor-core

[![tests](https://github.com/Jusman0/tiny-tensor-core/actions/workflows/test.yml/badge.svg)](https://github.com/Jusman0/tiny-tensor-core/actions/workflows/test.yml)

The [TinyML MNIST network](https://github.com/Jusman0/tinyml-mnist-uno) in Verilog: 32 multiply-accumulate lanes, integer-only requantization and an argmax digit output, checked against a Python golden model.

| | |
|---|---|
| Bit-exact | hidden activations, layer-2 accumulators and predicted digit on 10,000 / 10,000 MNIST test images |
| Accuracy | 96.48%; every prediction matches the Arduino's float network, emulated in NumPy on all 10,000 images (the UNO itself ran 5) |
| Clocks per image | 273. Arduino UNO: 30.7 ms (about 491,000 clocks at 16 MHz), measured with `micros()` in the [tinyml-mnist-uno](https://github.com/Jusman0/tinyml-mnist-uno) run (UNO serial log to be committed) |
| ECP5-45F place and route | ~50 MHz post-route estimate (nextpnr-ecp5, out-of-context, median of 3 seeds = 51.6 MHz; [`synth/reports/`](synth/reports/)), about 5.5 µs of compute per image |
| ECP5-45F resources | 3,125 LUT4s, 586 carry cells, 44 DSP multipliers, 9 block RAMs (LUT count from an older Yosys; Yosys 0.69 gives 2,785 LUT4s) |

## Architecture

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
| Requantization | 32 | 32 fixed-point multiplies |
| Layer 2 | 32 + 1 | 320 MACs, 10 per clock |
| Argmax | 10 | bias add and compare |
| Done | 1 | |
| **Total** | **273** | |

Weights sit in on-chip ROM (`rom/*.hex`). Pixels load through a write port; `start` runs the network and `done` pulses with the digit.

## Integer-only requantization

The Arduino rescales between layers in floating point, `h = round((acc * S1 + b1) / SH)`. The hardware uses one fixed-point multiply and shift:

```
h = clamp((acc * M1 + B1q + 2^23) >> 24, 0, 127)

M1  = round(S1 / SH * 2^24) = 31,942     one multiplier shared by every neuron
B1q = round(b1 / SH * 2^24)              bias in the same fixed-point units
```

The clamp at 0 is the ReLU. Layer 2 needs no rescaling: a common positive scale S2 cannot change the argmax, so the hardware compares `acc2 + round(b2 / S2)`.

Over all 10,000 test images ([`model/golden.py`](model/golden.py)), 19 of 320,000 hidden activations differ by 1 from the float version and 0 of 10,000 predictions change.

## Synthesis notes

The first version simulated correctly but did not fit the target FPGA. Fixes, each commented in the code:

- `wire [63:0] sum = acc * M1 + ...` builds a 64×64 multiplier; the product needs only 24 + 17 = 41 bits.
- `acc_all[24*idx +: 24]` becomes wide barrel shifters, since 24 is not a power of two. An explicit multiplexer (a `for` loop comparing `idx == k`) is much smaller.
- Lane inputs (pixels, post-ReLU activations) are always 0 to 127, so each lane uses an 8×7 multiplier, not a signed 8×8: 201 vs 337 iCE40 LUTs per lane, about 40% smaller, in earlier per-lane runs (script not committed).
- An earlier un-pipelined version, not in the git history, placed and routed at about 33 to 37 MHz, limited by the requantization path (select neuron → 24×17 multiply → add → shift → clamp). The figure cannot be re-checked from the repo. A 3-stage requantization pipeline gives the current ~50 MHz ([logs](synth/reports/)) and moves the slowest path into the layer-1 lanes. It costs zero clocks: layer 2 reads each activation about 30 clocks after it is written.
- Without hardware multipliers an iCE40 needs 10,766 LUTs, over the 7,680 on an HX8K. An ECP5 maps the 42 lane multipliers onto DSP blocks and uses 3,125 LUTs. Both counts are from the committed `synth/*_stat.txt` (older Yosys, version not recorded). Yosys 0.69 gives 2,785 on the ECP5 with the same DSP, block RAM, carry and flip-flop counts ([`synth/reports/`](synth/reports/)).

## Verification

Per image, the testbench checks all 32 hidden activations, all 10 layer-2 accumulators and the predicted digit bit-exact against the golden model, and counts accuracy against the labels.

`make mutants` plants one bug at a time in a copy of `rtl/` (one `sed` script each, in [`mutants/`](mutants/)) and runs the unchanged testbench on the first 300 images ([`mutants/mutants.log`](mutants/mutants.log)):

| Planted bug (first 300 images) | Accuracy | Caught? |
|---|---|---|
| Accumulator base left unsigned (negative products zero-extended) | 11.3% | yes |
| 16-bit accumulators instead of 24 | 81.0% | yes |
| Rounding term missing from requantization | 98.3%, the same as the correct design | yes: internal values differ on 300 / 300 images, the digit on only 1 / 300 |
| Argmax keeps the last maximum on ties (`>=`) | 98.3% | no |

The rounding bug keeps the correct accuracy and changes only 1 of 300 digits, which is why the testbench compares internal values, not just the digit. The tie bug is not caught: no image in all 10,000 has two equal top scores (smallest gap 1, from `mutants/data_stats.py`, same log). A directed test with forced ties would catch it.

[`model/prepare_mnist.py`](model/prepare_mnist.py) rebuilds the 14×14 dataset from the original MNIST files (checksums verified); its first five images are byte-identical to the Arduino project's test images.

## Usage

Requires [Icarus Verilog](https://steveicarus.github.io/iverilog/) (`brew install icarus-verilog`) and Python 3 with NumPy (in a virtualenv, add `PYTHON=path/to/venv/bin/python` to the make command). Synthesis also needs Yosys and nextpnr ([OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)).

```bash
make test        # 1,000 images, about 15 s on an Apple M2; ends with ALL TESTS PASSED
make test-full   # all 10,000 images, about 2.5 minutes on an M2 (what CI runs)
make mutants     # the 4 planted bugs in the Verification table, about 1 minute
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

Built with an AI pair programmer. Every result above can be reproduced with the commands shown, except these, which are labelled where they appear: the UNO figures (30.7 ms per image, and the 5 images the UNO ran), the figures from earlier versions of the design (33 to 37 MHz before pipelining, 201 vs 337 LUTs per lane), the LUT counts from an older Yosys (3,125 on the ECP5, 10,766 on the iCE40; Yosys 0.69 gives 2,785 on the ECP5), and the match between the first five images and the Arduino project's `weights.h`, which needs that repo. Run times are approximate.

## Layout

```
rtl/mac_lane.v            one int8 x uint7 multiply-accumulate lane
rtl/tensor_core.v         lanes, ROMs, requantization, argmax, control FSM
tb/tb_tensor_core.v       bit-exact checks on every image
mutants/                  planted bugs (sed scripts), their runner and mutants.log
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

Each project computes the weighted sum one step closer to a GPU:

1. [analog-neuron](https://github.com/Jusman0/analog-neuron): with resistors
2. [tinyml-mnist-uno](https://github.com/Jusman0/tinyml-mnist-uno): in int8 on an 8-bit CPU, one MAC at a time
3. [dp4a-unit](https://github.com/Jusman0/dp4a-unit): as dedicated hardware, four MACs per clock
4. **tiny-tensor-core**: the whole network in hardware, 32 MACs per clock
5. next: on a real FPGA next to the Arduino, with the UNO as host CPU and this core as its accelerator
