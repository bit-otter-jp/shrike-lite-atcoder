`timescale 1ns/1ps

module tb_abc468a;

    // ===== 50MHz FPGAクロックと実SPI端子 =====
    reg clk;
    reg rst_n;
    reg spi_ss_n;
    reg spi_sck;
    reg spi_mosi;

    wire clk_en;
    wire spi_miso;
    wire spi_miso_en;

    localparam integer SPI_HALF_PERIOD_NS = 125;

    reg [7:0] burst_data [0:99];
    integer check_count;
    integer fail_count;
    integer index;

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

    initial begin
        clk = 1'b0;
        forever #10 clk = ~clk;
    end

    // ===== SPI Mode 0、4MHz相当の1byte転送 =====
    task spi_select;
        begin
            spi_sck = 1'b0;
            spi_ss_n = 1'b0;
            // 非同期SPI入力が50MHz側へ同期される時間を確保する。
            #(SPI_HALF_PERIOD_NS * 2);
        end
    endtask

    task spi_deselect;
        begin
            #(SPI_HALF_PERIOD_NS);
            spi_ss_n = 1'b1;
            spi_sck = 1'b0;
            spi_mosi = 1'b0;
            #(SPI_HALF_PERIOD_NS * 2);
        end
    endtask

    task spi_transfer_byte;
        input [7:0] tx_byte;
        output reg [7:0] rx_byte;
        integer bit_index;
        begin
            rx_byte = 8'h00;
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                spi_mosi = tx_byte[bit_index];
                #SPI_HALF_PERIOD_NS;
                spi_sck = 1'b1;
                // 同期回路がSCK立上りを検出した後にMISOを読む。
                #60;
                rx_byte[bit_index] = spi_miso;
                #(SPI_HALF_PERIOD_NS - 60);
                spi_sck = 1'b0;
            end
        end
    endtask

    task spi_transaction;
        input [7:0] tx_byte;
        output reg [7:0] rx_byte;
        begin
            spi_select;
            spi_transfer_byte(tx_byte, rx_byte);
            spi_deselect;
        end
    endtask

    // ===== CS Lowを保持した配列バースト転送 =====
    task send_array_burst;
        input integer length;
        integer data_index;
        reg [7:0] rx_discard;
        begin
            spi_select;
            for (
                data_index = 0;
                data_index < length;
                data_index = data_index + 1
            ) begin
                spi_transfer_byte(burst_data[data_index], rx_discard);
            end
            spi_deselect;
        end
    endtask

    task clear_array;
        integer clear_index;
        begin
            for (
                clear_index = 0;
                clear_index < 100;
                clear_index = clear_index + 1
            ) begin
                burst_data[clear_index] = 8'h00;
            end
        end
    endtask

    // ===== Python側と同じ山の参照計算 =====
    function integer reference_answer;
        input integer length;
        integer answer_index;
        integer answer;
        begin
            answer = 0;
            for (
                answer_index = 0;
                answer_index < length - 2;
                answer_index = answer_index + 1
            ) begin
                if (
                    burst_data[answer_index] <
                    burst_data[answer_index + 1] &&
                    burst_data[answer_index + 1] >
                    burst_data[answer_index + 2]
                ) begin
                    answer = answer + 1;
                end
            end
            reference_answer = answer;
        end
    endfunction

    task check_byte;
        input [8*48-1:0] check_name;
        input [7:0] actual;
        input [7:0] expected;
        begin
            check_count = check_count + 1;
            if (actual === expected) begin
                $display(
                    "PASS %-48s RX=%02X EXPECT=%02X",
                    check_name,
                    actual,
                    expected
                );
            end else begin
                fail_count = fail_count + 1;
                $display(
                    "FAIL %-48s RX=%02X EXPECT=%02X",
                    check_name,
                    actual,
                    expected
                );
            end
        end
    endtask

    // ===== 1byte遅延を含むRESET、START手順 =====
    task reset_protocol;
        output reg [7:0] reset_ack;
        reg [7:0] rx_discard;
        begin
            spi_transaction(8'hFF, rx_discard);
            spi_transaction(8'h00, reset_ack);
        end
    endtask

    task start_protocol;
        input integer length;
        output reg [7:0] start_ack;
        reg [7:0] rx_discard;
        begin
            spi_transaction(8'hFE, rx_discard);
            spi_transaction(length, start_ack);
        end
    endtask

    // ===== 1ケース分の通常通信とDONE保持確認 =====
    task run_case;
        input [8*32-1:0] case_name;
        input integer length;
        integer expected_answer;
        reg [7:0] expected_reply;
        reg [7:0] reset_ack;
        reg [7:0] start_ack;
        reg [7:0] reply;
        reg [7:0] held_reply;
        begin
            expected_answer = reference_answer(length);
            expected_reply = 8'h80 | expected_answer;
            $display(
                "CASE %-32s N=%0d EXPECT=%0d",
                case_name,
                length,
                expected_answer
            );

            reset_protocol(reset_ack);
            check_byte("RESET_ACK", reset_ack, 8'h5A);

            start_protocol(length, start_ack);
            check_byte("START_ACK", start_ack, 8'hA5);

            send_array_burst(length);
            // 回答用NOPは配列バーストと別トランザクションにする。
            spi_transaction(8'h00, reply);
            check_byte(case_name, reply, expected_reply);

            // DONE状態の回答がNOPで消えないことを確認する。
            spi_transaction(8'h00, held_reply);
            check_byte("DONE_HOLD", held_reply, expected_reply);
        end
    endtask

    // ===== START前のDEBUG予約値と通常値の無視確認 =====
    task run_wait_start_filter_test;
        reg [7:0] reset_ack;
        reg [7:0] start_ack;
        reg [7:0] reply;
        reg [7:0] rx_discard;
        begin
            $display("CASE WAIT_START_FILTER");
            reset_protocol(reset_ack);
            check_byte("WAIT_START_FILTER RESET_ACK", reset_ack, 8'h5A);

            spi_transaction(8'hFD, rx_discard);
            spi_transaction(8'h03, rx_discard);

            start_protocol(3, start_ack);
            check_byte(
                "FD_AND_NORMAL_VALUE_DO_NOT_START",
                start_ack,
                8'hA5
            );

            clear_array;
            burst_data[0] = 8'd1;
            burst_data[1] = 8'd3;
            burst_data[2] = 8'd2;
            send_array_burst(3);
            spi_transaction(8'h00, reply);
            check_byte("WAIT_START_FILTER REPLY", reply, 8'h81);
        end
    endtask

    // ===== 配列受信途中のSPI RESETと次ケースの回復確認 =====
    task run_interrupted_reset_test;
        reg [7:0] reset_ack;
        reg [7:0] start_ack;
        reg [7:0] reply;
        reg [7:0] rx_discard;
        begin
            $display("CASE RESET_DURING_ARRAY");
            clear_array;
            burst_data[0] = 8'd1;
            burst_data[1] = 8'd4;
            burst_data[2] = 8'd2;
            burst_data[3] = 8'd5;
            burst_data[4] = 8'd1;

            reset_protocol(reset_ack);
            check_byte("INTERRUPTED RESET_ACK", reset_ack, 8'h5A);
            start_protocol(5, start_ack);
            check_byte("INTERRUPTED START_ACK", start_ack, 8'hA5);

            // 5要素中2要素だけを送り、RECEIVE_A中にRESETする。
            send_array_burst(2);
            spi_transaction(8'hFF, rx_discard);
            spi_transaction(8'h00, reset_ack);
            check_byte("RESET_DURING_ARRAY ACK", reset_ack, 8'h5A);

            // RESET後は新しいケースをSTARTから正常に開始する。
            start_protocol(3, start_ack);
            check_byte("RECOVERY START_ACK", start_ack, 8'hA5);
            clear_array;
            burst_data[0] = 8'd1;
            burst_data[1] = 8'd3;
            burst_data[2] = 8'd2;
            send_array_burst(3);
            spi_transaction(8'h00, reply);
            check_byte("RECOVERY REPLY", reply, 8'h81);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        spi_ss_n = 1'b1;
        spi_sck = 1'b0;
        spi_mosi = 1'b0;
        check_count = 0;
        fail_count = 0;
        clear_array;

        #200;
        rst_n = 1'b1;
        #200;

        run_wait_start_filter_test;

        clear_array;
        burst_data[0] = 8'd1;
        burst_data[1] = 8'd2;
        burst_data[2] = 8'd3;
        run_case("N3_NO_PEAK", 3);

        clear_array;
        burst_data[0] = 8'd1;
        burst_data[1] = 8'd3;
        burst_data[2] = 8'd2;
        run_case("N3_ONE_PEAK", 3);

        clear_array;
        for (index = 0; index < 6; index = index + 1) begin
            burst_data[index] = 8'd7;
        end
        run_case("ALL_EQUAL", 6);

        clear_array;
        for (index = 0; index < 6; index = index + 1) begin
            burst_data[index] = index + 1;
        end
        run_case("MONOTONIC_INCREASE", 6);

        clear_array;
        for (index = 0; index < 6; index = index + 1) begin
            burst_data[index] = 6 - index;
        end
        run_case("MONOTONIC_DECREASE", 6);

        clear_array;
        burst_data[0] = 8'd1;
        burst_data[1] = 8'd3;
        burst_data[2] = 8'd1;
        burst_data[3] = 8'd4;
        burst_data[4] = 8'd2;
        burst_data[5] = 8'd5;
        burst_data[6] = 8'd1;
        run_case("MULTIPLE_PEAKS", 7);

        clear_array;
        burst_data[0] = 8'd1;
        burst_data[1] = 8'd5;
        burst_data[2] = 8'd2;
        burst_data[3] = 8'd3;
        burst_data[4] = 8'd4;
        run_case("FIRST_THREE_PEAK", 5);

        clear_array;
        burst_data[0] = 8'd1;
        burst_data[1] = 8'd2;
        burst_data[2] = 8'd3;
        burst_data[3] = 8'd5;
        burst_data[4] = 8'd4;
        run_case("LAST_THREE_PEAK", 5);

        clear_array;
        burst_data[0] = 8'd1;
        burst_data[1] = 8'd2;
        burst_data[2] = 8'd3;
        burst_data[3] = 8'd1;
        run_case("LAST_A_ADDS", 4);

        clear_array;
        burst_data[0] = 8'd100;
        burst_data[1] = 8'd1;
        burst_data[2] = 8'd1;
        run_case("SENTINEL_NO_FALSE_ADD", 3);

        clear_array;
        for (index = 0; index < 100; index = index + 1) begin
            if ((index & 1) == 0) begin
                burst_data[index] = 8'd1;
            end else begin
                burst_data[index] = 8'd100;
            end
        end
        run_case("N100_ALTERNATING", 100);

        run_interrupted_reset_test;

        if (fail_count == 0) begin
            $display(
                "SIMULATION PASS CHECKS=%0d FAIL=%0d",
                check_count,
                fail_count
            );
        end else begin
            $display(
                "SIMULATION FAIL CHECKS=%0d FAIL=%0d",
                check_count,
                fail_count
            );
        end

        #1000;
        $finish;
    end

endmodule
