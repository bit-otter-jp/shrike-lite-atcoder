`timescale 1ns/1ps

module tb_bram0_8bit_template_v3;

    localparam [7:0] CMD_RESET = 8'hFF;
    localparam [7:0] CMD_START = 8'hFE;
    localparam [7:0] RESET_ACK = 8'h5A;
    localparam [7:0] START_ACK = 8'hA5;

    localparam [3:0] CMD_NOP           = 4'h0;
    localparam [3:0] CMD_SET_ADDR_MSB  = 4'h1;
    localparam [3:0] CMD_SET_ADDR_HIGH = 4'h2;
    localparam [3:0] CMD_SET_ADDR_LOW  = 4'h3;
    localparam [3:0] CMD_SET_DATA_HIGH = 4'h4;
    localparam [3:0] CMD_SET_DATA_LOW  = 4'h5;
    localparam [3:0] CMD_WRITE         = 4'h6;
    localparam [3:0] CMD_READ          = 4'h7;

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

    reg [7:0] rx_byte;
    reg [7:0] reset_ack_rx;
    reg [7:0] start_ack_rx;
    reg [7:0] reply_high;
    reg [7:0] reply_low;
    reg [7:0] read_value;
    reg       read_reply_valid;

    integer pass_count;
    integer fail_count;
    integer index;
    integer read_wait_count;
    integer last_read_wait_count;
    reg     read_wait_active;
    reg     normal_write_seen;
    reg     normal_read_seen;
    reg     no_wait_monitor;
    reg     no_wait_write_req_seen;
    reg     no_wait_read_req_seen;
    reg     no_wait_start_accepted;
    reg     no_wait_busy_at_start;
    reg     no_wait_busy_at_operation;
    reg     clear_duration_active;
    time    clear_start_time;
    time    last_clear_duration;

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

    // 50MHzのCustom Moduleクロック。
    initial begin
        clk = 1'b0;
        forever #10 clk = ~clk;
    end

    // BRAM読み出し要求からread_validまでの待ちクロックを観測する。
    always @(negedge bram0_ren_n) begin
        read_wait_count = 0;
        read_wait_active = 1'b1;
    end

    always @(posedge clk) begin
        if (read_wait_active) begin
            #1;
            read_wait_count = read_wait_count + 1;
            if (dut.bram_access_read_valid) begin
                last_read_wait_count = read_wait_count;
                read_wait_active = 1'b0;
            end
        end
    end

    // START後の通常アクセスで、Low有効の書込み・読出し要求を観測する。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            normal_write_seen <= 1'b0;
            normal_read_seen <= 1'b0;
            no_wait_write_req_seen <= 1'b0;
            no_wait_read_req_seen <= 1'b0;
        end else begin
            if (dut.protocol_started && !bram0_wen_n)
                normal_write_seen <= 1'b1;
            if (dut.protocol_started && !bram0_ren_n)
                normal_read_seen <= 1'b1;
            if (no_wait_monitor && dut.bram_write_req)
                no_wait_write_req_seen <= 1'b1;
            if (no_wait_monitor && dut.bram_read_req)
                no_wait_read_req_seen <= 1'b1;
        end
    end

    // コマンドRESETによるclear開始からbusy解除までの実時間を測る。
    always @(posedge dut.bram_clear) begin
        clear_start_time = $time;
        clear_duration_active = 1'b1;
    end

    always @(negedge dut.bram_access_busy) begin
        if (clear_duration_active) begin
            last_clear_duration = $time - clear_start_time;
            clear_duration_active = 1'b0;
        end
    end

    function [7:0] make_command;
        input [3:0] command;
        input [3:0] data;
        begin
            make_command = {command, data};
        end
    endfunction

    task check_byte;
        input [8*64-1:0] name;
        input [7:0] actual;
        input [7:0] expected;
        begin
            if (actual === expected) begin
                pass_count = pass_count + 1;
                $display(
                    "PASS NAME=%0s ACTUAL=0x%02x EXPECT=0x%02x",
                    name,
                    actual,
                    expected
                );
            end else begin
                fail_count = fail_count + 1;
                $display(
                    "FAIL NAME=%0s ACTUAL=0x%02x EXPECT=0x%02x",
                    name,
                    actual,
                    expected
                );
            end
        end
    endtask

    task check_integer;
        input [8*64-1:0] name;
        input integer actual;
        input integer expected;
        begin
            if (actual == expected) begin
                pass_count = pass_count + 1;
                $display(
                    "PASS NAME=%0s ACTUAL=%0d EXPECT=%0d",
                    name,
                    actual,
                    expected
                );
            end else begin
                fail_count = fail_count + 1;
                $display(
                    "FAIL NAME=%0s ACTUAL=%0d EXPECT=%0d",
                    name,
                    actual,
                    expected
                );
            end
        end
    endtask

    // CPOL=0、CPHA=0、MSB first、4MHz相当で1byte転送する。
    // CSの操作は呼出し側で行い、複数回呼べばLow保持バーストになる。
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
                #1;
                rx_value[bit_index] = spi_miso;
                #124;
                spi_sck = 1'b0;
            end
        end
    endtask

    task spi_select;
        begin
            spi_sck = 1'b0;
            spi_ss_n = 1'b0;
            #250;
        end
    endtask

    task spi_deselect;
        begin
            #125;
            spi_ss_n = 1'b1;
            spi_mosi = 1'b0;
            #250;
        end
    endtask

    task send_address;
        input [8:0] address;
        begin
            spi_byte(
                make_command(CMD_SET_ADDR_MSB, {3'b000, address[8]}),
                rx_byte
            );
            spi_byte(
                make_command(CMD_SET_ADDR_HIGH, address[7:4]),
                rx_byte
            );
            spi_byte(
                make_command(CMD_SET_ADDR_LOW, address[3:0]),
                rx_byte
            );
        end
    endtask

    task reset_and_start;
        output [7:0] reset_ack_value;
        output [7:0] start_ack_value;
        begin
            // RESETとACK読出しをCS Lowの2byteバーストで実行する。
            spi_select;
            spi_byte(CMD_RESET, rx_byte);
            spi_byte(make_command(CMD_NOP, 4'h0), reset_ack_value);
            spi_deselect;

            // 512wordのゼロクリア完了を待つ。
            #30000;

            // STARTとACK読出しをCS Lowの2byteバーストで実行する。
            spi_select;
            spi_byte(CMD_START, rx_byte);
            spi_byte(make_command(CMD_NOP, 4'h0), start_ack_value);
            spi_deselect;
        end
    endtask

    // RESET ACK後に待たず、START ACKをアドレス先頭byteで受信してREADする。
    task reset_start_read_no_wait;
        output [7:0] reset_ack_value;
        output [7:0] start_ack_value;
        output start_accepted;
        output busy_at_start;
        output busy_at_read;
        output [7:0] high_reply;
        output [7:0] low_reply;
        begin
            no_wait_write_req_seen = 1'b0;
            no_wait_read_req_seen = 1'b0;
            no_wait_monitor = 1'b1;

            spi_select;
            spi_byte(CMD_RESET, rx_byte);
            spi_byte(make_command(CMD_NOP, 4'h0), reset_ack_value);
            spi_byte(CMD_START, rx_byte);

            start_accepted = dut.protocol_started;
            busy_at_start = dut.bram_access_busy;

            // START ACKは、NOPではなく最初のアドレス設定byteで受信する。
            spi_byte(
                make_command(CMD_SET_ADDR_MSB, 4'h0),
                start_ack_value
            );
            spi_byte(make_command(CMD_SET_ADDR_HIGH, 4'h2), rx_byte);
            spi_byte(make_command(CMD_SET_ADDR_LOW, 4'hA), rx_byte);
            spi_byte(make_command(CMD_READ, 4'h0), rx_byte);

            busy_at_read = dut.bram_access_busy;

            spi_byte(make_command(CMD_NOP, 4'h0), high_reply);
            spi_byte(make_command(CMD_NOP, 4'h0), low_reply);
            spi_deselect;

            no_wait_monitor = 1'b0;
        end
    endtask

    // RESET ACK後に待たず、START ACKをアドレス先頭byteで受信してWRITEする。
    task reset_start_write_no_wait;
        output [7:0] reset_ack_value;
        output [7:0] start_ack_value;
        output start_accepted;
        output busy_at_start;
        output busy_at_write;
        begin
            no_wait_write_req_seen = 1'b0;
            no_wait_read_req_seen = 1'b0;
            no_wait_monitor = 1'b1;

            spi_select;
            spi_byte(CMD_RESET, rx_byte);
            spi_byte(make_command(CMD_NOP, 4'h0), reset_ack_value);
            spi_byte(CMD_START, rx_byte);

            #50;
            start_accepted = dut.protocol_started;
            busy_at_start = dut.bram_access_busy;

            // START ACKは、NOPではなく最初のアドレス設定byteで受信する。
            spi_byte(
                make_command(CMD_SET_ADDR_MSB, 4'h0),
                start_ack_value
            );
            spi_byte(make_command(CMD_SET_ADDR_HIGH, 4'h2), rx_byte);
            spi_byte(make_command(CMD_SET_ADDR_LOW, 4'hA), rx_byte);
            spi_byte(make_command(CMD_SET_DATA_HIGH, 4'hA), rx_byte);
            spi_byte(make_command(CMD_SET_DATA_LOW, 4'h5), rx_byte);
            spi_byte(make_command(CMD_WRITE, 4'h0), rx_byte);

            busy_at_write = dut.bram_access_busy;
            spi_deselect;

            no_wait_monitor = 1'b0;
        end
    endtask

    task write_bram;
        input [8:0] address;
        input [7:0] value;
        begin
            spi_select;
            send_address(address);
            spi_byte(
                make_command(CMD_SET_DATA_HIGH, value[7:4]),
                rx_byte
            );
            spi_byte(
                make_command(CMD_SET_DATA_LOW, value[3:0]),
                rx_byte
            );
            spi_byte(make_command(CMD_WRITE, 4'h0), rx_byte);
            spi_deselect;
        end
    endtask

    task read_bram;
        input [8:0] address;
        output [7:0] value;
        output valid;
        output [7:0] high_reply;
        output [7:0] low_reply;
        begin
            spi_select;
            send_address(address);
            spi_byte(make_command(CMD_READ, 4'h0), rx_byte);
            spi_byte(make_command(CMD_NOP, 4'h0), high_reply);
            spi_byte(make_command(CMD_NOP, 4'h0), low_reply);
            spi_deselect;

            valid =
                (high_reply[7:4] == 4'h8) &&
                (low_reply[7:4] == 4'h9);
            value = {high_reply[3:0], low_reply[3:0]};
        end
    endtask

    task check_read;
        input [8*64-1:0] name;
        input [8:0] address;
        input [7:0] expected;
        begin
            read_bram(
                address,
                read_value,
                read_reply_valid,
                reply_high,
                reply_low
            );
            check_integer(
                {name[8*62-1:0], "-reply"},
                read_reply_valid,
                1
            );
            check_byte(name, read_value, expected);
        end
    endtask

    task check_nop_burst;
        input integer length;
        integer burst_index;
        integer mismatch_count;
        begin
            mismatch_count = 0;
            spi_select;
            for (
                burst_index = 0;
                burst_index < length;
                burst_index = burst_index + 1
            ) begin
                spi_byte(make_command(CMD_NOP, 4'h0), rx_byte);
                if (rx_byte !== 8'h00)
                    mismatch_count = mismatch_count + 1;
            end
            spi_deselect;
            check_integer("nop-burst-mismatch-count", mismatch_count, 0);
            $display(
                "INFO BURST_LENGTH=%0d HALF_PERIOD_NS=125 SPI_HZ=4000000",
                length
            );
        end
    endtask

    initial begin
        rst_n = 1'b0;
        spi_ss_n = 1'b1;
        spi_sck = 1'b0;
        spi_mosi = 1'b0;
        pass_count = 0;
        fail_count = 0;
        read_wait_count = 0;
        last_read_wait_count = 0;
        read_wait_active = 1'b0;
        normal_write_seen = 1'b0;
        normal_read_seen = 1'b0;
        no_wait_monitor = 1'b0;
        no_wait_write_req_seen = 1'b0;
        no_wait_read_req_seen = 1'b0;
        no_wait_start_accepted = 1'b0;
        no_wait_busy_at_start = 1'b0;
        no_wait_busy_at_operation = 1'b0;
        clear_duration_active = 1'b0;
        clear_start_time = 0;
        last_clear_duration = 0;

        #200;
        rst_n = 1'b1;

        // ハードウェアリセット後の全領域クリア完了を待つ。
        #30000;

        // RESET ACK後に待たずSTARTとREADを送る競合再現。
        reset_start_read_no_wait(
            reset_ack_rx,
            start_ack_rx,
            no_wait_start_accepted,
            no_wait_busy_at_start,
            no_wait_busy_at_operation,
            reply_high,
            reply_low
        );
        check_byte("no-wait-read-reset-ack", reset_ack_rx, RESET_ACK);
        check_byte("no-wait-read-start-ack", start_ack_rx, 8'h00);
        check_integer(
            "no-wait-read-start-accepted",
            no_wait_start_accepted,
            0
        );
        check_integer(
            "no-wait-read-busy-at-start",
            no_wait_busy_at_start,
            1
        );
        check_integer(
            "no-wait-read-busy-at-read",
            no_wait_busy_at_operation,
            1
        );
        check_integer(
            "no-wait-read-request-seen",
            no_wait_read_req_seen,
            0
        );
        check_byte("no-wait-read-high-reply", reply_high, 8'h00);
        check_byte("no-wait-read-low-reply", reply_low, 8'h00);

        // 前のclear完了後、待ち時間なしWRITEの競合を再現する。
        #30000;
        reset_start_write_no_wait(
            reset_ack_rx,
            start_ack_rx,
            no_wait_start_accepted,
            no_wait_busy_at_start,
            no_wait_busy_at_operation
        );
        check_byte("no-wait-write-reset-ack", reset_ack_rx, RESET_ACK);
        check_byte("no-wait-write-start-ack", start_ack_rx, 8'h00);
        check_integer(
            "no-wait-write-start-accepted",
            no_wait_start_accepted,
            0
        );
        check_integer(
            "no-wait-write-busy-at-start",
            no_wait_busy_at_start,
            1
        );
        check_integer(
            "no-wait-write-busy-at-write",
            no_wait_busy_at_operation,
            1
        );
        check_integer(
            "no-wait-write-request-seen",
            no_wait_write_req_seen,
            0
        );

        #30000;
        spi_select;
        spi_byte(CMD_START, rx_byte);
        spi_byte(make_command(CMD_NOP, 4'h0), start_ack_rx);
        spi_deselect;
        check_byte(
            "post-clear-retry-start-ack",
            start_ack_rx,
            START_ACK
        );
        check_integer(
            "post-clear-retry-start-accepted",
            dut.protocol_started,
            1
        );
        check_read("no-wait-write-was-lost", 9'd42, 8'h00);
        write_bram(9'd42, 8'hA5);
        check_read("post-clear-write-read", 9'd42, 8'hA5);
        check_integer(
            "command-clear-duration-at-least-20us",
            (last_clear_duration >= 20000),
            1
        );
        $display(
            "INFO COMMAND_CLEAR_DURATION_NS=%0d",
            last_clear_duration
        );

        reset_and_start(reset_ack_rx, start_ack_rx);
        check_byte("reset-ack", reset_ack_rx, RESET_ACK);
        check_byte("start-ack", start_ack_rx, START_ACK);

        // 先頭、中間、最終アドレスと代表値。
        write_bram(9'd0, 8'h00);
        write_bram(9'd1, 8'h01);
        write_bram(9'd255, 8'h55);
        write_bram(9'd256, 8'hAA);
        write_bram(9'd511, 8'hFF);
        check_read("single-address-0", 9'd0, 8'h00);
        check_read("single-address-1", 9'd1, 8'h01);
        check_read("single-address-255", 9'd255, 8'h55);
        check_read("single-address-256", 9'd256, 8'hAA);
        check_read("single-address-511", 9'd511, 8'hFF);

        // 同じアドレスへの上書き。
        write_bram(9'd300, 8'h55);
        write_bram(9'd300, 8'hAA);
        write_bram(9'd300, 8'hFF);
        check_read("overwrite-address-300", 9'd300, 8'hFF);

        // CS Lowを保持し、連続8アドレスへ書き込む。
        spi_select;
        for (index = 0; index < 8; index = index + 1) begin
            send_address(9'd120 + index);
            spi_byte(
                make_command(
                    CMD_SET_DATA_HIGH,
                    ((index * 8'h11) + 8'h03) >> 4
                ),
                rx_byte
            );
            spi_byte(
                make_command(
                    CMD_SET_DATA_LOW,
                    ((index * 8'h11) + 8'h03) & 4'hF
                ),
                rx_byte
            );
            spi_byte(make_command(CMD_WRITE, 4'h0), rx_byte);
        end
        spi_deselect;

        // CS Lowを保持し、同じ8アドレスを連続して読み出す。
        spi_select;
        for (index = 0; index < 8; index = index + 1) begin
            send_address(9'd120 + index);
            spi_byte(make_command(CMD_READ, 4'h0), rx_byte);
            spi_byte(make_command(CMD_NOP, 4'h0), reply_high);
            spi_byte(make_command(CMD_NOP, 4'h0), reply_low);
            read_value = {reply_high[3:0], reply_low[3:0]};
            check_byte(
                "continuous-read",
                read_value,
                (index * 8'h11) + 8'h03
            );
        end
        spi_deselect;

        // BRAMアクセス回路が要求後4クロック待ってread_validを出す。
        check_integer("bram-read-wait-clocks", last_read_wait_count, 4);
        check_integer("bram-write-request-seen", normal_write_seen, 1);
        check_integer("bram-read-request-seen", normal_read_seen, 1);

        // 1、2、16、64、256byteのCS Low保持バースト。
        check_nop_burst(1);
        check_nop_burst(2);
        check_nop_burst(16);
        check_nop_burst(64);
        check_nop_burst(256);

        // 読み出し返信途中のRESETでFSMとACKを初期化する。
        spi_select;
        send_address(9'd300);
        spi_byte(make_command(CMD_READ, 4'h0), rx_byte);
        spi_deselect;

        spi_select;
        spi_byte(CMD_RESET, rx_byte);
        spi_byte(make_command(CMD_NOP, 4'h0), reset_ack_rx);
        spi_deselect;
        check_byte("reset-during-reply-ack", reset_ack_rx, RESET_ACK);

        #30000;
        spi_select;
        spi_byte(CMD_START, rx_byte);
        spi_byte(make_command(CMD_NOP, 4'h0), start_ack_rx);
        spi_deselect;
        check_byte("restart-ack", start_ack_rx, START_ACK);
        check_read("reset-clears-address-300", 9'd300, 8'h00);

        $display(
            "SUMMARY PASS=%0d FAIL=%0d RESULT=%0s",
            pass_count,
            fail_count,
            (fail_count == 0) ? "PASS" : "FAIL"
        );

        $finish;
    end

endmodule
