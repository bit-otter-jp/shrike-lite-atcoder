// Renesas AN-FG-018とREF/abc468b_distRAMの記述を基にした128x17bit分散RAM。
// メモリ本体はresetせず、同期readの出力レジスタだけをresetする。
module abc472b_lengths_ram (
    input              i_wr_clk,
    input              i_rd_clk,
    input              i_rst_n,
    input              i_wr_en,
    input      [6:0]   i_wr_addr,
    input      [16:0]  i_wr_data,
    input              i_rd_en,
    input      [6:0]   i_rd_addr,
    output reg [16:0]  o_rd_data
);

    // 論理深さ128、使用範囲0..99。全要素resetはRAM推論を妨げるため行わない。
    reg [16:0] mem_ram [127:0];

    always @(posedge i_wr_clk) begin
        if (i_wr_en)
            mem_ram[i_wr_addr] <= i_wr_data;
    end

    // read addressを提示した次clockからo_rd_dataを利用できる。
    always @(posedge i_rd_clk) begin
        if (!i_rst_n)
            o_rd_data <= 17'd0;
        else if (i_rd_en)
            o_rd_data <= mem_ram[i_rd_addr];
    end

endmodule


(* top *) module main (
    (* iopad_external_pin, clkbuf_inhibit *) input clk,
    (* iopad_external_pin *) output clk_en,
    (* iopad_external_pin *) input rst_n,

    (* iopad_external_pin *) input  spi_ss_n,
    (* iopad_external_pin *) input  spi_sck,
    (* iopad_external_pin *) input  spi_mosi,
    (* iopad_external_pin *) output spi_miso,
    (* iopad_external_pin *) output spi_miso_en
);

    localparam [2:0] RECEIVE_INPUT = 3'd0;
    localparam [2:0] CALC_READ     = 3'd1;
    localparam [2:0] CALC_EVALUATE = 3'd2;
    localparam [2:0] ANSWER_READY  = 3'd3;

    assign clk_en = 1'b1;

    wire [7:0] rx_data;
    wire       rx_data_strobe;
    reg  [7:0] tx_data;

    reg [2:0] state;

    // 入力受信。Nの後、各L_iを24bit big-endianの3byteとして組み立てる。
    reg        n_received;
    reg [6:0]  n_reg;
    reg [6:0]  lengths_received;
    reg [1:0]  length_byte_index;
    reg [15:0] length_high_bytes;
    reg [23:0] total_sum;

    // 同期DistRAM readをread/evaluateの2状態で扱う逐次CALC。
    reg [6:0]  calc_address;
    reg [23:0] prefix_sum;
    reg [23:0] best_diff;
    reg [23:0] answer;

    // 先頭dummyに続けてanswerのMSB/MID/LSBを返すためのbyte位置。
    reg [1:0] reply_byte_index;

    wire [23:0] received_length = {length_high_bytes, rx_data};
    wire [16:0] received_length_17 = received_length[16:0];
    wire [23:0] received_length_ext = {7'd0, received_length_17};

    wire lengths_write_enable =
        (state == RECEIVE_INPUT) && n_received && rx_data_strobe &&
        (length_byte_index == 2'd2);
    wire [6:0]  lengths_write_address = lengths_received;
    wire [16:0] lengths_write_data = received_length_17;

    wire        lengths_read_enable = (state == CALC_READ);
    wire [6:0]  lengths_read_address = calc_address;
    wire [16:0] lengths_read_data;

    abc472b_lengths_ram u_lengths_ram (
        .i_wr_clk(clk),
        .i_rd_clk(clk),
        .i_rst_n(rst_n),
        .i_wr_en(lengths_write_enable),
        .i_wr_addr(lengths_write_address),
        .i_wr_data(lengths_write_data),
        .i_rd_en(lengths_read_enable),
        .i_rd_addr(lengths_read_address),
        .o_rd_data(lengths_read_data)
    );

    wire [23:0] current_length = {7'd0, lengths_read_data};
    wire [23:0] prefix_after_read = prefix_sum + current_length;
    wire [23:0] right_after_read = total_sum - prefix_after_read;
    wire [23:0] current_diff =
        (prefix_after_read >= right_after_read)
            ? (prefix_after_read - right_after_read)
            : (right_after_read - prefix_after_read);
    wire [23:0] best_after_evaluate =
        (current_diff < best_diff) ? current_diff : best_diff;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= RECEIVE_INPUT;
            n_received          <= 1'b0;
            n_reg               <= 7'd0;
            lengths_received    <= 7'd0;
            length_byte_index   <= 2'd0;
            length_high_bytes   <= 16'd0;
            total_sum           <= 24'd0;
            calc_address        <= 7'd0;
            prefix_sum          <= 24'd0;
            best_diff           <= 24'hffffff;
            answer              <= 24'd0;
            reply_byte_index    <= 2'd0;
            tx_data             <= 8'h00;
        end else begin
            case (state)
                RECEIVE_INPUT: begin
                    // CS Highは入力状態へ影響しない。rx_data_strobeだけで進める。
                    if (rx_data_strobe) begin
                        tx_data <= 8'h00;
                        if (!n_received) begin
                            n_received        <= 1'b1;
                            n_reg             <= rx_data[6:0];
                            lengths_received  <= 7'd0;
                            length_byte_index <= 2'd0;
                            length_high_bytes <= 16'd0;
                            total_sum         <= 24'd0;
                        end else begin
                            case (length_byte_index)
                                2'd0: begin
                                    length_high_bytes[15:8] <= rx_data;
                                    length_byte_index       <= 2'd1;
                                end

                                2'd1: begin
                                    length_high_bytes[7:0] <= rx_data;
                                    length_byte_index      <= 2'd2;
                                end

                                default: begin
                                    // このclockにDistRAM writeも行われる。
                                    length_byte_index <= 2'd0;
                                    total_sum <= total_sum + received_length_ext;

                                    if (lengths_received + 7'd1 >= n_reg) begin
                                        // 最終L_i受信後、次clockから候補0をreadする。
                                        lengths_received <= lengths_received + 7'd1;
                                        calc_address     <= 7'd0;
                                        prefix_sum       <= 24'd0;
                                        best_diff        <= 24'hffffff;
                                        reply_byte_index <= 2'd0;
                                        tx_data          <= 8'h00;
                                        state            <= CALC_READ;
                                    end else begin
                                        lengths_received <= lengths_received + 7'd1;
                                    end
                                end
                            endcase
                        end
                    end
                end

                CALC_READ: begin
                    // 同期readを発行し、次clockのEVALUATEでデータを使用する。
                    state <= CALC_EVALUATE;
                end

                CALC_EVALUATE: begin
                    prefix_sum <= prefix_after_read;
                    best_diff  <= best_after_evaluate;

                    if (calc_address == n_reg - 7'd2) begin
                        answer           <= best_after_evaluate;
                        reply_byte_index <= 2'd0;
                        tx_data          <= 8'h00;
                        state            <= ANSWER_READY;
                    end else begin
                        calc_address <= calc_address + 7'd1;
                        state        <= CALC_READ;
                    end
                end

                ANSWER_READY: begin
                    // 別read burst: MISO = dummy, MSB, MID, LSB。
                    // 各dummy受信後に次byte用tx_dataを準備する。
                    if (rx_data_strobe) begin
                        case (reply_byte_index)
                            2'd0: begin
                                tx_data          <= answer[23:16];
                                reply_byte_index <= 2'd1;
                            end
                            2'd1: begin
                                tx_data          <= answer[15:8];
                                reply_byte_index <= 2'd2;
                            end
                            2'd2: begin
                                tx_data          <= answer[7:0];
                                reply_byte_index <= 2'd3;
                            end
                            default: begin
                                // LSBを運ぶ4byte目の完了後、次問題のN待ちへ戻る。
                                state             <= RECEIVE_INPUT;
                                n_received        <= 1'b0;
                                n_reg             <= 7'd0;
                                lengths_received  <= 7'd0;
                                length_byte_index <= 2'd0;
                                length_high_bytes <= 16'd0;
                                total_sum         <= 24'd0;
                                calc_address      <= 7'd0;
                                prefix_sum        <= 24'd0;
                                best_diff         <= 24'hffffff;
                                answer            <= 24'd0;
                                reply_byte_index  <= 2'd0;
                                tx_data           <= 8'h00;
                            end
                        endcase
                    end
                end

                default: begin
                    state               <= RECEIVE_INPUT;
                    n_received          <= 1'b0;
                    n_reg               <= 7'd0;
                    lengths_received    <= 7'd0;
                    length_byte_index   <= 2'd0;
                    length_high_bytes   <= 16'd0;
                    total_sum           <= 24'd0;
                    calc_address        <= 7'd0;
                    prefix_sum          <= 24'd0;
                    best_diff           <= 24'hffffff;
                    answer              <= 24'd0;
                    reply_byte_index    <= 2'd0;
                    tx_data             <= 8'h00;
                end
            endcase
        end
    end

    // REF/atcoder_spi_template_v3のSPI Targetを無変更で使用する。
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
