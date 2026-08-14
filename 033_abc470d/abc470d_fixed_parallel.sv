`timescale 1ns/1ps

// ABC470D - Inverse and Swap
// Ideal-FPGA fixed-width, in-order prefix parallel implementation.
module abc470d_fixed_parallel #(
    parameter integer K = 4
);
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

    // Positions tagged with the current group_stamp are already occupied by
    // an earlier lane in this clock's in-order prefix.
    integer used_stamp [1:MAX_N];
    integer group_stamp;

    reg clk;
    reg inverted;
    reg [1:0] phase;
    integer query_index;
    integer logical_clock;
    integer query_clock;

    integer i;
    integer lane;
    integer group_size;
    integer scan_active;
    integer scan_result;
    integer input_value;
    integer input_x;
    integer input_y;
    integer swap_a;
    integer swap_b;

    // TIME=0 input load. No logical clock is counted until all input has been
    // retained in the internal query arrays.
    initial begin
        clk = 1'b0;
        inverted = 1'b0;
        phase = PHASE_BUILD_INVERSE;
        query_index = 0;
        logical_clock = 0;
        query_clock = 0;
        group_stamp = 0;

        if ((K < 1) || (K > MAX_Q)) begin
            $fdisplay(32'h80000002, "ERROR: K is out of range");
            $finish(1);
        end

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

        forever #1 clk = ~clk;
    end

    always @(posedge clk) begin
        logical_clock = logical_clock + 1;

        case (phase)
            PHASE_BUILD_INVERSE: begin
                // Both loops represent independent one-clock register writes.
                for (i = 1; i <= n; i = i + 1) begin
                    pinv[p[i]] = i;
                    used_stamp[i] = 0;
                end
                phase <= PHASE_QUERY;
            end

            PHASE_QUERY: begin
                query_clock = query_clock + 1;

                if (query_type[query_index] == 2'd2) begin
                    // Type 2 is always a single-clock ordering boundary.
                    inverted <= ~inverted;
                    if (query_index == q - 1) begin
                        phase <= PHASE_ANSWER;
                    end else begin
                        query_index <= query_index + 1;
                    end
                end else begin
                    // Build only the conflict-free consecutive prefix. The
                    // loop condition stops inspection immediately at the first
                    // conflict, Type 2, input end, or K accepted queries.
                    group_stamp = group_stamp + 1;
                    group_size = 0;
                    scan_active = 1;
                    for (
                        lane = 0;
                        (lane < K) && (scan_active != 0);
                        lane = lane + 1
                    ) begin
                        if (query_index + lane >= q) begin
                            scan_active = 0;
                        end else if (
                            query_type[query_index + lane] != 2'd1
                        ) begin
                            scan_active = 0;
                        end else if (
                            (used_stamp[query_x[query_index + lane]] == group_stamp) ||
                            (used_stamp[query_y[query_index + lane]] == group_stamp)
                        ) begin
                            scan_active = 0;
                        end else begin
                            used_stamp[query_x[query_index + lane]] = group_stamp;
                            used_stamp[query_y[query_index + lane]] = group_stamp;
                            group_size = group_size + 1;
                        end
                    end

                    // group_size is at least one because this branch starts on
                    // a valid Type 1 query whose x and y differ.
                    for (lane = 0; lane < group_size; lane = lane + 1) begin
                        if (!inverted) begin
                            swap_a = p[query_x[query_index + lane]];
                            swap_b = p[query_y[query_index + lane]];

                            p[query_x[query_index + lane]] <= swap_b;
                            p[query_y[query_index + lane]] <= swap_a;
                            pinv[swap_a] <= query_y[query_index + lane];
                            pinv[swap_b] <= query_x[query_index + lane];
                        end else begin
                            swap_a = pinv[query_x[query_index + lane]];
                            swap_b = pinv[query_y[query_index + lane]];

                            pinv[query_x[query_index + lane]] <= swap_b;
                            pinv[query_y[query_index + lane]] <= swap_a;
                            p[swap_a] <= query_y[query_index + lane];
                            p[swap_b] <= query_x[query_index + lane];
                        end
                    end

                    if (query_index + group_size >= q) begin
                        phase <= PHASE_ANSWER;
                    end else begin
                        query_index <= query_index + group_size;
                    end
                end
            end

            PHASE_ANSWER: begin
                for (i = 1; i <= n; i = i + 1) begin
                    answer[i] = inverted ? pinv[i] : p[i];
                end

                // No time advance or additional logical clock after answer[].
                for (i = 1; i <= n; i = i + 1) begin
                    if (i > 1) begin
                        $write(" ");
                    end
                    $write("%0d", answer[i]);
                end
                $write("\n");
                $fdisplay(
                    32'h80000002,
                    "LOGICAL_CLOCKS=%0d QUERY_CLOCKS=%0d K=%0d SIM_TIME=%0t",
                    logical_clock,
                    query_clock,
                    K,
                    $time
                );
                $finish(0);
            end

            default: begin
                $fdisplay(32'h80000002, "ERROR: invalid phase");
                $finish(1);
            end
        endcase
    end
endmodule
