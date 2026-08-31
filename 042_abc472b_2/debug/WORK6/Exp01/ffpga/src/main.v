module exp01_lengths_ram (
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

    reg [16:0] mem_ram [127:0];

    always @(posedge i_wr_clk) begin
        if (i_wr_en)
            mem_ram[i_wr_addr] <= i_wr_data;
    end

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
    localparam [2:0] READ_ISSUE     = 3'd1;
    localparam [2:0] READ_CAPTURE   = 3'd2;
    localparam [2:0] TELEMETRY_READY = 3'd3;

    assign clk_en = 1'b1;

    wire [7:0] rx_data;
    wire       rx_data_strobe;
    reg  [7:0] tx_data;

    reg [2:0] state;
    reg        n_received;
    reg [6:0]  n_reg;
    reg [6:0]  lengths_received;
    reg [1:0]  length_byte_index;
    reg [15:0] length_high_bytes;
    reg [23:0] total_sum;

    reg [16:0] shadow0;
    reg [16:0] shadow1;
    reg [16:0] shadow2;
    reg [16:0] ram_readback0;
    reg [16:0] ram_readback1;
    reg [16:0] ram_readback2;
    reg [6:0]  debug_read_address;
    reg [5:0]  reply_byte_index;

    wire [23:0] received_length = {length_high_bytes, rx_data};
    wire [16:0] received_length_17 = received_length[16:0];
    wire [23:0] received_length_ext = {7'd0, received_length_17};

    wire lengths_write_enable =
        (state == RECEIVE_INPUT) && n_received && rx_data_strobe &&
        (length_byte_index == 2'd2);
    wire [6:0]  lengths_write_address = lengths_received;
    wire [16:0] lengths_write_data = received_length_17;

    wire lengths_read_enable = (state == READ_ISSUE);
    wire [6:0] lengths_read_address = debug_read_address;
    wire [16:0] lengths_read_data;

    exp01_lengths_ram u_lengths_ram (
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= RECEIVE_INPUT;
            n_received          <= 1'b0;
            n_reg               <= 7'd0;
            lengths_received    <= 7'd0;
            length_byte_index   <= 2'd0;
            length_high_bytes   <= 16'd0;
            total_sum           <= 24'd0;
            shadow0             <= 17'd0;
            shadow1             <= 17'd0;
            shadow2             <= 17'd0;
            ram_readback0       <= 17'd0;
            ram_readback1       <= 17'd0;
            ram_readback2       <= 17'd0;
            debug_read_address  <= 7'd0;
            reply_byte_index    <= 6'd0;
            tx_data             <= 8'h00;
        end else begin
            case (state)
                RECEIVE_INPUT: begin
                    if (rx_data_strobe) begin
                        tx_data <= 8'h00;
                        if (!n_received) begin
                            n_received        <= 1'b1;
                            n_reg             <= rx_data[6:0];
                            lengths_received  <= 7'd0;
                            length_byte_index <= 2'd0;
                            length_high_bytes <= 16'd0;
                            total_sum         <= 24'd0;
                            shadow0           <= 17'd0;
                            shadow1           <= 17'd0;
                            shadow2           <= 17'd0;
                            ram_readback0     <= 17'd0;
                            ram_readback1     <= 17'd0;
                            ram_readback2     <= 17'd0;
                            debug_read_address <= 7'd0;
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
                                    length_byte_index <= 2'd0;
                                    total_sum <= total_sum + received_length_ext;
                                    case (lengths_received)
                                        7'd0: shadow0 <= received_length_17;
                                        7'd1: shadow1 <= received_length_17;
                                        7'd2: shadow2 <= received_length_17;
                                        default: begin end
                                    endcase

                                    lengths_received <= lengths_received + 7'd1;
                                    if (lengths_received + 7'd1 >= n_reg) begin
                                        reply_byte_index <= 6'd0;
                                        debug_read_address <= 7'd0;
                                        tx_data          <= 8'h00;
                                        state            <= READ_ISSUE;
                                    end
                                end
                            endcase
                        end
                    end
                end

                READ_ISSUE: state <= READ_CAPTURE;
                READ_CAPTURE: begin
                    case (debug_read_address)
                        7'd0: ram_readback0 <= lengths_read_data;
                        7'd1: ram_readback1 <= lengths_read_data;
                        7'd2: ram_readback2 <= lengths_read_data;
                        default: begin end
                    endcase

                    if (debug_read_address + 7'd1 >= n_reg) begin
                        reply_byte_index <= 6'd0;
                        tx_data          <= 8'h00;
                        state            <= TELEMETRY_READY;
                    end else begin
                        debug_read_address <= debug_read_address + 7'd1;
                        state              <= READ_ISSUE;
                    end
                end

                TELEMETRY_READY: begin
                    if (rx_data_strobe) begin
                        reply_byte_index <= reply_byte_index + 6'd1;
                        case (reply_byte_index)
                            6'd0:  tx_data <= 8'hA6;
                            6'd1:  tx_data <= 8'h01;
                            6'd2:  tx_data <= {1'b0, n_reg};
                            6'd3:  tx_data <= {1'b0, lengths_received};
                            6'd4:  tx_data <= {6'd0, length_byte_index};
                            6'd5:  tx_data <= {7'd0, shadow0[16]};
                            6'd6:  tx_data <= shadow0[15:8];
                            6'd7:  tx_data <= shadow0[7:0];
                            6'd8:  tx_data <= {7'd0, shadow1[16]};
                            6'd9:  tx_data <= shadow1[15:8];
                            6'd10: tx_data <= shadow1[7:0];
                            6'd11: tx_data <= {7'd0, shadow2[16]};
                            6'd12: tx_data <= shadow2[15:8];
                            6'd13: tx_data <= shadow2[7:0];
                            6'd14: tx_data <= {7'd0, ram_readback0[16]};
                            6'd15: tx_data <= ram_readback0[15:8];
                            6'd16: tx_data <= ram_readback0[7:0];
                            6'd17: tx_data <= {7'd0, ram_readback1[16]};
                            6'd18: tx_data <= ram_readback1[15:8];
                            6'd19: tx_data <= ram_readback1[7:0];
                            6'd20: tx_data <= {7'd0, ram_readback2[16]};
                            6'd21: tx_data <= ram_readback2[15:8];
                            6'd22: tx_data <= ram_readback2[7:0];
                            6'd23: tx_data <= total_sum[23:16];
                            6'd24: tx_data <= total_sum[15:8];
                            6'd25: tx_data <= total_sum[7:0];
                            default: begin
                                state               <= RECEIVE_INPUT;
                                n_received          <= 1'b0;
                                n_reg               <= 7'd0;
                                lengths_received    <= 7'd0;
                                length_byte_index   <= 2'd0;
                                length_high_bytes   <= 16'd0;
                                total_sum           <= 24'd0;
                                reply_byte_index    <= 6'd0;
                                tx_data             <= 8'h00;
                            end
                        endcase
                    end
                end

                default: begin
                    state      <= RECEIVE_INPUT;
                    n_received <= 1'b0;
                    tx_data    <= 8'h00;
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
