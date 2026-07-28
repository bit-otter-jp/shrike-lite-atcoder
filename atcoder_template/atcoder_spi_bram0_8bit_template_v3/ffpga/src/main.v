// North BRAM側のBRAM_0専用で、BRAM構成は512×8bitとする。
// BRAMアクセス処理はbram0_8bit_access.vが担当する。
// MOSIとMISOは、上位4bitをCMD、下位4bitをDATAとして使用する。
// 読み出し結果は、上位4bitと下位4bitの2byteに分けて返信する。
// ハードウェアリセット解除後とCMD_RESET後に、BRAM全領域をゼロクリアする。
// clear中のSTARTはRTL側で拒否する。
// MicroPython試験ではSTARTの再試行を避けるため、CMD_RESET後に1ms待つ。。
// REF_WRITE_CLKとREF_READ_CLKの50MHz BRAMクロックはIO Plannerで設定する。
// SPIは4MHz、CPOL=0、CPHA=0、MSB firstで使用する。
// 同期BRAMの読み出し待ちと1byte遅延応答を両立するため、
// アドレス確定時に先行読み出しし、CMD_READ受信時に保持値を返信する。
(* top *) module main (
    // ===== 共通部分：Shrike-LiteとSPIの外部端子 =====
    (* iopad_external_pin, clkbuf_inhibit *) input clk,
    (* iopad_external_pin *) output clk_en,
    (* iopad_external_pin *) input rst_n,

    (* iopad_external_pin *) input  spi_ss_n,
    (* iopad_external_pin *) input  spi_sck,
    (* iopad_external_pin *) input  spi_mosi,
    (* iopad_external_pin *) output spi_miso,
    (* iopad_external_pin *) output spi_miso_en,

    // BRAM_0専用接続
    // IO PlannerでForgeFPGA内部のBRAM_0端子へ割り当てる。
    (* iopad_external_pin *) output [1:0] bram0_ratio,
    (* iopad_external_pin *) output [7:0] bram0_write_data,
    (* iopad_external_pin *) output [8:0] bram0_write_addr,
    (* iopad_external_pin *) output       bram0_wen_n,
    (* iopad_external_pin *) output       bram0_wclken_n,
    (* iopad_external_pin *) input  [7:0] bram0_read_data,
    (* iopad_external_pin *) output [8:0] bram0_read_addr,
    (* iopad_external_pin *) output       bram0_ren_n,
    (* iopad_external_pin *) output       bram0_rclken_n
);

    // ===== 共通部分：内部クロックとSPI送受信データ =====
    assign clk_en = 1'b1;

    wire [7:0] rx_data;
    wire       rx_data_strobe;
    reg  [7:0] tx_data;

    // SPI受信完了を1クロックのストローブへ変換し、同じコマンドの重複処理を防ぐ。
    // V3ではspi_target.vのo_rx_data_strobeをそのまま使用する。

    // ============================================================
    // 問題ごとに変更する部分
    // ============================================================
    // 今回はBRAMテンプレートの動作確認用として、
    // SPIからBRAMのアドレスと書き込みデータを直接指定し、
    // bram0_8bit_accessへ読み書き要求を発行する。
    //
    // AtCoder問題を実装するときは、SPIコマンドによる直接制御に限らず、
    // 問題固有ロジックがアドレスやデータを生成してBRAMを操作してよい。
    // このため、以下のコマンド定義、保持レジスタ、要求生成、
    // 読み出し返信処理は問題固有部分として扱う。
    // ============================================================

    // 動作確認用SPIコマンド定義
    localparam [3:0] CMD_NOP           = 4'h0;
    localparam [3:0] CMD_SET_ADDR_MSB  = 4'h1;
    localparam [3:0] CMD_SET_ADDR_HIGH = 4'h2;
    localparam [3:0] CMD_SET_ADDR_LOW  = 4'h3;
    localparam [3:0] CMD_SET_DATA_HIGH = 4'h4;
    localparam [3:0] CMD_SET_DATA_LOW  = 4'h5;
    localparam [3:0] CMD_WRITE         = 4'h6;
    localparam [3:0] CMD_READ          = 4'h7;

    // SPI V3共通の8bit制御コマンドと1byte遅延ACK
    localparam [7:0] CMD_RESET = 8'hFF;
    localparam [7:0] CMD_START = 8'hFE;
    localparam [7:0] RESET_ACK = 8'h5A;
    localparam [7:0] START_ACK = 8'hA5;

    localparam [3:0] REPLY_IDLE = 4'h0;
    localparam [3:0] REPLY_HIGH = 4'h8;
    localparam [3:0] REPLY_LOW  = 4'h9;

    // 読み出し返信状態
    localparam [1:0] REPLY_STATE_IDLE = 2'd0;
    localparam [1:0] REPLY_STATE_HIGH = 2'd1;
    localparam [1:0] REPLY_STATE_LOW  = 2'd2;

    wire [3:0] rx_cmd;
    wire [3:0] rx_command_data;
    assign rx_cmd          = rx_data[7:4];
    assign rx_command_data = rx_data[3:0];

    // アドレスと書き込みデータの保持
    reg [8:0] held_bram_addr;
    reg [7:0] held_write_data;

    // BRAMアクセス要求と読み出し結果
    reg        bram_clear;
    reg        bram_write_req;
    reg        bram_read_req;
    wire [7:0] bram_access_read_data;
    wire       bram_access_read_valid;
    wire       bram_access_busy;
    reg  [7:0] held_read_data;
    reg  [1:0] reply_state;

    // SPI V3の開始状態と、4MHz返信用の先行読み出し保持
    reg        protocol_started;
    // BRAMのゼロクリア完了までSTARTを受け付けない。
    //
    // clear要求を出した直後は、bram_access_busyがまだLowの期間があり得る。
    // busyがLowという条件だけでSTART可否を判断すると、clear開始前に
    // START_ACKを返し、ホストがBRAMを使用可能だと誤認する可能性がある。
    //
    // busyが一度Highになったことを確認し、その後Lowへ戻った時点を
    // ゼロクリア完了と判断する。
    //
    // START_ACKは単なるプロトコル受付ではなく、BRAMの初期化が完了し、
    // 通常アクセス可能であることを保証する。
    reg        clear_active;
    reg        clear_busy_seen;
    reg        prefetch_valid;
    reg  [8:0] prefetched_read_addr;
    reg  [7:0] prefetched_read_data;
    reg  [8:0] read_request_addr;

    // BRAM読み書き動作確認用のSPIコマンド処理
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            held_bram_addr       <= 9'd0;
            held_write_data      <= 8'h00;
            bram_write_req       <= 1'b0;
            bram_read_req        <= 1'b0;
            bram_clear           <= 1'b0;
            held_read_data       <= 8'h00;
            reply_state          <= REPLY_STATE_IDLE;
            protocol_started     <= 1'b0;
            clear_active         <= 1'b1;
            clear_busy_seen      <= 1'b0;
            prefetch_valid       <= 1'b0;
            prefetched_read_addr <= 9'd0;
            prefetched_read_data <= 8'h00;
            read_request_addr    <= 9'd0;
            tx_data              <= 8'h00;
        end else begin
            // BRAM要求信号は、コマンドを受け付けたクロックだけHighにする。
            bram_write_req <= 1'b0;
            bram_read_req  <= 1'b0;
            bram_clear     <= 1'b0;

            // busyが一度Highになったことを確認してから、
            // Lowへ戻った時点をゼロクリア完了と判断する。
            // ハードウェアリセット直後のBRAMゼロクリアも同じ条件で監視する。
            if (clear_active) begin
                if (bram_access_busy) begin
                    clear_busy_seen <= 1'b1;
                end else if (clear_busy_seen) begin
                    clear_active    <= 1'b0;
                    clear_busy_seen <= 1'b0;
                end
            end

            // 読み出し結果を保持し、後続のCMD_READで上位4bit返信を設定する。
            // 先行読み出し結果は返信状態と分離して保持する。
            // これにより、値が有効になる前にSPI返信へ取り込まない。
            if (bram_access_read_valid) begin
                prefetched_read_addr <= read_request_addr;
                prefetched_read_data <= bram_access_read_data;
                prefetch_valid       <= 1'b1;
            end

            // RESETによるBRAMゼロクリア要求。busyや返信状態に関係なく最優先する。
            // 旧版の上位4bit判定から、SPI V3の8'hFF完全一致へ変更する。
            if (rx_data_strobe && (rx_data == CMD_RESET)) begin
                held_bram_addr       <= 9'd0;
                held_write_data      <= 8'h00;
                bram_write_req       <= 1'b0;
                bram_read_req        <= 1'b0;
                bram_clear           <= 1'b1;
                held_read_data       <= 8'h00;
                reply_state          <= REPLY_STATE_IDLE;
                protocol_started     <= 1'b0;
                clear_active         <= 1'b1;
                clear_busy_seen      <= 1'b0;
                prefetch_valid       <= 1'b0;
                prefetched_read_addr <= 9'd0;
                prefetched_read_data <= 8'h00;
                read_request_addr    <= 9'd0;
                tx_data              <= RESET_ACK;
            end

            // START_ACKはBRAM初期化完了後にだけ返し、その時点でSTARTを受け付ける。
            // clear中のSTARTは非ACKのIDLEを返し、後続コマンドも受け付けない。
            else if (rx_data_strobe && (rx_data == CMD_START)) begin
                reply_state <= REPLY_STATE_IDLE;
                if (!clear_active && !bram_access_busy) begin
                    protocol_started <= 1'b1;
                    tx_data          <= START_ACK;
                end else begin
                    protocol_started <= 1'b0;
                    tx_data          <= {REPLY_IDLE, 4'h0};
                end
            end

            // 読み出し返信中は、NOPだけで上位・下位・IDLEの順に進める。
            else if (rx_data_strobe && (reply_state != REPLY_STATE_IDLE)) begin
                if (rx_cmd == CMD_NOP) begin
                    case (reply_state)
                        REPLY_STATE_HIGH: begin
                            // MISOへの下位4bit返信
                            tx_data     <= {REPLY_LOW, held_read_data[3:0]};
                            reply_state <= REPLY_STATE_LOW;
                        end

                        REPLY_STATE_LOW: begin
                            tx_data     <= {REPLY_IDLE, 4'h0};
                            reply_state <= REPLY_STATE_IDLE;
                        end

                        default: begin
                            tx_data     <= 8'h00;
                            reply_state <= REPLY_STATE_IDLE;
                        end
                    endcase
                end
            end

            // START前はBRAM操作を受け付けず、ACK読出し用NOPで返信をIDLEへ戻す。
            else if (rx_data_strobe && !protocol_started) begin
                tx_data <= {REPLY_IDLE, 4'h0};
            end

            // 返信中でない場合だけ、通常のMOSIコマンドを処理する。
            else if (rx_data_strobe) begin
                case (rx_cmd)
                    CMD_NOP: begin
                        // 通常時のNOPでは保持値を変更しない。
                        tx_data <= {REPLY_IDLE, 4'h0};
                    end

                    CMD_SET_ADDR_MSB: begin
                        // アドレスbit8だけを更新し、DATA[3:1]は無視する。
                        held_bram_addr[8] <= rx_command_data[0];
                        prefetch_valid    <= 1'b0;
                        tx_data           <= {REPLY_IDLE, 4'h0};
                    end

                    CMD_SET_ADDR_HIGH: begin
                        held_bram_addr[7:4] <= rx_command_data;
                        prefetch_valid      <= 1'b0;
                        tx_data             <= {REPLY_IDLE, 4'h0};
                    end

                    CMD_SET_ADDR_LOW: begin
                        held_bram_addr[3:0] <= rx_command_data;
                        prefetch_valid      <= 1'b0;
                        tx_data             <= {REPLY_IDLE, 4'h0};

                        // 最下位アドレス受信で9bitアドレスが確定するため、
                        // BRAMの4クロック読み出し待ちを先行して開始する。
                        // 読み出し要求の発行。busy中と直前要求の受付中は無視する。
                        if (!bram_access_busy &&
                            !bram_write_req &&
                            !bram_read_req) begin
                            bram_read_req <= 1'b1;
                            read_request_addr <= {
                                held_bram_addr[8:4],
                                rx_command_data
                            };
                        end
                    end

                    CMD_SET_DATA_HIGH: begin
                        held_write_data[7:4] <= rx_command_data;
                        tx_data              <= {REPLY_IDLE, 4'h0};
                    end

                    CMD_SET_DATA_LOW: begin
                        held_write_data[3:0] <= rx_command_data;
                        tx_data              <= {REPLY_IDLE, 4'h0};
                    end

                    CMD_WRITE: begin
                        tx_data <= {REPLY_IDLE, 4'h0};

                        // 書き込み要求の発行。busy中と直前要求の受付中は無視する。
                        if (!bram_access_busy &&
                            !bram_write_req &&
                            !bram_read_req) begin
                            bram_write_req <= 1'b1;

                            // 書き込み値は既知なので、完了後のREADに備えて保持する。
                            // read-during-writeのBRAM出力値には依存しない。
                            prefetched_read_addr <= held_bram_addr;
                            prefetched_read_data <= held_write_data;
                            prefetch_valid       <= 1'b1;
                        end
                    end

                    CMD_READ: begin
                        // 先行読み出し済みの値を、次のSPI byteの上位返信に設定する。
                        // 通常手順ではSET_ADDR_LOWから2us以上あるため、
                        // BRAMの4クロック待ちを完了してからここへ到達する。
                        if (prefetch_valid &&
                            (prefetched_read_addr == held_bram_addr)) begin
                            // MISOへの上位4bit返信
                            held_read_data <= prefetched_read_data;
                            tx_data <= {
                                REPLY_HIGH,
                                prefetched_read_data[7:4]
                            };
                        end else begin
                            // 手順外のREADも返信形式を崩さず、0を返す。
                            held_read_data <= 8'h00;
                            tx_data        <= {REPLY_HIGH, 4'h0};
                        end
                        reply_state <= REPLY_STATE_HIGH;
                    end

                    default: begin
                        // 予約コマンド4'h8～4'hEは何も変更しない。
                        // 4'hFのうち8'hFEと8'hFF以外も予約値として扱う。
                        tx_data <= {REPLY_IDLE, 4'h0};
                    end
                endcase
            end
        end
    end

    // ============================================================
    // 共通部分
    // ============================================================

    // 公式サンプルから取り込んだSPI Slaveモジュール
    // SPIテンプレートV3の動作確認済み版を変更せずに使用する。
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

    // BRAM_0アクセス共通モジュールとの接続
    // 問題固有部分は、このモジュールの抽象化された読み書き信号を使用する。
    bram0_8bit_access u_bram0_8bit_access (
        .clk              (clk),
        .rst_n            (rst_n),
        .clear            (bram_clear),
        .write_req        (bram_write_req),
        .write_addr       (held_bram_addr),
        .write_data       (held_write_data),
        .read_req         (bram_read_req),
        .read_addr        (held_bram_addr),
        .read_data        (bram_access_read_data),
        .read_valid       (bram_access_read_valid),
        .busy             (bram_access_busy),

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

endmodule
