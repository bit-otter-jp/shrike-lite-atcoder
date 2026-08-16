`timescale 1ns/1ps

// ABC470D - Inverse and Swap
// Ideal-FPGA baseline: inverse construction, one query per clock, answer latch.
module abc470d_baseline;
    localparam integer MAX_N = 500000;
    localparam integer MAX_Q = 500000;

    localparam [1:0] PHASE_BUILD_INVERSE = 2'd0;
    localparam [1:0] PHASE_QUERY         = 2'd1;
    localparam [1:0] PHASE_ANSWER        = 2'd2;

    integer n;
    integer q;

    // p and pinv are always inverse permutations of one another.
    integer p      [1:MAX_N];
    integer pinv   [1:MAX_N];
    integer answer [1:MAX_N];

    reg [1:0] query_type [0:MAX_Q-1];
    integer query_x      [0:MAX_Q-1];
    integer query_y      [0:MAX_Q-1];

    reg clk;
    reg inverted;
    reg [1:0] phase;
    integer query_index;
    integer logical_clock;

    integer i;
    integer scan_result;
    integer input_value;
    integer input_x;
    integer input_y;
    integer swap_a;
    integer swap_b;

    // TIME=0 input load. Wall-clock time spent here is intentionally not a
    // logical clock in the ideal-FPGA model.
    initial begin
        clk = 1'b0;
        inverted = 1'b0;
        phase = PHASE_BUILD_INVERSE;
        query_index = 0;
        logical_clock = 0;

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
        end

        for (i = 0; i < q; i = i + 1) begin
            scan_result = $fscanf(32'h80000000, "%d", input_value);
            if (scan_result != 1) begin
                $fdisplay(32'h80000002, "ERROR: failed to read query %0d", i + 1);
                $finish(1);
            end
            query_type[i] = input_value[1:0];

            if (query_type[i] == 2'd1) begin
                scan_result = $fscanf(
                    32'h80000000, "%d %d", input_x, input_y
                );
                if (scan_result != 2) begin
                    $fdisplay(
                        32'h80000002,
                        "ERROR: failed to read arguments of query %0d",
                        i + 1
                    );
                    $finish(1);
                end
                query_x[i] = input_x;
                query_y[i] = input_y;
            end else if (query_type[i] == 2'd2) begin
                query_x[i] = 0;
                query_y[i] = 0;
            end else begin
                $fdisplay(32'h80000002, "ERROR: invalid query type");
                $finish(1);
            end
        end

        // Start clocking only after all input has been loaded at TIME=0.
        forever #1 clk = ~clk;
    end

    always @(posedge clk) begin
        // Blocking assignment makes the diagnostic below report this edge.
        logical_clock = logical_clock + 1;

        case (phase)
            PHASE_BUILD_INVERSE: begin
                // p is a permutation, so all destinations pinv[p[i]] differ.
                // The procedural loop models N independent writes in one
                // ideal-FPGA clock; its Icarus wall time is measured separately.
                for (i = 1; i <= n; i = i + 1) begin
                    pinv[p[i]] = i;
                end
                phase <= PHASE_QUERY;
            end

            PHASE_QUERY: begin
                if (query_type[query_index] == 2'd1) begin
                    if (!inverted) begin
                        swap_a = p[query_x[query_index]];
                        swap_b = p[query_y[query_index]];

                        p[query_x[query_index]] <= swap_b;
                        p[query_y[query_index]] <= swap_a;
                        pinv[swap_a] <= query_y[query_index];
                        pinv[swap_b] <= query_x[query_index];
                    end else begin
                        swap_a = pinv[query_x[query_index]];
                        swap_b = pinv[query_y[query_index]];

                        pinv[query_x[query_index]] <= swap_b;
                        pinv[query_y[query_index]] <= swap_a;
                        p[swap_a] <= query_y[query_index];
                        p[swap_b] <= query_x[query_index];
                    end
                end else begin
                    inverted <= ~inverted;
                end

                if (query_index == q - 1) begin
                    phase <= PHASE_ANSWER;
                end else begin
                    query_index <= query_index + 1;
                end
            end

            PHASE_ANSWER: begin
                // Latch all answer registers in the final logical clock.
                for (i = 1; i <= n; i = i + 1) begin
                    answer[i] = inverted ? pinv[i] : p[i];
                end

                // Output adds no delay and waits for no further clock.
                for (i = 1; i <= n; i = i + 1) begin
                    if (i > 1) begin
                        $write(" ");
                    end
                    $write("%0d", answer[i]);
                end
                $write("\n");
                $fdisplay(
                    32'h80000002,
                    "LOGICAL_CLOCKS=%0d EXPECTED=%0d SIM_TIME=%0t",
                    logical_clock,
                    q + 2,
                    $time
                );
                // Diagnostic level 0 keeps judged stdout free of Icarus'
                // "$finish called" message.
                $finish(0);
            end

            default: begin
                $fdisplay(32'h80000002, "ERROR: invalid phase");
                $finish(1);
            end
        endcase
    end
endmodule
