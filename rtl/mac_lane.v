`timescale 1ns/1ps
// mac_lane: acc <= (first ? 0 : acc) + w * x, w int8, x uint7 (0..127).
// x is a pixel or post-ReLU activation (0..127), so an 8x7 multiplier suffices:
// about 40% smaller than a signed 8x8 (201 vs 337 iCE40 LUTs).
// `first` restarts the sum on its first beat: no clear cycle between neurons or images.

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
    // signed base: a bare {ACC_W{1'b0}} would make the sum unsigned and zero-extend negative products
    wire signed [ACC_W-1:0] base = first ? {ACC_W{1'b0}} : acc;

    always @(posedge clk)
        if (en) acc <= base + p;
endmodule
