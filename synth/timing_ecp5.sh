#!/usr/bin/env bash
# Place and route on a Lattice ECP5-45F (CABGA381) and report max clock
# frequency for three placement seeds. Needs yosys and nextpnr-ecp5.
# Run from the repo root:  bash synth/timing_ecp5.sh
#
# Other builds of the tools can be named, e.g. the YoWASP (pip) ones:
#   YOSYS=yowasp-yosys NEXTPNR=yowasp-nextpnr-ecp5 bash synth/timing_ecp5.sh
#
# Works on macOS and Linux: the number is pulled out of the log with sed,
# because the grep that ships with macOS has no -P option.
set -e
YOSYS=${YOSYS:-yosys}
NEXTPNR=${NEXTPNR:-nextpnr-ecp5}
mkdir -p sim

# print the tool versions: LUT counts differ between Yosys versions
$YOSYS -V
$NEXTPNR --version

$YOSYS -q -s synth/ecp5.ys
for seed in 1 2 3; do
  # nextpnr exits with an error when a seed misses the 50 MHz target. Keep
  # going so every seed is reported, and print that exit code, not hide it.
  rm -f sim/ecp5_s$seed.log          # never report an old run's number
  status=0
  $NEXTPNR --45k --package CABGA381 --json sim/tc_ecp5.json --seed $seed \
    --freq 50 --quiet --log sim/ecp5_s$seed.log || status=$?
  # The last "Max frequency" line in the log is the post-route result, e.g.
  #   Info: Max frequency for clock '...': 51.64 MHz (PASS at 50.00 MHz)
  result=$(sed -n "s/.*Max frequency for clock '[^']*': //p" sim/ecp5_s$seed.log | tail -1)
  if [ -z "$result" ]; then
    echo "seed $seed: no max frequency in sim/ecp5_s$seed.log (nextpnr exit $status)"
    exit 1
  fi
  echo "seed $seed: $result  (nextpnr exit $status)"
done
