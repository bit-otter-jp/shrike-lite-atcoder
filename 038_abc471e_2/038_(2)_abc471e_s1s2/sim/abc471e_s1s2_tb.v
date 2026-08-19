`timescale 1ns/1ps

module abc471e_s1s2_tb;

    localparam [31:0] MOD = 32'd998244353;
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
    reg [29:0] perf_lhs;
    reg [29:0] perf_rhs;
    wire perf_busy;
    wire perf_done;
    wire [29:0] perf_product;

    reg [31:0] test_a [0:15];
    integer test_total;
    integer test_pass;
    integer random_seed;
    integer clock_count;
    integer last_ai_cycles;
    integer ai_start_cycle;
    integer ai_min_cycles;
    integer ai_max_cycles;
    integer ai_samples;
    reg previous_x_busy;

    main dut (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .spi_ss_n(spi_ss_n),
        .spi_sck(spi_sck),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .spi_miso_en(spi_miso_en)
    );

    // A second instance is testbench-only and measures the primitive directly;
    // the synthesizable top contains exactly one multiplier instance.
    modular_multiplier perf_multiplier (
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

    always #10 clk = ~clk; // 50 MHz

    always @(posedge clk) begin
        clock_count = clock_count + 1;
        #1;
        if (!previous_x_busy && dut.x_busy)
            ai_start_cycle = clock_count;
        if (previous_x_busy && !dut.x_busy) begin
            last_ai_cycles = clock_count - ai_start_cycle;
            if (last_ai_cycles < ai_min_cycles)
                ai_min_cycles = last_ai_cycles;
            if (last_ai_cycles > ai_max_cycles)
                ai_max_cycles = last_ai_cycles;
            ai_samples = ai_samples + 1;
        end
        previous_x_busy = dut.x_busy;
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

    task automatic send_word;
        input [31:0] value;
        reg [7:0] ignored;
        begin
            spi_begin();
            spi_transfer_selected(value[31:24], ignored);
            spi_transfer_selected(value[23:16], ignored);
            spi_transfer_selected(value[15:8], ignored);
            spi_transfer_selected(value[7:0], ignored);
            spi_end();
        end
    endtask

    task automatic send_a_stream;
        input integer n;
        integer index;
        reg [7:0] ignored;
        begin
            // All A bytes use one CS-low burst.  This verifies that CS is not
            // interpreted as a word or element delimiter.
            spi_begin();
            for (index = 0; index < n; index = index + 1) begin
                spi_transfer_selected(test_a[index][31:24], ignored);
                spi_transfer_selected(test_a[index][23:16], ignored);
                spi_transfer_selected(test_a[index][15:8], ignored);
                spi_transfer_selected(test_a[index][7:0], ignored);
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
        reg [7:0] rx0;
        reg [7:0] rx1;
        reg [7:0] rx2;
        reg [7:0] rx3;
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
                spi_transfer_selected(CMD_NOP, rx0);
                spi_transfer_selected(CMD_NOP, rx1);
                spi_transfer_selected(CMD_NOP, rx2);
                spi_transfer_selected(CMD_NOP, rx3);
                spi_end();
                result = {rx0, rx1, rx2, rx3};
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
        reg [63:0] residue;
        begin
            total = 64'd0;
            for (mask = 0; mask < (1 << n); mask = mask + 1) begin
                selected = 0;
                sum_mod = 64'd0;
                for (index = 0; index < n; index = index + 1) begin
                    if (mask & (1 << index)) begin
                        selected = selected + 1;
                        residue = test_a[index] % MOD;
                        sum_mod = (sum_mod + residue) % MOD;
                    end
                end
                if (selected == k)
                    total = (total + ((sum_mod * sum_mod) % MOD)) % MOD;
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
        reg session_ok;
        reg reply_ok;
        reg [7:0] status;
        reg [31:0] result;
        reg [31:0] expected;
        reg passed;
        begin
            brute_force_expected(n, k, expected);
            begin_request(session_ok);
            send_word(n);
            send_word(k);
            send_a_stream(n);
            poll_and_read(status, result, reply_ok);
            passed = session_ok && reply_ok && (status == 8'h80) &&
                     (result == expected);
            if (!passed)
                $display("  n=%0d k=%0d status=%02x result=%0d expected=%0d",
                         n, k, status, result, expected);
            record_result(name, passed);
        end
    endtask

    task automatic wait_for_input_count;
        input integer wanted;
        output reg ok;
        integer guard;
        begin
            guard = 0;
            while (dut.input_count < wanted && guard < 1000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            #1;
            ok = (dut.input_count == wanted);
        end
    endtask

    task automatic wait_for_pair_twice;
        output reg ok;
        integer guard;
        begin
            guard = 0;
            while (dut.calc_state != dut.C_FINAL_TERM_SQUARE_START &&
                   guard < 20000) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
            end
            ok = (dut.calc_state == dut.C_FINAL_TERM_SQUARE_START) &&
                 (dut.term_pair == 30'd22);
        end
    endtask

    task automatic wait_for_pair_correction;
        output reg ok;
        integer guard;
        begin
            guard = 0;
            while (dut.calc_state != dut.C_FINAL_PAIR_CORRECT &&
                   guard < 20000) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
            end
            // For 0-2 in the 30-bit subtractor, the raw wrapped difference
            // is 2^30-2.  The correction state then adds MOD and wraps it to
            // the canonical MOD-2 result using the same arithmetic datapath.
            ok = (dut.calc_state == dut.C_FINAL_PAIR_CORRECT) &&
                 (dut.term_pair == 30'd1073741822);
            if (ok) begin
                @(posedge clk);
                #1;
                ok = (dut.calc_state == dut.C_FINAL_TERM_SQUARE_START) &&
                     (dut.term_pair == 30'd998244351);
            end
        end
    endtask

    task automatic test_s1_s2_states;
        reg ok;
        reg one_ok;
        reg wait_ok;
        reg pair_twice_ok;
        reg correction_ok;
        reg [7:0] status;
        reg [31:0] result;
        reg reply_ok;
        begin
            test_a[0] = 32'd1;
            test_a[1] = 32'd2;
            test_a[2] = 32'd3;
            begin_request(ok);
            send_word(3);
            send_word(2);

            send_word(test_a[0]);
            wait_for_input_count(1, wait_ok);
            ok = ok && wait_ok && dut.s1 == 30'd1 && dut.s2 == 30'd1;

            send_word(test_a[1]);
            wait_for_input_count(2, wait_ok);
            ok = ok && wait_ok && dut.s1 == 30'd3 && dut.s2 == 30'd5;

            send_word(test_a[2]);
            wait_for_input_count(3, wait_ok);
            ok = ok && wait_ok && dut.s1 == 30'd6 && dut.s2 == 30'd14;

            // At the start of term_square calculation, term_pair is the
            // shared scratch holding s1*s1-s2 = 36-14 = 22.
            wait_for_pair_twice(pair_twice_ok);
            ok = ok && pair_twice_ok;

            poll_and_read(status, result, reply_ok);
            ok = ok && reply_ok && status == 8'h80 && result == 32'd50;

            // Force S1^2 < S2 after modular reduction: s1=0, s2=2.
            // This exercises the borrow and shared +MOD correction path.
            test_a[0] = MOD - 1;
            test_a[1] = 32'd1;
            begin_request(one_ok);
            ok = ok && one_ok;
            send_word(2);
            send_word(2);
            send_word(test_a[0]);
            send_word(test_a[1]);
            wait_for_pair_correction(correction_ok);
            ok = ok && correction_ok;
            poll_and_read(status, result, reply_ok);
            ok = ok && reply_ok && status == 8'h80 && result == 32'd0;

            if (!ok)
                $display("  states s1=%0d s2=%0d pair_twice=%0d status=%02x result=%0d",
                         dut.s1, dut.s2, dut.term_pair,
                         status, result);
            record_result("s1_s2_updates_pair_twice_borrow_and_hand_example", ok);
        end
    endtask

    task automatic test_error_sticky;
        reg ok;
        reg reply_ok;
        reg [7:0] status;
        reg [7:0] repeated_status;
        reg [31:0] result;
        begin
            begin_request(ok);
            send_word(0);
            poll_and_read(status, result, reply_ok);
            spi_exchange(CMD_NOP, repeated_status);
            ok = ok && reply_ok && status == 8'hC0 && result == 32'd0 &&
                 repeated_status == 8'hC0 && dut.protocol_error;

            // Command RESET must clear the sticky flag and return RESET_ACK.
            spi_exchange(CMD_RESET, repeated_status);
            spi_exchange(CMD_NOP, repeated_status);
            ok = ok && repeated_status == 8'h5A && !dut.protocol_error;
            record_result("invalid_n_and_error_sticky_until_reset", ok);
        end
    endtask

    task automatic test_invalid_k;
        reg ok;
        reg reply_ok;
        reg [7:0] status;
        reg [31:0] result;
        begin
            begin_request(ok);
            send_word(3);
            send_word(4);
            poll_and_read(status, result, reply_ok);
            ok = ok && reply_ok && status == 8'hC0 && result == 32'd0;
            record_result("invalid_k_greater_than_n", ok);
        end
    endtask

    task automatic test_other_invalid_parameters;
        reg ok;
        reg one_ok;
        reg reply_ok;
        reg [7:0] status;
        reg [31:0] result;
        begin
            begin_request(ok);
            send_word(32'd200001);
            poll_and_read(status, result, reply_ok);
            one_ok = reply_ok && status == 8'hC0 && result == 32'd0;
            ok = ok && one_ok;

            begin_request(one_ok);
            ok = ok && one_ok;
            send_word(3);
            send_word(0);
            poll_and_read(status, result, reply_ok);
            ok = ok && reply_ok && status == 8'hC0 && result == 32'd0;
            record_result("n_above_max_and_k_zero", ok);
        end
    endtask

    task automatic test_busy_word_error;
        reg ok;
        reg reply_ok;
        reg [7:0] status;
        reg [31:0] result;
        begin
            begin_request(ok);
            send_word(1);
            send_word(1);

            // Force only the receiver's documented busy precondition so the
            // completed SPI word exercises the no-input-queue error path.
            force dut.x_busy = 1'b1;
            send_word(32'd9);
            release dut.x_busy;

            poll_and_read(status, result, reply_ok);
            ok = ok && reply_ok && status == 8'hC0 && result == 32'd0 &&
                 dut.protocol_error;
            record_result("a_word_completed_while_x_busy", ok);
        end
    endtask

    task automatic test_extra_payload;
        reg ok;
        reg reply_ok;
        reg [7:0] ignored;
        reg [7:0] status;
        reg [31:0] result;
        begin
            test_a[0] = 32'd7;
            begin_request(ok);
            send_word(1);
            send_word(1);
            send_word(test_a[0]);
            // This non-NOP byte arrives after the declared final A word.
            spi_exchange(8'h12, ignored);
            poll_and_read(status, result, reply_ok);
            ok = ok && reply_ok && status == 8'hC0 && dut.protocol_error;
            record_result("extra_payload_after_n_values", ok);
        end
    endtask

    task automatic measure_multiplier;
        reg [63:0] expected;
        integer cycles;
        reg ok;
        begin
            perf_lhs = 30'd123456789;
            perf_rhs = 30'd987654321;
            expected = (64'd123456789 * 64'd987654321) % MOD;
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
            ok = perf_done && cycles == 60 && perf_product == expected[29:0];
            $display("PERF MUL_CLOCKS=%0d PRODUCT=%0d", cycles, perf_product);
            record_result("shared_multiplier_60_clocks", ok);
        end
    endtask

    integer random_case;
    integer n_random;
    integer k_random;
    integer value_index;
    reg [31:0] random_value;

    initial begin
        clk             = 1'b0;
        rst_n           = 1'b0;
        spi_ss_n        = 1'b1;
        spi_sck         = 1'b0;
        spi_mosi        = 1'b0;
        perf_clear      = 1'b0;
        perf_start      = 1'b0;
        perf_lhs        = 30'd0;
        perf_rhs        = 30'd0;
        test_total      = 0;
        test_pass       = 0;
        random_seed     = 32'h471E2026;
        clock_count     = 0;
        last_ai_cycles  = 0;
        ai_start_cycle  = 0;
        ai_min_cycles   = 32'h7fffffff;
        ai_max_cycles   = 0;
        ai_samples      = 0;
        previous_x_busy = 1'b0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (8) @(posedge clk);

        measure_multiplier();
        test_s1_s2_states();

        test_a[0] = 32'd123456789;
        run_case("n1_k1", 1, 1);

        test_a[0] = 32'd1;
        test_a[1] = 32'd2;
        test_a[2] = 32'd3;
        test_a[3] = 32'd4;
        run_case("k1", 4, 1);
        run_case("k_equals_n", 4, 4);

        test_a[0] = MOD - 1;
        test_a[1] = MOD;
        test_a[2] = MOD + 1;
        test_a[3] = MOD + MOD;
        test_a[4] = 32'hFFFFFFFF;
        run_case("mod_boundaries_and_payload_ff", 5, 3);

        for (random_case = 0; random_case < 100; random_case = random_case + 1) begin
            random_value = $urandom(random_seed);
            n_random = 1 + (random_value % 8);
            random_value = $urandom(random_seed);
            k_random = 1 + (random_value % n_random);
            for (value_index = 0; value_index < n_random;
                 value_index = value_index + 1) begin
                test_a[value_index] = $urandom(random_seed);
            end
            run_case($sformatf("random_%0d", random_case), n_random, k_random);
        end

        // Print throughput before the forced-busy protocol unit test, whose
        // artificial force/release interval is not an A-processing sample.
        $display("PERF AI_SAMPLES=%0d AI_MIN_CLOCKS=%0d AI_MAX_CLOCKS=%0d",
                 ai_samples, ai_min_cycles, ai_max_cycles);

        test_error_sticky();
        test_invalid_k();
        test_other_invalid_parameters();
        test_busy_word_error();
        test_extra_payload();

        $display("SUMMARY TOTAL=%0d PASS=%0d FAIL=%0d",
                 test_total, test_pass, test_total - test_pass);

        if (test_pass != test_total)
            $fatal(1, "ABC471E S1/S2 simulation failed");
        $finish;
    end

endmodule
