`timescale 1ns/1ps

module tb_corridor_watch_distRAM;
    localparam [7:0] CMD_NOP   = 8'h00;
    localparam [7:0] CMD_RESET = 8'hFF;
    localparam [7:0] CMD_START = 8'hFE;
    localparam [7:0] RESET_ACK = 8'h5A;
    localparam [7:0] START_ACK = 8'hA5;

    localparam [2:0] WAIT_START    = 3'd0;
    localparam [2:0] RECEIVE_S     = 3'd3;
    localparam [2:0] WAIT_UPDATES  = 3'd4;
    localparam [2:0] COUNT_WATCHED = 3'd5;

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

    // 各ケースで逐次初期化と同期読み出しを直接監視する。
    reg monitor_init;
    reg monitor_count;
    reg monitor_receive;
    integer init_write_count;
    integer init_sequence_error;
    integer read_issue_count;
    integer read_collect_count;
    integer read_sequence_error;
    integer read_write_overlap_error;
    integer early_s_error;

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

    // RAMへ実際に提示される書き込みと読み出しをクロック単位で検査する。
    always @(posedge clk) begin
        if (monitor_init &&
            dut.ram_write_enable &&
            dut.init_active) begin
            if (dut.ram_write_address !== init_write_count[6:0] ||
                dut.ram_write_data !== 1'b1)
                init_sequence_error = 1;
            init_write_count = init_write_count + 1;
        end

        if (monitor_count) begin
            // 回収は、そのクロックより前に発行済みのデータだけを許可する。
            if (dut.state == COUNT_WATCHED &&
                dut.count_data_valid) begin
                if (read_collect_count >= read_issue_count)
                    read_sequence_error = 1;
                read_collect_count = read_collect_count + 1;
            end

            if (dut.ram_read_enable) begin
                if (dut.ram_read_address !== read_issue_count[6:0])
                    read_sequence_error = 1;
                read_issue_count = read_issue_count + 1;
            end

            if (dut.ram_read_enable && dut.ram_write_enable)
                read_write_overlap_error = 1;
        end

        if (monitor_receive &&
            dut.rx_data_strobe &&
            dut.state == RECEIVE_S &&
            !dut.init_done)
            early_s_error = 1;
    end

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
        input [8*56-1:0] case_name;
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
                        "FAIL %-56s RESET_ACK RX=%02x",
                        case_name, rx_byte
                    );
                    case_failed = 1;
                end
                if (dut.update_overrun !== 1'b0) begin
                    $display(
                        "FAIL %-56s RESET_OVERRUN_NOT_CLEAR",
                        case_name
                    );
                    case_failed = 1;
                end
            end

            // START直後の100クロック逐次初期化を全アドレスで監視する。
            init_write_count = 0;
            init_sequence_error = 0;
            monitor_init = 1'b1;

            transfer_one(CMD_START, rx_byte);
            transfer_one(m_value[7:0], rx_byte);
            if (rx_byte !== START_ACK) begin
                $display(
                    "FAIL %-56s START_ACK RX=%02x",
                    case_name, rx_byte
                );
                case_failed = 1;
            end

            transfer_one(d_value[7:0], rx_byte);
            monitor_init = 1'b0;
            if (rx_byte !== 8'h00) begin
                $display(
                    "FAIL %-56s PRE_DATA RX=%02x",
                    case_name, rx_byte
                );
                case_failed = 1;
            end

            if (dut.init_active !== 1'b0 ||
                dut.init_done !== 1'b1) begin
                $display(
                    "FAIL %-56s INIT_NOT_FINISHED_BEFORE_S0",
                    case_name
                );
                case_failed = 1;
            end
            if (init_write_count != 100 || init_sequence_error) begin
                $display(
                    "FAIL %-56s INIT_SEQUENCE WRITES=%0d ERROR=%0d",
                    case_name, init_write_count, init_sequence_error
                );
                case_failed = 1;
            end
            for (index = 0; index < 100; index = index + 1) begin
                if (dut.u_watched_ram.mem_ram[index] !== 1'b1) begin
                    $display(
                        "FAIL %-56s INIT_MEMORY ADDRESS=%0d DATA=%b",
                        case_name, index,
                        dut.u_watched_ram.mem_ram[index]
                    );
                    case_failed = 1;
                end
            end

            read_issue_count = 0;
            read_collect_count = 0;
            read_sequence_error = 0;
            read_write_overlap_error = 0;
            early_s_error = 0;
            monitor_count = 1'b1;
            monitor_receive = 1'b1;

            // MicroPython試験と同様に、S全体を1回のCS Lowで送信する。
            select_spi;
            for (index = 0; index < m_value; index = index + 1) begin
                spi_byte(cells[index], rx_byte);
                if (rx_byte !== 8'h00) begin
                    $display(
                        "FAIL %-56s DATA[%0d] RX=%02x",
                        case_name, index, rx_byte
                    );
                    case_failed = 1;
                end

                if (check_last_update_wait && index == m_value - 1) begin
                    #1;
                    if (dut.update_active !== 1'b1) begin
                        $display(
                            "FAIL %-56s LAST_G_UPDATE_NOT_ACTIVE",
                            case_name
                        );
                        case_failed = 1;
                    end
                    if (dut.state !== WAIT_UPDATES) begin
                        $display(
                            "FAIL %-56s COUNT_STARTED_EARLY STATE=%0d",
                            case_name, dut.state
                        );
                        case_failed = 1;
                    end
                    if (dut.tx_data[7] !== 1'b0) begin
                        $display(
                            "FAIL %-56s VALID_BEFORE_LAST_UPDATE",
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

            monitor_count = 1'b0;
            monitor_receive = 1'b0;

            expected_byte = 8'h80 | expected[7:0];
            if (!answer_valid) begin
                $display(
                    "FAIL %-56s VALID_TIMEOUT LAST_RX=%02x",
                    case_name, rx_byte
                );
                case_failed = 1;
            end else if (rx_byte !== expected_byte) begin
                $display(
                    "FAIL %-56s ANSWER RX=%02x EXPECT=%02x",
                    case_name, rx_byte, expected_byte
                );
                case_failed = 1;
            end

            if (read_issue_count != m_value ||
                read_collect_count != m_value ||
                read_sequence_error) begin
                $display(
                    "FAIL %-56s SYNC_READ ISSUE=%0d COLLECT=%0d ERROR=%0d",
                    case_name, read_issue_count,
                    read_collect_count, read_sequence_error
                );
                case_failed = 1;
            end
            if (read_write_overlap_error) begin
                $display(
                    "FAIL %-56s READ_WRITE_OVERLAP",
                    case_name
                );
                case_failed = 1;
            end
            if (early_s_error) begin
                $display(
                    "FAIL %-56s S0_BEFORE_INIT_DONE",
                    case_name
                );
                case_failed = 1;
            end
            if (dut.update_overrun !== 1'b0) begin
                $display(
                    "FAIL %-56s UPDATE_OVERRUN=1",
                    case_name
                );
                case_failed = 1;
            end

            if (case_failed) begin
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
                $display(
                    "PASS %-56s M=%0d D=%0d ANSWER=%0d VALID=1 OVERRUN=0 INIT_WRITES=100 READS=%0d",
                    case_name, m_value, d_value,
                    expected, read_collect_count
                );
            end
        end
    endtask

    task test_reset_clears_result;
        integer case_failed;
        reg [7:0] rx_byte;
        reg [7:0] previous_answer;
        reg [0:0] ram_before_reset;
        begin
            case_failed = 0;
            previous_answer = dut.tx_data;
            ram_before_reset = dut.u_watched_ram.mem_ram[0];
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

            // RESETコマンドではRAM内容を書き換えない。
            if (dut.u_watched_ram.mem_ram[0] !== ram_before_reset) begin
                $display(
                    "FAIL reset_clears_previous_result RAM_CHANGED"
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
                dut.init_active !== 1'b0 ||
                dut.init_done !== 1'b0 ||
                dut.update_active !== 1'b0 ||
                dut.pending_valid !== 1'b0 ||
                dut.update_overrun !== 1'b0 ||
                dut.count_data_valid !== 1'b0 ||
                dut.tx_data !== 8'h00) begin
                $display("FAIL reset_clears_previous_result INTERNAL_STATE");
                case_failed = 1;
            end

            if (case_failed) begin
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
                $display(
                    "PASS reset_clears_previous_result ACK=5a STALE=0 FLAGS=0 RAM_UNCHANGED=1"
                );
            end
        end
    endtask

    task test_pending_seamless;
        integer case_failed;
        integer timeout_count;
        reg [7:0] rx_byte;
        reg [6:0] saved_pending_start;
        reg [6:0] saved_pending_end;
        begin
            case_failed = 0;

            transfer_one(CMD_RESET, rx_byte);
            transfer_one(CMD_NOP, rx_byte);
            if (rx_byte !== RESET_ACK)
                case_failed = 1;

            transfer_one(CMD_START, rx_byte);
            transfer_one(8'd10, rx_byte);
            if (rx_byte !== START_ACK)
                case_failed = 1;
            transfer_one(8'd3, rx_byte);

            if (dut.init_done !== 1'b1)
                case_failed = 1;

            // 2件を連続注入し、2件目を1件保留バッファへ入れる。
            force dut.rx_data = 8'h01;
            force dut.rx_data_strobe = 1'b1;
            repeat (2) begin
                @(posedge clk);
                #1;
            end
            release dut.rx_data_strobe;
            release dut.rx_data;

            if (dut.update_active !== 1'b1 ||
                dut.pending_valid !== 1'b1) begin
                $display(
                    "FAIL pending_seamless REQUESTS_NOT_ACTIVE ACTIVE=%0d PENDING=%0d",
                    dut.update_active, dut.pending_valid
                );
                case_failed = 1;
            end

            timeout_count = 0;
            while (!(dut.update_active &&
                     dut.update_address == dut.update_end &&
                     dut.pending_valid) &&
                   timeout_count < 1000) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
            end

            if (timeout_count >= 1000) begin
                $display("FAIL pending_seamless FINISH_TIMEOUT");
                case_failed = 1;
            end else begin
                saved_pending_start = dut.pending_start;
                saved_pending_end = dut.pending_end;
                if (dut.ram_write_enable !== 1'b1)
                    case_failed = 1;

                @(posedge clk);
                #1;
                if (dut.update_active !== 1'b1 ||
                    dut.update_address !== saved_pending_start ||
                    dut.update_end !== saved_pending_end ||
                    dut.pending_valid !== 1'b0 ||
                    dut.ram_write_enable !== 1'b1) begin
                    $display(
                        "FAIL pending_seamless GAP_OR_WRONG_RANGE ACTIVE=%0d ADDRESS=%0d END=%0d PENDING=%0d WE=%0d",
                        dut.update_active, dut.update_address,
                        dut.update_end, dut.pending_valid,
                        dut.ram_write_enable
                    );
                    case_failed = 1;
                end
            end

            timeout_count = 0;
            while ((dut.update_active || dut.pending_valid) &&
                   timeout_count < 1000) begin
                @(posedge clk);
                #1;
                timeout_count = timeout_count + 1;
            end
            if (timeout_count >= 1000 ||
                dut.update_overrun !== 1'b0)
                case_failed = 1;

            if (case_failed) begin
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
                $display(
                    "PASS pending_seamless PENDING_TO_ACTIVE_WITHOUT_IDLE=1 OVERRUN=0"
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
                dut.init_active !== 1'b0 ||
                dut.init_done !== 1'b0 ||
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
        rst_n                   = 1'b0;
        spi_ss_n                = 1'b1;
        spi_sck                 = 1'b0;
        spi_mosi                = 1'b0;
        pass_count              = 0;
        fail_count              = 0;
        monitor_init            = 1'b0;
        monitor_count           = 1'b0;
        monitor_receive         = 1'b0;
        init_write_count        = 0;
        init_sequence_error     = 0;
        read_issue_count        = 0;
        read_collect_count      = 0;
        read_sequence_error     = 0;
        read_write_overlap_error = 0;
        early_s_error           = 0;
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

        // 最初と最後の未監視要素を個別に残し、集計境界を確認する。
        fill_guards(5);
        cells[0] = 0;
        run_case("first_cell_only_unwatched", 5, 0, 1, 0);

        fill_guards(5);
        cells[4] = 0;
        run_case("last_cell_only_unwatched", 5, 0, 1, 0);

        // 最後の文字による最大範囲更新の完了前に集計しないことを直接確認する。
        clear_cells;
        cells[99] = 1;
        run_case("last_g_waits_for_update", 100, 99, 1, 1);

        // 直前のVALID回答と内部状態がRESET後に残らないことを確認する。
        test_reset_clears_result;

        // 保留中の更新を完了境界で待機なしに開始することを確認する。
        test_pending_seamless;

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
