(* top *) module main (
    // ===== Shrike-Lite共通端子 =====
    (* iopad_external_pin, clkbuf_inhibit *) input  clk,
    (* iopad_external_pin *)                 output clk_en,
    (* iopad_external_pin *)                 input  rst_n,

    // ===== 4bit双方向データバス =====
    (* iopad_external_pin *) input  [3:0] data_in,
    (* iopad_external_pin *) output [3:0] data_out,
    (* iopad_external_pin *) output [3:0] data_oe,

    // ===== パラレル通信制御 =====
    (* iopad_external_pin *) input  parallel_clk,
    (* iopad_external_pin *) output req_out,
    (* iopad_external_pin *) output req_oe
);

// ===== 固定接続 =====
assign clk_en = 1'b1;
assign req_oe = rst_n;

// ===== 外部出力 =====
reg [3:0] data_out_reg;
reg       fpga_bus_owner;
reg       req_out_reg;

assign data_out = data_out_reg;
assign data_oe  = (rst_n && fpga_bus_owner) ? 4'b1111 : 4'b0000;
assign req_out  = rst_n ? req_out_reg : 1'b0;

// ===== parallel_clkの2段同期とエッジ検出 =====
reg parallel_clk_meta;
reg parallel_clk_sync;
reg parallel_clk_prev;

wire parallel_clk_rise;
wire parallel_clk_fall;

assign parallel_clk_rise =  parallel_clk_sync && !parallel_clk_prev;
assign parallel_clk_fall = !parallel_clk_sync &&  parallel_clk_prev;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        parallel_clk_meta <= 1'b0;
        parallel_clk_sync <= 1'b0;
        parallel_clk_prev <= 1'b0;
    end else begin
        parallel_clk_meta <= parallel_clk;
        parallel_clk_sync <= parallel_clk_meta;
        parallel_clk_prev <= parallel_clk_sync;
    end
end

// ===== Phase 1通信状態 =====
localparam [2:0] ST_RX_COMMAND    = 3'd0;
localparam [2:0] ST_RX_DATA       = 3'd1;
localparam [2:0] ST_WAIT_GRANT    = 3'd2;
localparam [2:0] ST_GRANT_LOW     = 3'd3;
localparam [2:0] ST_TX_RESPONSE   = 3'd4;

localparam [7:0] STATUS_OK          = 8'h00;
localparam [7:0] STATUS_UNSUPPORTED = 8'hE1;
localparam [7:0] STATUS_PROTOCOL_ERROR = 8'hE2;

