// Renesas AN-FG-018のデュアルポート分散RAM記述を基にした128×1bit RAM。
// メモリ本体にはRESETを接続せず、読み出しデータ用レジスタだけを初期化する。
module corridor_watch_dist_ram (
    input             i_wr_clk,
    input             i_rd_clk,
    input             i_rst_n,
    input             i_wr_en,
    input      [6:0]  i_wr_addr,
    input      [0:0]  i_wr_data,
    input             i_rd_en,
    input      [6:0]  i_rd_addr,
    output reg [0:0]  o_rd_data
);

    // 論理深さ128、幅1bit。問題で使用するのはアドレス0～99だけである。
    reg [0:0] mem_ram [127:0];

    // AN-FG-018と同じく、書き込みは書き込みクロックへ同期させる。
    always @(posedge i_wr_clk) begin
        if (i_wr_en)
            mem_ram[i_wr_addr] <= i_wr_data;
    end

    // AN-FG-018と同じ同期読み出し。アドレス設定の次クロックで値が有効になる。
    always @(posedge i_rd_clk) begin
        if (!i_rst_n)
            o_rd_data <= 1'b0;
        else if (i_rd_en)
            o_rd_data <= mem_ram[i_rd_addr];
    end

endmodule


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

    localparam [7:0] CMD_RESET = 8'hFF;
    localparam [7:0] CMD_START = 8'hFE;
    localparam [7:0] RESET_ACK = 8'h5A;
    localparam [7:0] START_ACK = 8'hA5;

    // ABC468Bの入力受信、更新待ち、集計、回答返却を制御するFSM状態。
    localparam [2:0] WAIT_START    = 3'd0;
    localparam [2:0] WAIT_M        = 3'd1;
    localparam [2:0] WAIT_D        = 3'd2;
    localparam [2:0] RECEIVE_S     = 3'd3;
    localparam [2:0] WAIT_UPDATES  = 3'd4;
    localparam [2:0] COUNT_WATCHED = 3'd5;
    localparam [2:0] PREPARE_REPLY = 3'd6;
    localparam [2:0] DONE          = 3'd7;

    // ===== 共通部分：内部クロックとSPI送受信データ =====
    assign clk_en = 1'b1;

    wire [7:0] rx_data;
    wire       rx_data_strobe;
    reg  [7:0] tx_data;

    // ===== 問題ごとに変更する部分 =====
    // テンプレート初期状態では、次の説明に対応するループバック処理だった。
    // 今回は動作確認用として、受信値に1を加えて返す。
    // AtCoder問題を実装するときは、
    // この処理を問題固有の判定・演算へ置き換える。
    // 今回は上記テンプレート処理をABC468Bの分散RAM処理へ置き換える。
    reg [2:0] state;
    reg [6:0] m_reg;
    reg [6:0] d_reg;
    reg [6:0] position;

    // START後の分散RAM逐次初期化器。
    reg       init_active;
    reg       init_done;
    reg [6:0] init_address;

    // 1クロックに1要素を0へ更新する範囲更新器。
    reg       update_active;
    reg [6:0] update_address;
    reg [6:0] update_end;

    // 4MHz SPIの文字境界付近で更新が重なった場合に備える1件分の保留。
    reg       pending_valid;
    reg [6:0] pending_start;
    reg [6:0] pending_end;

    // 保留1件を超えて更新要求が到着したことを示す内部観測信号。
    reg       update_overrun;

    // 同期読み出しの要求と有効データを分けて管理する集計器。
    reg [6:0] count_address;
    reg [6:0] answer_count;
    reg       count_data_valid;
    reg       count_last_issued;

    // 初期化と範囲更新が共有する分散RAM書き込みポート。
    wire       ram_write_enable;
    wire [6:0] ram_write_address;
    wire [0:0] ram_write_data;

    assign ram_write_enable =
        init_active || (!init_active && update_active);
    assign ram_write_address =
        init_active ? init_address : update_address;
    assign ram_write_data =
        init_active ? 1'b1 : 1'b0;

    // 最終集計だけが使用する分散RAM同期読み出しポート。
    wire       ram_read_enable;
    wire [6:0] ram_read_address;
    wire [0:0] ram_read_data;

    assign ram_read_enable =
        (state == COUNT_WATCHED) && !count_last_issued;
    assign ram_read_address = count_address;

    corridor_watch_dist_ram u_watched_ram (
        .i_wr_clk(clk),
        .i_rd_clk(clk),
        .i_rst_n(rst_n),
        .i_wr_en(ram_write_enable),
        .i_wr_addr(ram_write_address),
        .i_wr_data(ram_write_data),
        .i_rd_en(ram_read_enable),
        .i_rd_addr(ram_read_address),
        .o_rd_data(ram_read_data)
    );

    // 現在のS[position]がGだった場合の更新範囲を計算する。
    wire [7:0] position_ext = {1'b0, position};
    wire [7:0] d_ext        = {1'b0, d_reg};
    wire [7:0] right_sum    = position_ext + d_ext;
    wire [6:0] request_start =
        (position >= d_reg) ? (position - d_reg) : 7'd0;
    wire [6:0] request_end =
        (right_sum >= {1'b0, m_reg})
            ? (m_reg - 7'd1)
            : right_sum[6:0];

    wire update_finishing =
        !init_active && update_active &&
        (update_address == update_end);
    wire pending_consumed =
        !init_active && pending_valid &&
        (!update_active || update_finishing);

    // 応答は意図的に1byte遅延し、spi_targetは受信通知の次のbyteへtx_dataを載せる。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= WAIT_START;
            m_reg              <= 7'd0;
            d_reg              <= 7'd0;
            position           <= 7'd0;
            init_active        <= 1'b0;
            init_done          <= 1'b0;
            init_address       <= 7'd0;
            update_active      <= 1'b0;
            update_address     <= 7'd0;
            update_end         <= 7'd0;
            pending_valid      <= 1'b0;
            pending_start      <= 7'd0;
            pending_end        <= 7'd0;
            update_overrun     <= 1'b0;
            count_address      <= 7'd0;
            answer_count       <= 7'd0;
            count_data_valid   <= 1'b0;
            count_last_issued  <= 1'b0;
            tx_data            <= 8'h00;
        end else if (rx_data_strobe && rx_data == CMD_RESET) begin
            // SPI RESETコマンドは、すべての通信状態で最優先に処理する。
            // 分散RAM本体は変更せず、制御レジスタだけを初期状態へ戻す。
            state              <= WAIT_START;
            m_reg              <= 7'd0;
            d_reg              <= 7'd0;
            position           <= 7'd0;
            init_active        <= 1'b0;
            init_done          <= 1'b0;
            init_address       <= 7'd0;
            update_active      <= 1'b0;
            update_address     <= 7'd0;
            update_end         <= 7'd0;
            pending_valid      <= 1'b0;
            pending_start      <= 7'd0;
            pending_end        <= 7'd0;
            update_overrun     <= 1'b0;
            count_address      <= 7'd0;
            answer_count       <= 7'd0;
            count_data_valid   <= 1'b0;
            count_last_issued  <= 1'b0;
            tx_data            <= RESET_ACK;
        end else if (rx_data_strobe && rx_data == CMD_START) begin
            // DONEを含むどの状態からでも、新しい問題を開始できる。
            // RAMのアドレス0～99は、この後100クロックかけて1へ戻す。
            state              <= WAIT_M;
            m_reg              <= 7'd0;
            d_reg              <= 7'd0;
            position           <= 7'd0;
            init_active        <= 1'b1;
            init_done          <= 1'b0;
            init_address       <= 7'd0;
            update_active      <= 1'b0;
            update_address     <= 7'd0;
            update_end         <= 7'd0;
            pending_valid      <= 1'b0;
            pending_start      <= 7'd0;
            pending_end        <= 7'd0;
            update_overrun     <= 1'b0;
            count_address      <= 7'd0;
            answer_count       <= 7'd0;
            count_data_valid   <= 1'b0;
            count_last_issued  <= 1'b0;
            tx_data            <= START_ACK;
        end else begin
            // START後は100クロックでアドレス0～99を1へ戻す。
            // 初期化器は受信FSMと独立しているため、同時にMとDを受信できる。
            if (init_active) begin
                if (init_address == 7'd99) begin
                    init_active <= 1'b0;
                    init_done   <= 1'b1;
                end else begin
                    init_address <= init_address + 7'd1;
                end
            end else if (update_active) begin
                // 現在値を読まず、書き込みポートから無条件に0を書き込む。
                if (update_address == update_end) begin
                    if (pending_valid) begin
                        update_address <= pending_start;
                        update_end     <= pending_end;
                        pending_valid  <= 1'b0;
                    end else begin
                        update_active <= 1'b0;
                    end
                end else begin
                    update_address <= update_address + 7'd1;
                end
            end else if (pending_valid) begin
                // 通常は完了境界で直結するが、保留だけが残った場合も回収する。
                update_active  <= 1'b1;
                update_address <= pending_start;
                update_end     <= pending_end;
                pending_valid  <= 1'b0;
            end

            case (state)
                WAIT_START: begin
                    if (rx_data_strobe)
                        tx_data <= 8'h00;
                end

                WAIT_M: begin
                    if (rx_data_strobe) begin
                        m_reg   <= rx_data[6:0];
                        state   <= WAIT_D;
                        tx_data <= 8'h00;
                    end
                end

                WAIT_D: begin
                    if (rx_data_strobe) begin
                        d_reg       <= rx_data[6:0];
                        position    <= 7'd0;
                        state       <= RECEIVE_S;
                        tx_data     <= 8'h00;
                    end
                end

                RECEIVE_S: begin
                    if (rx_data_strobe) begin
                        // 0x01を'G'として扱い、それ以外は'.'として扱う。
                        if (rx_data == 8'h01) begin
                            // 完了クロックでは次の更新へ直結し、余分な空き時間を作らない。
                            if ((!update_active && !pending_valid) ||
                                (update_finishing && !pending_valid)) begin
                                update_active  <= 1'b1;
                                update_address <= request_start;
                                update_end     <= request_end;
                            end else if (pending_consumed) begin
                                // 保留中の要求を更新器へ渡す同じクロックで、
                                // 空いた保留スロットへ新しい要求を格納する。
                                pending_valid <= 1'b1;
                                pending_start <= request_start;
                                pending_end   <= request_end;
                            end else if (!pending_valid) begin
                                pending_valid <= 1'b1;
                                pending_start <= request_start;
                                pending_end   <= request_end;
                            end else begin
                                update_overrun <= 1'b1;
                            end
                        end

                        tx_data <= 8'h00;
                        if (position + 7'd1 >= m_reg) begin
                            state <= WAIT_UPDATES;
                        end else begin
                            position <= position + 7'd1;
                        end
                    end
                end

                WAIT_UPDATES: begin
                    // 最後の文字を受信しただけでは集計を開始しない。
                    if (init_done && !update_active && !pending_valid) begin
                        count_address     <= 7'd0;
                        answer_count      <= 7'd0;
                        count_data_valid  <= 1'b0;
                        count_last_issued <= 1'b0;
                        state             <= COUNT_WATCHED;
                    end
                end

                COUNT_WATCHED: begin
                    // 未発行アドレスを同期読み出しポートへ1クロック1件で提示する。
                    if (!count_last_issued) begin
                        count_data_valid <= 1'b1;
                        if (count_address + 7'd1 >= m_reg) begin
                            count_last_issued <= 1'b1;
                        end else begin
                            count_address <= count_address + 7'd1;
                        end
                    end

                    // 1クロック前に提示したアドレスのデータだけを集計する。
                    if (count_data_valid) begin
                        if (ram_read_data[0])
                            answer_count <= answer_count + 7'd1;

                        if (count_last_issued) begin
                            count_data_valid <= 1'b0;
                            state            <= PREPARE_REPLY;
                        end
                    end
                end

                PREPARE_REPLY: begin
                    // 最終要素の加算結果を反映した次クロックでVALIDを立てる。
                    tx_data <= {1'b1, answer_count};
                    state   <= DONE;
                end

                DONE: begin
                    // NOPで繰り返し読み出せるよう、有効な回答を保持する。
                    tx_data <= tx_data;
                end

                default: begin
                    state              <= WAIT_START;
                    m_reg              <= 7'd0;
                    d_reg              <= 7'd0;
                    position           <= 7'd0;
                    init_active        <= 1'b0;
                    init_done          <= 1'b0;
                    init_address       <= 7'd0;
                    update_active      <= 1'b0;
                    update_address     <= 7'd0;
                    update_end         <= 7'd0;
                    pending_valid      <= 1'b0;
                    pending_start      <= 7'd0;
                    pending_end        <= 7'd0;
                    update_overrun     <= 1'b0;
                    count_address      <= 7'd0;
                    answer_count       <= 7'd0;
                    count_data_valid   <= 1'b0;
                    count_last_issued  <= 1'b0;
                    tx_data            <= 8'h00;
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
