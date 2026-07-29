`timescale 1ns/1ps

module tb_corridor_watch_BRAM;

    localparam [7:0] CMD_NOP   = 8'h00;
    localparam [7:0] CMD_RESET = 8'hFF;
    localparam [7:0] CMD_START = 8'hFE;
    localparam [7:0] RESET_ACK = 8'h5A;
    localparam [7:0] START_ACK = 8'hA5;

    localparam [3:0] WAIT_START       = 4'd0;
    localparam [3:0] RECEIVE_S        = 4'd4;
    localparam [3:0] WAIT_UPDATES     = 4'd5;
    localparam [3:0] COUNT_REQUEST    = 4'd6;
    localparam [3:0] COUNT_WAIT_BUSY  = 4'd7;
    localparam [3:0] COUNT_WAIT_VALID = 4'd8;

    reg clk;
    reg rst_n;
    reg spi_ss_n;
    reg spi_sck;
    reg spi_mosi;

    wire clk_en;
    wire spi_miso;
    wire spi_miso_en;

    wire [1:0] bram0_ratio;
    wire [7:0] bram0_write_data;
    wire [8:0] bram0_write_addr;
    wire       bram0_wen_n;
    wire       bram0_wclken_n;
    wire [7:0] bram0_read_data;
    wire [8:0] bram0_read_addr;
    wire       bram0_ren_n;
    wire       bram0_rclken_n;

    reg [7:0] cells [0:99];
    reg [7:0] rx_byte;

    integer pass_count;
    integer fail_count;
    integer required_case_pass_count;
    integer required_case_fail_count;
    integer clock_count;

    // clear、通常書き込み、最終読み出しをBRAM端子で直接監視する。
    reg monitor_clear;
    reg clear_started;
    integer clear_write_count;
    integer clear_sequence_error;

    reg monitor_case;
    reg monitor_max_load;
    integer normal_write_count;
    integer normal_read_issue_count;
    integer normal_read_valid_count;
    integer bram_access_error;
    integer read_wait_error;
    integer read_issue_clock;
    integer update_active_seen;
    integer pending_seen;
    integer merge_seen;
    integer max_load_write_count;
    time max_load_first_write_time;
    time max_load_last_write_time;

    main dut (
        .clk              (clk),
        .clk_en           (clk_en),
        .rst_n            (rst_n),
        .spi_ss_n         (spi_ss_n),
        .spi_sck          (spi_sck),
        .spi_mosi         (spi_mosi),
        .spi_miso         (spi_miso),
        .spi_miso_en      (spi_miso_en),
        .bram0_ratio      (bram0_ratio),
        .bram0_write_data (bram0_write_data),
        .bram0_write_addr (bram0_write_addr),
        .bram0_wen_n      (bram0_wen_n),
        .bram0_wclken_n   (bram0_wclken_n),
        .bram0_read_data  (bram0_read_data),
        .bram0_read_addr  (bram0_read_addr),
        .bram0_ren_n      (bram0_ren_n),
        .bram0_rclken_n   (bram0_rclken_n)
    );

    bram0_model u_bram0_model (
        .clk       (clk),
        .write_data(bram0_write_data),
        .write_addr(bram0_write_addr),
        .wen_n     (bram0_wen_n),
        .wclken_n  (bram0_wclken_n),
        .read_data (bram0_read_data),
        .read_addr (bram0_read_addr),
        .ren_n     (bram0_ren_n),
        .rclken_n  (bram0_rclken_n)
    );

    // ForgeFPGA Custom Moduleと同じ50MHz内部クロック。
    initial begin
        clk = 1'b0;
        forever #10 clk = ~clk;
    end

    always @(posedge clk) begin
        clock_count = clock_count + 1;

        // RESET受信前に進行中だった通常書き込みはclear件数へ含めない。
        // bram_clearをアクセス層が受け付けるクロックから0番地を数え直す。
        if (monitor_clear && dut.bram_clear) begin
            clear_started = 1'b1;
            clear_write_count = 0;
            clear_sequence_error = 0;
        end

        #1;

        if (monitor_case) begin
            if (dut.update_active)
                update_active_seen = 1;
            if (dut.pending_valid)
                pending_seen = 1;

            if (dut.rx_data_strobe &&
                dut.state == RECEIVE_S &&
                dut.rx_data == 8'h01 &&
                dut.update_active &&
                dut.request_start <= (dut.update_end + 9'd1))
                merge_seen = 1;

            if (dut.bram_access_read_valid) begin
                normal_read_valid_count = normal_read_valid_count + 1;
                if (clock_count - read_issue_clock != 4)
                    read_wait_error = 1;
            end

            if (dut.bram_write_req && dut.bram_access_busy)
                bram_access_error = 1;
            if (dut.bram_read_req && dut.bram_access_busy)
                bram_access_error = 1;
        end
    end

    // Low有効のBRAM端子は、Enableが安定しているnegedgeで観測する。
    always @(negedge clk) begin
        if (monitor_clear && clear_started && !bram0_wen_n) begin
            if (bram0_write_data !== 8'h00 ||
                bram0_write_addr !== clear_write_count[8:0])
                clear_sequence_error = 1;
            clear_write_count = clear_write_count + 1;
        end

        if (monitor_case && !bram0_wen_n && !dut.clear_active) begin
            normal_write_count = normal_write_count + 1;
            if (bram0_write_data !== 8'h01)
                bram_access_error = 1;
            if (bram0_write_addr >= {2'b00, dut.m_reg})
                bram_access_error = 1;

            if (monitor_max_load) begin
                max_load_write_count = max_load_write_count + 1;
                if (max_load_write_count == 1)
                    max_load_first_write_time = $time;
                max_load_last_write_time = $time;
            end
        end

        if (monitor_case && !bram0_ren_n) begin
            normal_read_issue_count = normal_read_issue_count + 1;
            read_issue_clock = clock_count;

            if (bram0_read_addr >= {2'b00, dut.m_reg})
                bram_access_error = 1;
            if (dut.update_active || dut.pending_valid)
                bram_access_error = 1;
            if (dut.state != COUNT_WAIT_BUSY &&
                dut.state != COUNT_WAIT_VALID &&
                dut.state != COUNT_REQUEST)
                bram_access_error = 1;
        end

        if (!bram0_wen_n && !bram0_ren_n)
            bram_access_error = 1;
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

    function integer cell_is_watched;
        input integer cell_index;
        input integer m_value;
        input integer d_value;
        integer guard_index;
        integer watched;
        begin
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
            cell_is_watched = watched;
        end
    endfunction

    task reference_answer;
        input integer m_value;
        input integer d_value;
        output integer expected;
        integer cell_index;
        begin
            expected = 0;
            for (cell_index = 0;
                 cell_index < m_value;
                 cell_index = cell_index + 1) begin
                if (!cell_is_watched(cell_index, m_value, d_value))
                    expected = expected + 1;
            end
        end
    endtask

    // CPOL=0、CPHA=0、MSB first、半周期125nsの4MHzで1byte転送する。
    // CS操作は呼出し側へ分離し、S全体のLow保持バーストを再現する。
    task spi_byte;
        input [7:0] tx_value;
        output [7:0] rx_value;
        integer bit_index;
        begin
            rx_value = 8'h00;
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                spi_mosi = tx_value[bit_index];
                #125;
                spi_sck = 1'b1;
                #60;
                rx_value[bit_index] = spi_miso;
                #65;
                spi_sck = 1'b0;
            end
        end
    endtask

    task spi_select;
        begin
            spi_sck  = 1'b0;
            spi_ss_n = 1'b0;
            #200;
        end
    endtask

    task spi_deselect;
        begin
            #125;
            spi_ss_n = 1'b1;
            spi_mosi = 1'b0;
            #200;
        end
    endtask

    task transfer_one;
        input [7:0] tx_value;
        output [7:0] rx_value;
        begin
            spi_select;
            spi_byte(tx_value, rx_value);
            spi_deselect;
        end
    endtask

    task wait_clear_done;
        output integer timed_out;
        integer timeout_count;
        begin
            timeout_count = 0;
            while (dut.clear_active && timeout_count < 2000) begin
                @(posedge clk);
                #1;
                timeout_count = timeout_count + 1;
            end
            timed_out = (timeout_count >= 2000);
        end
    endtask

    task command_reset;
        output [7:0] reset_command_rx;
        output [7:0] reset_ack_rx;
        output integer reset_failed;
        integer clear_timeout;
        begin
            reset_failed = 0;
            clear_write_count = 0;
            clear_sequence_error = 0;
            clear_started = 1'b0;
            monitor_clear = 1'b1;

            transfer_one(CMD_RESET, reset_command_rx);
            transfer_one(CMD_NOP, reset_ack_rx);
            if (reset_ack_rx !== RESET_ACK)
                reset_failed = 1;

            wait_clear_done(clear_timeout);
            monitor_clear = 1'b0;
            if (clear_timeout ||
                clear_write_count != 512 ||
                clear_sequence_error)
                reset_failed = 1;
        end
    endtask

    task command_start;
        output [7:0] start_command_rx;
        output [7:0] start_ack_rx;
        output integer start_failed;
        begin
            start_failed = 0;
            transfer_one(CMD_START, start_command_rx);
            transfer_one(CMD_NOP, start_ack_rx);
            if (start_command_rx !== 8'h00 ||
                start_ack_rx !== START_ACK ||
                dut.protocol_started !== 1'b1)
                start_failed = 1;
        end
    endtask

    task begin_case_monitor;
        input integer is_max_load;
        begin
            monitor_case = 1'b1;
            monitor_max_load = is_max_load;
            normal_write_count = 0;
            normal_read_issue_count = 0;
            normal_read_valid_count = 0;
            bram_access_error = 0;
            read_wait_error = 0;
            read_issue_clock = 0;
            update_active_seen = 0;
            pending_seen = 0;
            merge_seen = 0;
            if (is_max_load) begin
                max_load_write_count = 0;
                max_load_first_write_time = 0;
                max_load_last_write_time = 0;
            end
        end
    endtask

    task run_case;
        input [8*56-1:0] case_name;
        input integer m_value;
        input integer d_value;
        input integer specified_expected;
        input integer check_last_update_wait;
        input integer is_max_load;
        input integer is_required_case;
        integer expected;
        integer reset_failed;
        integer start_failed;
        integer case_failed;
        integer answer_valid;
        integer poll_count;
        integer actual_poll_count;
        integer index;
        integer guard_count;
        integer expected_memory;
        reg [7:0] reset_command_rx;
        reg [7:0] reset_ack_rx;
        reg [7:0] start_command_rx;
        reg [7:0] start_ack_rx;
        reg [7:0] m_rx;
        reg [7:0] d_rx;
        reg [7:0] answer_rx;
        reg [7:0] expected_byte;
        begin
            reference_answer(m_value, d_value, expected);
            case_failed = 0;
            answer_valid = 0;
            answer_rx = 8'h00;
            actual_poll_count = 0;
            guard_count = 0;

            if (expected != specified_expected) begin
                $display(
                    "FAIL %-56s TEST_VECTOR EXPECT=%0d REFERENCE=%0d",
                    case_name, specified_expected, expected
                );
                case_failed = 1;
            end

            command_reset(
                reset_command_rx,
                reset_ack_rx,
                reset_failed
            );
            if (reset_failed) begin
                $display(
                    "FAIL %-56s RESET ACK=%02x CLEAR_WRITES=%0d CLEAR_ERROR=%0d",
                    case_name, reset_ack_rx,
                    clear_write_count, clear_sequence_error
                );
                case_failed = 1;
            end
            if (dut.update_overrun !== 1'b0 ||
                dut.protocol_started !== 1'b0)
                case_failed = 1;

            command_start(
                start_command_rx,
                start_ack_rx,
                start_failed
            );
            if (start_failed) begin
                $display(
                    "FAIL %-56s START COMMAND_RX=%02x ACK=%02x",
                    case_name, start_command_rx, start_ack_rx
                );
                case_failed = 1;
            end

            transfer_one(m_value[7:0], m_rx);
            transfer_one(d_value[7:0], d_rx);
            if (m_rx !== 8'h00 || d_rx !== 8'h00) begin
                $display(
                    "FAIL %-56s M_D_REPLY M_RX=%02x D_RX=%02x",
                    case_name, m_rx, d_rx
                );
                case_failed = 1;
            end

            begin_case_monitor(is_max_load);

            // MicroPython試験と同じく、S全体を1回のCS Lowで送る。
            spi_select;
            for (index = 0; index < m_value; index = index + 1) begin
                if (cells[index] == 8'h01)
                    guard_count = guard_count + 1;
                spi_byte(cells[index], rx_byte);
                if (rx_byte !== 8'h00) begin
                    $display(
                        "FAIL %-56s DATA[%0d] RX=%02x",
                        case_name, index, rx_byte
                    );
                    case_failed = 1;
                end

                if (check_last_update_wait &&
                    index == m_value - 1) begin
                    #1;
                    if (dut.update_active !== 1'b1 ||
                        dut.state !== WAIT_UPDATES ||
                        dut.tx_data[7] !== 1'b0) begin
                        $display(
                            "FAIL %-56s LAST_G_WAIT ACTIVE=%0d STATE=%0d TX=%02x",
                            case_name, dut.update_active,
                            dut.state, dut.tx_data
                        );
                        case_failed = 1;
                    end
                end
            end
            spi_deselect;

            // 回答は1byte遅延なので、VALIDまで上限付きNOPでポーリングする。
            for (poll_count = 1;
                 poll_count <= 16;
                 poll_count = poll_count + 1) begin
                if (!answer_valid) begin
                    transfer_one(CMD_NOP, answer_rx);
                    actual_poll_count = poll_count;
                    if (answer_rx[7] === 1'b1)
                        answer_valid = 1;
                end
            end

            monitor_case = 1'b0;
            monitor_max_load = 1'b0;

            expected_byte = 8'h80 | specified_expected[7:0];
            if (!answer_valid) begin
                $display(
                    "FAIL %-56s VALID_TIMEOUT LAST_RX=%02x",
                    case_name, answer_rx
                );
                case_failed = 1;
            end else if (answer_rx !== expected_byte) begin
                $display(
                    "FAIL %-56s ANSWER RX=%02x EXPECT=%02x",
                    case_name, answer_rx, expected_byte
                );
                case_failed = 1;
            end

            if (dut.update_overrun !== 1'b0) begin
                $display("FAIL %-56s UPDATE_OVERRUN=1", case_name);
                case_failed = 1;
            end
            if (normal_read_issue_count != m_value ||
                normal_read_valid_count != m_value ||
                read_wait_error ||
                bram_access_error) begin
                $display(
                    "FAIL %-56s BRAM READ_REQ=%0d READ_VALID=%0d WAIT_ERROR=%0d ACCESS_ERROR=%0d",
                    case_name, normal_read_issue_count,
                    normal_read_valid_count,
                    read_wait_error, bram_access_error
                );
                case_failed = 1;
            end
            if (guard_count == 0 && normal_write_count != 0) begin
                $display(
                    "FAIL %-56s DOT_CASE_WRITE_COUNT=%0d",
                    case_name, normal_write_count
                );
                case_failed = 1;
            end
            if (guard_count != 0 && !update_active_seen) begin
                $display("FAIL %-56s UPDATE_ACTIVE_NOT_SEEN", case_name);
                case_failed = 1;
            end

            // BRAM 0～M-1は参照結果と一致し、M以降はclear値0のままである。
            for (index = 0; index < 512; index = index + 1) begin
                if (index < m_value)
                    expected_memory =
                        cell_is_watched(index, m_value, d_value);
                else
                    expected_memory = 0;

                if (u_bram0_model.memory[index] !==
                    expected_memory[7:0]) begin
                    $display(
                        "FAIL %-56s MEMORY ADDRESS=%0d DATA=%02x EXPECT=%02x",
                        case_name, index,
                        u_bram0_model.memory[index],
                        expected_memory[7:0]
                    );
                    case_failed = 1;
                end
            end

            if (is_max_load) begin
                if (!merge_seen || max_load_write_count == 0) begin
                    $display(
                        "FAIL %-56s MAX_LOAD MERGE=%0d WRITES=%0d",
                        case_name, merge_seen, max_load_write_count
                    );
                    case_failed = 1;
                end
                $display(
                    "INFO MAX_LOAD WRITES=%0d FIRST_WRITE_NS=%0d LAST_WRITE_NS=%0d MERGE=%0d PENDING=%0d",
                    max_load_write_count,
                    max_load_first_write_time,
                    max_load_last_write_time,
                    merge_seen,
                    pending_seen
                );
            end

            if (case_failed) begin
                fail_count = fail_count + 1;
                if (is_required_case)
                    required_case_fail_count =
                        required_case_fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
                if (is_required_case)
                    required_case_pass_count =
                        required_case_pass_count + 1;
                $display(
                    "PASS %-56s M=%0d D=%0d ANSWER=%0d VALID=1 OVERRUN=0 WRITES=%0d READS=%0d POLLS=%0d",
                    case_name, m_value, d_value,
                    specified_expected, normal_write_count,
                    normal_read_valid_count, actual_poll_count
                );
            end
        end
    endtask

    task test_clear_start_guard;
        integer test_failed;
        integer clear_timeout;
        integer index;
        reg [7:0] reset_command_rx;
        reg [7:0] reset_ack_rx;
        reg [7:0] start_command_rx;
        reg [7:0] start_ack_rx;
        begin
            test_failed = 0;
            clear_write_count = 0;
            clear_sequence_error = 0;
            clear_started = 1'b0;
            monitor_clear = 1'b1;

            transfer_one(CMD_RESET, reset_command_rx);
            transfer_one(CMD_NOP, reset_ack_rx);
            if (reset_command_rx !== 8'h00 ||
                reset_ack_rx !== RESET_ACK)
                test_failed = 1;

            // 20.50usのclear中にSTARTを送り、次byteで非ACK 0x00を確認する。
            transfer_one(CMD_START, start_command_rx);
            transfer_one(CMD_NOP, start_ack_rx);
            if (start_ack_rx !== 8'h00 ||
                dut.protocol_started !== 1'b0)
                test_failed = 1;

            // START拒否後のM、D、S相当データはすべてSTART前ゲートで無視する。
            transfer_one(8'd10, rx_byte);
            transfer_one(8'd3, rx_byte);
            transfer_one(8'h01, rx_byte);
            if (dut.protocol_started !== 1'b0 ||
                dut.m_reg !== 7'd0 ||
                dut.d_reg !== 7'd0 ||
                dut.update_active !== 1'b0 ||
                dut.pending_valid !== 1'b0)
                test_failed = 1;

            wait_clear_done(clear_timeout);
            monitor_clear = 1'b0;
            if (clear_timeout ||
                clear_write_count != 512 ||
                clear_sequence_error)
                test_failed = 1;

            for (index = 0; index < 512; index = index + 1) begin
                if (u_bram0_model.memory[index] !== 8'h00)
                    test_failed = 1;
            end

            // clear完了後にSTARTを再送した場合だけACKを返す。
            transfer_one(CMD_START, start_command_rx);
            transfer_one(CMD_NOP, start_ack_rx);
            if (start_command_rx !== 8'h00 ||
                start_ack_rx !== START_ACK ||
                dut.protocol_started !== 1'b1)
                test_failed = 1;

            if (test_failed) begin
                fail_count = fail_count + 1;
                $display(
                    "FAIL clear_start_guard RESET_ACK=%02x REJECT_ACK=%02x RETRY_ACK=%02x CLEAR_WRITES=%0d",
                    reset_ack_rx, 8'h00,
                    start_ack_rx, clear_write_count
                );
            end else begin
                pass_count = pass_count + 1;
                $display(
                    "PASS clear_start_guard RESET_ACK=5a REJECT_ACK=00 PROTOCOL=0 INPUT_IGNORED=1 RETRY_ACK=a5 CLEAR_WRITES=512"
                );
            end
        end
    endtask

    task test_pending_seamless;
        integer test_failed;
        integer reset_failed;
        integer start_failed;
        integer timeout_count;
        integer first_write_clock;
        integer second_write_clock;
        reg [7:0] reset_command_rx;
        reg [7:0] reset_ack_rx;
        reg [7:0] start_command_rx;
        reg [7:0] start_ack_rx;
        reg [7:0] m_rx;
        reg [7:0] d_rx;
        begin
            test_failed = 0;
            first_write_clock = -1;
            second_write_clock = -1;

            command_reset(
                reset_command_rx,
                reset_ack_rx,
                reset_failed
            );
            command_start(
                start_command_rx,
                start_ack_rx,
                start_failed
            );
            if (reset_failed || start_failed)
                test_failed = 1;

            transfer_one(8'd5, m_rx);
            transfer_one(8'd0, d_rx);

            // BRAMを一時的にbusyとして、G . Gを内部受信クロックで注入する。
            // これは1件保留の単体試験だけに用い、4MHz正常系は実SPIで別途確認する。
            force dut.bram_access_busy = 1'b1;
            force dut.rx_data_strobe = 1'b1;

            force dut.rx_data = 8'h01;
            @(posedge clk);
            #1;
            force dut.rx_data = 8'h00;
            @(posedge clk);
            #1;
            force dut.rx_data = 8'h01;
            @(posedge clk);
            #1;

            release dut.rx_data;
            release dut.rx_data_strobe;

            if (dut.update_active !== 1'b1 ||
                dut.pending_valid !== 1'b1 ||
                dut.pending_start !== 9'd2 ||
                dut.pending_end !== 9'd2 ||
                dut.update_overrun !== 1'b0)
                test_failed = 1;

            release dut.bram_access_busy;

            timeout_count = 0;
            while ((dut.update_active || dut.pending_valid ||
                    dut.bram_access_busy) &&
                   timeout_count < 100) begin
                @(posedge clk);
                #1;
                if (!bram0_wen_n) begin
                    if (first_write_clock < 0)
                        first_write_clock = clock_count;
                    else if (second_write_clock < 0)
                        second_write_clock = clock_count;
                end
                timeout_count = timeout_count + 1;
            end

            if (timeout_count >= 100 ||
                first_write_clock < 0 ||
                second_write_clock - first_write_clock != 2 ||
                u_bram0_model.memory[0] !== 8'h01 ||
                u_bram0_model.memory[2] !== 8'h01 ||
                dut.update_overrun !== 1'b0)
                test_failed = 1;

            if (test_failed) begin
                fail_count = fail_count + 1;
                $display(
                    "FAIL pending_seamless FIRST_CLOCK=%0d SECOND_CLOCK=%0d ACTIVE=%0d PENDING=%0d OVERRUN=%0d",
                    first_write_clock, second_write_clock,
                    dut.update_active, dut.pending_valid,
                    dut.update_overrun
                );
            end else begin
                pass_count = pass_count + 1;
                $display(
                    "PASS pending_seamless ACTIVE_AND_PENDING=1 WRITE_INTERVAL_CLOCKS=2 OVERRUN=0"
                );
            end
        end
    endtask

    task test_overrun_and_reset;
        integer test_failed;
        integer reset_failed;
        integer start_failed;
        reg [7:0] reset_command_rx;
        reg [7:0] reset_ack_rx;
        reg [7:0] start_command_rx;
        reg [7:0] start_ack_rx;
        reg [7:0] m_rx;
        reg [7:0] d_rx;
        begin
            test_failed = 0;

            command_reset(
                reset_command_rx,
                reset_ack_rx,
                reset_failed
            );
            command_start(
                start_command_rx,
                start_ack_rx,
                start_failed
            );
            if (reset_failed || start_failed)
                test_failed = 1;

            transfer_one(8'd5, m_rx);
            transfer_one(8'd0, d_rx);

            // G . G . Gをbusy中に注入し、実行中＋保留1件を意図的に超える。
            force dut.bram_access_busy = 1'b1;
            force dut.rx_data_strobe = 1'b1;

            force dut.rx_data = 8'h01;
            @(posedge clk); #1;
            force dut.rx_data = 8'h00;
            @(posedge clk); #1;
            force dut.rx_data = 8'h01;
            @(posedge clk); #1;
            force dut.rx_data = 8'h00;
            @(posedge clk); #1;
            force dut.rx_data = 8'h01;
            @(posedge clk); #1;

            release dut.rx_data;
            release dut.rx_data_strobe;
            release dut.bram_access_busy;

            if (dut.update_overrun !== 1'b1)
                test_failed = 1;

            command_reset(
                reset_command_rx,
                reset_ack_rx,
                reset_failed
            );
            if (reset_failed ||
                dut.update_overrun !== 1'b0 ||
                dut.update_active !== 1'b0 ||
                dut.pending_valid !== 1'b0 ||
                dut.protocol_started !== 1'b0 ||
                dut.state !== WAIT_START)
                test_failed = 1;

            if (test_failed) begin
                fail_count = fail_count + 1;
                $display("FAIL overrun_and_reset");
            end else begin
                pass_count = pass_count + 1;
                $display(
                    "PASS overrun_and_reset THIRD_DISJOINT_REQUEST_SET=1 RESET_CLEAR=1"
                );
            end
        end
    endtask

    task test_reset_during_processing;
        integer test_failed;
        integer reset_failed;
        integer start_failed;
        integer index;
        reg [7:0] reset_command_rx;
        reg [7:0] reset_ack_rx;
        reg [7:0] start_command_rx;
        reg [7:0] start_ack_rx;
        reg [7:0] m_rx;
        reg [7:0] d_rx;
        begin
            test_failed = 0;

            command_reset(
                reset_command_rx,
                reset_ack_rx,
                reset_failed
            );
            command_start(
                start_command_rx,
                start_ack_rx,
                start_failed
            );
            if (reset_failed || start_failed)
                test_failed = 1;

            transfer_one(8'd100, m_rx);
            transfer_one(8'd99, d_rx);
            spi_select;
            for (index = 0; index < 100; index = index + 1)
                spi_byte((index == 99) ? 8'h01 : 8'h00, rx_byte);
            spi_deselect;

            // 最後の最大範囲更新中にRESETし、進行中処理をclearへ切り替える。
            if (!dut.update_active)
                test_failed = 1;
            command_reset(
                reset_command_rx,
                reset_ack_rx,
                reset_failed
            );
            if (reset_failed ||
                dut.update_active !== 1'b0 ||
                dut.pending_valid !== 1'b0 ||
                dut.update_overrun !== 1'b0 ||
                dut.protocol_started !== 1'b0 ||
                dut.state !== WAIT_START)
                test_failed = 1;

            for (index = 0; index < 512; index = index + 1) begin
                if (u_bram0_model.memory[index] !== 8'h00)
                    test_failed = 1;
            end

            if (test_failed) begin
                fail_count = fail_count + 1;
                $display("FAIL reset_during_processing");
            end else begin
                pass_count = pass_count + 1;
                $display(
                    "PASS reset_during_processing UPDATE_ABORTED=1 CLEAR_WRITES=512 STATE=WAIT_START"
                );
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        spi_ss_n = 1'b1;
        spi_sck = 1'b0;
        spi_mosi = 1'b0;
        pass_count = 0;
        fail_count = 0;
        required_case_pass_count = 0;
        required_case_fail_count = 0;
        clock_count = 0;
        monitor_clear = 1'b0;
        clear_started = 1'b0;
        clear_write_count = 0;
        clear_sequence_error = 0;
        monitor_case = 1'b0;
        monitor_max_load = 1'b0;
        normal_write_count = 0;
        normal_read_issue_count = 0;
        normal_read_valid_count = 0;
        bram_access_error = 0;
        read_wait_error = 0;
        read_issue_clock = 0;
        update_active_seen = 0;
        pending_seen = 0;
        merge_seen = 0;
        max_load_write_count = 0;
        max_load_first_write_time = 0;
        max_load_last_write_time = 0;
        clear_cells;

        #200;
        rst_n = 1'b1;

        // ハードウェアリセットによる512word clear完了を待つ。
        while (dut.clear_active) begin
            @(posedge clk);
            #1;
        end

        if (bram0_ratio !== 2'b00 ||
            bram0_wclken_n !== 1'b0 ||
            bram0_rclken_n !== 1'b0) begin
            fail_count = fail_count + 1;
            $display("FAIL bram_static_ports");
        end else begin
            pass_count = pass_count + 1;
            $display(
                "PASS bram_static_ports RATIO=00 WCLKEN_N=0 RCLKEN_N=0"
            );
        end

        test_clear_start_guard;

        // 公式サンプル3件。
        clear_cells;
        cells[1] = 1; cells[5] = 1; cells[6] = 1;
        run_case("official_sample_1", 7, 1, 1, 0, 0, 1);

        clear_cells;
        run_case("official_sample_2", 6, 5, 6, 0, 0, 1);

        clear_cells;
        cells[4] = 1; cells[8] = 1;
        cells[9] = 1; cells[15] = 1;
        run_case("official_sample_3", 21, 2, 6, 0, 0, 1);

        // 指定された追加8件。
        clear_cells;
        run_case("min_dot", 1, 0, 1, 0, 0, 1);

        clear_cells;
        cells[0] = 1;
        run_case("min_g", 1, 0, 0, 0, 0, 1);

        clear_cells;
        cells[0] = 1;
        run_case("left_edge", 10, 3, 6, 0, 0, 1);

        clear_cells;
        cells[9] = 1;
        run_case("right_edge", 10, 3, 6, 0, 0, 1);

        clear_cells;
        cells[2] = 1; cells[4] = 1;
        run_case("overlap", 10, 2, 3, 0, 0, 1);

        clear_cells;
        run_case("no_g_max", 100, 99, 100, 0, 0, 1);

        clear_cells;
        cells[0] = 1;
        run_case("full_watch", 100, 99, 0, 0, 0, 1);

        fill_guards(100);
        run_case("max_load", 100, 99, 0, 0, 1, 1);

        // 最後の要素の最大範囲更新完了を待つことを直接確認する。
        clear_cells;
        cells[99] = 1;
        run_case("directed_last_g_wait", 100, 99, 0, 1, 0, 0);

        test_pending_seamless;
        test_overrun_and_reset;
        test_reset_during_processing;

        $display(
            "REQUIRED_CASES PASS=%0d FAIL=%0d TOTAL=%0d",
            required_case_pass_count,
            required_case_fail_count,
            required_case_pass_count + required_case_fail_count
        );
        $display(
            "SUMMARY PASS=%0d FAIL=%0d TOTAL=%0d RESULT=%0s",
            pass_count,
            fail_count,
            pass_count + fail_count,
            (fail_count == 0) ? "PASS" : "FAIL"
        );

        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILURES DETECTED");

        $finish;
    end

endmodule
