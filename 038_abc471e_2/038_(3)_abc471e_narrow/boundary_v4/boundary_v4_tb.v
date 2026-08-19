`timescale 1ns/1ps

`ifndef TEST_WIDTH
`define TEST_WIDTH 8
`endif
`ifndef TEST_MOD
`define TEST_MOD 251
`endif
`ifndef TEST_N_MAX
`define TEST_N_MAX 250
`endif
`ifndef TEST_VALUE_BYTES
`define TEST_VALUE_BYTES ((`TEST_WIDTH + 7) / 8)
`endif

module compact_v3_tb #(
    parameter integer WIDTH = `TEST_WIDTH,
    parameter [WIDTH-1:0] MOD = `TEST_MOD,
    parameter [WIDTH-1:0] N_MAX = `TEST_N_MAX,
    parameter integer VALUE_BYTES = `TEST_VALUE_BYTES
);

    localparam [31:0] MOD32 = {{(32-WIDTH){1'b0}}, MOD};
    localparam [31:0] N_MAX32 = {{(32-WIDTH){1'b0}}, N_MAX};
    localparam integer EXPECTED_COUNT_WIDTH =
        (N_MAX <= 1) ? 1 : $clog2(N_MAX + 1'b1);
`ifdef BOUNDARY_SHORT
    localparam integer RANDOM_CASE_COUNT = 4;
`else
    localparam integer RANDOM_CASE_COUNT = 24;
`endif
    localparam [7:0] CMD_NOP   = 8'h00;
    localparam [7:0] CMD_START = 8'hFE;
    localparam [7:0] CMD_RESET = 8'hFF;

    reg clk;
    reg rst_n;
    reg spi_ss_n;
    reg spi_sck;
    reg spi_mosi;
    wire spi_miso;
    wire spi_miso_en;
    wire clk_en;

    reg perf_clear;
    reg perf_start;
    reg [WIDTH-1:0] perf_lhs;
    reg [WIDTH-1:0] perf_rhs;
    wire perf_busy;
    wire perf_done;
    wire [WIDTH-1:0] perf_product;

    reg [31:0] test_a [0:15];
    integer test_total;
    integer test_pass;
    integer random_seed;
    integer clock_count;
    integer ai_start_cycle;
    integer ai_min_cycles;
    integer ai_max_cycles;
    integer ai_samples;
    reg previous_x_busy;

    reg capture_perf;
    reg previous_reply_valid;
    integer perf_comb_start;
    integer perf_pow_start;
    integer perf_final_start;
    integer perf_reply_cycle;
    integer measured_comb_clocks;
    integer measured_pow_clocks;
    integer measured_final_clocks;
    integer estimated_nmax_clocks;
    integer estimated_comb_clocks;
    integer worst_r;
    integer comb_per_iteration;

    main #(
        .WIDTH(WIDTH),
        .MOD(MOD),
        .N_MAX(N_MAX),
        .VALUE_BYTES(VALUE_BYTES)
    ) dut (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .spi_ss_n(spi_ss_n),
        .spi_sck(spi_sck),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .spi_miso_en(spi_miso_en)
    );

    // Testbench-only instance for an unambiguous multiplier latency measure.
    modular_multiplier #(
        .WIDTH(WIDTH),
        .MOD(MOD)
    ) perf_multiplier (
        .i_clk(clk),
        .i_rst_n(rst_n),
        .i_clear(perf_clear),
        .i_start(perf_start),
        .i_lhs(perf_lhs),
        .i_rhs(perf_rhs),
        .o_busy(perf_busy),
        .o_done(perf_done),
        .o_product(perf_product)
    );

    always #10 clk = ~clk; // 50 MHz system clock; SPI stimulus is 4 MHz.

    always @(posedge clk) begin
        clock_count = clock_count + 1;
        #1;
        if (!previous_x_busy && dut.x_busy)
            ai_start_cycle = clock_count;
        if (previous_x_busy && !dut.x_busy) begin
            if ((clock_count - ai_start_cycle) < ai_min_cycles)
                ai_min_cycles = clock_count - ai_start_cycle;
            if ((clock_count - ai_start_cycle) > ai_max_cycles)
                ai_max_cycles = clock_count - ai_start_cycle;
            ai_samples = ai_samples + 1;
        end
        previous_x_busy = dut.x_busy;

        if (capture_perf) begin
            if (dut.arith_state == dut.A_COMB_CHECK &&
                perf_comb_start < 0)
                perf_comb_start = clock_count;
            if (dut.arith_state == dut.A_POW_CHECK &&
                perf_pow_start < 0)
                perf_pow_start = clock_count;
            if (dut.arith_state == dut.A_LAUNCH &&
                dut.mul_context == dut.M_FINAL_S1 &&
                perf_final_start < 0)
                perf_final_start = clock_count;
            if (!previous_reply_valid && dut.reply_valid &&
                perf_reply_cycle < 0)
                perf_reply_cycle = clock_count;
        end
        previous_reply_valid = dut.reply_valid;
    end

    task automatic spi_begin;
        begin
            spi_sck  = 1'b0;
            spi_ss_n = 1'b0;
            #100;
        end
    endtask

    task automatic spi_transfer_selected;
        input [7:0] tx;
        output [7:0] rx;
        integer bit_index;
        begin
            rx = 8'h00;
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                spi_mosi = tx[bit_index];
                #125;
                spi_sck = 1'b1;
                #50;
                rx[bit_index] = spi_miso;
                #75;
                spi_sck = 1'b0;
            end
        end
    endtask

    task automatic spi_end;
        begin
            #125;
            spi_ss_n = 1'b1;
            spi_mosi = 1'b0;
            #100;
        end
    endtask

    task automatic spi_exchange;
        input [7:0] tx;
        output [7:0] rx;
        begin
            spi_begin();
            spi_transfer_selected(tx, rx);
            spi_end();
        end
    endtask

    task automatic send_value;
        input [31:0] value;
        integer byte_index;
        reg [7:0] ignored;
        begin
            spi_begin();
            for (byte_index = VALUE_BYTES - 1;
                 byte_index >= 0; byte_index = byte_index - 1)
                spi_transfer_selected(value >> (byte_index * 8), ignored);
            spi_end();
        end
    endtask

    task automatic send_a_stream;
        input integer n;
        integer value_index;
        integer byte_index;
        reg [7:0] ignored;
        begin
            // All values use one CS-low burst; CS is not an element delimiter.
            spi_begin();
            for (value_index = 0; value_index < n;
                 value_index = value_index + 1) begin
                for (byte_index = VALUE_BYTES - 1;
                     byte_index >= 0; byte_index = byte_index - 1)
                    spi_transfer_selected(
                        test_a[value_index] >> (byte_index * 8), ignored);
            end
            spi_end();
        end
    endtask

    task automatic send_repeated_a;
        input integer n;
        input [31:0] value;
        integer value_index;
        integer byte_index;
        reg [7:0] ignored;
        begin
            spi_begin();
            for (value_index = 0; value_index < n;
                 value_index = value_index + 1) begin
                for (byte_index = VALUE_BYTES - 1;
                     byte_index >= 0; byte_index = byte_index - 1)
                    spi_transfer_selected(
                        value >> (byte_index * 8), ignored);
            end
            spi_end();
        end
    endtask

    task automatic begin_request;
        output reg ok;
        reg [7:0] rx;
        begin
            ok = 1'b1;
            spi_exchange(CMD_RESET, rx);
            spi_exchange(CMD_NOP, rx);
            if (rx !== 8'h5A) begin
                $display("FAIL RESET_ACK got=%02x", rx);
                ok = 1'b0;
            end
            spi_exchange(CMD_START, rx);
            spi_exchange(CMD_NOP, rx);
            if (rx !== 8'hA5) begin
                $display("FAIL START_ACK got=%02x", rx);
                ok = 1'b0;
            end
        end
    endtask

    task automatic poll_and_read;
        output reg [7:0] status;
        output reg [31:0] result;
        output reg ok;
        integer polls;
        integer byte_index;
        reg [7:0] rx;
        begin
            status = 8'h00;
            result = 32'd0;
            ok = 1'b1;
            polls = 0;
            while (!status[7] && polls < 2000000) begin
                spi_exchange(CMD_NOP, status);
                polls = polls + 1;
            end
            if (!status[7]) begin
                $display("FAIL status timeout");
                ok = 1'b0;
            end else begin
                spi_begin();
                for (byte_index = 0; byte_index < VALUE_BYTES;
                     byte_index = byte_index + 1) begin
                    spi_transfer_selected(CMD_NOP, rx);
                    result = (result << 8) | rx;
                end
                spi_end();
            end
        end
    endtask

    task automatic brute_force_expected;
        input integer n;
        input integer k;
        output reg [31:0] expected;
        integer mask;
        integer index;
        integer selected;
        reg [63:0] sum_mod;
        reg [63:0] total;
        begin
            total = 64'd0;
            for (mask = 0; mask < (1 << n); mask = mask + 1) begin
                selected = 0;
                sum_mod = 64'd0;
                for (index = 0; index < n; index = index + 1) begin
                    if (mask & (1 << index)) begin
                        selected = selected + 1;
                        sum_mod = (sum_mod + test_a[index]) % MOD32;
                    end
                end
                if (selected == k)
                    total = (total + ((sum_mod * sum_mod) % MOD32)) % MOD32;
            end
            expected = total[31:0];
        end
    endtask

    task automatic record_result;
        input string name;
        input reg passed;
        begin
            test_total = test_total + 1;
            if (passed) begin
                test_pass = test_pass + 1;
                $display("PASS %0s", name);
            end else begin
                $display("FAIL %0s", name);
            end
        end
    endtask

    task automatic run_case;
        input string name;
        input integer n;
        input integer k;
        input reg check_busy_status;
        reg session_ok;
        reg reply_ok;
        reg [7:0] status;
        reg [7:0] busy_status;
        reg [31:0] result;
        reg [31:0] expected;
        reg passed;
        begin
            brute_force_expected(n, k, expected);
            begin_request(session_ok);
            send_value(n);
            send_value(k);
            send_a_stream(n);
            busy_status = 8'h00;
            if (check_busy_status)
                spi_exchange(CMD_NOP, busy_status);
            poll_and_read(status, result, reply_ok);
            passed = session_ok && reply_ok && (status == 8'h80) &&
                     (result == expected) &&
                     (!check_busy_status || busy_status == 8'h00) &&
                     (!dut.value_phase) &&
                     (dut.proto_state == dut.P_WAIT_RESULT);
            if (!passed)
                $display("  n=%0d k=%0d busy=%02x status=%02x result=%0d expected=%0d proto=%0d",
                         n, k, busy_status, status, result, expected,
                         dut.proto_state);
            record_result(name, passed);
        end
    endtask

    task automatic run_error_n;
        input string name;
        input [31:0] n_value;
        reg ok;
        reg reply_ok;
        reg [7:0] status;
        reg [31:0] result;
        begin
            begin_request(ok);
            send_value(n_value);
            poll_and_read(status, result, reply_ok);
            ok = ok && reply_ok && status == 8'hC0 && result == 0 &&
                 dut.protocol_error;
            record_result(name, ok);
        end
    endtask

    task automatic run_error_k;
        input string name;
        input [31:0] n_value;
        input [31:0] k_value;
        reg ok;
        reg reply_ok;
        reg [7:0] status;
        reg [31:0] result;
        begin
            begin_request(ok);
            send_value(n_value);
            send_value(k_value);
            poll_and_read(status, result, reply_ok);
            ok = ok && reply_ok && status == 8'hC0 && result == 0 &&
                 dut.protocol_error;
            record_result(name, ok);
        end
    endtask

    task automatic run_error_ai;
        input string name;
        input [31:0] a_value;
        reg ok;
        reg reply_ok;
        reg [7:0] status;
        reg [31:0] result;
        begin
            begin_request(ok);
            send_value(1);
            send_value(1);
            send_value(a_value);
            poll_and_read(status, result, reply_ok);
            ok = ok && reply_ok && status == 8'hC0 && result == 0 &&
                 dut.protocol_error;
            record_result(name, ok);
        end
    endtask

    task automatic test_sticky_and_reset;
        reg ok;
        reg reply_ok;
        reg [7:0] status;
        reg [7:0] repeated_status;
        reg [31:0] result;
        begin
            begin_request(ok);
            send_value(0);
            poll_and_read(status, result, reply_ok);
            spi_exchange(CMD_NOP, repeated_status);
            ok = ok && reply_ok && status == 8'hC0 && result == 0 &&
                 repeated_status == 8'hC0 && dut.protocol_error;

            spi_exchange(CMD_RESET, repeated_status);
            spi_exchange(CMD_NOP, repeated_status);
            ok = ok && repeated_status == 8'h5A &&
                 !dut.protocol_error &&
                 dut.proto_state == dut.P_WAIT_START;
            record_result("sticky_error_and_reset_recovery", ok);
        end
    endtask

    task automatic test_extra_payload;
        reg ok;
        reg reply_ok;
        reg [7:0] ignored;
        reg [7:0] status;
        reg [31:0] result;
        begin
            test_a[0] = 7;
            begin_request(ok);
            send_value(1);
            send_value(1);
            send_a_stream(1);
            spi_exchange(8'h12, ignored);
            poll_and_read(status, result, reply_ok);
            ok = ok && reply_ok && status == 8'hC0 &&
                 dut.protocol_error;
            record_result("extra_payload_after_n_values", ok);
        end
    endtask

    task automatic test_nmax_valid;
        reg ok;
        reg reply_ok;
        reg [7:0] status;
        reg [31:0] result;
        begin
            begin_request(ok);
            send_value(N_MAX32);
            send_value(1);
            send_repeated_a(N_MAX32, 0);
            poll_and_read(status, result, reply_ok);
            ok = ok && reply_ok && status == 8'h80 && result == 0 &&
                 dut.n_reg == N_MAX &&
                 $bits(dut.n_reg) == EXPECTED_COUNT_WIDTH;
            record_result("n_equals_nmax", ok);
        end
    endtask

    task automatic test_reserved_payload_bytes;
        integer index;
        reg all_ok;
        reg ok;
        reg reply_ok;
        reg [7:0] status;
        reg [31:0] result;
        reg [31:0] expected;
        begin
            all_ok = 1'b1;
            if (MOD32 > 255) begin
                for (index = 0; index < 3; index = index + 1) begin
                    test_a[0] = 32'hFD + index;
                    brute_force_expected(1, 1, expected);
                    begin_request(ok);
                    send_value(1);
                    send_value(1);
                    send_value(test_a[0]);
                    poll_and_read(status, result, reply_ok);
                    all_ok = all_ok && ok && reply_ok &&
                             status == 8'h80 && result == expected &&
                             !dut.protocol_error;
                end
            end else begin
                for (index = 0; index < 3; index = index + 1) begin
                    begin_request(ok);
                    send_value(1);
                    send_value(1);
                    send_value(32'hFD + index);
                    poll_and_read(status, result, reply_ok);
                    all_ok = all_ok && ok && reply_ok &&
                             status == 8'hC0 && result == 0 &&
                             dut.protocol_error;
                end
            end
            record_result("fd_fe_ff_are_payload_not_commands", all_ok);
        end
    endtask

    task automatic measure_multiplier;
        reg [63:0] expected;
        integer cycles;
        reg ok;
        begin
            perf_lhs = MOD32 - 2;
            perf_rhs = MOD32 - 3;
            expected = ((MOD32 - 2) * (MOD32 - 3)) % MOD32;
            @(negedge clk);
            perf_start = 1'b1;
            @(posedge clk);
            #1;
            perf_start = 1'b0;
            cycles = 0;
            while (!perf_done && cycles < 100) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end
            ok = perf_done && cycles == (2 * WIDTH) &&
                 perf_product == expected[WIDTH-1:0];
            $display("PERF WIDTH=%0d VALUE_BYTES=%0d MUL_CLOCKS=%0d PRODUCT=%0d",
                     WIDTH, VALUE_BYTES, cycles, perf_product);
            record_result($sformatf("shared_multiplier_%0d_clocks",
                                    2 * WIDTH), ok);
        end
    endtask

    task automatic run_performance_case;
        reg ok;
        reg reply_ok;
        reg [7:0] status;
        reg [31:0] result;
        reg [31:0] expected;
        integer index;
        begin
            for (index = 0; index < 8; index = index + 1)
                test_a[index] = index + 1;
            brute_force_expected(8, 4, expected);
            perf_comb_start = -1;
            perf_pow_start = -1;
            perf_final_start = -1;
            perf_reply_cycle = -1;
            capture_perf = 1'b1;
            begin_request(ok);
            send_value(8);
            send_value(4);
            send_a_stream(8);
            poll_and_read(status, result, reply_ok);
            capture_perf = 1'b0;
            measured_comb_clocks = perf_pow_start - perf_comb_start;
            measured_pow_clocks = perf_final_start - perf_pow_start;
            measured_final_clocks = perf_reply_cycle - perf_final_start;
            ok = ok && reply_ok && status == 8'h80 && result == expected &&
                 perf_comb_start >= 0 && perf_pow_start > perf_comb_start &&
                 perf_final_start > perf_pow_start &&
                 perf_reply_cycle > perf_final_start;
            $display("PERF PHASE_CASE=N8K4 COMB_CLOCKS=%0d POW_CLOCKS=%0d FINAL_CLOCKS=%0d",
                     measured_comb_clocks, measured_pow_clocks,
                     measured_final_clocks);
            record_result("phase_cycle_measurement_n8_k4", ok);
        end
    endtask

    integer random_case;
    integer n_random;
    integer k_random;
    integer base_n;
    integer base_k;
    integer value_index;
    reg [31:0] random_value;

    initial begin
        clk                  = 1'b0;
        rst_n                = 1'b0;
        spi_ss_n             = 1'b1;
        spi_sck              = 1'b0;
        spi_mosi             = 1'b0;
        perf_clear           = 1'b0;
        perf_start           = 1'b0;
        perf_lhs             = 'd0;
        perf_rhs             = 'd0;
        test_total           = 0;
        test_pass            = 0;
        random_seed          = 32'h471E3003;
        clock_count          = 0;
        ai_start_cycle       = 0;
        ai_min_cycles        = 32'h7fffffff;
        ai_max_cycles        = 0;
        ai_samples           = 0;
        previous_x_busy      = 1'b0;
        capture_perf         = 1'b0;
        previous_reply_valid = 1'b0;
        perf_comb_start      = -1;
        perf_pow_start       = -1;
        perf_final_start     = -1;
        perf_reply_cycle     = -1;
        measured_comb_clocks = 0;
        measured_pow_clocks  = 0;
        measured_final_clocks = 0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (8) @(posedge clk);

        measure_multiplier();

        base_n = (N_MAX32 < 3) ? N_MAX32 : 3;
        base_k = (base_n < 2) ? 1 : 2;
        test_a[0] = 1;
        test_a[1] = 2;
        test_a[2] = 3;
        run_case("hand_small_status_and_framing",
                 base_n, base_k, 1'b1);

        test_a[0] = MOD32 / 2;
        run_case("n1_k1", 1, 1, 1'b0);

        base_n = (N_MAX32 < 4) ? N_MAX32 : 4;
        test_a[0] = 1;
        test_a[1] = 2;
        test_a[2] = 3;
        test_a[3] = 4;
        run_case("k1", base_n, 1, 1'b0);
        run_case("k_equals_n", base_n, base_n, 1'b0);

        test_a[0] = 0;
        run_case("ai_zero", 1, 1, 1'b0);
        test_a[0] = MOD32 - 1;
        run_case("ai_mod_minus_one", 1, 1, 1'b0);

        for (random_case = 0; random_case < RANDOM_CASE_COUNT;
             random_case = random_case + 1) begin
            random_value = $urandom(random_seed);
            n_random = 1 + (random_value %
                ((N_MAX32 < 8) ? N_MAX32 : 8));
            random_value = $urandom(random_seed);
            k_random = 1 + (random_value % n_random);
            for (value_index = 0; value_index < n_random;
                 value_index = value_index + 1) begin
                random_value = $urandom(random_seed);
                test_a[value_index] = random_value % MOD32;
            end
            run_case($sformatf("random_bruteforce_%0d", random_case),
                     n_random, k_random, 1'b0);
        end

        if (N_MAX32 >= 8)
            run_performance_case();
        else begin
            test_a[0] = 1;
            run_case("small_nmax_performance_substitute", 1, 1, 1'b0);
        end

        test_sticky_and_reset();
        run_error_n("n_zero", 0);
        run_error_n("n_equal_mod_above_nmax", MOD32);
        run_error_n("n_max_plus_one", N_MAX32 + 1);
        run_error_k("k_zero", 1, 0);
        run_error_k("k_greater_than_n", 1, 2);
        run_error_ai("ai_equal_mod", MOD32);
        test_extra_payload();
        test_reserved_payload_bytes();
        test_nmax_valid();

        worst_r = (N_MAX32 - 1) / 2;
        // N=8,K=4 has r=3.  The measured combination interval contains
        // one check clock plus three identical two-product iterations.
        if (N_MAX32 >= 8) begin
            comb_per_iteration = (measured_comb_clocks - 1) / 3;
            estimated_comb_clocks = 1 + worst_r * comb_per_iteration;
            estimated_nmax_clocks = N_MAX32 * ai_max_cycles +
                estimated_comb_clocks + measured_pow_clocks +
                measured_final_clocks;
        end else begin
            comb_per_iteration = 0;
            estimated_comb_clocks = 0;
            estimated_nmax_clocks = 0;
        end
        $display("PERF AI_SAMPLES=%0d AI_MIN_CLOCKS=%0d AI_MAX_CLOCKS=%0d",
                 ai_samples, ai_min_cycles, ai_max_cycles);
        $display("PERF NMAX_ESTIMATE=%0d COMB_ESTIMATE=%0d WORST_R=%0d EXCLUDES_SPI=1",
                 estimated_nmax_clocks, estimated_comb_clocks, worst_r);

        $display("SUMMARY WIDTH=%0d VALUE_BYTES=%0d TOTAL=%0d PASS=%0d FAIL=%0d",
                 WIDTH, VALUE_BYTES, test_total, test_pass,
                 test_total - test_pass);
        if (test_pass != test_total)
            $fatal(1, "boundary_v4 simulation failed");
        $finish;
    end

endmodule
