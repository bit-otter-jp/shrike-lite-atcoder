// Based on Vicharak Shrike official spi_loopback_led/spi_target.v.
// Modified for atcoder_spi_template_v2 on 2026-07-19:
// - Added o_rx_data_strobe.
// Original hardware design license: CERN OHL v1.2.

module spi_target #(
    parameter CPOL = 1'b0,
    parameter CPHA = 1'b0,
    parameter WIDTH = 8,
    parameter LSB = 1'b0
) (
    input i_clk,
    input i_rst_n,
    input i_enable,
    input i_ss_n,
    input i_sck,
    input i_mosi,
    output o_miso,
    output o_miso_oe,
    output reg [WIDTH-1:0] o_rx_data,
    output reg o_rx_data_valid,
    output o_rx_data_strobe,
    input [WIDTH-1:0] i_tx_data,
    output o_tx_data_hold
);

    reg [2:0] r_ss_n_sync;
    reg [2:0] r_sck_sync;
    reg [$clog2(WIDTH-1):0] r_transmision_count;
    reg [WIDTH-1:0] r_miso_data;
    reg r_rx_data_valid_d;

    wire w_sck_r_edge;
    wire w_sck_f_edge;
    wire w_sck_edge;
    wire w_sck_edge_op;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n)
            r_ss_n_sync <= 'b111;
        else if (i_enable)
            r_ss_n_sync <= {r_ss_n_sync[1:0], i_ss_n};
        else
            r_ss_n_sync <= 'b111;
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n)
            r_sck_sync <= 'h0;
        else if (i_enable)
            r_sck_sync <= {r_sck_sync[1:0], i_sck};
        else
            r_sck_sync <= 'h0;
    end

    assign w_sck_r_edge = ~r_sck_sync[2] & r_sck_sync[1];
    assign w_sck_f_edge = r_sck_sync[2] & ~r_sck_sync[1];
    assign w_sck_edge =
        (CPHA ^ CPOL) ? w_sck_f_edge : w_sck_r_edge;
    assign w_sck_edge_op =
        (CPHA ^ CPOL) ? w_sck_r_edge : w_sck_f_edge;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_transmision_count <= 'h0;
        end else if (!i_enable || r_ss_n_sync[1]) begin
            r_transmision_count <= 'h0;
        end else if (w_sck_edge) begin
            if (r_transmision_count == WIDTH-1)
                r_transmision_count <= 'h0;
            else
                r_transmision_count <= r_transmision_count + 1'b1;
        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_rx_data <= 'h0;
        end else if (w_sck_edge) begin
            if (LSB)
                o_rx_data <= {i_mosi, o_rx_data[WIDTH-1:1]};
            else
                o_rx_data <= {o_rx_data[WIDTH-2:0], i_mosi};
        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_rx_data_valid <= 1'b0;
        end else if (r_ss_n_sync[1] ||
                     (r_transmision_count == 0 && w_sck_edge)) begin
            o_rx_data_valid <= 1'b0;
        end else if (w_sck_edge &&
                     r_transmision_count == WIDTH-1) begin
            o_rx_data_valid <= 1'b1;
        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n)
            r_rx_data_valid_d <= 1'b0;
        else
            r_rx_data_valid_d <= o_rx_data_valid;
    end

    assign o_rx_data_strobe =
        o_rx_data_valid & ~r_rx_data_valid_d;

    assign o_tx_data_hold =
        (~CPHA & r_ss_n_sync[2] & ~r_ss_n_sync[1]) |
        (r_transmision_count == 0 & w_sck_edge_op);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_miso_data <= 'h0;
        end else if (o_tx_data_hold) begin
            r_miso_data <= i_tx_data;
        end else if (w_sck_edge_op) begin
            if (LSB)
                r_miso_data <= r_miso_data >> 1;
            else
                r_miso_data <= r_miso_data << 1;
        end
    end

    assign o_miso =
        LSB ? r_miso_data[0] : r_miso_data[WIDTH-1];
    assign o_miso_oe = ~r_ss_n_sync[2];

endmodule
