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

    localparam [7:0] CMD_NOP   = 8'h00;
    localparam [7:0] CMD_START = 8'hFE;
    localparam [7:0] CMD_RESET = 8'hFF;
    localparam [7:0] RESET_ACK = 8'h5A;
    localparam [7:0] START_ACK = 8'hA5;

    localparam [2:0] ST_WAIT_START     = 3'd0;
    localparam [2:0] ST_WAIT_START_ACK = 3'd1;
    localparam [2:0] ST_RECEIVE_A      = 3'd2;
    localparam [2:0] ST_RECEIVE_B      = 3'd3;
    localparam [2:0] ST_CALC           = 3'd4;
    localparam [2:0] ST_SEND_REPLY     = 3'd5;

    reg [2:0] state;
    reg [7:0] a_reg;
    reg [7:0] b_reg;
    reg       answer;
    reg       protocol_error;
    reg       reply_valid;

    // ABC471Aの4条件を同じA、Bから並列に判定する。
    // 乗算条件は9の因数の比較だけで、除算条件は9*Bをshift-addで作る。
    wire       sum_nine;
    wire       sub_nine;
    wire       mul_nine;
    wire [10:0] b_times_nine;
    wire       div_nine;
    wire       nine_result;

    assign sum_nine = (a_reg + b_reg) == 8'd9;
    assign sub_nine = a_reg == (b_reg + 8'd9);
    assign mul_nine = ((a_reg == 8'd1) && (b_reg == 8'd9)) ||
                      ((a_reg == 8'd3) && (b_reg == 8'd3)) ||
                      ((a_reg == 8'd9) && (b_reg == 8'd1));
    assign b_times_nine = ({3'b000, b_reg} << 3) + {3'b000, b_reg};
    assign div_nine = {3'b000, a_reg} == b_times_nine;
    assign nine_result = sum_nine | sub_nine | mul_nine | div_nine;

    // RESET/STARTの1バイト遅延応答と、A/Bの2バイト入力を処理する。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_WAIT_START;
            a_reg          <= 8'd0;
            b_reg          <= 8'd0;
            answer         <= 1'b0;
            protocol_error <= 1'b0;
            reply_valid    <= 1'b0;
            tx_data        <= 8'h00;
        end else if (rx_data_strobe && rx_data == CMD_RESET) begin
            state          <= ST_WAIT_START;
            a_reg          <= 8'd0;
            b_reg          <= 8'd0;
            answer         <= 1'b0;
            protocol_error <= 1'b0;
            reply_valid    <= 1'b0;
            tx_data        <= RESET_ACK;
        end else begin
            case (state)
                ST_WAIT_START: begin
                    if (rx_data_strobe) begin
                        if (rx_data == CMD_START) begin
                            a_reg       <= 8'd0;
                            b_reg       <= 8'd0;
                            answer      <= 1'b0;
                            reply_valid <= 1'b0;
                            tx_data     <= START_ACK;
                            state       <= ST_WAIT_START_ACK;
                        end else if (rx_data == CMD_NOP) begin
                            tx_data <= 8'h00;
                        end else begin
                            protocol_error <= 1'b1;
                        end
                    end
                end

                // START_ACKを読み出すNOPはAとして扱わない。
                ST_WAIT_START_ACK: begin
                    if (rx_data_strobe) begin
                        tx_data <= 8'h00;
                        if (rx_data != CMD_NOP)
                            protocol_error <= 1'b1;
                        state <= ST_RECEIVE_A;
                    end
                end

                ST_RECEIVE_A: begin
                    if (rx_data_strobe) begin
                        a_reg  <= rx_data;
                        tx_data <= 8'h00;
                        if (rx_data < 8'd1 || rx_data > 8'd100)
                            protocol_error <= 1'b1;
                        state <= ST_RECEIVE_B;
                    end
                end

                ST_RECEIVE_B: begin
                    if (rx_data_strobe) begin
                        b_reg  <= rx_data;
                        tx_data <= 8'h00;
                        if (rx_data < 8'd1 || rx_data > 8'd100)
                            protocol_error <= 1'b1;
                        state <= ST_CALC;
                    end
                end

                ST_CALC: begin
                    // 通常はB受信後の次クロックでここを通る。
                    // この計算周期に新しいbyteが来た場合もsticky errorにする。
                    if (rx_data_strobe)
                        protocol_error <= 1'b1;

                    answer      <= nine_result;
                    reply_valid <= 1'b1;
                    tx_data     <= {
                        1'b1,
                        protocol_error | rx_data_strobe,
                        5'b00000,
                        nine_result
                    };
                    state <= ST_SEND_REPLY;
                end

                ST_SEND_REPLY: begin
                    if (rx_data_strobe) begin
                        if (rx_data == CMD_NOP) begin
                            tx_data <= {
                                reply_valid,
                                protocol_error,
                                5'b00000,
                                answer
                            };
                        end else begin
                            protocol_error <= 1'b1;
                            tx_data <= {
                                reply_valid,
                                1'b1,
                                5'b00000,
                                answer
                            };
                        end
                    end
                end

                default: begin
                    state          <= ST_SEND_REPLY;
                    answer         <= 1'b0;
                    protocol_error <= 1'b1;
                    reply_valid    <= 1'b1;
                    tx_data        <= 8'hC0;
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
