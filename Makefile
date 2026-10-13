# make test       1,000 MNIST images through the RTL (about 15 s on an Apple M2)
# make test-full  all 10,000 images (about 2.5 minutes on an Apple M2)
# make golden     regenerate rom/ and sim/ from the Python golden model
# make mutants    planted bugs: copies of rtl/ with one bug each, through the testbench
# make synth      resource reports for ECP5, Gowin and iCE40 FPGAs
# make timing     place and route on an ECP5-45F, max clock frequency

PYTHON ?= python3
IVERILOG = iverilog -g2005 -Wall -I.
RTL = rtl/mac_lane.v rtl/tensor_core.v
N ?= 1000

.PHONY: test test-full golden mutants synth timing clean

# sim/images.hex comes first so golden runs (and writes rom/params.vh) before
# the testbench is compiled
test: sim/images.hex sim/tb_tensor_core
	vvp -n sim/tb_tensor_core +n=$(N) | tee sim/tb.log
	@grep -q '^PASS' sim/tb.log && echo "ALL TESTS PASSED"

test-full:
	$(MAKE) test N=10000

# golden.py writes rom/params.vh as well as the test vectors. Listing it here
# tells make that the testbench, which includes params.vh, depends on golden.
golden rom/params.vh sim/images.hex: model/golden.py data/mnist_test_14x14.npz model/tinyml_weights_int8.npz | sim
	$(PYTHON) model/golden.py

sim/tb_tensor_core: tb/tb_tensor_core.v $(RTL) rom/params.vh | sim
	$(IVERILOG) -o $@ $(RTL) tb/tb_tensor_core.v

# Planted bugs (README, Verification). The report goes to sim/mutants.log and
# is printed; the committed copy is mutants/mutants.log. status=$$? saves the
# script's exit status (make turns $$ into $), so the cat can't hide it. 0
# means the original design passed and every run finished, not that every bug
# was caught: the argmax bug is expected to pass (see the README).
mutants: sim/images.hex rom/params.vh
	PYTHON=$(PYTHON) bash mutants/run_mutants.sh > sim/mutants.log; \
	status=$$?; cat sim/mutants.log; exit $$status

sim:
	mkdir -p sim

synth: | sim
	yosys -q -s synth/ecp5.ys
	yosys -q -s synth/gowin.ys
	yosys -q -s synth/ice40.ys

timing:
	bash synth/timing_ecp5.sh

clean:
	rm -rf sim
