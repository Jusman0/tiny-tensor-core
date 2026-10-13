# file: rtl/tensor_core.v
# models: 16-bit accumulators instead of 24
#
# The worst case |acc1| is 196 x 127 x 128 = 3,186,176, which needs 23 bits
# plus the sign. On real images |acc1| reaches 138,694, still too big for a
# signed 16-bit register (at most 32,767), so the sums wrap around.
s|parameter ACC_W   = 24,|parameter ACC_W   = 16,|
