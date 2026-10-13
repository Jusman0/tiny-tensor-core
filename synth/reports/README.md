# Place-and-route reports (ECP5-45F)

These are the logs behind the "~50 MHz" in the main README. They were made on 2026-10-12 on an Apple M2 with the YoWASP (pip) builds of Yosys and nextpnr:

```bash
YOSYS=yowasp-yosys NEXTPNR=yowasp-nextpnr-ecp5 make timing
```

| File | What it is |
|---|---|
| `make_timing.txt` | console output of that run (it was wrapped in `/usr/bin/time -p`, which printed the last three lines) |
| `ecp5_s1.log`, `ecp5_s2.log`, `ecp5_s3.log` | nextpnr logs for placement seeds 1, 2 and 3 (trimmed, see below) |
| `ecp5_stat_yosys-0.69.txt` | the Yosys `stat` resource count from the same run |
| `tool_versions.txt` | exact tool versions |

| Seed | Post-route max clock | At the 50 MHz target |
|---|---|---|
| 1 | 51.64 MHz | PASS |
| 2 | 53.14 MHz | PASS |
| 3 | 50.00 MHz | FAIL: just under 50 MHz, shown rounded, so nextpnr exits with an error |
| **median** | **51.64 MHz** | |

**What these numbers are.** An estimate, not a measurement on a board. The runs are out-of-context: there's no pin constraint file and no PLL, so nextpnr places the I/O pins itself and the clock comes straight in from a pin. Each log has two "Max frequency" lines. The first is nextpnr's estimate before routing; the last one is the post-route result.

**Slowest path.** In all three seeds it is in layer 1 (`rtl/mac_lane.v`), not the requantizer. A block-RAM read (the image RAM or the weight ROM) feeds a lane's DSP multiplier, then the carry chain of the accumulator add: 18.8 to 20.0 ns in total.

**Trimming.** The placer and router progress lines were removed, and everything else is exactly as nextpnr wrote it:

```bash
grep -v -E '^Info: +(at |IterCnt |[0-9]+ +\||\|)' sim/ecp5_s1.log > synth/reports/ecp5_s1.log
```

**LUT counts depend on the Yosys version.**
- Yosys 0.69 (this run) gives 2,785 LUT4s.
- The committed `synth/ecp5_stat.txt` was made with an older Yosys whose version wasn't recorded, and shows 3,125 LUT4s.
- The other counts are identical in both: 44 MULT18X18D (DSP multipliers), 9 DP16KD (block RAMs), 586 CCU2C (carry cells) and 1,574 flip-flops.
- `make synth` and `make timing` rewrite `synth/ecp5_stat.txt` with whatever Yosys you have installed.

**Known warning.** Yosys 0.69 prints two "Drivers conflicting with a constant driver" warnings (in `make_timing.txt`). They come from `rtl/tensor_core.v` using the same `integer k` as the loop variable in two different `always` blocks. That doesn't change the logic, but each block should have its own loop variable.
