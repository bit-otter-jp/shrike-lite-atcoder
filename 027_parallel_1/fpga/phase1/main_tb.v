`timescale 1ns/1ps

module main_tb;

localparam integer PARALLEL_HALF_NS = 100;

reg        clk;
reg        rst_n;
reg        parallel_clk;
reg        rp_data_oe;
reg  [3:0] rp_data_out;

wire [3:0] data_bus;
wire [3:0] data_out;
wire [3:0] data_oe;
wire       clk_en;
wire       req_out;
wire       req_oe;

// RP2040側とFPGA側の2つのドライバで双方向バスを模擬する
assign data_bus = rp_data_oe ? rp_data_out : 4'bzzzz;
assign data_bus = (data_oe == 4'b1111) ? data_out : 4'bzzzz;

main dut (
    .clk          (clk),
    .clk_en       (clk_en),
    .rst_n        (rst_n),
    .data_in      (data_bus),
    .data_out     (data_out),
    .data_oe      (data_oe),
    .parallel_clk (parallel_clk),
    .req_out      (req_out),
    .req_oe       (req_oe)
);

initial clk = 1'b0;
always #5 clk = ~clk;

// 両側の出力許可が重なった瞬間にシミュレーションを停止する
always @(rp_data_oe or data_oe) begin
    if ((rp_data_oe === 1'b1) && (data_oe !== 4'b0000)) begin
        $display("TEST FAIL: BUS CONTENTION");
        $finish;
    end
end

task check_condition;
    input condition;
    input integer error_code;
    begin
        if (condition !== 1'b1) begin
            $display("TEST FAIL: CHECK %0d", error_code);
            $finish;
        end
    end
endtask

task parallel_pulse;
    begin
        #(PARALLEL_HALF_NS);
        parallel_clk = 1'b1;
        #(PARALLEL_HALF_NS);
        parallel_clk = 1'b0;
        #(PARALLEL_HALF_NS);
    end
endtask

task start_rp_request;
    begin
        check_condition(parallel_clk == 1'b0, 100);
        check_condition(req_out == 1'b0, 101);
        check_condition(data_oe == 4'b0000, 102);
        rp_data_oe = 1'b1;
        #(PARALLEL_HALF_NS * 2);
    end
endtask

task rp_send_nibble;
    input [3:0] value;
    begin
        check_condition(rp_data_oe == 1'b1, 110);
        check_condition(data_oe == 4'b0000, 111);
        rp_data_out = value;
        parallel_pulse;
    end
endtask

task rp_send_byte;
    input [7:0] value;
    begin
        // 必ず上位ニブルから送信する
        rp_send_nibble(value[7:4]);
        rp_send_nibble(value[3:0]);
    end
endtask

task grant_bus_to_fpga;
    begin
        check_condition(parallel_clk == 1'b0, 120);
        check_condition(req_out == 1'b1, 121);
        check_condition(data_oe == 4'b0000, 122);

        // RP2040をHi-Zにしてガード時間を設ける
        rp_data_oe = 1'b0;
        #(PARALLEL_HALF_NS * 2);

        // この1パルスは返信データには数えない
        parallel_pulse;
        #(PARALLEL_HALF_NS * 2);

        check_condition(data_oe == 4'b1111, 123);
        check_condition(req_out == 1'b1, 124);
    end
endtask

task rp_receive_nibble;
    output [3:0] value;
    begin
        check_condition(rp_data_oe == 1'b0, 130);
        check_condition(data_oe == 4'b1111, 131);

        parallel_clk = 1'b1;
        #(PARALLEL_HALF_NS);
        value = data_bus;
        parallel_clk = 1'b0;
        #(PARALLEL_HALF_NS);
    end
endtask

task rp_receive_byte;
    output [7:0] value;
    reg [3:0] high_nibble;
    reg [3:0] low_nibble;
    begin
        rp_receive_nibble(high_nibble);
        rp_receive_nibble(low_nibble);
        value = {high_nibble, low_nibble};
    end
endtask

task check_bus_released;
    input integer base_code;
    begin
        #(PARALLEL_HALF_NS * 2);
        check_condition(data_oe == 4'b0000, base_code);
        check_condition(req_out == 1'b0, base_code + 1);
        check_condition(rp_data_oe == 1'b0, base_code + 2);
    end
endtask

task run_soft_reset;
    reg [7:0] status;
    begin
        start_rp_request;
        rp_send_byte(8'h00);
        check_condition(req_out == 1'b1, 200);
        check_condition(data_oe == 4'b0000, 201);

        grant_bus_to_fpga;
        rp_receive_byte(status);
        check_condition(status == 8'h00, 202);
        check_bus_released(203);
    end
endtask

task run_invert;
    input [7:0] source;
    input [7:0] expected;
    input integer base_code;
    reg [7:0] status;
    reg [7:0] result;
    begin
        start_rp_request;
        rp_send_byte(8'h01);

        // INVERTはデータbyteを受信するまでREQを上げない
        check_condition(req_out == 1'b0, base_code);
        check_condition(data_oe == 4'b0000, base_code + 1);

        rp_send_byte(source);
        check_condition(req_out == 1'b1, base_code + 2);
        check_condition(data_oe == 4'b0000, base_code + 3);

        grant_bus_to_fpga;
        rp_receive_byte(status);

        // STATUS後もRESULTが残っているためFPGAが所有を継続する
        check_condition(data_oe == 4'b1111, base_code + 4);
        check_condition(req_out == 1'b1, base_code + 5);
        rp_receive_byte(result);

        check_condition(status == 8'h00, base_code + 6);
        check_condition(result == expected, base_code + 7);
        check_bus_released(base_code + 8);
    end
endtask

task run_unsupported_and_order_test;
    reg [7:0] status;
    begin
        start_rp_request;

        // 0xA5の上位ニブル0xAが先に格納されることを直接確認
        rp_send_nibble(4'hA);
        check_condition(dut.rx_high_pending == 1'b1, 500);
        check_condition(dut.rx_high_nibble == 4'hA, 501);
        check_condition(req_out == 1'b0, 502);

        rp_send_nibble(4'h5);
        check_condition(req_out == 1'b1, 503);
        check_condition(data_oe == 4'b0000, 504);

        grant_bus_to_fpga;

        // Grant後も最初の返信ニブル位置であり、Grant自体は未計数
        check_condition(dut.tx_nibble_index == 2'd0, 505);
        check_condition(data_out == 4'hE, 506);

        rp_receive_byte(status);
        check_condition(status == 8'hE1, 507);
        check_bus_released(508);
    end
endtask

task run_protocol_error_recovery;
    begin
        check_condition(req_out == 1'b0, 550);
        check_condition(data_oe == 4'b0000, 551);

        // 不正な内部状態を注入し、安全解放と受信待機への復帰を確認
        force dut.state = 3'b111;
        #30;
        release dut.state;
        #50;

        check_condition(dut.state == 3'd0, 552);
        check_condition(dut.protocol_error == 1'b1, 553);
        check_condition(dut.tx_status == 8'hE2, 554);
        check_condition(req_out == 1'b0, 555);
        check_condition(data_oe == 4'b0000, 556);

        // SOFT_RESET ACKを失わず、エラーフラグも初期化される
        run_soft_reset;
        check_condition(dut.protocol_error == 1'b0, 557);
    end
endtask

initial begin
    rst_n        = 1'b0;
    parallel_clk = 1'b0;
    rp_data_oe   = 1'b0;
    rp_data_out  = 4'b0000;

    // 1. メインリセット中と解除後の安全な初期状態
    #50;
    check_condition(clk_en == 1'b1, 1);
    check_condition(req_oe == 1'b0, 2);
    check_condition(req_out == 1'b0, 3);
    check_condition(data_oe == 4'b0000, 4);

    rst_n = 1'b1;
    #100;
    check_condition(req_oe == 1'b1, 5);
    check_condition(req_out == 1'b0, 6);
    check_condition(data_oe == 4'b0000, 7);

    // 2. SOFT_RESET
    run_soft_reset;

    // 3～5. 規定INVERTケース
    run_invert(8'h00, 8'hFF, 300);
    run_invert(8'h55, 8'hAA, 320);
    run_invert(8'hFF, 8'h00, 340);

    // 6～8. 未対応コマンド、ニブル順、Grant非計数
    run_unsupported_and_order_test;

    // プロトコルエラー時の安全な待機復帰
    run_protocol_error_recovery;

    // 9～12. 返信中だけOE有効、終了後解放、連続通信
    run_invert(8'h0F, 8'hF0, 360);
    run_soft_reset;

    // 動作後のメインリセットでも即座に安全状態へ戻る
    rst_n = 1'b0;
    #50;
    check_condition(req_oe == 1'b0, 600);
    check_condition(req_out == 1'b0, 601);
    check_condition(data_oe == 4'b0000, 602);

    rst_n = 1'b1;
    #100;
    run_soft_reset;

    $display("ALL TESTS PASS");
    $finish;
end

endmodule
