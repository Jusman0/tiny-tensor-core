# file: rtl/tensor_core.v
# models: argmax keeps the last maximum on ties (>= instead of >)
#
# The golden model (NumPy argmax) keeps the first maximum. The two only
# differ on an image where two logits tie for the top.
s@if (idx == 0 || logit > best) begin@if (idx == 0 || logit >= best) begin@
