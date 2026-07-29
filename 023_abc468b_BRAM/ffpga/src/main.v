// North BRAM側のBRAM_0専用で、BRAM構成は512×8bitとする。
// BRAMアクセス処理はbram0_8bit_access.vが担当する。
// BRAMアドレス0～M-1へ、未監視を8'h00、監視済みを8'h01として保持する。
// ハードウェアリセット解除後とCMD_RESET後に、BRAM全領域をゼロクリアする。
// clear中のSTARTはRTL側で拒否する。
// MicroPython試験ではSTARTの再試行を避けるため、CMD_RESET後に1ms待つ。
// REF_WRITE_CLKとREF_READ_CLKの50MHz BRAMクロックはIO Plannerで設定する。
// SPIは4MHz、CPOL=0、CPHA=0、MSB firstで使用する。
// RESET、START、およびVALID付き回答は意図的に1byte遅延して返信する。
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

    localparam [7:0] CMD_RESET = 8'hFF;
    localparam [7:0] CMD_START = 8'hFE;
    localparam [7:0] RESET_ACK = 8'h5A;
    localparam [7:0] START_ACK = 8'hA5;

    // START ACK読出し用NOPを問題入力Mと取り違えないため、専用状態を設ける。
    localparam [3:0] WAIT_START      = 4'd0;
    localparam [3:0] WAIT_START_NOP  = 4'd1;
    localparam [3:0] WAIT_M          = 4'd2;
    localparam [3:0] WAIT_D          = 4'd3;
    localparam [3:0] RECEIVE_S       = 4'd4;
    localparam [3:0] WAIT_UPDATES    = 4'd5;
    localparam [3:0] COUNT_REQUEST   = 4'd6;
    localparam [3:0] COUNT_WAIT_BUSY = 4'd7;
    localparam [3:0] COUNT_WAIT_VALID = 4'd8;
    localparam [3:0] PREPARE_REPLY   = 4'd9;
    localparam [3:0] DONE            = 4'd10;

    // ===== 共通部分：内部クロックとSPI送受信データ =====
    assign clk_en = 1'b1;

    wire [7:0] rx_data;
    wire       rx_data_strobe;
    reg  [7:0] tx_data;

    // ===== ABC468B問題固有部分 =====
    reg [3:0] state;
    reg [6:0] m_reg;
    reg [6:0] d_reg;
    reg [6:0] position;

    // RESET後のBRAM clear完了までSTARTを受け付けない。
    //
    // clear要求を出した直後は、bram_access_busyがまだLowの期間があり得る。
    // busyがLowという条件だけでSTART可否を判断すると、clear開始前に
    // START_ACKを返し、ホストがBRAMを使用可能だと誤認する可能性がある。
    //
    // busyが一度Highになったことを確認し、その後Lowへ戻った時点を
    // ゼロクリア完了と判断する。
    //
    // START_ACKは単なるプロトコル受付ではなく、BRAMの初期化が完了し、
    // ABC468B入力を受け付けられることを保証する。
    reg protocol_started;
    reg clear_active;
    reg clear_busy_seen;

    // BRAMアクセス要求と読み出し結果。
    reg        bram_clear;
    wire       bram_write_req;
    wire       bram_read_req;
    wire [7:0] bram_access_read_data;
    wire       bram_access_read_valid;
    wire       bram_access_busy;

    // 範囲更新器。BRAMの物理アドレス幅に合わせて9bitで保持する。
    reg       update_active;
    reg [8:0] update_address;
    reg [8:0] update_end;

    // 最後に完了した区間の右端。
    // 今後の要求開始位置は非減少なので、右端まで包含される要求は再書き込み不要である。
    reg       covered_valid;
    reg [8:0] covered_end;

    // 実行中更新と別に、次の1区間だけを保持する。
    reg       pending_valid;
    reg [8:0] pending_start;
    reg [8:0] pending_end;

    // 実行中、保留、許可された区間統合のいずれにも収容できない場合に立つ。
    reg update_overrun;

    // 最終集計器。
    reg [8:0] count_address;
    reg [6:0] answer_count;

    // 現在のS[position]がGだった場合の更新範囲を0～M-1へクリップする。
    wire [7:0] position_ext;
    wire [7:0] d_ext;
    wire [7:0] right_sum;
    wire [6:0] request_start_7;
    wire [6:0] request_end_7;
    wire [8:0] request_start;
    wire [8:0] request_end;

    assign position_ext = {1'b0, position};
    assign d_ext        = {1'b0, d_reg};
    assign right_sum    = position_ext + d_ext;
    assign request_start_7 =
        (position >= d_reg) ? (position - d_reg) : 7'd0;
    assign request_end_7 =
        (right_sum >= {1'b0, m_reg})
            ? (m_reg - 7'd1)
            : right_sum[6:0];
    assign request_start = {2'b00, request_start_7};
    assign request_end   = {2'b00, request_end_7};

    // busyがLowの1クロックだけ要求を提示する。
    // bram0_8bit_accessは同じクロック端で要求と現在アドレスを受け付けるため、
    // 更新アドレスはこの条件が成立したクロックでだけ進める。
    assign bram_write_req = update_active && !bram_access_busy;
    assign bram_read_req =
        (state == COUNT_REQUEST) && !bram_access_busy;

    wire update_finishing;
    wire pending_consumed;
    wire pending_recovering;
    assign update_finishing =
        bram_write_req && (update_address == update_end);
    assign pending_consumed =
        update_finishing && pending_valid;
    assign pending_recovering =
        !update_active && pending_valid && !bram_access_busy;

    // 応答は意図的に1byte遅延し、spi_targetは受信通知の次のbyteへtx_dataを載せる。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= WAIT_START;
            m_reg              <= 7'd0;
            d_reg              <= 7'd0;
            position           <= 7'd0;
            protocol_started   <= 1'b0;
            clear_active       <= 1'b1;
            clear_busy_seen    <= 1'b0;
            bram_clear         <= 1'b0;
            update_active      <= 1'b0;
            update_address     <= 9'd0;
            update_end         <= 9'd0;
            covered_valid      <= 1'b0;
            covered_end        <= 9'd0;
            pending_valid      <= 1'b0;
            pending_start      <= 9'd0;
            pending_end        <= 9'd0;
            update_overrun     <= 1'b0;
            count_address      <= 9'd0;
            answer_count       <= 7'd0;
            tx_data            <= 8'h00;
        end else begin
            bram_clear <= 1'b0;

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

            // RESETはすべての通信状態と問題処理より優先する。
            if (rx_data_strobe && (rx_data == CMD_RESET)) begin
                state              <= WAIT_START;
                m_reg              <= 7'd0;
                d_reg              <= 7'd0;
                position           <= 7'd0;
                protocol_started   <= 1'b0;
                clear_active       <= 1'b1;
                clear_busy_seen    <= 1'b0;
                bram_clear         <= 1'b1;
                update_active      <= 1'b0;
                update_address     <= 9'd0;
                update_end         <= 9'd0;
                covered_valid      <= 1'b0;
                covered_end        <= 9'd0;
                pending_valid      <= 1'b0;
                pending_start      <= 9'd0;
                pending_end        <= 9'd0;
                update_overrun     <= 1'b0;
                count_address      <= 9'd0;
                answer_count       <= 7'd0;
                tx_data            <= RESET_ACK;
            end

            // START_ACKはBRAM初期化完了後だけ返す。
            // clear中のSTARTは保留せず、非ACK値0x00を返してSTART前へ留める。
            else if (rx_data_strobe && (rx_data == CMD_START)) begin
                m_reg            <= 7'd0;
                d_reg            <= 7'd0;
                position         <= 7'd0;
                update_active    <= 1'b0;
                update_address   <= 9'd0;
                update_end       <= 9'd0;
                covered_valid    <= 1'b0;
                covered_end      <= 9'd0;
                pending_valid    <= 1'b0;
                pending_start    <= 9'd0;
                pending_end      <= 9'd0;
                update_overrun   <= 1'b0;
                count_address    <= 9'd0;
                answer_count     <= 7'd0;

                if (!clear_active && !bram_access_busy) begin
                    protocol_started <= 1'b1;
                    state            <= WAIT_START_NOP;
                    tx_data          <= START_ACK;
                end else begin
                    protocol_started <= 1'b0;
                    state            <= WAIT_START;
                    tx_data          <= 8'h00;
                end
            end

            else begin
                // BRAM更新器はSPI受信FSMと並行して動作する。
                if (update_active && bram_write_req) begin
                    if (update_address == update_end) begin
                        covered_valid <= 1'b1;
                        covered_end   <= update_end;
                        if (pending_valid) begin
                            // 最終wordの受付と同じクロックで保留区間へ切り替える。
                            // BRAM側busyが次の要求までの間隔を保証するため、
                            // アイドル状態を別に挟まず安全に連結できる。
                            update_active  <= 1'b1;
                            update_address <= pending_start;
                            update_end     <= pending_end;
                            pending_valid  <= 1'b0;
                        end else begin
                            update_active <= 1'b0;
                        end
                    end else begin
                        update_address <= update_address + 9'd1;
                    end
                end else if (pending_recovering) begin
                    // 完了受付と同じクロックに新規保留が生じた場合の回収経路。
                    update_active  <= 1'b1;
                    update_address <= pending_start;
                    update_end     <= pending_end;
                    pending_valid  <= 1'b0;
                end

                case (state)
                    WAIT_START: begin
                        // START前は問題入力を受け付けない。
                        if (rx_data_strobe)
                            tx_data <= 8'h00;
                    end

                    WAIT_START_NOP: begin
                        if (rx_data_strobe) begin
                            // START_ACKを読み出す1byteは問題入力へ数えない。
                            state   <= WAIT_M;
                            tx_data <= 8'h00;
                        end
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
                            d_reg     <= rx_data[6:0];
                            position  <= 7'd0;
                            state     <= RECEIVE_S;
                            tx_data   <= 8'h00;
                        end
                    end

                    RECEIVE_S: begin
                        if (rx_data_strobe) begin
                            // 0x01をGとして扱い、それ以外は'.'として扱う。
                            if (rx_data == 8'h01) begin
                                // 全更新は8'h01で、入力位置の増加に伴い区間端は
                                // 非減少である。このため、重複・隣接区間の和集合化は
                                // 監視済みを未監視へ戻さず、論理結果を変えない。
                                if (pending_consumed ||
                                    pending_recovering) begin
                                    // 旧保留を更新器へ渡す同じクロックで、
                                    // 新要求を統合するか空いた保留へ格納する。
                                    if (request_start <=
                                        (pending_end + 9'd1)) begin
                                        update_active <= 1'b1;
                                        if (request_end > pending_end)
                                            update_end <= request_end;
                                        pending_valid <= 1'b0;
                                    end else begin
                                        pending_valid <= 1'b1;
                                        pending_start <= request_start;
                                        pending_end   <= request_end;
                                    end
                                end else if (update_active) begin
                                    if (request_start <=
                                        (update_end + 9'd1)) begin
                                        // 実行中区間に含まれる要求は追加仕事が不要。
                                        // 右端だけが伸びる場合は同じ更新へ連結する。
                                        if (request_end > update_end) begin
                                            update_active <= 1'b1;
                                            update_end    <= request_end;
                                        end
                                    end else if (!pending_valid) begin
                                        pending_valid <= 1'b1;
                                        pending_start <= request_start;
                                        pending_end   <= request_end;
                                    end else if (request_start <=
                                                 (pending_end + 9'd1)) begin
                                        if (request_end > pending_end)
                                            pending_end <= request_end;
                                    end else begin
                                        update_overrun <= 1'b1;
                                    end
                                end else if (pending_valid) begin
                                    if (request_start <=
                                        (pending_end + 9'd1)) begin
                                        if (request_end > pending_end)
                                            pending_end <= request_end;
                                    end else begin
                                        update_overrun <= 1'b1;
                                    end
                                end else if (covered_valid &&
                                             request_start <=
                                             (covered_end + 9'd1)) begin
                                    // 完了済み区間に含まれる部分はBRAM上ですでに1である。
                                    // 右端が伸びる場合だけ、未書込みの末尾を新規更新する。
                                    if (request_end > covered_end) begin
                                        update_active  <= 1'b1;
                                        update_address <=
                                            covered_end + 9'd1;
                                        update_end     <= request_end;
                                    end
                                end else begin
                                    update_active  <= 1'b1;
                                    update_address <= request_start;
                                    update_end     <= request_end;
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
                        // 最後の書き込み要求を発行済みでもbusy中は集計しない。
                        // これにより、最後のBRAM書き込み完了が必ず集計開始に先行する。
                        if (!update_active &&
                            !pending_valid &&
                            !bram_access_busy &&
                            !bram_write_req) begin
                            count_address <= 9'd0;
                            answer_count  <= 7'd0;
                            state         <= COUNT_REQUEST;
                        end
                    end

                    COUNT_REQUEST: begin
                        // busyがLowの1クロックだけ読み出し要求を出す。
                        if (!bram_access_busy)
                            state <= COUNT_WAIT_BUSY;
                    end

                    COUNT_WAIT_BUSY: begin
                        // 要求直後のbusy立上りを確認してからread_valid待ちへ進む。
                        if (bram_access_busy)
                            state <= COUNT_WAIT_VALID;
                    end

                    COUNT_WAIT_VALID: begin
                        // read_validより前のread_dataは使用しない。
                        if (bram_access_read_valid) begin
                            if (bram_access_read_data == 8'h00)
                                answer_count <= answer_count + 7'd1;

                            if (count_address + 9'd1 >=
                                {2'b00, m_reg}) begin
                                state <= PREPARE_REPLY;
                            end else begin
                                count_address <= count_address + 9'd1;
                                state         <= COUNT_REQUEST;
                            end
                        end
                    end

                    PREPARE_REPLY: begin
                        // 最終要素の非ブロッキング加算を反映した次クロックでVALIDを立てる。
                        tx_data <= {1'b1, answer_count};
                        state   <= DONE;
                    end

                    DONE: begin
                        // NOPで繰り返し読み出せるよう、有効な回答を保持する。
                        tx_data <= tx_data;
                    end

                    default: begin
                        state            <= WAIT_START;
                        m_reg            <= 7'd0;
                        d_reg            <= 7'd0;
                        position         <= 7'd0;
                        protocol_started <= 1'b0;
                        update_active    <= 1'b0;
                        update_address   <= 9'd0;
                        update_end       <= 9'd0;
                        covered_valid    <= 1'b0;
                        covered_end      <= 9'd0;
                        pending_valid    <= 1'b0;
                        pending_start    <= 9'd0;
                        pending_end      <= 9'd0;
                        update_overrun   <= 1'b0;
                        count_address    <= 9'd0;
                        answer_count     <= 7'd0;
                        tx_data          <= 8'h00;
                    end
                endcase
            end
        end
    end

    // ===== 共通部分 =====

    // 公式サンプルから取り込んだSPI Slaveモジュール。
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

    // BRAM_0アクセス共通モジュールとの接続。
    // 問題固有部分は、このモジュールの抽象化された読み書き信号を使用する。
    bram0_8bit_access u_bram0_8bit_access (
        .clk              (clk),
        .rst_n            (rst_n),
        .clear            (bram_clear),
        .write_req        (bram_write_req),
        .write_addr       (update_address),
        .write_data       (8'h01),
        .read_req         (bram_read_req),
        .read_addr        (count_address),
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
