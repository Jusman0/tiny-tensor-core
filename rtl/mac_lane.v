`timescale 1ns/1ps
// mac_lane: one multiply-accumulate lane.
//
//   acc <= (first ? 0 : acc) + w * x      w: int8   x: uint7 (0..127)
//
// x is always a pixel or a post-ReLU activation, both clamped to 0..127, so
// the lane takes a 7-bit unsigned input. An 8x7 multiplier is about 40%
// smaller in FPGA logic than a full signed 8x8 (201 vs 337 iCE40 LUTs).
//
// `first` starts a new dot product on its first beat, so there is no
// separate clear cycle between neurons or images.

module mac_lane #(
    parameter ACC_W = 24
) (
    input  wire                    clk,
    input  wire                    en,
    input  wire                    first,
    input  wire signed [7:0]       w,
    input  wire        [6:0]       x,
    output reg  signed [ACC_W-1:0] acc
);
    wire signed [14:0]      p    = w * $signed({1'b0, x});
    // base must be a signed wire: a bare {ACC_W{1'b0}} in the same expression
    // would make the whole sum unsigned and zero-extend negative products.
    wire signed [ACC_W-1:0] base = first ? {ACC_W{1'b0}} : acc;

    always @(posedge clk)
        if (en) acc <= base + p;
endmodule
