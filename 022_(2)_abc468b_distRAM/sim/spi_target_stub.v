// 既存の共通SPIターゲットに代わる、構文確認専用のスタブ。
// 機能を確認する統合シミュレーションでは使用しない。
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
    output [WIDTH-1:0] o_rx_data,
    output o_rx_data_valid,
    output o_rx_data_strobe,
    input [WIDTH-1:0] i_tx_data,
    output o_tx_data_hold
);

    assign o_miso = 1'b0;
    assign o_miso_oe = 1'b0;
    assign o_rx_data = {WIDTH{1'b0}};
    assign o_rx_data_valid = 1'b0;
    assign o_rx_data_strobe = 1'b0;
    assign o_tx_data_hold = 1'b0;

endmodule
