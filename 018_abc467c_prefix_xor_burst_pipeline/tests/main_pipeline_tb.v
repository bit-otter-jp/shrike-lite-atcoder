`timescale 1ns/1ps

module main_pipeline_tb;
    localparam [7:0] NOP_BYTE   = 8'h00;
    localparam [7:0] RESET_BYTE = 8'he0;

    reg clk;
    reg rst_n;
    reg spi_ss_n;
    reg spi_sck;
    reg spi_mosi;
    wire spi_miso;
    wire spi_miso_en;
    wire clk_en;

    integer failure_count;
    integer executed_count;

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

    always #10 clk = ~clk;

    task check_value;
        input [8*56-1:0] label;
        input [31:0] actual;
        input [31:0] expected;
        begin
            executed_count = executed_count + 1;
            if (actual !== expected) begin
                failure_count = failure_count + 1;
                $display(
                    "CHECK_FAIL %0s actual=0x%08x expected=0x%08x",
                    label,
                    actual,
                    expected
                );
            end
        end
    endtask

    task hardware_reset;
        begin
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            repeat (6) @(posedge clk);
        end
    endtask

    task spi_select;
        begin
            spi_sck = 1'b0;
            spi_ss_n = 1'b0;
            repeat (6) @(posedge clk);
        end
    endtask

    task spi_deselect;
        begin
            spi_sck = 1'b0;
            spi_ss_n = 1'b1;
            repeat (6) @(posedge clk);
        end
    endtask

    // 50MHzの内部クロックに対して約5MHzのSPI mode 0転送を行う。
    task spi_byte;
        input [7:0] tx_value;
        output [7:0] rx_value;
        integer bit_index;
        begin
            rx_value = 8'h00;
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                spi_mosi = tx_value[bit_index];
                repeat (5) @(posedge clk);
                spi_sck = 1'b1;
                #1;
                rx_value[bit_index] = spi_miso;
                repeat (5) @(posedge clk);
                spi_sck = 1'b0;
            end
        end
    endtask

    task spi_transaction;
        input [7:0] tx_value;
        output [7:0] rx_value;
        begin
            spi_select;
            spi_byte(tx_value, rx_value);
            spi_deselect;
        end
    endtask

    task send_header_selected;
        input [17:0] n;
        input a_first;
        reg [7:0] ignored_rx;
        begin
            spi_byte({3'b001, 2'b00, n[17:15]}, ignored_rx);
            spi_byte({3'b010, n[14:10]}, ignored_rx);
            spi_byte({3'b011, n[9:5]}, ignored_rx);
            spi_byte({3'b100, n[4:0]}, ignored_rx);
            spi_byte({3'b101, 4'b0000, a_first}, ignored_rx);
        end
    endtask

    task send_reset_command;
        reg [7:0] ignored_rx;
        begin
            spi_transaction(RESET_BYTE, ignored_rx);
        end
    endtask

    task check_reset_state;
        begin
            check_value("reset n_value", dut.n_value, 0);
            check_value("reset pair_count", dut.pair_count, 0);
            check_value("reset package_count", dut.package_count, 0);
            check_value("reset value_reg", dut.value_reg, 0);
            check_value("reset answer_count", dut.answer_count, 0);
            check_value("reset answer_reg", dut.answer_reg, 0);
            check_value("reset answer_ready", dut.answer_ready, 0);
            check_value("reset count_ok", dut.count_ok, 0);
            check_value("reset protocol_error", dut.protocol_error, 0);
            check_value("reset stream_active", dut.stream_active, 0);
            check_value(
                "reset total_pair_count_reg",
                dut.total_pair_count_reg,
                0
            );
            check_value(
                "reset expected_package_count_reg",
                dut.expected_package_count_reg,
                0
            );
            check_value(
                "reset remaining_pairs_reg",
                dut.remaining_pairs_reg,
                0
            );
            check_value("reset final_pending", dut.final_pending, 0);
            check_value("reset tx_data", dut.tx_data, 0);
        end
    endtask

    task receive_and_check_answer;
        input [8*40-1:0] name;
        input [17:0] expected_answer;
        input expected_count_ok;
        reg [7:0] rx_hi;
        reg [7:0] rx_mid;
        reg [7:0] rx_lo;
        reg [17:0] received_answer;
        begin
            spi_transaction(NOP_BYTE, rx_hi);
            spi_transaction(NOP_BYTE, rx_mid);
            spi_transaction(NOP_BYTE, rx_lo);

            received_answer = {
                rx_hi[1:0],
                rx_mid,
                rx_lo
            };

            check_value({name, " valid"}, rx_hi[7], 1);
            check_value(
                {name, " count_ok"},
                rx_hi[6],
                expected_count_ok
            );
            check_value({name, " reserved"}, rx_hi[5:2], 0);
            check_value(
                {name, " answer"},
                received_answer,
                expected_answer
            );
            check_value(
                {name, " answer_ready_clear"},
                dut.answer_ready,
                0
            );
        end
    endtask

    task run_zero_case;
        input [8*32-1:0] name;
        input [17:0] n;
        integer data_byte_count;
        integer byte_index;
        reg [7:0] ignored_rx;
        begin
            send_reset_command;
            data_byte_count = (n - 1 + 3) / 4;

            spi_select;
            send_header_selected(n, 1'b0);

            check_value(
                {name, " total_init"},
                dut.total_pair_count_reg,
                n - 1
            );
            check_value(
                {name, " expected_init"},
                dut.expected_package_count_reg,
                data_byte_count
            );
            check_value(
                {name, " remaining_init"},
                dut.remaining_pairs_reg,
                n - 1
            );

            if (n <= 5) begin
                check_value(
                    {name, " initial_valid_count"},
                    dut.valid_count,
                    n - 1
                );
            end

            for (
                byte_index = 0;
                byte_index < data_byte_count;
                byte_index = byte_index + 1
            ) begin
                spi_byte(8'h00, ignored_rx);
                if ((n == 6) && (byte_index == 0)) begin
                    check_value(
                        "n6 remaining before tail",
                        dut.remaining_pairs_reg,
                        1
                    );
                    check_value(
                        "n6 valid_count before tail",
                        dut.valid_count,
                        1
                    );
                end
            end
            spi_deselect;

            check_value(
                {name, " final remaining"},
                dut.remaining_pairs_reg,
                0
            );
            check_value(
                {name, " final pair_count"},
                dut.pair_count,
                n - 1
            );
            check_value(
                {name, " final package_count"},
                dut.package_count,
                data_byte_count
            );
            check_value({name, " final_pending_clear"}, dut.final_pending, 0);
            check_value({name, " answer_ready"}, dut.answer_ready, 1);
            check_value({name, " count_ok_internal"}, dut.count_ok, 1);
            check_value(
                {name, " protocol_error_internal"},
                dut.protocol_error,
                0
            );

            receive_and_check_answer(name, 18'd0, 1'b1);
        end
    endtask

    task run_packed_case;
        input [8*32-1:0] name;
        input [17:0] n;
        input a_first;
        input integer data_byte_count;
        input [7:0] data0;
        input [7:0] data1;
        input [7:0] data2;
        input [17:0] expected_answer;
        reg [7:0] ignored_rx;
        begin
            send_reset_command;
            spi_select;
            send_header_selected(n, a_first);
            if (data_byte_count >= 1) begin
                spi_byte(data0, ignored_rx);
            end
            if (data_byte_count >= 2) begin
                spi_byte(data1, ignored_rx);
            end
            if (data_byte_count >= 3) begin
                spi_byte(data2, ignored_rx);
            end
            spi_deselect;

            check_value({name, " count_ok_internal"}, dut.count_ok, 1);
            check_value(
                {name, " protocol_error_internal"},
                dut.protocol_error,
                0
            );
            receive_and_check_answer(
                name,
                expected_answer,
                1'b1
            );
        end
    endtask

    // SPIを待たずにmain内部へ1クロックの受信strobeを与える。
    // 外部プロトコルでは同時発生させられない優先順位試験にだけ使う。
    task inject_internal_byte;
        input [7:0] value;
        begin
            @(negedge clk);
            force dut.rx_data = value;
            force dut.rx_data_strobe = 1'b1;
            @(posedge clk);
            #1;
            release dut.rx_data_strobe;
            release dut.rx_data;
        end
    endtask

    task test_package_shortage;
        reg [7:0] ignored_rx;
        begin
            send_reset_command;
            spi_select;
            send_header_selected(18'd6, 1'b0);
            spi_byte(8'h00, ignored_rx);
            spi_deselect;

            check_value("shortage stream_active", dut.stream_active, 1);
            check_value("shortage answer_ready", dut.answer_ready, 0);
            check_value("shortage remaining", dut.remaining_pairs_reg, 1);
            check_value("shortage pair_count", dut.pair_count, 4);
            check_value("shortage package_count", dut.package_count, 1);
            hardware_reset;
        end
    endtask

    task test_extra_package_guard;
        reg [7:0] ignored_rx;
        reg [17:0] answer_before;
        begin
            send_reset_command;
            spi_select;
            send_header_selected(18'd2, 1'b0);
            spi_deselect;

            answer_before = dut.answer_count;
            force dut.remaining_pairs_reg = 18'd0;
            spi_transaction(8'hff, ignored_rx);
            release dut.remaining_pairs_reg;
            repeat (3) @(posedge clk);

            check_value("extra protocol_error", dut.protocol_error, 1);
            check_value("extra stream_active", dut.stream_active, 0);
            check_value("extra answer_unchanged", dut.answer_count, answer_before);
            check_value("extra pair_unchanged", dut.pair_count, 0);
            check_value("extra package_unchanged", dut.package_count, 0);
            hardware_reset;
        end
    endtask

    task prepare_internal_final;
        begin
            send_reset_command;
            spi_select;
            send_header_selected(18'd2, 1'b0);
            spi_deselect;
            inject_internal_byte(8'h00);
            check_value("internal final pending", dut.final_pending, 1);
            check_value("internal final answer_count", dut.answer_count, 0);
            check_value("internal final pair_count", dut.pair_count, 1);
            check_value("internal final package_count", dut.package_count, 1);
        end
    endtask

    task test_reset_command_during_pending;
        begin
            prepare_internal_final;
            inject_internal_byte(RESET_BYTE);
            check_reset_state;
        end
    endtask

    task test_hardware_reset_during_pending;
        begin
            prepare_internal_final;
            rst_n = 1'b0;
            #1;
            check_reset_state;
            repeat (2) @(posedge clk);
            rst_n = 1'b1;
            repeat (4) @(posedge clk);
        end
    endtask

    task test_strobe_during_pending;
        begin
            prepare_internal_final;
            inject_internal_byte(8'h00);
            check_value("pending extra final_pending", dut.final_pending, 0);
            check_value("pending extra stream_active", dut.stream_active, 0);
            check_value("pending extra answer_ready", dut.answer_ready, 0);
            check_value("pending extra count_ok", dut.count_ok, 0);
            check_value("pending extra protocol_error", dut.protocol_error, 1);
            check_value("pending extra pair_count", dut.pair_count, 1);
            check_value("pending extra package_count", dut.package_count, 1);
            hardware_reset;
        end
    endtask

    task test_stage2_tx_hold_collision;
        begin
            prepare_internal_final;
            @(negedge clk);
            force dut.u_spi_target.o_tx_data_hold = 1'b1;
            @(posedge clk);
            #1;
            check_value(
                "stage2 hold loaded header",
                dut.u_spi_target.r_miso_data,
                8'hc0
            );
            check_value("stage2 final_pending clear", dut.final_pending, 0);
            check_value("stage2 tx_data header", dut.tx_data, 8'hc0);
            release dut.u_spi_target.o_tx_data_hold;
            hardware_reset;
        end
    endtask

    task test_count_mismatch;
        begin
            prepare_internal_final;
            force dut.expected_package_count_reg = 17'd2;
            @(posedge clk);
            #1;
            release dut.expected_package_count_reg;
            check_value("mismatch answer_ready", dut.answer_ready, 1);
            check_value("mismatch count_ok", dut.count_ok, 0);
            check_value("mismatch protocol_error", dut.protocol_error, 1);
            check_value("mismatch header", dut.tx_data, 8'h80);
            hardware_reset;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b1;
        spi_ss_n = 1'b1;
        spi_sck = 1'b0;
        spi_mosi = 1'b0;
        failure_count = 0;
        executed_count = 0;

        hardware_reset;
        check_reset_state;

        send_reset_command;
        check_reset_state;

        // 公式サンプル。
        run_packed_case(
            "official_sample_1",
            18'd3,
            1'b1,
            1,
            8'hf0,
            8'h00,
            8'h00,
            18'd1
        );
        run_packed_case(
            "official_sample_2",
            18'd2,
            1'b1,
            1,
            8'h80,
            8'h00,
            8'h00,
            18'd0
        );
        run_packed_case(
            "official_sample_3",
            18'd10,
            1'b0,
            3,
            8'h1b,
            8'h33,
            8'h00,
            18'd4
        );

        // N=2～6で最終パッケージの有効組数1～4と次パッケージを確認する。
        run_zero_case("zero_n2_tail1", 18'd2);
        run_zero_case("zero_n3_tail2", 18'd3);
        run_zero_case("zero_n4_tail3", 18'd4);
        run_zero_case("zero_n5_tail4", 18'd5);
        run_zero_case("zero_n6_second_tail1", 18'd6);

        // 18bitプロトコル最大Nと17bit package_count上限を確認する。
        run_zero_case("zero_protocol_max", 18'h3ffff);

        test_package_shortage;
        test_extra_package_guard;
        test_reset_command_during_pending;
        test_hardware_reset_during_pending;
        test_strobe_during_pending;
        test_stage2_tx_hold_collision;
        test_count_mismatch;

        if (failure_count == 0) begin
            $display(
                "TEST_PASS checks=%0d failures=%0d",
                executed_count,
                failure_count
            );
        end else begin
            $display(
                "TEST_FAIL checks=%0d failures=%0d",
                executed_count,
                failure_count
            );
        end

        $finish;
    end
endmodule
