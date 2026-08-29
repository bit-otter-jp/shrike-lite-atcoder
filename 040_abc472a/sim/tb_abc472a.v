`timescale 1ns/1ps

module tb_abc472a;
    localparam integer SPI_HALF_NS = 125; // 4 MHz SPI clock
    localparam [7:0] DUMMY_BYTE = 8'h00;

    reg clk;
    reg rst_n;
    reg spi_ss_n;
    reg spi_sck;
    reg spi_mosi;
    wire clk_en;
    wire spi_miso;
    wire spi_miso_en;

    reg [7:0] input_bytes [0:99];
    reg [7:0] expected_bytes [0:99];
    reg [15:0] lfsr;
    integer failures;
    integer cases_run;
    integer i;
    integer j;
    integer random_length;

    main dut (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .spi_ss_n(spi_ss_n),
        .spi_sck(spi_sck),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .spi_miso_en(spi_miso_en)
    );

    always #10 clk = ~clk; // 50 MHz fabric clock

    function [7:0] converted;
        input [7:0] value;
        begin
            converted = (value == 8'h41) ? 8'h41 : 8'h2e;
        end
    endfunction

    task spi_transfer_byte;
        input [7:0] tx;
        output [7:0] rx;
        integer bit_index;
        begin
            rx = 8'h00;
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                spi_mosi = tx[bit_index];
                #(SPI_HALF_NS);
                spi_sck = 1'b1;
                #1;
                rx[bit_index] = spi_miso;
                #(SPI_HALF_NS - 1);
                spi_sck = 1'b0;
            end
        end
    endtask

    task run_case;
        input integer length;
        input [8*40-1:0] case_name;
        reg [7:0] rx;
        integer index;
        integer failures_before;
        begin
            cases_run = cases_run + 1;
            failures_before = failures;

            // One CS-low burst contains all source bytes and one flush byte.
            spi_ss_n = 1'b0;
            #500;
            if (spi_miso_en !== 1'b1) begin
                $display("FAIL %0s: MISO output-enable did not assert", case_name);
                failures = failures + 1;
            end

            for (index = 0; index < length; index = index + 1) begin
                spi_transfer_byte(input_bytes[index], rx);
                if (index == 0) begin
                    if (rx !== DUMMY_BYTE) begin
                        $display("FAIL %0s: first byte is %02x, expected dummy 00", case_name, rx);
                        failures = failures + 1;
                    end
                end else if (rx !== expected_bytes[index-1]) begin
                    $display("FAIL %0s: response[%0d]=%02x expected %02x",
                             case_name, index-1, rx, expected_bytes[index-1]);
                    failures = failures + 1;
                end
            end

            // The flush byte recovers the conversion of the final input byte.
            spi_transfer_byte(8'h00, rx);
            if (rx !== expected_bytes[length-1]) begin
                $display("FAIL %0s: flush response=%02x expected final %02x",
                         case_name, rx, expected_bytes[length-1]);
                failures = failures + 1;
            end

            spi_ss_n = 1'b1;
            spi_mosi = 1'b0;
            #500;
            if (spi_miso_en !== 1'b0) begin
                $display("FAIL %0s: MISO output-enable did not release", case_name);
                failures = failures + 1;
            end

            if (failures == failures_before)
                $display("PASS %0s length=%0d", case_name, length);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        spi_ss_n = 1'b1;
        spi_sck = 1'b0;
        spi_mosi = 1'b0;
        failures = 0;
        cases_run = 0;
        lfsr = 16'h1ace;

        #100;
        rst_n = 1'b1;
        #500;

        // Length-one A followed immediately by another transaction proves
        // that the previous result cannot replace the new first dummy byte.
        input_bytes[0] = "A";
        expected_bytes[0] = "A";
        run_case(1, "length_1_A_seed");

        input_bytes[0] = "Z";
        expected_bytes[0] = ".";
        run_case(1, "length_1_after_A");

        // Official sample 1: ATCODER -> A......
        input_bytes[0] = "A"; input_bytes[1] = "T";
        input_bytes[2] = "C"; input_bytes[3] = "O";
        input_bytes[4] = "D"; input_bytes[5] = "E";
        input_bytes[6] = "R";
        for (i = 0; i < 7; i = i + 1)
            expected_bytes[i] = converted(input_bytes[i]);
        run_case(7, "official_sample_1");

        // Official sample 2: BANANA -> .A.A.A
        input_bytes[0] = "B"; input_bytes[1] = "A";
        input_bytes[2] = "N"; input_bytes[3] = "A";
        input_bytes[4] = "N"; input_bytes[5] = "A";
        for (i = 0; i < 6; i = i + 1)
            expected_bytes[i] = converted(input_bytes[i]);
        run_case(6, "official_sample_2");

        // Official sample 3: CORRECT -> .......
        input_bytes[0] = "C"; input_bytes[1] = "O";
        input_bytes[2] = "R"; input_bytes[3] = "R";
        input_bytes[4] = "E"; input_bytes[5] = "C";
        input_bytes[6] = "T";
        for (i = 0; i < 7; i = i + 1)
            expected_bytes[i] = converted(input_bytes[i]);
        run_case(7, "official_sample_3");

        // Every uppercase letter in one burst.
        for (i = 0; i < 26; i = i + 1) begin
            input_bytes[i] = 8'h41 + i;
            expected_bytes[i] = (i == 0) ? 8'h41 : 8'h2e;
        end
        run_case(26, "all_A_to_Z");

        // Boundary and placement cases.
        for (i = 0; i < 100; i = i + 1) begin
            input_bytes[i] = "A";
            expected_bytes[i] = "A";
        end
        run_case(100, "length_100_all_A");

        for (i = 0; i < 100; i = i + 1) begin
            input_bytes[i] = "B";
            expected_bytes[i] = ".";
        end
        run_case(100, "length_100_no_A");

        for (i = 0; i < 100; i = i + 1) begin
            input_bytes[i] = (i == 0) ? "A" : "B";
            expected_bytes[i] = (i == 0) ? "A" : ".";
        end
        run_case(100, "leading_A_only");

        for (i = 0; i < 100; i = i + 1) begin
            input_bytes[i] = (i == 99) ? "A" : "B";
            expected_bytes[i] = (i == 99) ? "A" : ".";
        end
        run_case(100, "trailing_A_only");

        for (i = 0; i < 100; i = i + 1) begin
            input_bytes[i] = ((i % 7) == 0) ? "A" : (8'h42 + (i % 25));
            expected_bytes[i] = ((i % 7) == 0) ? "A" : ".";
        end
        run_case(100, "multiple_A");

        // Deterministic pseudo-random uppercase strings, including both
        // boundaries across the set. Each is a separate CS transaction.
        for (j = 0; j < 24; j = j + 1) begin
            if (j == 0)
                random_length = 1;
            else if (j == 23)
                random_length = 100;
            else
                random_length = ((j * 37) % 100) + 1;

            for (i = 0; i < random_length; i = i + 1) begin
                lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
                input_bytes[i] = 8'h41 + (lfsr % 26);
                expected_bytes[i] = converted(input_bytes[i]);
            end
            run_case(random_length, "deterministic_random");
        end

        if (clk_en !== 1'b1) begin
            $display("FAIL clk_en is not asserted");
            failures = failures + 1;
        end

        if (failures == 0) begin
            $display("SUMMARY PASS cases=%0d failures=0", cases_run);
            $finish;
        end else begin
            $display("SUMMARY FAIL cases=%0d failures=%0d", cases_run, failures);
            $fatal(1);
        end
    end
endmodule
