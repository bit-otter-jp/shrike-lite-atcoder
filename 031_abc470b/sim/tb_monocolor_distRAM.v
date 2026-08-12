`timescale 1ns/1ps

module tb_monocolor_distRAM;
    localparam [7:0] CMD_NOP   = 8'h00;
    localparam [7:0] CMD_RESET = 8'hFF;
    localparam [7:0] CMD_START = 8'hFE;
    localparam [7:0] RESET_ACK = 8'h5A;
    localparam [7:0] START_ACK = 8'hA5;

    localparam [2:0] WAIT_START    = 3'd0;
    localparam [2:0] RECEIVE_C     = 3'd2;
    localparam [2:0] RMW_READ      = 3'd3;
    localparam [2:0] RMW_CAPTURE   = 3'd4;
    localparam [2:0] RMW_WRITE     = 3'd5;
    localparam [2:0] PREPARE_REPLY = 3'd6;

    reg clk;
    reg rst_n;
    reg spi_ss_n;
    reg spi_sck;
    reg spi_mosi;
    wire spi_miso;
    wire spi_miso_en;
    wire clk_en;

    reg [7:0] colors [0:99];
    integer reference_counts [0:100];
    integer observed_counts [0:100];
    integer pass_count;
    integer fail_count;
    integer random_seed;
    integer random_value;
    integer i;

    // START後の逐次初期化と各色のRMW順序をクロック単位で監視する。
    reg monitor_init;
    reg monitor_rmw;
    reg [2:0] previous_state;
    integer active_n;
    integer init_write_count;
    integer init_sequence_error;
    integer early_color_error;
    integer rmw_read_count;
    integer rmw_capture_count;
    integer rmw_write_count;
    integer rmw_sequence_error;
    integer early_valid_error;
    integer valid_seen;

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

    always @(posedge clk) begin
        if (!rst_n) begin
            previous_state = WAIT_START;
        end else begin
            if (monitor_init && dut.ram_write_enable && dut.init_active) begin
                if (dut.ram_write_address !== init_write_count + 7'd1 ||
                    dut.ram_write_data !== 7'd0)
                    init_sequence_error = 1;
                init_write_count = init_write_count + 1;
            end

            if (monitor_rmw) begin
                if (dut.rx_data_strobe &&
                    dut.state == RECEIVE_C &&
                    !dut.init_done)
                    early_color_error = 1;

                if (dut.state == RMW_READ) begin
                    if (!dut.ram_read_enable ||
                        dut.ram_read_address !== colors[rmw_read_count][6:0])
                        rmw_sequence_error = 1;
                    rmw_read_count = rmw_read_count + 1;
                end

                if (dut.state == RMW_CAPTURE) begin
                    if (previous_state !== RMW_READ)
                        rmw_sequence_error = 1;
                    rmw_capture_count = rmw_capture_count + 1;
                end

                if (dut.state == RMW_WRITE) begin
                    if (previous_state !== RMW_CAPTURE ||
                        !dut.ram_write_enable ||
                        dut.ram_write_address !==
                            colors[rmw_write_count][6:0])
                        rmw_sequence_error = 1;

                    observed_counts[dut.color_address] =
                        observed_counts[dut.color_address] + 1;
                    if (dut.new_count !==
                        observed_counts[dut.color_address][6:0] ||
                        dut.ram_write_data !== dut.new_count)
                        rmw_sequence_error = 1;
                    rmw_write_count = rmw_write_count + 1;
                end

                if (dut.tx_data[7] && !valid_seen) begin
                    valid_seen = 1;
                    if (previous_state !== PREPARE_REPLY ||
                        rmw_write_count != active_n)
                        early_valid_error = 1;
                end
            end

            previous_state = dut.state;
        end
    end

    task clear_colors;
        integer index;
        begin
            for (index = 0; index < 100; index = index + 1)
                colors[index] = 8'd1;
        end
    endtask

    task fill_same;
        input integer length;
        input integer color;
        integer index;
        begin
            clear_colors;
            for (index = 0; index < length; index = index + 1)
                colors[index] = color[7:0];
        end
    endtask

    task fill_different;
        input integer length;
        integer index;
        begin
            clear_colors;
            for (index = 0; index < length; index = index + 1)
                colors[index] = index + 1;
        end
    endtask

    task fill_random;
        input integer length;
        integer index;
        begin
            clear_colors;
            for (index = 0; index < length; index = index + 1) begin
                random_value = $random(random_seed);
                colors[index] =
                    ((random_value & 32'h7fffffff) % length) + 1;
            end
        end
    endtask

    task reference_answer;
        input integer n_value;
        output integer expected;
        integer index;
        integer maximum;
        begin
            for (index = 0; index <= 100; index = index + 1)
                reference_counts[index] = 0;
            for (index = 0; index < n_value; index = index + 1)
                reference_counts[colors[index]] =
                    reference_counts[colors[index]] + 1;

            maximum = 0;
            for (index = 1; index <= n_value; index = index + 1) begin
                if (reference_counts[index] > maximum)
                    maximum = reference_counts[index];
            end
            expected = n_value - maximum;
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
        input integer n_value;
        input integer reset_before;
        integer expected;
        integer index;
        integer poll_index;
        integer answer_valid;
        integer case_failed;
        reg [7:0] rx_byte;
        reg [7:0] expected_byte;
        begin
            reference_answer(n_value, expected);
            case_failed = 0;
            answer_valid = 0;

            if (reset_before) begin
                transfer_one(CMD_RESET, rx_byte);
                transfer_one(CMD_NOP, rx_byte);
                if (rx_byte !== RESET_ACK) begin
                    $display("FAIL %-48s RESET_ACK RX=%02x", case_name, rx_byte);
                    case_failed = 1;
                end
            end

            init_write_count = 0;
            init_sequence_error = 0;
            monitor_init = 1'b1;

            transfer_one(CMD_START, rx_byte);

            // NとC[0]～C[N-1]を1回のCS Lowで連続転送する。
            select_spi;
            spi_byte(n_value[7:0], rx_byte);
            if (rx_byte !== START_ACK) begin
                $display("FAIL %-48s START_ACK RX=%02x", case_name, rx_byte);
                case_failed = 1;
            end

            #1;
            monitor_init = 1'b0;
            if (dut.init_active !== 1'b0 || dut.init_done !== 1'b1) begin
                $display("FAIL %-48s INIT_NOT_FINISHED_BEFORE_C0", case_name);
                case_failed = 1;
            end
            if (init_write_count != 100 || init_sequence_error) begin
                $display(
                    "FAIL %-48s INIT_SEQUENCE WRITES=%0d ERROR=%0d",
                    case_name, init_write_count, init_sequence_error
                );
                case_failed = 1;
            end
            for (index = 1; index <= 100; index = index + 1) begin
                if (dut.u_count_ram.mem_ram[index] !== 7'd0) begin
                    $display(
                        "FAIL %-48s INIT_MEMORY ADDRESS=%0d DATA=%0d",
                        case_name, index,
                        dut.u_count_ram.mem_ram[index]
                    );
                    case_failed = 1;
                end
            end

            active_n = n_value;
            rmw_read_count = 0;
            rmw_capture_count = 0;
            rmw_write_count = 0;
            rmw_sequence_error = 0;
            early_color_error = 0;
            early_valid_error = 0;
            valid_seen = 0;
            for (index = 0; index <= 100; index = index + 1)
                observed_counts[index] = 0;
            monitor_rmw = 1'b1;

            for (index = 0; index < n_value; index = index + 1) begin
                spi_byte(colors[index], rx_byte);
                if (rx_byte !== 8'h00) begin
                    $display(
                        "FAIL %-48s DATA[%0d] RX=%02x",
                        case_name, index, rx_byte
                    );
                    case_failed = 1;
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

            monitor_rmw = 1'b0;
            expected_byte = {1'b1, expected[6:0]};
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

            if (rmw_read_count != n_value ||
                rmw_capture_count != n_value ||
                rmw_write_count != n_value ||
                rmw_sequence_error) begin
                $display(
                    "FAIL %-48s RMW READ=%0d CAPTURE=%0d WRITE=%0d ERROR=%0d",
                    case_name, rmw_read_count, rmw_capture_count,
                    rmw_write_count, rmw_sequence_error
                );
                case_failed = 1;
            end
            if (early_color_error) begin
                $display("FAIL %-48s C0_BEFORE_INIT_DONE", case_name);
                case_failed = 1;
            end
            if (early_valid_error) begin
                $display("FAIL %-48s VALID_BEFORE_FINAL_RMW", case_name);
                case_failed = 1;
            end
            if (dut.max_count !== n_value - expected) begin
                $display(
                    "FAIL %-48s MAX_COUNT=%0d EXPECT=%0d",
                    case_name, dut.max_count, n_value - expected
                );
                case_failed = 1;
            end
            for (index = 1; index <= 100; index = index + 1) begin
                if (dut.u_count_ram.mem_ram[index] !==
                    reference_counts[index][6:0]) begin
                    $display(
                        "FAIL %-48s RAM ADDRESS=%0d DATA=%0d EXPECT=%0d",
                        case_name, index,
                        dut.u_count_ram.mem_ram[index],
                        reference_counts[index]
                    );
                    case_failed = 1;
                end
            end

            if (case_failed) begin
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
                $display(
                    "PASS %-48s N=%0d ANSWER=%0d VALID=1 INIT_WRITES=100 RMW=%0d",
                    case_name, n_value, expected, rmw_write_count
                );
            end
        end
    endtask

    task test_reset_clears_result;
        integer case_failed;
        reg [7:0] rx_byte;
        reg [6:0] ram_before_reset;
        begin
            case_failed = 0;
            ram_before_reset = dut.u_count_ram.mem_ram[1];
            if (dut.tx_data[7] !== 1'b1) begin
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
            if (dut.u_count_ram.mem_ram[1] !== ram_before_reset) begin
                $display("FAIL reset_clears_previous_result RAM_CHANGED");
                case_failed = 1;
            end

            transfer_one(CMD_NOP, rx_byte);
            if (rx_byte !== 8'h00 ||
                dut.state !== WAIT_START ||
                dut.init_active !== 1'b0 ||
                dut.init_done !== 1'b0 ||
                dut.received_count !== 7'd0 ||
                dut.max_count !== 7'd0 ||
                dut.tx_data !== 8'h00) begin
                $display("FAIL reset_clears_previous_result STALE_STATE");
                case_failed = 1;
            end

            if (case_failed) begin
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
                $display(
                    "PASS reset_clears_previous_result ACK=5a STALE=0 RAM_UNCHANGED=1"
                );
            end
        end
    endtask

    initial begin
        rst_n                = 1'b0;
        spi_ss_n             = 1'b1;
        spi_sck              = 1'b0;
        spi_mosi             = 1'b0;
        pass_count           = 0;
        fail_count           = 0;
        random_seed          = 32'h0470b123;
        random_value         = 0;
        monitor_init         = 1'b0;
        monitor_rmw          = 1'b0;
        previous_state       = WAIT_START;
        active_n             = 0;
        init_write_count     = 0;
        init_sequence_error  = 0;
        early_color_error    = 0;
        rmw_read_count       = 0;
        rmw_capture_count    = 0;
        rmw_write_count      = 0;
        rmw_sequence_error   = 0;
        early_valid_error    = 0;
        valid_seen           = 0;
        clear_colors;

        #200;
        rst_n = 1'b1;
        #400;

        // 公式サンプル3件。
        clear_colors;
        colors[0] = 3; colors[1] = 1; colors[2] = 2; colors[3] = 1;
        run_case("sample1", 4, 1);

        fill_same(5, 3);
        run_case("sample2_start_without_reset", 5, 0);

        clear_colors;
        colors[0] = 4; colors[1] = 2; colors[2] = 3;
        colors[3] = 3; colors[4] = 4; colors[5] = 1;
        colors[6] = 2; colors[7] = 7; colors[8] = 1;
        run_case("sample3", 9, 1);

        // SPEC.mdに記載された境界・最大負荷ケース。
        fill_same(1, 1);
        run_case("min_n1", 1, 1);

        fill_same(100, 100);
        run_case("all_same_max_4mhz", 100, 1);

        fill_different(100);
        run_case("all_different_address_100", 100, 1);

        clear_colors;
        for (i = 0; i < 50; i = i + 1)
            colors[i] = 1;
        for (i = 50; i < 100; i = i + 1)
            colors[i] = 2;
        run_case("two_colors_equal", 100, 1);

        clear_colors;
        for (i = 0; i < 9; i = i + 1)
            colors[i] = i + 1;
        colors[9] = 9;
        run_case("max_updates_on_last_input", 10, 1);

        clear_colors;
        colors[0] = 1; colors[1] = 1; colors[2] = 1; colors[3] = 1;
        colors[4] = 2; colors[5] = 2; colors[6] = 2; colors[7] = 2;
        run_case("repeated_consecutive", 8, 1);

        // RESETを挟まずSTARTだけで前回RAM内容を消去する。
        fill_same(6, 1);
        run_case("start_reuse_first", 6, 1);
        fill_different(6);
        run_case("start_reuse_second_no_reset", 6, 0);

        // 固定seedのランダムケースを単純参照モデルと比較する。
        fill_random(2);
        run_case("random_fixed_seed_n2", 2, 1);
        fill_random(7);
        run_case("random_fixed_seed_n7", 7, 1);
        fill_random(16);
        run_case("random_fixed_seed_n16", 16, 1);
        fill_random(31);
        run_case("random_fixed_seed_n31", 31, 1);
        fill_random(64);
        run_case("random_fixed_seed_n64", 64, 1);
        fill_random(100);
        run_case("random_fixed_seed_n100", 100, 1);

        // RESET ACK、旧回答消去、RAM本体をRESETしないことを確認する。
        test_reset_clears_result;

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
