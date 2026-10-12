`timescale 1ns/1ps
// tensor_core: runs the whole TinyML MNIST network (196 -> 32 -> 10) in
// integer-only hardware and outputs the predicted digit.
//
//   1. layer 1   32 MAC lanes, one per hidden neuron. Each clock one pixel
//                is broadcast to all 32 lanes, each with its own weight.
//                196 clocks for 6,272 MACs.
//   2. requant   one fixed-point multiply + shift per neuron turns the int
//                accumulator into an int8 activation (ReLU and clamp
//                included). 32 clocks, through a 3-stage pipeline.
//   3. layer 2   10 MAC lanes, one per digit, 32 clocks.
//   4. argmax    adds the layer-2 bias and keeps the largest. 10 clocks.
//
// Load the 196 pixels through the img_* port, pulse start, wait for done.
// See model/golden.py for where M1 and the ROM contents come from.

module tensor_core #(
    parameter N_IN    = 196,
    parameter N_HID   = 32,
    parameter N_OUT   = 10,
    parameter ACC_W   = 24,           // worst case |acc1| = 196*127*128 < 2^23
    parameter SHIFT   = 24,
    parameter M1      = 31942,        // round(S1 / SH * 2^SHIFT)
    parameter W1_FILE = "rom/w1.hex",
    parameter B1_FILE = "rom/b1q.hex",
    parameter W2_FILE = "rom/w2.hex",
    parameter B2_FILE = "rom/b2q.hex"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        img_we,
    input  wire [7:0]  img_addr,
    input  wire [7:0]  img_data,
    input  wire        start,
    output reg         busy,
    output reg         done,          // one-clock pulse
    output reg  [3:0]  digit,
    output reg  [15:0] cycles         // clocks from start to done
);
    // ---------------------------------------------------------- memories
    reg [8*N_HID-1:0] w1_rom [0:N_IN-1];    // word i = W1[0..31][i]
    reg [31:0]        b1_rom [0:N_HID-1];
    reg [8*N_OUT-1:0] w2_rom [0:N_HID-1];   // word j = W2[0..9][j]
    reg [31:0]        b2_rom [0:N_OUT-1];
    reg [7:0]         img    [0:N_IN-1];

    initial begin
        $readmemh(W1_FILE, w1_rom);
        $readmemh(B1_FILE, b1_rom);
        $readmemh(W2_FILE, w2_rom);
        $readmemh(B2_FILE, b2_rom);
    end

    always @(posedge clk)
        if (img_we) img[img_addr] <= img_data;

    // ---------------------------------------------------------- control
    localparam S_IDLE = 3'd0, S_L1 = 3'd1, S_L1W = 3'd2, S_REQ = 3'd3,
               S_L2   = 3'd4, S_L2W = 3'd5, S_ARG = 3'd6, S_DONE = 3'd7;

    reg [2:0]  state;
    reg [7:0]  idx;            // pixel, neuron or digit index, by state
    reg [15:0] cnt;

    // Synchronous ROM/RAM reads: address this clock, data next clock.
    reg [8*N_HID-1:0] w1_q;
    reg [8*N_OUT-1:0] w2_q;
    reg [7:0]         x_q, h_q;
    reg               l1_v, l1_first, l2_v, l2_first;
    reg [8*N_HID-1:0] h_all;   // int8 hidden activations, neuron j in byte j
    reg [7:0]         h_sel;   // h_all byte idx (selector below)

    always @(posedge clk) begin
        w1_q     <= w1_rom[idx];
        x_q      <= img[idx];
        w2_q     <= w2_rom[idx[4:0]];
        h_q      <= h_sel;
        l1_v     <= (state == S_L1);
        l1_first <= (state == S_L1) && (idx == 0);
        l2_v     <= (state == S_L2);
        l2_first <= (state == S_L2) && (idx == 0);
    end

    // ---------------------------------------------------------- MAC lanes
    wire [ACC_W*N_HID-1:0] acc1_all;
    wire [ACC_W*N_OUT-1:0] acc2_all;

    genvar g;
    generate
        for (g = 0; g < N_HID; g = g + 1) begin : l1
            mac_lane #(.ACC_W(ACC_W)) u (
                .clk(clk), .en(l1_v), .first(l1_first),
                .w(w1_q[8*g +: 8]), .x(x_q[6:0]),
                .acc(acc1_all[ACC_W*g +: ACC_W])
            );
        end
        for (g = 0; g < N_OUT; g = g + 1) begin : l2
            mac_lane #(.ACC_W(ACC_W)) u (
                .clk(clk), .en(l2_v), .first(l2_first),
                .w(w2_q[8*g +: 8]), .x(h_q[6:0]),
                .acc(acc2_all[ACC_W*g +: ACC_W])
            );
        end
    endgenerate

    // ---------------------------------------------------------- selectors
    // Plain multiplexers indexed by idx. Writing these as acc1_all[24*idx +: 24]
    // looks the same in simulation but synthesizes into wide barrel shifters,
    // because 24 isn't a power of two.
    reg signed [ACC_W-1:0] acc1_sel, acc2_sel;
    integer k;
    always @* begin
        acc1_sel = {ACC_W{1'b0}};
        acc2_sel = {ACC_W{1'b0}};
        h_sel    = 8'd0;
        for (k = 0; k < N_HID; k = k + 1)
            if (idx[4:0] == k) begin
                acc1_sel = acc1_all[ACC_W*k +: ACC_W];
                h_sel    = h_all[8*k +: 8];
            end
        for (k = 0; k < N_OUT; k = k + 1)
            if (idx[3:0] == k) acc2_sel = acc2_all[ACC_W*k +: ACC_W];
    end

    // ---------------------------------------------------------- requantize
    // h = clamp((acc1 * M1 + B1q + 2^(SHIFT-1)) >>> SHIFT, 0, 127)
    // Negative results clamp to 0, which is the ReLU.
    //
    // Three pipeline stages: select, multiply, add/shift/clamp/write. In one
    // clock this path limited the whole design to 33-37 MHz. The pipeline
    // adds no clocks: layer 2 reads activation j about 30 clocks after
    // it is written.
    //
    // Widths are sized to the math, not to 64 bits: a 64-bit expression
    // here made synthesis build a 64x64 multiplier.
    localparam [16:0]        M1_V  = M1;
    localparam signed [41:0] ROUND = 42'sd1 <<< (SHIFT - 1);

    reg signed [ACC_W-1:0] rq_acc;
    reg signed [31:0]      rq_b1, rq_b2;
    reg signed [40:0]      rq_mul;              // 24b x 17b
    reg [4:0]              rq_j1, rq_j2;
    reg                    rq_v1, rq_v2;

    wire signed [41:0] req_sum = rq_mul + rq_b2 + ROUND;
    wire signed [41:0] req_shr = req_sum >>> SHIFT;
    wire [7:0]         h_val   = req_shr[41]      ? 8'd0   :
                                 (req_shr > 127)  ? 8'd127 : req_shr[7:0];

    always @(posedge clk) begin
        // stage 1: select neuron idx
        rq_v1  <= (state == S_REQ);
        rq_acc <= acc1_sel;
        rq_b1  <= b1_rom[idx[4:0]];
        rq_j1  <= idx[4:0];
        // stage 2: multiply
        rq_v2  <= rq_v1;
        rq_mul <= rq_acc * $signed(M1_V);
        rq_b2  <= rq_b1;
        rq_j2  <= rq_j1;
        // stage 3: add bias, round, shift, clamp, store
        if (rq_v2)
            for (k = 0; k < N_HID; k = k + 1)
                if (rq_j2 == k) h_all[8*k +: 8] <= h_val;
    end

    // ---------------------------------------------------------- argmax
    wire signed [31:0]      logit    = acc2_sel + $signed(b2_rom[idx[3:0]]);
    reg  signed [31:0]      best;
    reg  [3:0]              best_k;

    // ---------------------------------------------------------- FSM
    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state <= S_IDLE;
            busy  <= 1'b0;
            idx   <= 8'd0;
        end else begin
            if (state != S_IDLE) cnt <= cnt + 16'd1;
            case (state)
                S_IDLE: if (start) begin
                    state <= S_L1;  idx <= 8'd0;  busy <= 1'b1;  cnt <= 16'd1;
                end
                S_L1: begin                         // issue pixel idx
                    if (idx == N_IN - 1) begin state <= S_L1W; idx <= 8'd0; end
                    else idx <= idx + 8'd1;
                end
                S_L1W: state <= S_REQ;              // last MAC lands
                S_REQ: begin                        // start requantizing neuron idx
                    if (idx == N_HID - 1) begin state <= S_L2; idx <= 8'd0; end
                    else idx <= idx + 8'd1;
                end
                S_L2: begin                         // issue hidden value idx
                    if (idx == N_HID - 1) begin state <= S_L2W; idx <= 8'd0; end
                    else idx <= idx + 8'd1;
                end
                S_L2W: state <= S_ARG;
                S_ARG: begin                        // compare digit idx
                    if (idx == 0 || logit > best) begin
                        best   <= logit;
                        best_k <= idx[3:0];
                    end
                    if (idx == N_OUT - 1) state <= S_DONE;
                    else idx <= idx + 8'd1;
                end
                S_DONE: begin
                    digit  <= best_k;
                    cycles <= cnt;
                    done   <= 1'b1;
                    busy   <= 1'b0;
                    state  <= S_IDLE;
                    idx    <= 8'd0;
                end
            endcase
        end
    end
endmodule
