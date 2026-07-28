(* top *) module main (
    // Shrike-Liteの共通クロック、リセット、SPI端子。
    (* iopad_external_pin, clkbuf_inhibit *) input clk,
    (* iopad_external_pin *) output clk_en,
    (* iopad_external_pin *) input rst_n,

    (* iopad_external_pin *) input  spi_ss_n,
    (* iopad_external_pin *) input  spi_sck,
    (* iopad_external_pin *) input  spi_mosi,
    (* iopad_external_pin *) output spi_miso,
    (* iopad_external_pin *) output spi_miso_en
);

    localparam [7:0] CMD_RESET  = 8'hFF;
    localparam [7:0] CMD_START  = 8'hFE;
    localparam [7:0] RESET_ACK  = 8'h5A;
    localparam [7:0] START_ACK  = 8'hA5;

    // ABC468Bの入力受信と回答返却を制御するFSM状態。
    localparam [2:0] WAIT_START    = 3'd0;
    localparam [2:0] WAIT_M        = 3'd1;
    localparam [2:0] WAIT_D        = 3'd2;
    localparam [2:0] RECEIVE_S     = 3'd3;
    localparam [2:0] PREPARE_REPLY = 3'd4;
    localparam [2:0] DONE          = 3'd5;

    assign clk_en = 1'b1;

    wire [7:0] rx_data;
    wire       rx_data_strobe;
    reg  [7:0] tx_data;

    reg [2:0] state;
    reg [7:0] m_reg;
    reg [7:0] d_reg;
    reg [7:0] position;
    // leftは、まだ監視済みであることが確定していない最も左の位置を表す。
    reg [7:0] left;
    reg [7:0] answer_count;

    // 8bit同士の加算結果を確実に保持し、式評価幅による桁落ちを避けるため、
    // 区間演算は加算前に9bitへ拡張する。
    wire [8:0] left_plus_d_ext =
        {1'b0, left} + {1'b0, d_reg};
    wire [8:0] position_ext = {1'b0, position};
    // position - Dを作らず、left + D < positionで負数を避けて隙間を判定する。
    wire       has_gap = left_plus_d_ext < position_ext;
    wire [8:0] gap_ext = position_ext - left_plus_d_ext;

    // ガードの監視区間の右端の次までleftを進め、Mを超える場合はMへ丸める。
    wire [8:0] right_exclusive_ext =
        position_ext + {1'b0, d_reg} + 9'd1;
    wire [7:0] right_clamped =
        (right_exclusive_ext >= {1'b0, m_reg})
            ? m_reg
            : right_exclusive_ext[7:0];
    wire [7:0] left_after_guard =
        (right_clamped > left) ? right_clamped : left;
    wire [8:0] answer_after_guard_ext =
        {1'b0, answer_count} + (has_gap ? gap_ext : 9'd0);

    wire [8:0] position_next_ext = position_ext + 9'd1;
    wire [8:0] trailing_unwatched_ext =
        {1'b0, m_reg} - {1'b0, left};
    wire [8:0] final_answer_ext =
        {1'b0, answer_count} + trailing_unwatched_ext;

    // 応答は意図的に1byte遅延し、spi_targetは受信通知の次のbyteへtx_dataを載せる。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= WAIT_START;
            m_reg        <= 8'd0;
            d_reg        <= 8'd0;
            position     <= 8'd0;
            left         <= 8'd0;
            answer_count <= 8'd0;
            tx_data      <= 8'h00;
        end else if (rx_data_strobe && rx_data == CMD_RESET) begin
            // SPI RESETコマンドは、すべての通信状態で最優先に処理する。
            state        <= WAIT_START;
            m_reg        <= 8'd0;
            d_reg        <= 8'd0;
            position     <= 8'd0;
            left         <= 8'd0;
            answer_count <= 8'd0;
            tx_data      <= RESET_ACK;
        end else begin
            case (state)
                WAIT_START: begin
                    if (rx_data_strobe) begin
                        if (rx_data == CMD_START) begin
                            state        <= WAIT_M;
                            m_reg        <= 8'd0;
                            d_reg        <= 8'd0;
                            position     <= 8'd0;
                            left         <= 8'd0;
                            answer_count <= 8'd0;
                            tx_data      <= START_ACK;
                        end else begin
                            tx_data <= 8'h00;
                        end
                    end
                end

                WAIT_M: begin
                    if (rx_data_strobe) begin
                        m_reg   <= rx_data;
                        state   <= WAIT_D;
                        tx_data <= 8'h00;
                    end
                end

                WAIT_D: begin
                    if (rx_data_strobe) begin
                        d_reg        <= rx_data;
                        position     <= 8'd0;
                        left         <= 8'd0;
                        answer_count <= 8'd0;
                        state        <= RECEIVE_S;
                        tx_data      <= 8'h00;
                    end
                end

                RECEIVE_S: begin
                    if (rx_data_strobe) begin
                        // 0x01を'G'として扱い、それ以外のデータ値は'.'として扱う。
                        if (rx_data == 8'h01) begin
                            left <= left_after_guard;
                            if (has_gap)
                                answer_count <= answer_after_guard_ext[7:0];
                        end

                        position <= position_next_ext[7:0];
                        tx_data  <= 8'h00;

                        if (position_next_ext >= {1'b0, m_reg})
                            state <= PREPARE_REPLY;
                    end
                end

                PREPARE_REPLY: begin
                    // 最後の文字に対するleftとanswer_countの更新を反映してから、
                    // PREPARE_REPLYで末尾の未監視区間を加えて回答を作成する。
                    tx_data <= {1'b1, final_answer_ext[6:0]};
                    state   <= DONE;
                end

                DONE: begin
                    // NOPで繰り返し読み出せるよう、有効な回答を保持する。
                    tx_data <= tx_data;
                end

                default: begin
                    state        <= WAIT_START;
                    m_reg        <= 8'd0;
                    d_reg        <= 8'd0;
                    position     <= 8'd0;
                    left         <= 8'd0;
                    answer_count <= 8'd0;
                    tx_data      <= 8'h00;
                end
            endcase
        end
    end

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
