# file: rtl/mac_lane.v
# models: accumulator base left unsigned, so negative products are zero-extended
#
# In Verilog, one unsigned operand makes the whole expression unsigned. If
# base is a plain (unsigned) wire, base + p zero-extends the 15-bit signed
# product p, and every negative product becomes a large positive number.
s|wire signed \[ACC_W-1:0\] base = first|wire        [ACC_W-1:0] base = first|
