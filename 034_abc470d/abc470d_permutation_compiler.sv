`timescale 1ns/1ps

// ABC470D - Inverse and Swap
// Compile the complete query stream into U/V permutations at TIME=0, then
// materialize the composed transformation into answer[] in one logical clock.
module abc470d_permutation_compiler;
    localparam integer MAX_N = 500000;
    localparam integer MAX_Q = 500000;

    integer n;
    integer q;

    integer p      [1:MAX_N];
    integer answer [1:MAX_N];
    integer u      [1:MAX_N];
    integer uinv   [1:MAX_N];
    integer v      [1:MAX_N];
    integer vinv   [1:MAX_N];

    reg clk;
    reg inverted;
    reg materialized;

    integer logical_clock;
    integer type1_count;
    integer type2_count;

    integer i;
    integer k;
    integer scan_result;
    integer input_value;
    integer input_type;
    integer input_x;
    integer input_y;
    integer a;
    integer b;
    integer px;
    integer py;

    initial begin
        clk = 1'b0;
        inverted = 1'b0;
        materialized = 1'b0;
        logical_clock = 0;
        type1_count = 0;
        type2_count = 0;

        scan_result = $fscanf(32'h80000000, "%d %d", n, q);
        if (scan_result != 2) begin
            $fdisplay(32'h80000002, "ERROR: failed to read N and Q");
            $finish(1);
        end
        if ((n < 2) || (n > MAX_N) || (q < 1) || (q > MAX_Q)) begin
            $fdisplay(32'h80000002, "ERROR: N or Q is out of range");
            $finish(1);
        end

        for (i = 1; i <= n; i = i + 1) begin
            scan_result = $fscanf(32'h80000000, "%d", input_value);
            if (scan_result != 1) begin
                $fdisplay(32'h80000002, "ERROR: failed to read P[%0d]", i);
                $finish(1);
            end
            p[i] = input_value;
            u[i] = i;
            uinv[i] = i;
            v[i] = i;
            vinv[i] = i;
        end

        // Query compilation is deliberately a TIME=0 host computation in
        // this ideal-FPGA model. No raw query array is retained.
        for (i = 0; i < q; i = i + 1) begin
            scan_result = $fscanf(32'h80000000, "%d", input_type);
            if (scan_result != 1) begin
                $fdisplay(32'h80000002, "ERROR: failed to read query %0d", i + 1);
                $finish(1);
            end

            if (input_type == 1) begin
                scan_result = $fscanf(
                    32'h80000000,
                    "%d %d",
                    input_x,
                    input_y
                );
                if (scan_result != 2) begin
                    $fdisplay(
                        32'h80000002,
                        "ERROR: failed to read arguments of query %0d",
                        i + 1
                    );
                    $finish(1);
                end
                if (
                    (input_x < 1) || (input_x > n) ||
                    (input_y < 1) || (input_y > n)
                ) begin
                    $fdisplay(32'h80000002, "ERROR: query position is out of range");
                    $finish(1);
                end

                type1_count = type1_count + 1;
                if (inverted == 1'b0) begin
                    // V <- V o T(x,y): exchange the two input slots.
                    a = v[input_x];
                    b = v[input_y];
                    v[input_x] = b;
                    v[input_y] = a;
                    vinv[a] = input_y;
                    vinv[b] = input_x;
                end else begin
                    // U <- T(x,y) o U: exchange the two output labels.
                    px = uinv[input_x];
                    py = uinv[input_y];
                    u[px] = input_y;
                    u[py] = input_x;
                    uinv[input_x] = py;
                    uinv[input_y] = px;
                end
            end else if (input_type == 2) begin
                type2_count = type2_count + 1;
                inverted = ~inverted;
            end else begin
                $fdisplay(32'h80000002, "ERROR: invalid query type");
                $finish(1);
            end
        end

        forever #1 clk = ~clk;
    end

    // The only logical clock: apply the already compiled transformation.
    always @(posedge clk) begin
        if (materialized == 1'b0) begin
            logical_clock = logical_clock + 1;
            if (inverted == 1'b0) begin
                for (i = 1; i <= n; i = i + 1) begin
                    answer[i] <= u[p[v[i]]];
                end
            end else begin
                // Pinv-free scatter. U o P is a permutation, so every target
                // answer index is distinct in this clock.
                for (k = 1; k <= n; k = k + 1) begin
                    answer[u[p[k]]] <= vinv[k];
                end
            end
            materialized <= 1'b1;
        end
    end

    // Observe the committed nonblocking writes without adding another
    // positive-edge logical clock.
    always @(negedge clk) begin
        if (materialized != 1'b0) begin
            for (i = 1; i <= n; i = i + 1) begin
                if (i > 1) begin
                    $write(" ");
                end
                $write("%0d", answer[i]);
            end
            $write("\n");
            $fdisplay(
                32'h80000002,
                {"LOGICAL_CLOCKS=%0d TYPE1_COUNT=%0d TYPE2_COUNT=%0d ",
                 "FINAL_INVERTED=%0d SIM_TIME=%0t"},
                logical_clock,
                type1_count,
                type2_count,
                inverted,
                $time
            );
            $finish(0);
        end
    end
endmodule