reg [2:0] state;
reg       rx_high_pending;
reg [3:0] rx_high_nibble;
reg [7:0] tx_status;
reg [7:0] tx_result;
reg       tx_has_result;
reg [1:0] tx_nibble_index;
reg       protocol_error;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state             <= ST_RX_COMMAND;
        rx_high_pending   <= 1'b0;
        rx_high_nibble    <= 4'b0000;
        tx_status         <= STATUS_OK;
        tx_result         <= 8'h00;
        tx_has_result     <= 1'b0;
        tx_nibble_index   <= 2'd0;
        protocol_error    <= 1'b0;
        data_out_reg      <= 4'b0000;
        fpga_bus_owner    <= 1'b0;
        req_out_reg       <= 1'b0;
    end else begin
        case (state)
            ST_RX_COMMAND: begin
                // RP2040が所有中なのでFPGA出力は常に無効
                fpga_bus_owner <= 1'b0;
                req_out_reg    <= 1'b0;
                data_out_reg   <= 4'b0000;

                if (parallel_clk_rise) begin
                    if (!rx_high_pending) begin
                        // 1クロック目は上位ニブル
                        rx_high_nibble  <= data_in;
                        rx_high_pending <= 1'b1;
                    end else begin
                        // 2クロック目でコマンドbyteを確定
                        rx_high_pending <= 1'b0;
                        if ({rx_high_nibble, data_in} == 8'h00) begin
                            // 通信FSMはACK完了まで維持する
                            protocol_error <= 1'b0;
                            rx_high_nibble <= 4'b0000;
                            tx_status       <= STATUS_OK;
                            tx_result       <= 8'h00;
                            tx_has_result   <= 1'b0;
                            req_out_reg     <= 1'b1;
                            state           <= ST_WAIT_GRANT;
                        end else if ({rx_high_nibble, data_in} == 8'h01) begin
                            state <= ST_RX_DATA;
                        end else begin
                            tx_status     <= STATUS_UNSUPPORTED;
                            tx_result     <= 8'h00;
                            tx_has_result <= 1'b0;
                            req_out_reg   <= 1'b1;
                            state         <= ST_WAIT_GRANT;
                        end
                    end
                end
            end

            ST_RX_DATA: begin
                // INVERTの固定長1byteパラメータを受信
                if (parallel_clk_rise) begin
                    if (!rx_high_pending) begin
                        rx_high_nibble  <= data_in;
                        rx_high_pending <= 1'b1;
                    end else begin
                        rx_high_pending <= 1'b0;
                        tx_status       <= STATUS_OK;
                        tx_result       <= ~{rx_high_nibble, data_in};
                        tx_has_result   <= 1'b1;
                        req_out_reg     <= 1'b1;
                        state           <= ST_WAIT_GRANT;
                    end
                end
            end

            ST_WAIT_GRANT: begin
                // この立ち上がりはGrant Clockであり、データには数えない
                if (parallel_clk_rise)
                    state <= ST_GRANT_LOW;
            end

            ST_GRANT_LOW: begin
                // Grant ClockがLowへ戻ってからバスを駆動する
                if (parallel_clk_fall) begin
                    fpga_bus_owner  <= 1'b1;
                    data_out_reg    <= tx_status[7:4];
                    tx_nibble_index <= 2'd0;
                    state           <= ST_TX_RESPONSE;
                end
            end

            ST_TX_RESPONSE: begin
                // 立ち上がり中は値を保持し、Low期間の開始時に次を準備
                if (parallel_clk_fall) begin
                    case (tx_nibble_index)
                        2'd0: begin
                            data_out_reg    <= tx_status[3:0];
                            tx_nibble_index <= 2'd1;
                        end

                        2'd1: begin
                            if (tx_has_result) begin
                                data_out_reg    <= tx_result[7:4];
                                tx_nibble_index <= 2'd2;
                            end else begin
                                fpga_bus_owner  <= 1'b0;
                                req_out_reg     <= 1'b0;
                                data_out_reg    <= 4'b0000;
                                rx_high_pending <= 1'b0;
                                state           <= ST_RX_COMMAND;
                            end
                        end

                        2'd2: begin
                            data_out_reg    <= tx_result[3:0];
                            tx_nibble_index <= 2'd3;
                        end

                        2'd3: begin
                            fpga_bus_owner  <= 1'b0;
                            req_out_reg     <= 1'b0;
                            data_out_reg    <= 4'b0000;
                            rx_high_pending <= 1'b0;
                            state           <= ST_RX_COMMAND;
                        end

                        default: begin
                            fpga_bus_owner  <= 1'b0;
                            req_out_reg     <= 1'b0;
                            data_out_reg    <= 4'b0000;
                            rx_high_pending <= 1'b0;
                            tx_status       <= STATUS_PROTOCOL_ERROR;
                            tx_result       <= 8'h00;
                            tx_has_result   <= 1'b0;
                            tx_nibble_index <= 2'd0;
                            protocol_error  <= 1'b1;
                            state           <= ST_RX_COMMAND;
                        end
                    endcase
                end
            end

            default: begin
                // 不正状態では直ちにバスを解放して受信待機へ復帰
                state             <= ST_RX_COMMAND;
                rx_high_pending   <= 1'b0;
                rx_high_nibble    <= 4'b0000;
                tx_status         <= STATUS_PROTOCOL_ERROR;
                tx_result         <= 8'h00;
                tx_has_result     <= 1'b0;
                tx_nibble_index   <= 2'd0;
                protocol_error    <= 1'b1;
                data_out_reg      <= 4'b0000;
                fpga_bus_owner    <= 1'b0;
                req_out_reg       <= 1'b0;
            end
        endcase
    end
end

endmodule
