// BRAM_0専用の、512×8bit構成のアクセスモジュール。
// RATIOは2'b00固定で、使用するアドレスは0～511とする。
// REF_WRITE_CLKとREF_READ_CLKは、IO Plannerで50MHzクロックへ割り当てる。
// bram0_wclken_nとbram0_rclken_nは常時Lowとし、BRAMクロックを常に有効にする。
// ハードウェアリセット解除後とclear入力後に、BRAM_0の全領域をゼロクリアする。
// 読み出しは公式サンプルに合わせ、要求受付後に4クロック待ってデータを取り込む。
module bram0_8bit_access (
    input              clk,
    input              rst_n,
    input              clear,
    input              write_req,
    input      [8:0]   write_addr,
    input      [7:0]   write_data,
    input              read_req,
    input      [8:0]   read_addr,
    output reg [7:0]   read_data,
    output reg         read_valid,
    output reg         busy,

    output     [1:0]   bram0_ratio,
    output reg [7:0]   bram0_write_data,
    output reg [8:0]   bram0_write_addr,
    output reg         bram0_wen_n,
    output             bram0_wclken_n,
    input      [7:0]   bram0_read_data,
    output reg [8:0]   bram0_read_addr,
    output reg         bram0_ren_n,
    output             bram0_rclken_n
);

    // BRAM_0は512×8bit構成で使用し、書き込み・読み出しクロックを常に有効にする。
    assign bram0_ratio    = 2'b00;
    assign bram0_wclken_n = 1'b0;
    assign bram0_rclken_n = 1'b0;

    // 読み出しの待ちクロック数設定（0、1、2、3の4クロック）
    localparam [1:0] READ_WAIT_LAST = 2'd3;

    // 通常要求を待つ状態。
    localparam [2:0] STATE_IDLE        = 3'd0;
    // 通常書き込みのEnableパルスを終了する状態。
    localparam [2:0] STATE_WRITE_DONE  = 3'd1;
    // BRAM読み出しデータが有効になるまで待つ状態。
    localparam [2:0] STATE_READ_WAIT   = 3'd2;
    // 読み出し結果の通知を終了する状態。
    localparam [2:0] STATE_READ_VALID  = 3'd3;
    // ゼロクリア対象アドレスへ書き込みEnableを出す状態。
    localparam [2:0] STATE_CLEAR_WRITE = 3'd4;
    // ゼロクリアの書き込みEnableをHighへ戻し、次のアドレスへ進む状態。
    localparam [2:0] STATE_CLEAR_GAP   = 3'd5;

    reg [2:0] state;
    reg [8:0] clear_addr;
    reg [1:0] read_wait_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= STATE_CLEAR_WRITE;
            clear_addr       <= 9'd0;
            read_wait_count  <= 2'd0;
            read_data        <= 8'h00;
            read_valid       <= 1'b0;
            busy             <= 1'b1;
            bram0_write_data <= 8'h00;
            bram0_write_addr <= 9'd0;
            bram0_wen_n      <= 1'b1;
            bram0_read_addr  <= 9'd0;
            bram0_ren_n      <= 1'b1;
        end else begin
            // Enableとread_validは必要な状態だけで1クロック有効にする。
            bram0_wen_n <= 1'b1;
            bram0_ren_n <= 1'b1;
            read_valid  <= 1'b0;

            // clearは全状態で最優先し、進行中の処理を中断して0番地からやり直す。
            if (clear) begin
                state            <= STATE_CLEAR_WRITE;
                clear_addr       <= 9'd0;
                read_wait_count  <= 2'd0;
                busy             <= 1'b1;
                bram0_write_data <= 8'h00;
                bram0_write_addr <= 9'd0;
            end else begin
                case (state)
                    STATE_IDLE: begin
                        busy <= 1'b0;

                        // write_reqとread_reqが同時の場合は、write_reqを優先する。
                        if (write_req) begin
                            bram0_write_addr <= write_addr;
                            bram0_write_data <= write_data;
                            bram0_wen_n      <= 1'b0;
                            busy             <= 1'b1;
                            state            <= STATE_WRITE_DONE;
                        end else if (read_req) begin
                            bram0_read_addr <= read_addr;
                            bram0_ren_n     <= 1'b0;
                            read_wait_count <= 2'd0;
                            busy            <= 1'b1;
                            state           <= STATE_READ_WAIT;
                        end
                    end

                    STATE_WRITE_DONE: begin
                        // 直前の1クロックだけLowだった書き込みEnableを解除して完了する。
                        busy  <= 1'b0;
                        state <= STATE_IDLE;
                    end

                    STATE_READ_WAIT: begin
                        busy <= 1'b1;

                        // 要求受付クロックは数えず、次のクロックから4クロック数える。
                        if (read_wait_count == READ_WAIT_LAST) begin
                            read_data  <= bram0_read_data;
                            read_valid <= 1'b1;
                            state      <= STATE_READ_VALID;
                        end else begin
                            read_wait_count <= read_wait_count + 1'b1;
                        end
                    end

                    STATE_READ_VALID: begin
                        // read_validを1クロックで解除し、読み出し処理を完了する。
                        busy  <= 1'b0;
                        state <= STATE_IDLE;
                    end

                    STATE_CLEAR_WRITE: begin
                        // 現在のクリア対象へ8'h00を書き込むため、1クロックだけLowにする。
                        busy             <= 1'b1;
                        bram0_write_addr <= clear_addr;
                        bram0_write_data <= 8'h00;
                        bram0_wen_n      <= 1'b0;
                        state            <= STATE_CLEAR_GAP;
                    end

                    STATE_CLEAR_GAP: begin
                        // EnableがHighの間に次のアドレスを準備し、Lowの連続を防ぐ。
                        busy <= 1'b1;
                        if (clear_addr == 9'd511) begin
                            busy  <= 1'b0;
                            state <= STATE_IDLE;
                        end else begin
                            clear_addr       <= clear_addr + 1'b1;
                            bram0_write_addr <= clear_addr + 1'b1;
                            state            <= STATE_CLEAR_WRITE;
                        end
                    end

                    default: begin
                        // 不正状態からは、安全に0番地からのゼロクリアへ戻る。
                        state            <= STATE_CLEAR_WRITE;
                        clear_addr       <= 9'd0;
                        read_wait_count  <= 2'd0;
                        busy             <= 1'b1;
                        bram0_write_data <= 8'h00;
                        bram0_write_addr <= 9'd0;
                    end
                endcase
            end
        end
    end

endmodule
