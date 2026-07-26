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
    // ABC467C - Adjacent Sums (easy)
    // M=2なので、A_1の最終値を0と仮定した候補をPrefix XORで計算する。
    // もう一方の候補は全位置の一致・不一致が反転することを利用して求める。
    localparam NOP          = 3'b000;
    localparam SEND_N_17_15 = 3'b001;
    localparam SEND_N_14_10 = 3'b010;
    localparam SEND_N_9_5   = 3'b011;
    localparam SEND_N_4_0   = 3'b100;
    localparam SEND_A1      = 3'b101;
    localparam RESET        = 3'b111;

    reg [17:0] n_value;
    reg [17:0] pair_count;
    reg [16:0] package_count;

    reg        value_reg;
    reg [17:0] answer_count;

    reg [17:0] answer_reg;
    reg [1:0]  reply_index;
    reg        answer_ready;
    reg        count_ok;
    reg        protocol_error;
    reg        stream_active;

    // 2段パイプライン用のストリーム状態。
    // SEND_A1で固定し、データパッケージごとの再計算を避ける。
    reg [17:0] total_pair_count_reg;
    reg [16:0] expected_package_count_reg;
    reg [17:0] remaining_pairs_reg;
    reg        final_pending;

    // 受信byteの上位側から順に、4組のA/Bを取り出す。
    wire a0;
    wire b0;
    wire a1;
    wire b1;
    wire a2;
    wire b2;
    wire a3;
    wire b3;

    wire value_next0;
    wire value_next1;
    wire value_next2;
    wire value_next3;

    wire diff0_raw;
    wire diff1_raw;
    wire diff2_raw;
    wire diff3_raw;
    wire diff0;
    wire diff1;
    wire diff2;
    wire diff3;
    wire [1:0] sum01;
    wire [1:0] sum23;
    wire [2:0] package_cost;

    wire [17:0] stream_total_pair_count;
    wire [18:0] stream_expected_package_count_wide;
    wire [2:0] valid_count;
    wire [17:0] remaining_pairs_next;
    wire [17:0] pair_count_next;
    wire [16:0] package_count_next;
    wire        last_value_next;
    wire [17:0] answer_count_next;
    wire        final_package;

    wire [17:0] final_answer1;
    wire [17:0] final_answer;
    wire        final_count_match;
    wire [7:0]  final_reply_header;
    wire [7:0]  spi_tx_data;
    wire        tx_data_hold;
    wire        reset_command;

    assign a0 = rx_data[7];
    assign b0 = rx_data[6];
    assign a1 = rx_data[5];
    assign b1 = rx_data[4];
    assign a2 = rx_data[3];
    assign b2 = rx_data[2];
    assign a3 = rx_data[1];
    assign b3 = rx_data[0];

    // M=2では加算剰余はXORと同じ。
    assign value_next0 = value_reg ^ b0;
    assign value_next1 = value_next0 ^ b1;
    assign value_next2 = value_next1 ^ b2;
    assign value_next3 = value_next2 ^ b3;

    assign diff0_raw = a0 ^ value_next0;
    assign diff1_raw = a1 ^ value_next1;
    assign diff2_raw = a2 ^ value_next2;
    assign diff3_raw = a3 ^ value_next3;

    // SEND_A1で取り込むストリーム中の不変値。
    assign stream_total_pair_count =
        (n_value >= 18'd1) ? (n_value - 18'd1) : 18'd0;
    assign stream_expected_package_count_wide =
        (n_value >= 18'd2) ?
        (({1'b0, n_value} - 19'd1 + 19'd3) >> 2) : 19'd0;

    // 更新前のremaining_pairs_regから、現在のbyteで有効な組数を決める。
    assign valid_count =
        (|remaining_pairs_reg[17:2]) ? 3'd4 :
        (remaining_pairs_reg[1:0] == 2'd3) ? 3'd3 :
        (remaining_pairs_reg[1:0] == 2'd2) ? 3'd2 :
        (remaining_pairs_reg[1:0] == 2'd1) ? 3'd1 : 3'd0;

    // 4組以上なら4を減らし、最後の1～3組なら0へ飽和させる。
    assign remaining_pairs_next =
        (|remaining_pairs_reg[17:2]) ?
        (remaining_pairs_reg - 18'd4) : 18'd0;

    // 最終パッケージの無効位置は加算しない。
    assign diff0 = (valid_count >= 3'd1) ? diff0_raw : 1'b0;
    assign diff1 = (valid_count >= 3'd2) ? diff1_raw : 1'b0;
    assign diff2 = (valid_count >= 3'd3) ? diff2_raw : 1'b0;
    assign diff3 = (valid_count >= 3'd4) ? diff3_raw : 1'b0;

    // 4個の不一致を2段の加算木で集計する。
    assign sum01 = {1'b0, diff0} + {1'b0, diff1};
    assign sum23 = {1'b0, diff2} + {1'b0, diff3};
    assign package_cost = {1'b0, sum01} + {1'b0, sum23};

    assign pair_count_next =
        pair_count + {15'd0, valid_count};
    assign package_count_next = package_count + 17'd1;

    assign last_value_next =
        (valid_count == 3'd1) ? value_next0 :
        (valid_count == 3'd2) ? value_next1 :
        (valid_count == 3'd3) ? value_next2 :
        (valid_count == 3'd4) ? value_next3 : value_reg;

    assign answer_count_next =
        answer_count + {15'd0, package_cost};

    // 更新後の残数が0になる有効パッケージを最終パッケージとする。
    assign final_package =
        (valid_count != 3'd0) && (remaining_pairs_next == 18'd0);

    // 第2段は、第1段で更新済みのレジスタ値だけを使用する。
    assign final_answer1 = n_value - answer_count;
    assign final_answer =
        (answer_count <= final_answer1) ?
        answer_count : final_answer1;
    assign final_count_match =
        (pair_count == total_pair_count_reg) &&
        (package_count == expected_package_count_reg);
    assign final_reply_header = {
        1'b1,
        final_count_match & ~protocol_error,
        4'b0000,
        final_answer[17:16]
    };

    // 第2段とSPIの送信データ取込みが同一クロックでも、
    // SPI側には更新前のtx_dataではなく確定済みヘッダを見せる。
    assign spi_tx_data =
        (final_pending && !rx_data_strobe) ?
        final_reply_header : tx_data;

    // RESETコマンドはストリーム外または最終pending中に解釈する。
    // 通常のストリーム処理中の3'b111は従来どおり問題データとして扱う。
    assign reset_command =
        rx_data_strobe &&
        (!stream_active || final_pending) &&
        (rx_data[7:5] == RESET);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_value        <= 18'd0;
            pair_count     <= 18'd0;
            package_count  <= 17'd0;
            value_reg      <= 1'b0;
            answer_count   <= 18'd0;
            answer_reg     <= 18'd0;
            reply_index    <= 2'd0;
            answer_ready   <= 1'b0;
            count_ok       <= 1'b0;
            protocol_error <= 1'b0;
            stream_active  <= 1'b0;
            tx_data        <= 8'h00;
            total_pair_count_reg       <= 18'd0;
            expected_package_count_reg <= 17'd0;
            remaining_pairs_reg        <= 18'd0;
            final_pending              <= 1'b0;
        end else if (reset_command) begin
            // RESETコマンドはpending処理と通常コマンドより優先する。
            n_value        <= 18'd0;
            pair_count     <= 18'd0;
            package_count  <= 17'd0;
            value_reg      <= 1'b0;
            answer_count   <= 18'd0;
            answer_reg     <= 18'd0;
            reply_index    <= 2'd0;
            answer_ready   <= 1'b0;
            count_ok       <= 1'b0;
            protocol_error <= 1'b0;
            stream_active  <= 1'b0;
            tx_data        <= 8'h00;
            total_pair_count_reg       <= 18'd0;
            expected_package_count_reg <= 17'd0;
            remaining_pairs_reg        <= 18'd0;
            final_pending              <= 1'b0;
        end else if (final_pending) begin
            if (rx_data_strobe) begin
                // pending中の次byteは余分なデータとして明示的に拒否する。
                count_ok       <= 1'b0;
                protocol_error <= 1'b1;
                answer_ready   <= 1'b0;
                stream_active  <= 1'b0;
                tx_data        <= 8'h00;
                final_pending  <= 1'b0;
            end else begin
                // 第2段：更新済みの集計レジスタから最終結果を確定する。
                answer_reg     <= final_answer;
                reply_index    <= 2'd0;
                answer_ready   <= 1'b1;
                count_ok       <= final_count_match;
                protocol_error <= protocol_error | ~final_count_match;
                stream_active  <= 1'b0;
                tx_data        <= final_reply_header;
                final_pending  <= 1'b0;
            end
        end else if (rx_data_strobe) begin
            if (stream_active) begin
                if (pair_count > total_pair_count_reg) begin
                    count_ok       <= 1'b0;
                    protocol_error <= 1'b1;
                    stream_active  <= 1'b0;
                    tx_data        <= 8'h00;
                    final_pending  <= 1'b0;
                end else if (valid_count == 3'd0) begin
                    count_ok       <= 1'b0;
                    protocol_error <= 1'b1;
                    stream_active  <= 1'b0;
                    tx_data        <= 8'h00;
                    final_pending  <= 1'b0;
                end else if (pair_count_next > total_pair_count_reg) begin
                    count_ok       <= 1'b0;
                    protocol_error <= 1'b1;
                    stream_active  <= 1'b0;
                    tx_data        <= 8'h00;
                    final_pending  <= 1'b0;
                end else begin
                    // 第1段：1byte分を集計して既存レジスタへ格納する。
                    answer_count        <= answer_count_next;
                    pair_count          <= pair_count_next;
                    package_count       <= package_count_next;
                    value_reg           <= last_value_next;
                    remaining_pairs_reg <= remaining_pairs_next;

                    if (final_package) begin
                        // 最終回答と個数整合判定は次クロックへ渡す。
                        final_pending <= 1'b1;
                    end
                end
            end else begin
                case (rx_data[7:5])
                    NOP: begin
                        // 答えは3byteで返す。
                        // 1byte目: VALID、COUNT_OK、予約、ANSWER[17:16]
                        // 2byte目: ANSWER[15:8]
                        // 3byte目: ANSWER[7:0]
                        if (answer_ready) begin
                            case (reply_index)
                                2'd0: begin
                                    tx_data     <= answer_reg[15:8];
                                    reply_index <= 2'd1;
                                end
                                2'd1: begin
                                    tx_data     <= answer_reg[7:0];
                                    reply_index <= 2'd2;
                                end
                                default: begin
                                    tx_data      <= 8'h00;
                                    reply_index  <= 2'd0;
                                    answer_ready <= 1'b0;
                                end
                            endcase
                        end else begin
                            tx_data <= 8'h00;
                        end
                    end

                    SEND_N_17_15: begin
                        n_value[17:15] <= rx_data[2:0];
                    end

                    SEND_N_14_10: begin
                        n_value[14:10] <= rx_data[4:0];
                    end

                    SEND_N_9_5: begin
                        n_value[9:5] <= rx_data[4:0];
                    end

                    SEND_N_4_0: begin
                        n_value[4:0] <= rx_data[4:0];
                    end

                    SEND_A1: begin
                        // A_1の最終値を0と仮定する候補を開始する。
                        value_reg                 <= 1'b0;
                        answer_count              <=
                            rx_data[0] ? 18'd1 : 18'd0;
                        pair_count                <= 18'd0;
                        package_count             <= 17'd0;
                        answer_reg                <= 18'd0;
                        reply_index               <= 2'd0;
                        answer_ready              <= 1'b0;
                        count_ok                  <= 1'b0;
                        protocol_error            <=
                            (n_value < 18'd2);
                        stream_active             <=
                            (n_value >= 18'd2);
                        tx_data                   <= 8'h00;
                        total_pair_count_reg      <=
                            stream_total_pair_count;
                        expected_package_count_reg <=
                            stream_expected_package_count_wide[16:0];
                        remaining_pairs_reg       <=
                            stream_total_pair_count;
                        final_pending             <= 1'b0;
                    end

                    default: begin
                        // 3'b110は通常コマンドとして使用しない。
                        // RESETは優先処理済みなので、ここには到達しない。
                    end
                endcase
            end
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

        .i_tx_data(spi_tx_data),
        .o_tx_data_hold(tx_data_hold)
    );

endmodule
