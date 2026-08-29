(* top *) module main (
    // Shrike-Lite external clock/reset and SPI pins.
    (* iopad_external_pin, clkbuf_inhibit *) input clk,
    (* iopad_external_pin *) output clk_en,
    (* iopad_external_pin *) input rst_n,

    (* iopad_external_pin *) input  spi_ss_n,
    (* iopad_external_pin *) input  spi_sck,
    (* iopad_external_pin *) input  spi_mosi,
    (* iopad_external_pin *) output spi_miso,
    (* iopad_external_pin *) output spi_miso_en
);

    localparam [7:0] DUMMY_BYTE = 8'h00;
    localparam [7:0] ASCII_A    = 8'h41;
    localparam [7:0] ASCII_DOT  = 8'h2e;

    assign clk_en = 1'b1;

    wire [7:0] rx_data;
    wire       rx_data_strobe;
    reg  [7:0] tx_data;

    // ABC472A is a one-byte stream transform. No input string is buffered.
    // While CS is inactive, prepare a fixed first-byte dummy so a completed
    // previous transaction cannot leak into the next transaction.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_data <= DUMMY_BYTE;
        end else if (!spi_miso_en) begin
            tx_data <= DUMMY_BYTE;
        end else if (rx_data_strobe) begin
            tx_data <= (rx_data == ASCII_A) ? ASCII_A : ASCII_DOT;
        end
    end

    // Unmodified V3-template SPI target: Mode 0, 8-bit, MSB-first.
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
