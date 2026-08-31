`timescale 1ns/1ps

module tb_abc472b;
    localparam integer SPI_HALF_NS = 125; // 4 MHz
    localparam integer MAX_BURST_BYTES = 256;
    localparam integer RANDOM_CASES = 512;

    localparam [2:0] RECEIVE_INPUT = 3'd0;
    localparam [2:0] CALC_READ     = 3'd1;
    localparam [2:0] CALC_EVALUATE = 3'd2;
    localparam [2:0] ANSWER_READY  = 3'd3;
    localparam [2:0] CALC_WAIT     = 3'd4;

    reg clk;
    reg rst_n;
    reg spi_ss_n;
    reg spi_sck;
    reg spi_mosi;
    wire clk_en;
    wire spi_miso;
    wire spi_miso_en;

    reg [16:0] case_lengths [0:99];
    reg [31:0] prng_state;

    integer failures;
    integer cases_run;
    integer random_passed;
    integer current_burst_bytes;
    integer bursts_used;

    integer total_int;
    integer prefix_int;
    integer right_int;
    integer diff_int;
    integer expected_int;
    integer best_int;

    // CALCへ入ってからANSWER_READYになるまでの実clockを観測する。
    reg [2:0] observed_state;
    integer active_calc_clocks;
    integer active_candidates;
    integer completed_calc_clocks;
    integer completed_candidates;
    integer maximum_calc_clocks;

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

    always #10 clk = ~clk; // 50 MHz

    always @(posedge clk) begin
        if (!rst_n) begin
            observed_state           = RECEIVE_INPUT;
            active_calc_clocks       = 0;
            active_candidates        = 0;
            completed_calc_clocks    = 0;
            completed_candidates     = 0;
            maximum_calc_clocks      = 0;
        end else begin
            if ((observed_state == RECEIVE_INPUT) &&
                (dut.state == CALC_READ)) begin
                active_calc_clocks = 1;
                active_candidates  = 0;
            end else if ((dut.state == CALC_READ) ||
                         (dut.state == CALC_WAIT) ||
                         (dut.state == CALC_EVALUATE)) begin
                active_calc_clocks = active_calc_clocks + 1;
            end

            if (dut.state == CALC_EVALUATE)
                active_candidates = active_candidates + 1;

            if ((observed_state == CALC_EVALUATE) &&
                (dut.state == ANSWER_READY)) begin
                completed_calc_clocks = active_calc_clocks;
                completed_candidates  = active_candidates;
                if (active_calc_clocks > maximum_calc_clocks)
                    maximum_calc_clocks = active_calc_clocks;
            end

            observed_state = dut.state;
        end
    end

    task spi_transfer_byte;
        input [7:0] tx;
        output [7:0] rx;
        integer bit_index;
        begin
            rx = 8'h00;
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                spi_mosi = tx[bit_index];
                #(SPI_HALF_NS);
                spi_sck = 1'b1;
                #1;
                rx[bit_index] = spi_miso;
                #(SPI_HALF_NS - 1);
                spi_sck = 1'b0;
            end
        end
    endtask

    task begin_spi_burst;
        begin
            spi_ss_n = 1'b0;
            #500;
            if (spi_miso_en !== 1'b1) begin
                $display("FAIL MISO output-enable did not assert");
                failures = failures + 1;
            end
        end
    endtask

    task end_spi_burst;
        begin
            spi_ss_n = 1'b1;
            spi_mosi = 1'b0;
            #500;
            if (spi_miso_en !== 1'b0) begin
                $display("FAIL MISO output-enable did not release");
                failures = failures + 1;
            end
        end
    endtask

    task send_logical_byte;
        input [7:0] value;
        input integer has_more;
        reg [7:0] ignored_rx;
        begin
            spi_transfer_byte(value, ignored_rx);
            current_burst_bytes = current_burst_bytes + 1;

            if ((current_burst_bytes == MAX_BURST_BYTES) && has_more) begin
                end_spi_burst;
                // CS境界は通信上の区切りであり、入力FSMを保持する。
                if (dut.state !== RECEIVE_INPUT) begin
                    $display("FAIL state changed at input burst boundary: %0d",
                             dut.state);
                    failures = failures + 1;
                end
                begin_spi_burst;
                bursts_used = bursts_used + 1;
                current_burst_bytes = 0;
            end
        end
    endtask

    task compute_expected;
        input integer length_count;
        integer index;
        begin
            total_int = 0;
            for (index = 0; index < length_count; index = index + 1)
                total_int = total_int + case_lengths[index];

            prefix_int = 0;
            best_int = 24'hffffff;
            for (index = 0; index < length_count - 1; index = index + 1) begin
                prefix_int = prefix_int + case_lengths[index];
                right_int = total_int - prefix_int;
                if (prefix_int >= right_int)
                    diff_int = prefix_int - right_int;
                else
                    diff_int = right_int - prefix_int;
                if (diff_int < best_int)
                    best_int = diff_int;
            end
            expected_int = best_int;
        end
    endtask

    task run_case;
        input integer n_case;
        input [8*64-1:0] case_name;
        input integer verbose;
        integer index;
        integer logical_bytes;
        integer sent_bytes;
        integer expected_bursts;
        integer failures_before;
        reg [7:0] rx0;
        reg [7:0] rx1;
        reg [7:0] rx2;
        reg [7:0] rx3;
        reg [23:0] received_answer;
        begin
            failures_before = failures;
            cases_run = cases_run + 1;
            compute_expected(n_case);

            logical_bytes = 1 + 3 * n_case;
            expected_bursts = (logical_bytes + MAX_BURST_BYTES - 1) /
                              MAX_BURST_BYTES;
            sent_bytes = 0;
            current_burst_bytes = 0;
            bursts_used = 1;

            begin_spi_burst;

            send_logical_byte(n_case, 1);
            sent_bytes = sent_bytes + 1;

            if ((dut.state !== RECEIVE_INPUT) || !dut.n_received) begin
                $display("FAIL %0s: N did not leave receiver in input state",
                         case_name);
                failures = failures + 1;
            end

            for (index = 0; index < n_case; index = index + 1) begin
                send_logical_byte(
                    {7'd0, case_lengths[index][16]},
                    (sent_bytes + 1 < logical_bytes)
                );
                sent_bytes = sent_bytes + 1;
                send_logical_byte(
                    case_lengths[index][15:8],
                    (sent_bytes + 1 < logical_bytes)
                );
                sent_bytes = sent_bytes + 1;
                send_logical_byte(
                    case_lengths[index][7:0],
                    (sent_bytes + 1 < logical_bytes)
                );
                sent_bytes = sent_bytes + 1;

                // 最終要素より前にCALCへ遷移してはならない。
                if ((index < n_case - 1) && (dut.state !== RECEIVE_INPUT)) begin
                    $display("FAIL %0s: CALC started after only %0d/%0d lengths",
                             case_name, index + 1, n_case);
                    failures = failures + 1;
                end
            end

            end_spi_burst;

            if (bursts_used != expected_bursts) begin
                $display("FAIL %0s: bursts=%0d expected=%0d bytes=%0d",
                         case_name, bursts_used, expected_bursts, logical_bytes);
                failures = failures + 1;
            end

            if (dut.total_sum !== total_int[23:0]) begin
                $display("FAIL %0s: total=%0d expected=%0d",
                         case_name, dut.total_sum, total_int);
                failures = failures + 1;
            end

            // 17bit値が100件までDistRAMへ書かれたことを直接確認する。
            for (index = 0; index < n_case; index = index + 1) begin
                if (dut.u_lengths_ram.mem_ram[index] !== case_lengths[index]) begin
                    $display("FAIL %0s: RAM[%0d]=%0d expected=%0d",
                             case_name, index,
                             dut.u_lengths_ram.mem_ram[index],
                             case_lengths[index]);
                    failures = failures + 1;
                end
            end

            // firmwareと同じ10us待ち。最大297clock=7.92usに十分な余裕がある。
            #10000;
            if (dut.state !== ANSWER_READY) begin
                $display("FAIL %0s: answer not ready after 10us, state=%0d",
                         case_name, dut.state);
                failures = failures + 1;
            end

            if (dut.answer !== expected_int[23:0]) begin
                $display("FAIL %0s: internal answer=%0d expected=%0d",
                         case_name, dut.answer, expected_int);
                failures = failures + 1;
            end

            if (completed_candidates != n_case - 1) begin
                $display("FAIL %0s: candidates=%0d expected=%0d",
                         case_name, completed_candidates, n_case - 1);
                failures = failures + 1;
            end

            if (completed_calc_clocks != 3 * (n_case - 1)) begin
                $display("FAIL %0s: CALC clocks=%0d expected=%0d",
                         case_name, completed_calc_clocks, 3 * (n_case - 1));
                failures = failures + 1;
            end

            // 回答は別の4byte read burst。MISOは1byte遅延する。
            begin_spi_burst;
            spi_transfer_byte(8'h00, rx0);
            spi_transfer_byte(8'h00, rx1);
            spi_transfer_byte(8'h00, rx2);
            spi_transfer_byte(8'h00, rx3);
            end_spi_burst;

            received_answer = {rx1, rx2, rx3};
            if (rx0 !== 8'h00) begin
                $display("FAIL %0s: reply dummy=%02x expected=00",
                         case_name, rx0);
                failures = failures + 1;
            end
            if (received_answer !== expected_int[23:0]) begin
                $display("FAIL %0s: SPI answer=%06x expected=%06x",
                         case_name, received_answer, expected_int[23:0]);
                failures = failures + 1;
            end

            // 4byte目完了後は、RAM内容を一括resetせず受信制御だけ初期化する。
            if ((dut.state !== RECEIVE_INPUT) || dut.n_received) begin
                $display("FAIL %0s: receiver did not re-arm after answer",
                         case_name);
                failures = failures + 1;
            end

            if ((failures == failures_before) && verbose)
                $display("PASS %0s N=%0d bytes=%0d bursts=%0d answer=%0d calc_clocks=%0d",
                         case_name, n_case, logical_bytes, bursts_used,
                         expected_int, completed_calc_clocks);
        end
    endtask

    integer i;
    integer j;
    integer failures_before_random;
    integer n_random;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        spi_ss_n = 1'b1;
        spi_sck = 1'b0;
        spi_mosi = 1'b0;
        failures = 0;
        cases_run = 0;
        random_passed = 0;
        prng_state = 32'h472b2026;

        #100;
        rst_n = 1'b1;
        #500;

        // 公式サンプル3件。
        case_lengths[0] = 5; case_lengths[1] = 2;
        case_lengths[2] = 3; case_lengths[3] = 8;
        run_case(4, "official_sample_1", 1);

        case_lengths[0] = 31; case_lengths[1] = 41;
        case_lengths[2] = 59; case_lengths[3] = 26;
        case_lengths[4] = 53; case_lengths[5] = 58;
        case_lengths[6] = 97;
        run_case(7, "official_sample_2", 1);

        case_lengths[0] = 67011; case_lengths[1] = 35764;
        case_lengths[2] = 33042; case_lengths[3] = 24098;
        case_lengths[4] = 63738; case_lengths[5] = 98760;
        case_lengths[6] = 17199; case_lengths[7] = 68579;
        case_lengths[8] = 21812; case_lengths[9] = 45408;
        run_case(10, "official_sample_3", 1);

        // N=2、L_i=1、answer=0。
        case_lengths[0] = 1; case_lengths[1] = 1;
        run_case(2, "n2_minimum", 1);

        // 24bit answerのMSBが非0になるケース。
        case_lengths[0] = 1; case_lengths[1] = 100000;
        run_case(2, "answer_24bit", 1);

        // 最適切れ目が先頭、末尾、複数同値。
        case_lengths[0] = 100; case_lengths[1] = 1;
        case_lengths[2] = 1;
        run_case(3, "best_at_first_cut", 1);

        case_lengths[0] = 1; case_lengths[1] = 1;
        case_lengths[2] = 100;
        run_case(3, "best_at_last_cut", 1);

        case_lengths[0] = 1; case_lengths[1] = 1;
        case_lengths[2] = 1;
        run_case(3, "equal_best_cuts", 1);

        // V3 256byte境界: N=85は256byte、N=86は259byte。
        for (i = 0; i < 85; i = i + 1)
            case_lengths[i] = 1 + ((i * 97) % 100000);
        run_case(85, "burst_boundary_256", 1);

        for (i = 0; i < 86; i = i + 1)
            case_lengths[i] = 1 + ((i * 193) % 100000);
        run_case(86, "burst_boundary_259", 1);

        // N=100、全L_i=1。
        for (i = 0; i < 100; i = i + 1)
            case_lengths[i] = 1;
        run_case(100, "n100_all_one", 1);

        // 合計最大10,000,000、L_i最大100,000、301byte分割。
        for (i = 0; i < 100; i = i + 1)
            case_lengths[i] = 100000;
        run_case(100, "maximum_total", 1);

        // 決定的LCGによる512ケース。期待値はテスト専用oracleで逐次算出。
        failures_before_random = failures;
        for (j = 0; j < RANDOM_CASES; j = j + 1) begin
            prng_state = prng_state * 32'd1664525 + 32'd1013904223;
            n_random = 2 + (prng_state % 99);
            for (i = 0; i < n_random; i = i + 1) begin
                prng_state = prng_state * 32'd1664525 + 32'd1013904223;
                case_lengths[i] = 1 + (prng_state % 100000);
            end
            run_case(n_random, "deterministic_random", 0);
        end
        random_passed = RANDOM_CASES - (failures - failures_before_random);
        if (failures == failures_before_random)
            $display("PASS deterministic_random cases=%0d", RANDOM_CASES);

        if (clk_en !== 1'b1) begin
            $display("FAIL clk_en is not asserted");
            failures = failures + 1;
        end

        if (failures == 0) begin
            $display("SUMMARY PASS cases=%0d random=%0d failures=0 max_calc_clocks=%0d",
                     cases_run, RANDOM_CASES, maximum_calc_clocks);
            $finish;
        end else begin
            $display("SUMMARY FAIL cases=%0d failures=%0d max_calc_clocks=%0d",
                     cases_run, failures, maximum_calc_clocks);
            $fatal(1);
        end
    end

endmodule
