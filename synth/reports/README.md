# Place-and-route reports (ECP5-45F)

Logs behind the ~50 MHz in the main README, made on 2026-10-12 on an Apple M2 with the YoWASP (pip) builds of Yosys and nextpnr:

```bash
YOSYS=yowasp-yosys NEXTPNR=yowasp-nextpnr-ecp5 make timing
```

| File | Contents |
|---|---|
| `make_timing.txt` | console output of that run under `/usr/bin/time -p` (the last three lines) |
| `ecp5_s1.log`, `ecp5_s2.log`, `ecp5_s3.log` | nextpnr logs for placement seeds 1, 2 and 3, trimmed |
| `ecp5_stat_yosys-0.69.txt` | Yosys `stat` resource count from the same run |
| `tool_versions.txt` | exact tool versions |

| Seed | Post-route max clock | At the 50 MHz target |
|---|---|---|
| 1 | 51.64 MHz | PASS |
| 2 | 53.14 MHz | PASS |
| 3 | 50.00 MHz | FAIL: just under 50 MHz, shown rounded, so nextpnr exits with an error |
| median | 51.64 MHz | |

## Scope

Post-route estimates, not board measurements. The runs are out-of-context: no pin constraints and no PLL, so nextpnr places the I/O itself and the clock enters directly from a pin. Each log has two "Max frequency" lines: the first is the pre-route estimate, the last the post-route result.

## Critical path

In all three seeds the slowest path is in layer 1 (`rtl/mac_lane.v`), not requantization: a block-RAM read (image RAM or weight ROM) into a lane's DSP multiplier, then the accumulator's carry chain, 18.8 to 20.0 ns in total.

## Trimming

Placer and router progress lines are removed; the rest is verbatim nextpnr output:

```bash
grep -v -E '^Info: +(at |IterCnt |[0-9]+ +\||\|)' sim/ecp5_s1.log > synth/reports/ecp5_s1.log
```

## LUT counts by Yosys version

- Yosys 0.69 (this run): 2,785 LUT4s.
- Committed `synth/ecp5_stat.txt`, older Yosys (version not recorded): 3,125 LUT4s.
- Identical in both: 44 MULT18X18D (DSP multipliers), 9 DP16KD (block RAMs), 586 CCU2C (carry cells), 1,574 flip-flops.
- `make synth` and `make timing` rewrite `synth/ecp5_stat.txt` with the installed Yosys.

## Known warning

Yosys 0.69 prints two "Drivers conflicting with a constant driver" warnings (in `make_timing.txt`). The cause is `rtl/tensor_core.v` using the same `integer k` as the loop variable in two `always` blocks. The logic is unaffected; each block should have its own loop variable.
