#!/usr/bin/env bash
# run_mutants.sh: planted-bug tests for the README's Verification table.
#
# A testbench that never fails proves nothing. So: plant one small bug in a
# COPY of rtl/, run the unchanged testbench on it, and see whether it says
# FAIL. Each bug is a sed script, mutants/NN_name.sed. Its first two lines
# say which file it edits ("# file:") and what mistake it models
# ("# models:").
#
# For the unmodified design ("00_original") and for each mutant:
#   1. copy rtl/*.v to sim/mutants/<name>/ and apply the sed script there
#   2. check that the file really changed (a pattern that no longer matches
#      would leave the design unchanged, and it would PASS: that is a broken
#      mutant, not a bug the testbench missed)
#   3. compile the copy with tb/tb_tensor_core.v (unchanged) and run the
#      first N images
#   4. report the testbench's verdict, its three bit-exact checks and the
#      accuracy against the true labels
#
# Usage, from anywhere (the Makefile's "make mutants" runs this):
#   bash mutants/run_mutants.sh
# Settings, from the environment:
#   PYTHON=python3   a python with numpy (for mutants/data_stats.py)
#   N=300            images per run
# Needs sim/ from "make golden". The report goes to stdout. Exit status 0
# means the original design passed and every run finished.

set -u
cd "$(dirname "$0")/.." || exit 1   # repo root: the testbench opens sim/*.hex from here

PYTHON=${PYTHON:-python3}
N=${N:-300}
WORK=sim/mutants

if [ ! -f sim/images.hex ] || [ ! -f rom/params.vh ]; then
    echo "run_mutants.sh: no test vectors in sim/, run make golden first" >&2
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"

MUTANTS=00_original
for f in mutants/*.sed; do
    MUTANTS="$MUTANTS $(basename "$f" .sed)"
done

for name in $MUTANTS; do
    dir="$WORK/$name"
    mkdir -p "$dir"
    cp rtl/*.v "$dir/"
    if [ "$name" != 00_original ]; then
        file=$(sed -n 's|^# file: rtl/||p' "mutants/$name.sed")
        sed -f "mutants/$name.sed" "rtl/$file" > "$dir/$file"
        # diff exits with 1 when the files differ, which is what we want
        diff "rtl/$file" "$dir/$file" > "$dir/diff.txt"
        if [ $? -ne 1 ]; then echo "not applied" > "$dir/status"; continue; fi
    fi
    # the same flags as the Makefile's testbench rule
    if ! iverilog -g2005 -Wall -I. -o "$dir/tb" "$dir/mac_lane.v" "$dir/tensor_core.v" \
            tb/tb_tensor_core.v > "$dir/compile.txt" 2>&1; then
        echo "compile error" > "$dir/status"; continue
    fi
    vvp -n "$dir/tb" +n="$N" > "$dir/run.txt" 2>&1
done

# value NAME PREFIX: the "x/N" on the testbench line that starts with
# PREFIX, e.g. "hidden activations    : 300/300 images bit-exact" -> 300/300
value() {
    sed -n "s|^$2 *: \([^ ]*\).*|\1|p" "$WORK/$1/run.txt"
}

# accuracy NAME: "accuracy vs labels    : 295/300 = 98.33%" -> 98.33%
accuracy() {
    sed -n 's|^accuracy vs labels *: .* = ||p' "$WORK/$1/run.txt"
}

verdict() {
    if [ -f "$WORK/$1/status" ]; then cat "$WORK/$1/status"
    elif grep -q '^PASS$' "$WORK/$1/run.txt"; then echo PASS
    elif grep -q '^FAIL' "$WORK/$1/run.txt"; then echo FAIL
    else echo "no result"; fi
}

models() {
    if [ "$1" = 00_original ]; then echo "nothing planted: the RTL as committed"
    else sed -n 's|^# models: ||p' "mutants/$1.sed"; fi
}

echo "# Planted-bug tests: bash mutants/run_mutants.sh"
echo "# $(date '+%Y-%m-%d %H:%M:%S'), $(iverilog -V 2>&1 | head -n 1), N = $N images"
echo "# rtl/ and tb/ from commit $(git rev-parse --short HEAD 2>/dev/null || echo '?')" \
     "($(git status --porcelain rtl tb 2>/dev/null | wc -l | tr -d ' ') uncommitted changes)"
echo
echo "The testbench says PASS only if all three bit-exact checks match the golden"
echo "model on every image. Columns: images where the check matched, out of $N."
echo
row='%-17s | %-76s | %-7s | %-7s | %-8s | %-7s | %s\n'
printf "$row" "mutant" "what it models" "verdict" "hidden" "layer-2" "digit" "accuracy"
for name in $MUTANTS; do
    printf "$row" "$name" "$(models "$name")" "$(verdict "$name")" \
        "$(value "$name" "hidden activations")" "$(value "$name" "layer-2 accumulators")" \
        "$(value "$name" "predicted digit")" "$(accuracy "$name")"
done
echo
echo "Data facts behind the results (python3 mutants/data_stats.py $N):"
"$PYTHON" mutants/data_stats.py "$N" | sed 's|^|  |'
echo "wall time: $SECONDS s"

status=0
[ "$(verdict 00_original)" = PASS ] || status=1
for name in $MUTANTS; do
    case "$(verdict "$name")" in PASS|FAIL) ;; *) status=1 ;; esac
done

echo
echo "################################################################"
echo "# Details: each mutant's change and the testbench output"
for name in $MUTANTS; do
    echo
    echo "== $name: $(models "$name")"
    [ -f "$WORK/$name/diff.txt" ] && { echo "-- change (diff rtl/ mutated):"; cat "$WORK/$name/diff.txt"; }
    [ -s "$WORK/$name/compile.txt" ] && { echo "-- compiler output:"; cat "$WORK/$name/compile.txt"; }
    [ -f "$WORK/$name/run.txt" ] && { echo "-- testbench, first $N images:"; cat "$WORK/$name/run.txt"; }
done
rm -rf "$WORK"
exit $status
