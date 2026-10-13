# file: rtl/tensor_core.v
# models: rounding term missing from requantization
#
# h = (acc * M1 + B1q + 2^23) >> 24. The + 2^23 turns the floor shift into
# round-to-nearest. Without it every hidden value is rounded down instead.
s|localparam signed \[41:0\] ROUND = 42'sd1 <<< (SHIFT - 1);|localparam signed [41:0] ROUND = 42'sd0;|
