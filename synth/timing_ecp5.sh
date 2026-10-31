#!/usr/bin/env bash
# Place and route on a Lattice ECP5-45F (CABGA381); max clock for three placement seeds.
# Needs yosys and nextpnr-ecp5. Run from the repo root:  bash synth/timing_ecp5.sh
# Other builds, e.g. YoWASP (pip):
#   YOSYS=yowasp-yosys NEXTPNR=yowasp-nextpnr-ecp5 bash synth/timing_ecp5.sh
# Parses with sed, not grep -P (absent on macOS).
set -e
YOSYS=${YOSYS:-yosys}
NEXTPNR=${NEXTPNR:-nextpnr-ecp5}
mkdir -p sim

# LUT counts differ between Yosys versions
$YOSYS -V
$NEXTPNR --version

$YOSYS -q -s synth/ecp5.ys
for seed in 1 2 3; do
  # nextpnr fails a seed that misses 50 MHz; report every seed with its exit code
  rm -f sim/ecp5_s$seed.log          # never report an old run's number
  status=0
  $NEXTPNR --45k --package CABGA381 --json sim/tc_ecp5.json --seed $seed \
    --freq 50 --quiet --log sim/ecp5_s$seed.log || status=$?
  # the last "Max frequency" line is the post-route result, e.g.
  #   Info: Max frequency for clock '...': 51.64 MHz (PASS at 50.00 MHz)
  result=$(sed -n "s/.*Max frequency for clock '[^']*': //p" sim/ecp5_s$seed.log | tail -1)
  if [ -z "$result" ]; then
    echo "seed $seed: no max frequency in sim/ecp5_s$seed.log (nextpnr exit $status)"
    exit 1
  fi
  echo "seed $seed: $result  (nextpnr exit $status)"
done
