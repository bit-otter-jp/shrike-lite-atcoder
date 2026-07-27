(* top *) module main (
    // ===== 共通部分：Shrike-LiteとSPIの外部端子 =====
    (* iopad_external_pin, clkbuf_inhibit *) input clk,
    (* iopad_external_pin *) output clk_en,
    (* iopad_external_pin *) input rst_n,

    (* iopad_external_pin *) input  spi_ss_n,
    (* iopad_external_pin *) input  spi_sck,
    (* iopad_external_pin *) input  spi_mosi,
    (* iopad_external_pin *) output spi_miso,
    (* iopad_external_pin *) output spi_miso_en
);

    // ===== 共通部分：内部クロックとSPI送受信データ =====
    assign clk_en = 1'b1;

    wire [7:0] rx_data;
    wire       rx_data_strobe;
    reg  [7:0] tx_data;

    // ===== 問題ごとに変更する部分 =====
    localparam [2:0] WAIT_START    = 3'd0;
    localparam [2:0] WAIT_N        = 3'd1;
    localparam [2:0] RECEIVE_A     = 3'd2;
    localparam [2:0] PREPARE_REPLY = 3'd3;
    localparam [2:0] DONE          = 3'd4;

    localparam [7:0] RESET_ACK = 8'h5A;
    localparam [7:0] START_ACK = 8'hA5;

    reg [2:0] state;
    reg [6:0] remaining_count;
    reg [6:0] answer_count;

    // 直近2要素を保持するFF。101は入力範囲外の番兵値とする。
    reg [6:0] a_middle;
    reg [6:0] a_right;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_data <= 8'h00;
            state <= WAIT_START;
            remaining_count <= 7'd0;
            answer_count <= 7'd0;
            a_middle <= 7'd101;
            a_right <= 7'd101;
        end else if (rx_data_strobe && rx_data == 8'hFF) begin
            // SPI RESETはすべての状態で最優先に処理する。
            tx_data <= RESET_ACK;
            state <= WAIT_START;
            remaining_count <= 7'd0;
            answer_count <= 7'd0;
            a_middle <= 7'd101;
            a_right <= 7'd101;
        end else begin
            case (state)
                WAIT_START: begin
                    if (rx_data_strobe) begin
                        if (rx_data == 8'hFE) begin
                            tx_data <= START_ACK;
                            state <= WAIT_N;
                        end else if (rx_data == 8'h00) begin
                            // NOPでは直前のACKを返した後、次回値を0へ戻す。
                            tx_data <= 8'h00;
                        end else if (rx_data == 8'hFD) begin
                            // DEBUG用予約値は無視し、通常処理を開始しない。
                        end
                    end
                end

                WAIT_N: begin
                    if (rx_data_strobe) begin
                        // START直後のbyteはコマンド判定せずNとして扱う。
                        remaining_count <= rx_data[6:0];
                        answer_count <= 7'd0;
                        a_middle <= 7'd101;
                        a_right <= 7'd101;
                        tx_data <= 8'h00;
                        state <= RECEIVE_A;
                    end
                end

                RECEIVE_A: begin
                    if (rx_data_strobe) begin
                        // シフト前の中央・右FFと今回値で山を判定する。
                        a_middle <= a_right;
                        a_right <= rx_data[6:0];

                        if (a_middle < a_right &&
                            a_right > rx_data[6:0]) begin
                            answer_count <= answer_count + 7'd1;
                        end

                        // CSではなく受信残数でN個の受信完了を判定する。
                        if (remaining_count == 7'd1) begin
                            remaining_count <= 7'd0;
                            state <= PREPARE_REPLY;
                        end else begin
                            remaining_count <= remaining_count - 7'd1;
                        end
                    end
                end

                PREPARE_REPLY: begin
                    // 最終要素による加算後のカウンタを次クロックで返信へ反映する。
                    tx_data <= {1'b1, answer_count};
                    state <= DONE;
                end

                DONE: begin
                    // 回答読出し用NOPを受信しても返信値と状態を保持する。
                end

                default: begin
                    tx_data <= 8'h00;
                    state <= WAIT_START;
                    remaining_count <= 7'd0;
                    answer_count <= 7'd0;
                    a_middle <= 7'd101;
                    a_right <= 7'd101;
                end
            endcase
        end
    end

    // ===== 共通部分：SPI Targetモジュール =====
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
