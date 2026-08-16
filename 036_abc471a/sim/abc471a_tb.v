`timescale 1ns/1ps

module abc471a_tb;
    localparam integer CLK_HALF_NS = 10;
    localparam integer SPI_HALF_NS = 125;

    localparam [7:0] CMD_NOP   = 8'h00;
    localparam [7:0] CMD_START = 8'hFE;
    localparam [7:0] CMD_RESET = 8'hFF;
    localparam [7:0] RESET_ACK = 8'h5A;
    localparam [7:0] START_ACK = 8'hA5;

    reg clk;
    reg rst_n;
    reg spi_ss_n;
    reg spi_sck;
    reg spi_mosi;

    wire clk_en;
    wire spi_miso;
    wire spi_miso_en;

    integer a;
    integer b;
    integer exhaustive_count;
    integer protocol_count;
    integer failure_count;

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

    always #CLK_HALF_NS clk = ~clk;

    function integer reference_nine;
        input integer a_value;
        input integer b_value;
        begin
            reference_nine =
                ((a_value + b_value) == 9) ||
                ((a_value - b_value) == 9) ||
                ((a_value * b_value) == 9) ||
                (a_value == (9 * b_value));
        end
    endfunction

    // CSがLowの間にSPI mode 0、MSB firstで1byte転送する。
    task spi_shift_byte;
        input [7:0] tx_value;
        output [7:0] rx_value;
        integer bit_index;
        begin
            rx_value = 8'h00;
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                spi_mosi = tx_value[bit_index];
                #(SPI_HALF_NS);
                spi_sck = 1'b1;
                #1;
                rx_value[bit_index] = spi_miso;
                #(SPI_HALF_NS - 1);
                spi_sck = 1'b0;
            end
        end
    endtask

    task spi_exchange_1byte;
        input [7:0] tx_value;
        output [7:0] rx_value;
        begin
            spi_ss_n = 1'b0;
            spi_shift_byte(tx_value, rx_value);
            #(SPI_HALF_NS);
            spi_ss_n = 1'b1;
            #(SPI_HALF_NS * 2);
        end
    endtask

    task spi_exchange_ab;
        input [7:0] a_value;
        input [7:0] b_value;
        output [7:0] a_rx;
        output [7:0] b_rx;
        begin
            // AとBの間ではCSをHighにしない。
            spi_ss_n = 1'b0;
            spi_shift_byte(a_value, a_rx);
            spi_shift_byte(b_value, b_rx);
            #(SPI_HALF_NS);
            spi_ss_n = 1'b1;
            #(SPI_HALF_NS * 2);
        end
    endtask

    task reset_and_start;
        output [7:0] reset_ack_rx;
        output [7:0] start_ack_rx;
        reg [7:0] ignored;
        begin
            spi_exchange_1byte(CMD_RESET, ignored);
            spi_exchange_1byte(CMD_NOP, reset_ack_rx);
            spi_exchange_1byte(CMD_START, ignored);
            spi_exchange_1byte(CMD_NOP, start_ack_rx);
        end
    endtask

    task poll_reply;
        output [7:0] reply;
        output integer poll_count;
        begin
            reply = 8'h00;
            poll_count = 0;
            while (!reply[7] && poll_count < 8) begin
                spi_exchange_1byte(CMD_NOP, reply);
                poll_count = poll_count + 1;
            end
        end
    endtask

    task run_exhaustive_case;
        input integer a_value;
        input integer b_value;
        reg [7:0] reset_ack_rx;
        reg [7:0] start_ack_rx;
        reg [7:0] a_rx;
        reg [7:0] b_rx;
        reg [7:0] reply;
        reg [7:0] expected_reply;
        integer polls;
        begin
            reset_and_start(reset_ack_rx, start_ack_rx);
            spi_exchange_ab(a_value[7:0], b_value[7:0], a_rx, b_rx);
            poll_reply(reply, polls);

            expected_reply = 8'h80 | reference_nine(a_value, b_value);
            exhaustive_count = exhaustive_count + 1;

            if (reset_ack_rx !== RESET_ACK ||
                start_ack_rx !== START_ACK ||
                reply !== expected_reply) begin
                failure_count = failure_count + 1;
                $display(
                    "FAIL A=%0d B=%0d RESET_ACK=%02x START_ACK=%02x REPLY=%02x EXPECT=%02x POLLS=%0d",
                    a_value,
                    b_value,
                    reset_ack_rx,
                    start_ack_rx,
                    reply,
                    expected_reply,
                    polls
                );
            end
        end
    endtask

    task run_invalid_input_case;
        input [7:0] a_value;
        input [7:0] b_value;
        input expected_answer;
        reg [7:0] reset_ack_rx;
        reg [7:0] start_ack_rx;
        reg [7:0] a_rx;
        reg [7:0] b_rx;
        reg [7:0] reply;
        reg [7:0] expected_reply;
        integer polls;
        begin
            reset_and_start(reset_ack_rx, start_ack_rx);
            spi_exchange_ab(a_value, b_value, a_rx, b_rx);
            poll_reply(reply, polls);

            expected_reply = 8'hC0 | expected_answer;
            protocol_count = protocol_count + 1;

            if (reset_ack_rx !== RESET_ACK ||
                start_ack_rx !== START_ACK ||
                reply !== expected_reply) begin
                failure_count = failure_count + 1;
                $display(
                    "FAIL INVALID A=%0d B=%0d RESET_ACK=%02x START_ACK=%02x REPLY=%02x EXPECT=%02x",
                    a_value,
                    b_value,
                    reset_ack_rx,
                    start_ack_rx,
                    reply,
                    expected_reply
                );
            end
        end
    endtask

    task run_unexpected_state_case;
        reg [7:0] ignored;
        reg [7:0] reset_ack_rx;
        reg [7:0] start_ack_rx;
        reg [7:0] a_rx;
        reg [7:0] b_rx;
        reg [7:0] reply;
        integer polls;
        begin
            spi_exchange_1byte(CMD_RESET, ignored);
            spi_exchange_1byte(CMD_NOP, reset_ack_rx);

            // WAIT_START中の非NOP/非START byteでsticky errorを立てる。
            spi_exchange_1byte(8'h01, ignored);
            spi_exchange_1byte(CMD_START, ignored);
            spi_exchange_1byte(CMD_NOP, start_ack_rx);
            spi_exchange_ab(8'd66, 8'd7, a_rx, b_rx);
            poll_reply(reply, polls);

            protocol_count = protocol_count + 1;
            if (reset_ack_rx !== RESET_ACK ||
                start_ack_rx !== START_ACK ||
                reply !== 8'hC0) begin
                failure_count = failure_count + 1;
                $display(
                    "FAIL UNEXPECTED_STATE RESET_ACK=%02x START_ACK=%02x REPLY=%02x",
                    reset_ack_rx,
                    start_ack_rx,
                    reply
                );
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        spi_ss_n = 1'b1;
        spi_sck = 1'b0;
        spi_mosi = 1'b0;
        exhaustive_count = 0;
        protocol_count = 0;
        failure_count = 0;

        #200;
        rst_n = 1'b1;
        #500;

        for (a = 1; a <= 100; a = a + 1) begin
            for (b = 1; b <= 100; b = b + 1)
                run_exhaustive_case(a, b);
        end

        // 範囲外入力と想定外状態でERRORがstickyになることを確認する。
        run_invalid_input_case(8'd0,   8'd1,   1'b0);
        run_invalid_input_case(8'd101, 8'd1,   1'b0);
        run_invalid_input_case(8'd1,   8'd0,   1'b0);
        run_invalid_input_case(8'd1,   8'd101, 1'b0);
        run_invalid_input_case(8'd0,   8'd9,   1'b1);
        run_unexpected_state_case();

        $display(
            "SUMMARY EXHAUSTIVE_CASES=%0d PROTOCOL_CASES=%0d FAILURES=%0d %s",
            exhaustive_count,
            protocol_count,
            failure_count,
            failure_count == 0 ? "PASS" : "FAIL"
        );

        if (exhaustive_count != 10000 || failure_count != 0)
            $fatal(1, "ABC471A verification failed");

        $finish;
    end
endmodule
