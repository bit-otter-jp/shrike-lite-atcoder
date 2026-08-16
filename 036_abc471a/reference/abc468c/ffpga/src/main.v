(* top *) module main (
    // ===== Shrike-LiteとSPIの外部端子 =====
    (* iopad_external_pin, clkbuf_inhibit *) input clk,
    (* iopad_external_pin *) output clk_en,
    (* iopad_external_pin *) input rst_n,

    (* iopad_external_pin *) input  spi_ss_n,
    (* iopad_external_pin *) input  spi_sck,
    (* iopad_external_pin *) input  spi_mosi,
    (* iopad_external_pin *) output spi_miso,
    (* iopad_external_pin *) output spi_miso_en
);

    assign clk_en = 1'b1;

    wire [7:0] rx_data;
    wire       rx_data_strobe;
    reg  [7:0] tx_data;

    localparam [7:0] CMD_NOP       = 8'h00;
    localparam [7:0] CMD_START     = 8'hFE;
    localparam [7:0] CMD_RESET     = 8'hFF;
    localparam [7:0] RESET_ACK     = 8'h5A;
    localparam [7:0] START_ACK     = 8'hA5;

    localparam [3:0] ST_WAIT_START          = 4'd0;
    localparam [3:0] ST_WAIT_START_ACK      = 4'd1;
    localparam [3:0] ST_RECEIVE_N           = 4'd2;
    localparam [3:0] ST_WAIT_SEQUENCE_BYTE = 4'd3;
    localparam [3:0] ST_LOAD_NIBBLE         = 4'd4;
    localparam [3:0] ST_VALIDATE_NIBBLE     = 4'd5;
    localparam [3:0] ST_SCAN_CANDIDATE      = 4'd6;
    localparam [3:0] ST_MARK_USED           = 4'd7;
    localparam [3:0] ST_FINISH_DIGIT        = 4'd8;
    localparam [3:0] ST_FINISH_SEQUENCE     = 4'd9;
    localparam [3:0] ST_CALC_ANSWER         = 4'd10;
    localparam [3:0] ST_SEND_REPLY          = 4'd11;

    reg [3:0] state;
    reg [3:0] n_reg;
    reg       sequence_phase;  // 0: P、1: Q
    reg [3:0] digit_index;
    reg [3:0] current_value;
    reg [3:0] candidate;
    reg [9:0] used_mask;
    reg [21:0] rank_work;
    reg [21:0] rank_p;
    reg [21:0] answer;
    reg [7:0] rx_byte_buffer;
    reg       nibble_select;  // 0: 上位、1: 下位
    reg       protocol_error;
    reg       reply_valid;
    reg [1:0] reply_byte_index;

    // 固定値の階乗選択回路。BRAMや可変乗算器は使用しない。
    reg [21:0] factorial_value;
    always @(*) begin
        case (n_reg - digit_index - 4'd1)
            4'd0: factorial_value = 22'd1;
            4'd1: factorial_value = 22'd1;
            4'd2: factorial_value = 22'd2;
            4'd3: factorial_value = 22'd6;
            4'd4: factorial_value = 22'd24;
            4'd5: factorial_value = 22'd120;
            4'd6: factorial_value = 22'd720;
            4'd7: factorial_value = 22'd5040;
            4'd8: factorial_value = 22'd40320;
            4'd9: factorial_value = 22'd362880;
            default: factorial_value = 22'd0;
        endcase
    end

    // RESETとSTARTには、テンプレートの1バイト遅延応答を使用する。
    // PとQの順位は、この1つのFSMと作業用レジスタで計算する。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= ST_WAIT_START;
            n_reg            <= 4'd0;
            sequence_phase   <= 1'b0;
            digit_index      <= 4'd0;
            current_value    <= 4'd0;
            candidate        <= 4'd0;
            used_mask        <= 10'd0;
            rank_work        <= 22'd0;
            rank_p           <= 22'd0;
            answer           <= 22'd0;
            rx_byte_buffer   <= 8'd0;
            nibble_select    <= 1'b0;
            protocol_error   <= 1'b0;
            reply_valid      <= 1'b0;
            reply_byte_index <= 2'd0;
            tx_data          <= 8'h00;
        end else if (rx_data_strobe && rx_data == CMD_RESET) begin
            state            <= ST_WAIT_START;
            n_reg            <= 4'd0;
            sequence_phase   <= 1'b0;
            digit_index      <= 4'd0;
            current_value    <= 4'd0;
            candidate        <= 4'd0;
            used_mask        <= 10'd0;
            rank_work        <= 22'd0;
            rank_p           <= 22'd0;
            answer           <= 22'd0;
            rx_byte_buffer   <= 8'd0;
            nibble_select    <= 1'b0;
            protocol_error   <= 1'b0;
            reply_valid      <= 1'b0;
            reply_byte_index <= 2'd0;
            tx_data          <= RESET_ACK;
        end else begin
            case (state)
                ST_WAIT_START: begin
                    if (rx_data_strobe) begin
                        if (rx_data == CMD_START) begin
                            n_reg            <= 4'd0;
                            sequence_phase   <= 1'b0;
                            digit_index      <= 4'd0;
                            current_value    <= 4'd0;
                            candidate        <= 4'd0;
                            used_mask        <= 10'd0;
                            rank_work        <= 22'd0;
                            rank_p           <= 22'd0;
                            answer           <= 22'd0;
                            rx_byte_buffer   <= 8'd0;
                            nibble_select    <= 1'b0;
                            reply_valid      <= 1'b0;
                            reply_byte_index <= 2'd0;
                            tx_data          <= START_ACK;
                            state            <= ST_WAIT_START_ACK;
                        end else if (rx_data != CMD_NOP) begin
                            protocol_error <= 1'b1;
                        end
                    end
                end

                // START_ACKを読み出すNOPをNとして解釈しない。
                ST_WAIT_START_ACK: begin
                    if (rx_data_strobe) begin
                        if (rx_data != CMD_NOP)
                            protocol_error <= 1'b1;
                        tx_data <= 8'h00;
                        state   <= ST_RECEIVE_N;
                    end
                end

                ST_RECEIVE_N: begin
                    if (rx_data_strobe) begin
                        tx_data <= 8'h00;
                        if (rx_data[7:4] != 4'd0 ||
                            rx_data[3:0] < 4'd1 ||
                            rx_data[3:0] > 4'd10) begin
                            n_reg            <= 4'd0;
                            answer           <= 22'd0;
                            protocol_error   <= 1'b1;
                            reply_valid      <= 1'b1;
                            reply_byte_index <= 2'd0;
                            tx_data          <= 8'hC0;
                            state            <= ST_SEND_REPLY;
                        end else begin
                            n_reg          <= rx_data[3:0];
                            sequence_phase <= 1'b0;
                            digit_index    <= 4'd0;
                            used_mask      <= 10'd0;
                            rank_work      <= 22'd0;
                            state          <= ST_WAIT_SEQUENCE_BYTE;
                        end
                    end
                end

                ST_WAIT_SEQUENCE_BYTE: begin
                    if (rx_data_strobe) begin
                        rx_byte_buffer <= rx_data;
                        nibble_select  <= 1'b0;
                        tx_data        <= 8'h00;
                        state          <= ST_LOAD_NIBBLE;
                    end
                end

                ST_LOAD_NIBBLE: begin
                    if (rx_data_strobe)
                        protocol_error <= 1'b1;

                    if (nibble_select == 1'b0)
                        current_value <= rx_byte_buffer[7:4];
                    else
                        current_value <= rx_byte_buffer[3:0];
                    state <= ST_VALIDATE_NIBBLE;
                end

                ST_VALIDATE_NIBBLE: begin
                    if (rx_data_strobe)
                        protocol_error <= 1'b1;

                    if (current_value == 4'd0 ||
                        current_value > n_reg) begin
                        protocol_error <= 1'b1;
                        state          <= ST_FINISH_DIGIT;
                    end else if (used_mask[current_value - 4'd1]) begin
                        protocol_error <= 1'b1;
                        state          <= ST_FINISH_DIGIT;
                    end else begin
                        candidate <= 4'd1;
                        state     <= ST_SCAN_CANDIDATE;
                    end
                end

                // 1クロックごとに候補を1つ確認し、同じ22ビットの
                // rank_work + factorial_value加算器を繰り返し使用する。
                ST_SCAN_CANDIDATE: begin
                    if (rx_data_strobe)
                        protocol_error <= 1'b1;

                    if (candidate < current_value) begin
                        if (!used_mask[candidate - 4'd1])
                            rank_work <= rank_work + factorial_value;
                        candidate <= candidate + 4'd1;
                    end else begin
                        state <= ST_MARK_USED;
                    end
                end

                ST_MARK_USED: begin
                    if (rx_data_strobe)
                        protocol_error <= 1'b1;

                    used_mask[current_value - 4'd1] <= 1'b1;
                    state <= ST_FINISH_DIGIT;
                end

                ST_FINISH_DIGIT: begin
                    if (rx_data_strobe)
                        protocol_error <= 1'b1;

                    if ((digit_index + 4'd1) >= n_reg) begin
                        state <= ST_FINISH_SEQUENCE;
                    end else begin
                        digit_index <= digit_index + 4'd1;
                        if (nibble_select == 1'b0) begin
                            nibble_select <= 1'b1;
                            state         <= ST_LOAD_NIBBLE;
                        end else begin
                            nibble_select <= 1'b0;
                            state         <= ST_WAIT_SEQUENCE_BYTE;
                        end
                    end
                end

                ST_FINISH_SEQUENCE: begin
                    if (rx_data_strobe)
                        protocol_error <= 1'b1;

                    if (sequence_phase == 1'b0) begin
                        rank_p         <= rank_work;
                        rank_work      <= 22'd0;
                        used_mask      <= 10'd0;
                        digit_index    <= 4'd0;
                        current_value  <= 4'd0;
                        candidate      <= 4'd0;
                        nibble_select  <= 1'b0;
                        sequence_phase <= 1'b1;
                        state          <= ST_WAIT_SEQUENCE_BYTE;
                    end else begin
                        state <= ST_CALC_ANSWER;
                    end
                end

                ST_CALC_ANSWER: begin
                    if (rx_data_strobe)
                        protocol_error <= 1'b1;

                    if (rank_work > (rank_p + 22'd1))
                        answer <= rank_work - rank_p - 22'd1;
                    else
                        answer <= 22'd0;

                    reply_valid      <= 1'b1;
                    reply_byte_index <= 2'd0;
                    tx_data <= (protocol_error || rx_data_strobe) ?
                               8'hC0 : 8'h80;
                    state <= ST_SEND_REPLY;
                end

                // tx_dataは1転送先の値を保持する。STATUSを受信したNOPで、
                // 次に返す回答の先頭バイトを選択済みにする。
                ST_SEND_REPLY: begin
                    if (rx_data_strobe) begin
                        if (rx_data == CMD_NOP) begin
                            case (reply_byte_index)
                                2'd0: begin
                                    tx_data <= {2'b00, answer[21:16]};
                                    reply_byte_index <= 2'd1;
                                end
                                2'd1: begin
                                    tx_data <= answer[15:8];
                                    reply_byte_index <= 2'd2;
                                end
                                2'd2: begin
                                    tx_data <= answer[7:0];
                                    reply_byte_index <= 2'd3;
                                end
                                default: begin
                                    tx_data <= {
                                        reply_valid,
                                        protocol_error,
                                        6'b000000
                                    };
                                    reply_byte_index <= 2'd0;
                                end
                            endcase
                        end else begin
                            protocol_error   <= 1'b1;
                            reply_byte_index <= 2'd0;
                            tx_data          <= 8'hC0;
                        end
                    end
                end

                default: begin
                    state            <= ST_SEND_REPLY;
                    answer           <= 22'd0;
                    protocol_error   <= 1'b1;
                    reply_valid      <= 1'b1;
                    reply_byte_index <= 2'd0;
                    tx_data          <= 8'hC0;
                end
            endcase
        end
    end

    // ===== SPIテンプレートV3のSPIターゲットモジュール =====
    spi_target #(
        .CPOL(1'b0),
        .CPHA(1'b0),
        .WIDTH(8),
        .LSB(1'b0)
    ) u_spi_target (
        .i_clk(clk),
        .i_rst_n(rst_n),
        .i_enable(1'b1),

        .i_ss_n(spi_ss_n),
        .i_sck(spi_sck),
        .i_mosi(spi_mosi),
        .o_miso(spi_miso),
        .o_miso_oe(spi_miso_en),

        .o_rx_data(rx_data),
        .o_rx_data_valid(),
        .o_rx_data_strobe(rx_data_strobe),

        .i_tx_data(tx_data),
        .o_tx_data_hold()
    );

endmodule
