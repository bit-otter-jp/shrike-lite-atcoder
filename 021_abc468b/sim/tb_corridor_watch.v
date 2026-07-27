`timescale 1ns/1ps

module tb_corridor_watch;
    localparam [7:0] CMD_RESET = 8'hFF;
    localparam [7:0] CMD_START = 8'hFE;
    localparam [7:0] RESET_ACK = 8'h5A;
    localparam [7:0] START_ACK = 8'hA5;

    reg clk;
    reg rst_n;
    reg spi_ss_n;
    reg spi_sck;
    reg spi_mosi;
    wire spi_miso;
    wire spi_miso_en;
    wire clk_en;

    reg [7:0] cells [0:99];
    integer pass_count;
    integer fail_count;
    integer random_seed;
    integer random_value;
    integer random_case;
    integer i;

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

    // Shrike-Liteプロジェクトの50MHzクロック。
    initial clk = 1'b0;
    always #10 clk = ~clk;

    task clear_cells;
        integer index;
        begin
            for (index = 0; index < 100; index = index + 1)
                cells[index] = 8'h00;
        end
    endtask

    task fill_guards;
        input integer length;
        integer index;
        begin
            clear_cells;
            for (index = 0; index < length; index = index + 1)
                cells[index] = 8'h01;
        end
    endtask

    task reference_answer;
        input integer m_value;
        input integer d_value;
        output integer expected;
        integer cell_index;
        integer guard_index;
        integer watched;
        begin
            expected = 0;
            for (cell_index = 0;
                 cell_index < m_value;
                 cell_index = cell_index + 1) begin
                watched = 0;
                for (guard_index = 0;
                     guard_index < m_value;
                     guard_index = guard_index + 1) begin
                    if (cells[guard_index] == 8'h01) begin
                        if ((cell_index >= guard_index &&
                             cell_index - guard_index <= d_value) ||
                            (guard_index > cell_index &&
                             guard_index - cell_index <= d_value))
                            watched = 1;
                    end
                end
                if (!watched)
                    expected = expected + 1;
            end
        end
    endtask

    // 選択済みのmode 0、MSB firstのSPIバースト内で1byteを転送する。
    // 半周期を125nsとして、指定された4MHzのSPIクロックを生成する。
    task spi_byte;
        input [7:0] tx_byte;
        output [7:0] rx_byte;
        integer bit_index;
        begin
            rx_byte = 8'h00;
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                spi_mosi = tx_byte[bit_index];
                #125;
                spi_sck = 1'b1;
                #60;
                rx_byte[bit_index] = spi_miso;
                #65;
                spi_sck = 1'b0;
            end
        end
    endtask

    task select_spi;
        begin
            spi_sck  = 1'b0;
            spi_ss_n = 1'b0;
            #200;
        end
    endtask

    task deselect_spi;
        begin
            #125;
            spi_ss_n = 1'b1;
            spi_mosi = 1'b0;
            #200;
        end
    endtask

    task transfer_one;
        input [7:0] tx_byte;
        output [7:0] rx_byte;
        begin
            select_spi;
            spi_byte(tx_byte, rx_byte);
            deselect_spi;
        end
    endtask

    task start_partial_transaction;
        input integer m_value;
        input integer d_value;
        input integer data_count;
        reg [7:0] rx_byte;
        integer index;
        begin
            transfer_one(CMD_RESET, rx_byte);
            transfer_one(8'h00, rx_byte);
            transfer_one(CMD_START, rx_byte);
            transfer_one(m_value[7:0], rx_byte);
            transfer_one(d_value[7:0], rx_byte);
            select_spi;
            for (index = 0; index < data_count; index = index + 1)
                spi_byte(cells[index], rx_byte);
            deselect_spi;
        end
    endtask

    task run_case;
        input [8*40-1:0] case_name;
        input integer m_value;
        input integer d_value;
        integer expected;
        integer index;
        integer case_failed;
        reg [7:0] rx_byte;
        reg [7:0] expected_byte;
        begin
            reference_answer(m_value, d_value, expected);
            case_failed = 0;

            transfer_one(CMD_RESET, rx_byte);
            transfer_one(8'h00, rx_byte);
            if (rx_byte !== RESET_ACK) begin
                $display("FAIL %-40s RESET_ACK RX=%02x", case_name, rx_byte);
                case_failed = 1;
            end

            transfer_one(CMD_START, rx_byte);
            transfer_one(m_value[7:0], rx_byte);
            if (rx_byte !== START_ACK) begin
                $display("FAIL %-40s START_ACK RX=%02x", case_name, rx_byte);
                case_failed = 1;
            end

            transfer_one(d_value[7:0], rx_byte);
            if (rx_byte !== 8'h00) begin
                $display("FAIL %-40s PRE_DATA RX=%02x", case_name, rx_byte);
                case_failed = 1;
            end

            // MicroPythonテストと同様に、S全体を1回のCS Lowバーストで送信する。
            select_spi;
            for (index = 0; index < m_value; index = index + 1) begin
                spi_byte(cells[index], rx_byte);
                if (rx_byte !== 8'h00) begin
                    $display(
                        "FAIL %-40s DATA[%0d] RX=%02x",
                        case_name, index, rx_byte
                    );
                    case_failed = 1;
                end
            end
            deselect_spi;

            transfer_one(8'h00, rx_byte);
            expected_byte = 8'h80 | expected[7:0];
            if (rx_byte !== expected_byte) begin
                $display(
                    "FAIL %-40s ANSWER RX=%02x EXPECT=%02x",
                    case_name, rx_byte, expected_byte
                );
                case_failed = 1;
            end
            if (rx_byte[7] !== 1'b1) begin
                $display("FAIL %-40s VALID=0", case_name);
                case_failed = 1;
            end

            if (case_failed) begin
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
                $display(
                    "PASS %-40s M=%0d D=%0d ANSWER=%0d",
                    case_name, m_value, d_value, expected
                );
            end
        end
    endtask

    initial begin
        rst_n      = 1'b0;
        spi_ss_n   = 1'b1;
        spi_sck    = 1'b0;
        spi_mosi   = 1'b0;
        pass_count = 0;
        fail_count = 0;
        random_seed = 32'h468B2026;
        clear_cells;

        #200;
        rst_n = 1'b1;
        #400;

        // 公式サンプル。
        clear_cells;
        cells[1] = 1; cells[5] = 1; cells[6] = 1;
        run_case("official_sample_1", 7, 1);

        clear_cells;
        run_case("official_sample_2", 6, 5);

        clear_cells;
        cells[4] = 1; cells[8] = 1; cells[9] = 1; cells[15] = 1;
        run_case("official_sample_3", 21, 2);

        // 指定された境界条件と区間統合のテスト。
        clear_cells;
        run_case("m1_dot", 1, 0);

        clear_cells;
        cells[0] = 1;
        run_case("m1_guard", 1, 0);

        clear_cells;
        run_case("all_dots", 20, 7);

        fill_guards(20);
        run_case("all_guards", 20, 7);

        clear_cells;
        cells[1] = 1; cells[4] = 1; cells[9] = 1;
        run_case("d_zero", 12, 0);

        clear_cells;
        cells[0] = 1;
        run_case("leading_guard_left_clamp", 12, 4);

        clear_cells;
        cells[11] = 1;
        run_case("trailing_guard_right_clamp_last_g", 12, 4);

        clear_cells;
        cells[2] = 1; cells[10] = 1; cells[18] = 1;
        run_case("separated_guards", 20, 2);

        clear_cells;
        cells[3] = 1; cells[6] = 1;
        run_case("overlapping_intervals", 12, 2);

        clear_cells;
        cells[2] = 1; cells[7] = 1;
        run_case("touching_intervals", 12, 2);

        clear_cells;
        cells[2] = 1; cells[8] = 1;
        run_case("one_cell_gap", 12, 2);

        clear_cells;
        cells[2] = 1; cells[9] = 1;
        run_case("final_character_guard", 10, 1);

        clear_cells;
        for (i = 0; i < 100; i = i + 11)
            cells[i] = 1;
        cells[99] = 1;
        run_case("maximum_m_100", 100, 9);

        // RECEIVE_Sの途中でRESETし、その後に完全な再実行を行う。
        clear_cells;
        cells[1] = 1; cells[5] = 1;
        start_partial_transaction(10, 2, 4);
        clear_cells;
        cells[0] = 1; cells[7] = 1;
        run_case("reset_mid_receive_then_rerun", 8, 1);

        // 決定的な疑似ランダム200ケースを単純参照実装と比較する。
        for (random_case = 0;
             random_case < 200;
             random_case = random_case + 1) begin
            random_value = $random(random_seed);
            random_value = random_value & 32'h7fffffff;
            i = (random_value % 100) + 1;

            clear_cells;
            begin : random_case_body
                integer random_m;
                integer random_d;
                integer random_index;
                random_m = i;
                random_value = $random(random_seed);
                random_value = random_value & 32'h7fffffff;
                random_d = random_value % random_m;
                for (random_index = 0;
                     random_index < random_m;
                     random_index = random_index + 1) begin
                    random_value = $random(random_seed);
                    random_value = random_value & 32'h7fffffff;
                    cells[random_index] = random_value & 1;
                end
                run_case("random_reference_case", random_m, random_d);
            end
        end

        $display(
            "SUMMARY PASS=%0d FAIL=%0d TOTAL=%0d",
            pass_count, fail_count, pass_count + fail_count
        );

        if (fail_count == 0) begin
            $display("ALL TESTS PASSED");
            $finish;
        end else begin
            $display("TEST FAILURES DETECTED");
            $finish;
        end
    end
endmodule
