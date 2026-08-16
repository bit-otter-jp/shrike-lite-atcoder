`timescale 1ns/1ps

// Experimental one-fgets-per-query parser with fixed-width digit decoding.
// It assumes the LF line endings used by the AtCoder Linux judge.
module abc470d_fast_fgets_unrolled;
    localparam integer MAX_N = 500000;
    integer p [1:MAX_N];
    integer pinv [1:MAX_N];
    reg [8*32-1:0] line;
    reg [8*8-1:0] x_field;
    integer n, q, i, j, scan_result, char_count;
    integer x_digits, y_digits, x, y, a, b;
    reg inverted;
    reg inverse_ready;

    initial begin
        inverted = 1'b0;
        inverse_ready = 1'b0;
        scan_result = $fscanf(32'h80000000, "%d %d", n, q);
        for (i = 1; i <= n; i = i + 1) begin
            scan_result = $fscanf(32'h80000000, "%d", a);
            p[i] = a;
        end
        char_count = $fgets(line, 32'h80000000);
        for (i = 0; i < q; i = i + 1) begin
            char_count = $fgets(line, 32'h80000000);
            if (char_count > 3) begin
                if (line[23:16] == 8'd32) begin
                    y_digits = 1;
                end else if (line[31:24] == 8'd32) begin
                    y_digits = 2;
                end else if (line[39:32] == 8'd32) begin
                    y_digits = 3;
                end else if (line[47:40] == 8'd32) begin
                    y_digits = 4;
                end else if (line[55:48] == 8'd32) begin
                    y_digits = 5;
                end else begin
                    y_digits = 6;
                end
                case (y_digits)
                    1: y = line[15:8] - 8'd48;
                    2: y = (line[23:16] - 8'd48) * 10
                         + line[15:8] - 8'd48;
                    3: y = (line[31:24] - 8'd48) * 100
                         + (line[23:16] - 8'd48) * 10
                         + line[15:8] - 8'd48;
                    4: y = (line[39:32] - 8'd48) * 1000
                         + (line[31:24] - 8'd48) * 100
                         + (line[23:16] - 8'd48) * 10
                         + line[15:8] - 8'd48;
                    5: y = (line[47:40] - 8'd48) * 10000
                         + (line[39:32] - 8'd48) * 1000
                         + (line[31:24] - 8'd48) * 100
                         + (line[23:16] - 8'd48) * 10
                         + line[15:8] - 8'd48;
                    default: y = (line[55:48] - 8'd48) * 100000
                         + (line[47:40] - 8'd48) * 10000
                         + (line[39:32] - 8'd48) * 1000
                         + (line[31:24] - 8'd48) * 100
                         + (line[23:16] - 8'd48) * 10
                         + line[15:8] - 8'd48;
                endcase

                x_digits = char_count - y_digits - 4;
                x_field = line >> (8 * (y_digits + 2));
                case (x_digits)
                    1: x = x_field[7:0] - 8'd48;
                    2: x = (x_field[15:8] - 8'd48) * 10
                         + x_field[7:0] - 8'd48;
                    3: x = (x_field[23:16] - 8'd48) * 100
                         + (x_field[15:8] - 8'd48) * 10
                         + x_field[7:0] - 8'd48;
                    4: x = (x_field[31:24] - 8'd48) * 1000
                         + (x_field[23:16] - 8'd48) * 100
                         + (x_field[15:8] - 8'd48) * 10
                         + x_field[7:0] - 8'd48;
                    5: x = (x_field[39:32] - 8'd48) * 10000
                         + (x_field[31:24] - 8'd48) * 1000
                         + (x_field[23:16] - 8'd48) * 100
                         + (x_field[15:8] - 8'd48) * 10
                         + x_field[7:0] - 8'd48;
                    default: x = (x_field[47:40] - 8'd48) * 100000
                         + (x_field[39:32] - 8'd48) * 10000
                         + (x_field[31:24] - 8'd48) * 1000
                         + (x_field[23:16] - 8'd48) * 100
                         + (x_field[15:8] - 8'd48) * 10
                         + x_field[7:0] - 8'd48;
                endcase

                if (inverted == 1'b0) begin
                    a = p[x];
                    b = p[y];
                    p[x] = b;
                    p[y] = a;
                    if (inverse_ready != 1'b0) begin
                        pinv[a] = y;
                        pinv[b] = x;
                    end
                end else begin
                    if (inverse_ready == 1'b0) begin
                        for (j = 1; j <= n; j = j + 1) begin
                            pinv[p[j]] = j;
                        end
                        inverse_ready = 1'b1;
                    end
                    a = pinv[x];
                    b = pinv[y];
                    pinv[x] = b;
                    pinv[y] = a;
                    p[a] = y;
                    p[b] = x;
                end
            end else begin
                inverted = ~inverted;
            end
        end
        if ((inverted != 1'b0) && (inverse_ready == 1'b0)) begin
            for (j = 1; j <= n; j = j + 1) begin
                pinv[p[j]] = j;
            end
        end
        if (inverted == 1'b0) begin
            for (i = 1; i <= n; i = i + 1) begin
                $write("%0d ", p[i]);
            end
        end else begin
            for (i = 1; i <= n; i = i + 1) begin
                $write("%0d ", pinv[i]);
            end
        end
        $write("\n");
        $finish(0);
    end
endmodule
