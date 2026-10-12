// tb_tensor_core: pushes MNIST test images through tensor_core and checks,
// for every image, that
//   - all 32 hidden activations,
//   - all 10 layer-2 accumulators, and
//   - the predicted digit
// match the Python golden model bit for bit. Also reports accuracy against
// the true labels and the clocks per image.
//
// Runs all 10,000 images by default; `vvp sim/tb_tensor_core +n=500` for fewer.
`timescale 1ns/1ps

module tb_tensor_core;
    `include "rom/params.vh"

    localparam N_MAX = 10000, N_IN = 196, N_HID = 32, N_OUT = 10, ACC_W = 24;

    reg [7:0]             images   [0:N_MAX*N_IN-1];
    reg [7:0]             labels   [0:N_MAX-1];
    reg [7:0]             exp_pred [0:N_MAX-1];
    reg [8*N_HID-1:0]     exp_h    [0:N_MAX-1];
    reg [ACC_W*N_OUT-1:0] exp_acc2 [0:N_MAX-1];

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst = 1'b1, img_we = 1'b0, start = 1'b0;
    reg  [7:0] img_addr = 8'd0, img_data = 8'd0;
    wire       busy, done;
    wire [3:0] digit;
    wire [15:0] cycles;

    tensor_core #(.SHIFT(TC_SHIFT), .M1(TC_M1)) dut (
        .clk(clk), .rst(rst),
        .img_we(img_we), .img_addr(img_addr), .img_data(img_data),
        .start(start), .busy(busy), .done(done),
        .digit(digit), .cycles(cycles)
    );

    integer n, i, p;
    integer bad_h = 0, bad_acc2 = 0, bad_pred = 0, correct = 0;
    integer min_cyc = 65535, max_cyc = 0;

    initial begin
        if (!$value$plusargs("n=%d", n)) n = N_MAX;
        $readmemh("sim/images.hex",   images);
        $readmemh("sim/labels.hex",   labels);
        $readmemh("sim/exp_pred.hex", exp_pred);
        $readmemh("sim/exp_h.hex",    exp_h);
        $readmemh("sim/exp_acc2.hex", exp_acc2);

        repeat (2) @(negedge clk);
        rst = 1'b0;

        for (i = 0; i < n; i = i + 1) begin
            // load the image, one pixel per clock
            for (p = 0; p < N_IN; p = p + 1) begin
                @(negedge clk);
                img_we = 1'b1;  img_addr = p;  img_data = images[i*N_IN + p];
            end
            @(negedge clk);  img_we = 1'b0;  start = 1'b1;
            @(negedge clk);  start = 1'b0;
            while (!done) @(negedge clk);

            if (dut.h_all !== exp_h[i]) begin
                if (bad_h < 3) $display("image %0d: hidden activations differ", i);
                bad_h = bad_h + 1;
            end
            if (dut.acc2_all !== exp_acc2[i]) begin
                if (bad_acc2 < 3) $display("image %0d: layer-2 accumulators differ", i);
                bad_acc2 = bad_acc2 + 1;
            end
            if (digit !== exp_pred[i][3:0]) begin
                if (bad_pred < 3) $display("image %0d: predicted %0d, golden %0d",
                                           i, digit, exp_pred[i]);
                bad_pred = bad_pred + 1;
            end
            if (digit == labels[i][3:0]) correct = correct + 1;
            if (cycles < min_cyc) min_cyc = cycles;
            if (cycles > max_cyc) max_cyc = cycles;

            if (i < 5)
                $display("image %0d: label %0d, predicted %0d, %0d clocks",
                         i, labels[i], digit, cycles);
        end

        $display("images run            : %0d", n);
        $display("hidden activations    : %0d/%0d images bit-exact", n - bad_h, n);
        $display("layer-2 accumulators  : %0d/%0d images bit-exact", n - bad_acc2, n);
        $display("predicted digit       : %0d/%0d match the golden model", n - bad_pred, n);
        $display("accuracy vs labels    : %0d/%0d = %0d.%02d%%", correct, n,
                 (correct * 100) / n, ((correct * 10000) / n) % 100);
        $display("clocks per image      : %0d (min) to %0d (max)", min_cyc, max_cyc);
        if (bad_h == 0 && bad_acc2 == 0 && bad_pred == 0) $display("PASS");
        else                                             $display("FAIL");
        $finish;
    end
endmodule
