// Renesas AN-FG-018のデュアルポート分散RAM記述を基にした128×7bit RAM。
// メモリ本体にはRESETを接続せず、読み出しデータ用レジスタだけを初期化する。
module monocolor_count_dist_ram (
    input             i_wr_clk,
    input             i_rd_clk,
    input             i_rst_n,
    input             i_wr_en,
    input      [6:0]  i_wr_addr,
    input      [6:0]  i_wr_data,
    input             i_rd_en,
    input      [6:0]  i_rd_addr,
    output reg [6:0]  o_rd_data
);

    // 論理深さ128、幅7bit。色番号に対応するアドレス1～100を使用する。
    reg [6:0] mem_ram [127:0];

    // AN-FG-018と同じく、書き込みは書き込みクロックへ同期させる。
    always @(posedge i_wr_clk) begin
        if (i_wr_en)
            mem_ram[i_wr_addr] <= i_wr_data;
    end

    // AN-FG-018と同じ同期読み出し。アドレス設定の次クロックで値が有効になる。
    always @(posedge i_rd_clk) begin
        if (!i_rst_n)
            o_rd_data <= 7'd0;
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

    // ABC470Bの入力受信、read-modify-write、回答返却を制御するFSM状態。
    localparam [2:0] WAIT_START     = 3'd0;
    localparam [2:0] WAIT_N         = 3'd1;
    localparam [2:0] RECEIVE_C      = 3'd2;
    localparam [2:0] RMW_READ       = 3'd3;
    localparam [2:0] RMW_CAPTURE    = 3'd4;
    localparam [2:0] RMW_WRITE      = 3'd5;
    localparam [2:0] PREPARE_REPLY  = 3'd6;
    localparam [2:0] DONE           = 3'd7;

    // ===== 共通部分：内部クロックとSPI送受信データ =====
    assign clk_en = 1'b1;

    wire [7:0] rx_data;
    wire       rx_data_strobe;
    reg  [7:0] tx_data;

    // ===== 問題ごとに変更する部分 =====
    // テンプレートのループバック処理をABC470Bの色別カウントへ置き換える。
    reg [2:0] state;
    reg [6:0] n_reg;
    reg [6:0] received_count;
    reg [6:0] max_count;

    // 処理中の色と、最後の入力かどうかをwrite-back完了まで保持する。
    reg [6:0] color_address;
    reg       color_is_last;
    reg [6:0] new_count;

    // START後の分散RAM逐次初期化器。
    reg       init_active;
    reg       init_done;
    reg [6:0] init_address;

    // 初期化とカウント更新が共有する分散RAM書き込みポート。
    wire       ram_write_enable;
    wire [6:0] ram_write_address;
    wire [6:0] ram_write_data;

    assign ram_write_enable = init_active || (state == RMW_WRITE);
    assign ram_write_address =
        init_active ? init_address : color_address;
    assign ram_write_data =
        init_active ? 7'd0 : new_count;

    // read要求クロックの次クロックから読出し値を利用する。
    wire       ram_read_enable;
    wire [6:0] ram_read_address;
    wire [6:0] ram_read_data;

    assign ram_read_enable = (state == RMW_READ);
    assign ram_read_address = color_address;

    monocolor_count_dist_ram u_count_ram (
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

    // 応答は意図的に1byte遅延し、spi_targetは受信通知の次のbyteへtx_dataを載せる。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= WAIT_START;
            n_reg          <= 7'd0;
            received_count <= 7'd0;
            max_count      <= 7'd0;
            color_address  <= 7'd0;
            color_is_last  <= 1'b0;
            new_count      <= 7'd0;
            init_active    <= 1'b0;
            init_done      <= 1'b0;
            init_address   <= 7'd1;
            tx_data        <= 8'h00;
        end else if (rx_data_strobe && rx_data == CMD_RESET) begin
            // SPI RESETコマンドは、すべての通信状態で最優先に処理する。
            // 分散RAM本体は変更せず、制御レジスタだけを初期状態へ戻す。
            state          <= WAIT_START;
            n_reg          <= 7'd0;
            received_count <= 7'd0;
            max_count      <= 7'd0;
            color_address  <= 7'd0;
            color_is_last  <= 1'b0;
            new_count      <= 7'd0;
            init_active    <= 1'b0;
            init_done      <= 1'b0;
            init_address   <= 7'd1;
            tx_data        <= RESET_ACK;
        end else if (rx_data_strobe && rx_data == CMD_START) begin
            // DONEを含むどの状態からでも、新しい問題を開始できる。
            // RAMのアドレス1～100は、この後100クロックかけて0へ戻す。
            state          <= WAIT_N;
            n_reg          <= 7'd0;
            received_count <= 7'd0;
            max_count      <= 7'd0;
            color_address  <= 7'd0;
            color_is_last  <= 1'b0;
            new_count      <= 7'd0;
            init_active    <= 1'b1;
            init_done      <= 1'b0;
            init_address   <= 7'd1;
            tx_data        <= START_ACK;
        end else begin
            // START後は100クロックでアドレス1～100を0へ戻す。
            // 初期化器は受信FSMと独立しているため、同時にNを受信できる。
            if (init_active) begin
                if (init_address == 7'd100) begin
                    init_active <= 1'b0;
                    init_done   <= 1'b1;
                end else begin
                    init_address <= init_address + 7'd1;
                end
            end

            case (state)
                WAIT_START: begin
                    if (rx_data_strobe)
                        tx_data <= 8'h00;
                end

                WAIT_N: begin
                    if (rx_data_strobe) begin
                        n_reg   <= rx_data[6:0];
                        state   <= RECEIVE_C;
                        tx_data <= 8'h00;
                    end
                end

                RECEIVE_C: begin
                    if (rx_data_strobe) begin
                        // 色番号をそのままRAMアドレスとして保持する。
                        color_address  <= rx_data[6:0];
                        color_is_last  <=
                            (received_count + 7'd1 >= n_reg);
                        received_count <= received_count + 7'd1;
                        state          <= RMW_READ;
                        tx_data        <= 8'h00;
                    end
                end

                RMW_READ: begin
                    // このクロックで同期readを発行する。
                    state <= RMW_CAPTURE;
                end

                RMW_CAPTURE: begin
                    // 1クロック前の同期read結果から更新後カウントを作る。
                    new_count <= ram_read_data + 7'd1;
                    state     <= RMW_WRITE;
                end

                RMW_WRITE: begin
                    // このクロックでwrite-backし、更新後の値で最大値を比較する。
                    if (new_count > max_count)
                        max_count <= new_count;

                    if (color_is_last)
                        state <= PREPARE_REPLY;
                    else
                        state <= RECEIVE_C;
                end

                PREPARE_REPLY: begin
                    // 最後のwrite-backとmax_count更新を反映した次クロックで確定する。
                    tx_data <= {1'b1, n_reg - max_count};
                    state   <= DONE;
                end

                DONE: begin
                    // NOPで繰り返し読み出せるよう、有効な回答を保持する。
                    tx_data <= tx_data;
                end

                default: begin
                    state          <= WAIT_START;
                    n_reg          <= 7'd0;
                    received_count <= 7'd0;
                    max_count      <= 7'd0;
                    color_address  <= 7'd0;
                    color_is_last  <= 1'b0;
                    new_count      <= 7'd0;
                    init_active    <= 1'b0;
                    init_done      <= 1'b0;
                    init_address   <= 7'd1;
                    tx_data        <= 8'h00;
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
