`timescale 1ns/1ps

// シミュレーション専用のBRAM_0モデル。
// 旧BRAMテンプレートと同じ512×8bit、9bitアドレス、Low有効Enableとする。
// 読み出し出力はクロック同期で更新し、bram0_8bit_access側の
// 4クロック待ちが完了するまで安定して保持する。
module bram0_model (
    input             clk,
    input      [7:0]  write_data,
    input      [8:0]  write_addr,
    input             wen_n,
    input             wclken_n,
    output reg [7:0]  read_data,
    input      [8:0]  read_addr,
    input             ren_n,
    input             rclken_n
);

    reg [7:0] memory [0:511];

    always @(posedge clk) begin
        if (!wclken_n && !wen_n)
            memory[write_addr] <= write_data;

        if (!rclken_n && !ren_n)
            read_data <= memory[read_addr];
    end

endmodule
