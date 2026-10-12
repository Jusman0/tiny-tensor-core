# make test       1,000 MNIST images through the RTL (about a minute)
# make test-full  all 10,000 images (a few minutes)
# make golden     regenerate rom/ and sim/ from the Python golden model
# make synth      resource reports for ECP5, Gowin and iCE40 FPGAs
# make timing     place and route on an ECP5-45F, max clock frequency

IVERILOG = iverilog -g2005 -Wall -I.
RTL = rtl/mac_lane.v rtl/tensor_core.v
N ?= 1000

.PHONY: test test-full golden synth timing clean

test: sim/tb_tensor_core sim/images.hex
	vvp -n sim/tb_tensor_core +n=$(N) | tee sim/tb.log
	@grep -q '^PASS' sim/tb.log && echo "ALL TESTS PASSED"

test-full:
	$(MAKE) test N=10000

golden sim/images.hex: model/golden.py data/mnist_test_14x14.npz model/tinyml_weights_int8.npz | sim
	python3 model/golden.py

sim/tb_tensor_core: tb/tb_tensor_core.v $(RTL) rom/params.vh | sim
	$(IVERILOG) -o $@ $(RTL) tb/tb_tensor_core.v

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
