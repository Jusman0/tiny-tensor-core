#!/usr/bin/env bash
# Place and route on a Lattice ECP5-45F (CABGA381) and report max clock
# frequency for three placement seeds. Needs yosys and nextpnr-ecp5.
# Run from the repo root:  bash synth/timing_ecp5.sh
set -e
mkdir -p sim
yosys -q -s synth/ecp5.ys
for seed in 1 2 3; do
  nextpnr-ecp5 --45k --package CABGA381 --json sim/tc_ecp5.json --seed $seed \
    --freq 50 --quiet --log sim/ecp5_s$seed.log 2>/dev/null || true
  fmax=$(grep -oP "Max frequency for clock '.*?': \K[0-9.]+" sim/ecp5_s$seed.log | tail -1)
  echo "seed $seed: $fmax MHz"
done
