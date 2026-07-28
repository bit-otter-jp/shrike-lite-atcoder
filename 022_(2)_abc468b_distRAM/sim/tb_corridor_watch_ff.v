`timescale 1ns/1ps

module tb_corridor_watch_ff;
    localparam [7:0] CMD_NOP   = 8'h00;
    localparam [7:0] CMD_RESET = 8'hFF;
    localparam [7:0] CMD_START = 8'hFE;
    localparam [7:0] RESET_ACK = 8'h5A;
    localparam [7:0] START_ACK = 8'hA5;

    localparam [2:0] WAIT_START   = 3'd0;
    localparam [2:0] WAIT_UPDATES = 3'd4;

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
        integer is_watched;
        begin
            expected = 0;
            for (cell_index = 0;
                 cell_index < m_value;
                 cell_index = cell_index + 1) begin
                is_watched = 0;
                for (guard_index = 0;
                     guard_index < m_value;
                     guard_index = guard_index + 1) begin
                    if (cells[guard_index] == 8'h01) begin
                        if ((cell_index >= guard_index &&
                             cell_index - guard_index <= d_value) ||
                            (guard_index > cell_index &&
                             guard_index - cell_index <= d_value))
                            is_watched = 1;
                    end
                end
                if (!is_watched)
                    expected = expected + 1;
            end
        end
    endtask

    // mode 0、MSB firstのSPIバースト内で1byteを転送する。
    // 半周期125ns、1byte 2usで、指定された4MHzを正確に再現する。
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

    task run_case;
        input [8*48-1:0] case_name;
        input integer m_value;
        input integer d_value;
        input integer reset_before;
        input integer check_last_update_wait;
        integer expected;
        integer index;
        integer poll_index;
        integer case_failed;
        integer answer_valid;
        reg [7:0] rx_byte;
        reg [7:0] expected_byte;
        begin
            reference_answer(m_value, d_value, expected);
            case_failed = 0;
            answer_valid = 0;

            if (reset_before) begin
                transfer_one(CMD_RESET, rx_byte);
                transfer_one(CMD_NOP, rx_byte);
                if (rx_byte !== RESET_ACK) begin
                    $display(
                        "FAIL %-48s RESET_ACK RX=%02x",
                        case_name, rx_byte
                    );
                    case_failed = 1;
                end
                if (dut.update_overrun !== 1'b0) begin
                    $display(
                        "FAIL %-48s RESET_OVERRUN_NOT_CLEAR",
                        case_name
                    );
                    case_failed = 1;
                end
            end

            transfer_one(CMD_START, rx_byte);
            transfer_one(m_value[7:0], rx_byte);
            if (rx_byte !== START_ACK) begin
                $display(
                    "FAIL %-48s START_ACK RX=%02x",
                    case_name, rx_byte
                );
                case_failed = 1;
            end

            transfer_one(d_value[7:0], rx_byte);
            if (rx_byte !== 8'h00) begin
                $display(
                    "FAIL %-48s PRE_DATA RX=%02x",
                    case_name, rx_byte
                );
                case_failed = 1;
            end

            if (dut.init_active !== 1'b0) begin
                $display(
                    "FAIL %-48s INIT_NOT_FINISHED_BEFORE_S0",
                    case_name
                );
                case_failed = 1;
            end

            // MicroPython試験と同様に、S全体を1回のCS Lowで送信する。
            select_spi;
            for (index = 0; index < m_value; index = index + 1) begin
                spi_byte(cells[index], rx_byte);
                if (rx_byte !== 8'h00) begin
                    $display(
                        "FAIL %-48s DATA[%0d] RX=%02x",
                        case_name, index, rx_byte
                    );
                    case_failed = 1;
                end

                if (check_last_update_wait && index == m_value - 1) begin
                    #1;
                    if (dut.update_active !== 1'b1) begin
                        $display(
                            "FAIL %-48s LAST_G_UPDATE_NOT_ACTIVE",
                            case_name
                        );
                        case_failed = 1;
                    end
                    if (dut.state !== WAIT_UPDATES) begin
                        $display(
                            "FAIL %-48s COUNT_STARTED_EARLY STATE=%0d",
                            case_name, dut.state
                        );
                        case_failed = 1;
                    end
                    if (dut.tx_data[7] !== 1'b0) begin
                        $display(
                            "FAIL %-48s VALID_BEFORE_LAST_UPDATE",
                            case_name
                        );
                        case_failed = 1;
                    end
                end
            end
            deselect_spi;

            // 1byte遅延応答を、上限付きNOPポーリングで待つ。
            for (poll_index = 0; poll_index < 16; poll_index = poll_index + 1) begin
                if (!answer_valid) begin
                    transfer_one(CMD_NOP, rx_byte);
                    if (rx_byte[7] === 1'b1)
                        answer_valid = 1;
                end
            end

            expected_byte = 8'h80 | expected[7:0];
            if (!answer_valid) begin
                $display(
                    "FAIL %-48s VALID_TIMEOUT LAST_RX=%02x",
                    case_name, rx_byte
                );
                case_failed = 1;
            end else if (rx_byte !== expected_byte) begin
                $display(
                    "FAIL %-48s ANSWER RX=%02x EXPECT=%02x",
                    case_name, rx_byte, expected_byte
                );
                case_failed = 1;
            end

            if (dut.update_overrun !== 1'b0) begin
                $display(
                    "FAIL %-48s UPDATE_OVERRUN=1",
                    case_name
                );
                case_failed = 1;
            end

            if (case_failed) begin
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
                $display(
                    "PASS %-48s M=%0d D=%0d ANSWER=%0d VALID=1 OVERRUN=0",
                    case_name, m_value, d_value, expected
                );
            end
        end
    endtask

    task test_reset_clears_result;
        integer case_failed;
        reg [7:0] rx_byte;
        reg [7:0] previous_answer;
        begin
            case_failed = 0;
            previous_answer = dut.tx_data;
            if (previous_answer[7] !== 1'b1) begin
                $display("FAIL reset_clears_previous_result NO_OLD_RESULT");
                case_failed = 1;
            end

            transfer_one(CMD_RESET, rx_byte);
            transfer_one(CMD_NOP, rx_byte);
            if (rx_byte !== RESET_ACK) begin
                $display(
                    "FAIL reset_clears_previous_result RESET_ACK RX=%02x",
                    rx_byte
                );
                case_failed = 1;
            end

            transfer_one(CMD_NOP, rx_byte);
            if (rx_byte !== 8'h00) begin
                $display(
                    "FAIL reset_clears_previous_result STALE_RX=%02x",
                    rx_byte
                );
                case_failed = 1;
            end
            if (dut.state !== WAIT_START ||
                dut.update_active !== 1'b0 ||
                dut.pending_valid !== 1'b0 ||
                dut.update_overrun !== 1'b0 ||
                dut.tx_data !== 8'h00 ||
                dut.watched !== {100{1'b1}}) begin
                $display("FAIL reset_clears_previous_result INTERNAL_STATE");
                case_failed = 1;
            end

            if (case_failed) begin
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
                $display(
                    "PASS reset_clears_previous_result ACK=5a STALE=0 FLAGS=0"
                );
            end
        end
    endtask

    task test_overrun_and_reset;
        integer case_failed;
        reg [7:0] rx_byte;
        begin
            case_failed = 0;

            transfer_one(CMD_RESET, rx_byte);
            transfer_one(CMD_NOP, rx_byte);
            if (rx_byte !== RESET_ACK)
                case_failed = 1;

            transfer_one(CMD_START, rx_byte);
            transfer_one(8'd100, rx_byte);
            if (rx_byte !== START_ACK)
                case_failed = 1;
            transfer_one(8'd99, rx_byte);

            // update_overrunの単体確認だけは、SPIの動作範囲外へ速度を上げず、
            // 受信通知を3クロック連続で注入して保留1件を意図的にあふれさせる。
            // 4MHzの正常系と最大負荷ケースはすべて実SPI経路で確認している。
            force dut.rx_data = 8'h01;
            force dut.rx_data_strobe = 1'b1;
            repeat (3) begin
                @(posedge clk);
                #1;
            end
            release dut.rx_data_strobe;
            release dut.rx_data;
            @(posedge clk);
            #1;

            if (dut.update_overrun !== 1'b1) begin
                $display(
                    "FAIL overrun_and_reset OVERRUN_DID_NOT_SET POSITION=%0d ACTIVE=%0d ADDRESS=%0d PENDING=%0d",
                    dut.position, dut.update_active,
                    dut.update_address, dut.pending_valid
                );
                case_failed = 1;
            end

            transfer_one(CMD_RESET, rx_byte);
            transfer_one(CMD_NOP, rx_byte);
            if (rx_byte !== RESET_ACK) begin
                $display(
                    "FAIL overrun_and_reset RESET_ACK RX=%02x",
                    rx_byte
                );
                case_failed = 1;
            end
            if (dut.update_overrun !== 1'b0 ||
                dut.update_active !== 1'b0 ||
                dut.pending_valid !== 1'b0 ||
                dut.state !== WAIT_START) begin
                $display("FAIL overrun_and_reset RESET_DID_NOT_CLEAR");
                case_failed = 1;
            end

            if (case_failed) begin
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
                $display("PASS overrun_and_reset SET=1 RESET_CLEAR=1");
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
        clear_cells;

        #200;
        rst_n = 1'b1;
        #400;

        // 公式サンプル。
        clear_cells;
        cells[1] = 1; cells[5] = 1; cells[6] = 1;
        run_case("official_sample_1", 7, 1, 1, 0);

        clear_cells;
        run_case("official_sample_2_start_without_reset", 6, 5, 0, 0);

        clear_cells;
        cells[4] = 1; cells[8] = 1; cells[9] = 1; cells[15] = 1;
        run_case("official_sample_3", 21, 2, 1, 0);

        // SPEC.mdに記載された追加テスト。
        clear_cells;
        run_case("min_dot", 1, 0, 1, 0);

        clear_cells;
        cells[0] = 1;
        run_case("min_g", 1, 0, 1, 0);

        clear_cells;
        cells[0] = 1;
        run_case("left_edge", 10, 3, 1, 0);

        clear_cells;
        cells[9] = 1;
        run_case("right_edge", 10, 3, 1, 0);

        clear_cells;
        cells[2] = 1; cells[4] = 1;
        run_case("overlap", 10, 2, 1, 0);

        clear_cells;
        run_case("no_g_max", 100, 99, 1, 0);

        clear_cells;
        cells[0] = 1;
        run_case("full_watch", 100, 99, 1, 0);

        fill_guards(100);
        run_case("max_load_4mhz", 100, 99, 1, 0);

        // 最後の文字による最大範囲更新の完了前に集計しないことを直接確認する。
        clear_cells;
        cells[99] = 1;
        run_case("last_g_waits_for_update", 100, 99, 1, 1);

        // 直前のVALID回答と内部状態がRESET後に残らないことを確認する。
        test_reset_clears_result;

        // 異常フラグのセット条件とRESETによるクリアを確認する。
        test_overrun_and_reset;

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
