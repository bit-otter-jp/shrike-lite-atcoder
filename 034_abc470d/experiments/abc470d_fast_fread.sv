`timescale 1ns/1ps

// Experimental whole-input parser. Kept to make the wall-time comparison
// reproducible; abc470d_fast_vvp.sv is the selected submission source.
module abc470d_fast_fread;
    localparam integer MAX_N = 500000;
    localparam integer MAX_INPUT_BYTES = 12000000;
    localparam integer OUTPUT_BATCH = 64;

    integer p    [1:MAX_N];
    integer pinv [1:MAX_N];
    reg [7:0] input_bytes [0:MAX_INPUT_BYTES-1];

    integer input_size;
    integer input_pos;
    integer n;
    integer q;
    integer i;
    integer input_type;
    integer x;
    integer y;
    integer a;
    integer b;
    reg inverted;

    function integer next_integer;
        integer value;
        begin
            while (
                (input_pos < input_size) &&
                (input_bytes[input_pos] <= 8'd32)
            ) begin
                input_pos = input_pos + 1;
            end
            value = 0;
            while (
                (input_pos < input_size) &&
                (input_bytes[input_pos] >= 8'd48)
            ) begin
                value = value * 10 + input_bytes[input_pos] - 8'd48;
                input_pos = input_pos + 1;
            end
            next_integer = value;
        end
    endfunction

    initial begin
        input_size = $fread(input_bytes, 32'h80000000);
        input_pos = 0;
        inverted = 1'b0;
        n = next_integer();
        q = next_integer();

        for (i = 1; i <= n; i = i + 1) begin
            a = next_integer();
            p[i] = a;
            pinv[a] = i;
        end

        for (i = 0; i < q; i = i + 1) begin
            input_type = next_integer();
            if (input_type == 1) begin
                x = next_integer();
                y = next_integer();
                if (inverted == 1'b0) begin
                    a = p[x];
                    b = p[y];
                    p[x] = b;
                    p[y] = a;
                    pinv[a] = y;
                    pinv[b] = x;
                end else begin
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

        i = 1;
        if (inverted == 1'b0) begin
            while (i + OUTPUT_BATCH - 1 <= n) begin
                $write(
                    "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d ",
                    p[i + 0],
                    p[i + 1],
                    p[i + 2],
                    p[i + 3],
                    p[i + 4],
                    p[i + 5],
                    p[i + 6],
                    p[i + 7],
                    p[i + 8],
                    p[i + 9],
                    p[i + 10],
                    p[i + 11],
                    p[i + 12],
                    p[i + 13],
                    p[i + 14],
                    p[i + 15],
                    p[i + 16],
                    p[i + 17],
                    p[i + 18],
                    p[i + 19],
                    p[i + 20],
                    p[i + 21],
                    p[i + 22],
                    p[i + 23],
                    p[i + 24],
                    p[i + 25],
                    p[i + 26],
                    p[i + 27],
                    p[i + 28],
                    p[i + 29],
                    p[i + 30],
                    p[i + 31],
                    p[i + 32],
                    p[i + 33],
                    p[i + 34],
                    p[i + 35],
                    p[i + 36],
                    p[i + 37],
                    p[i + 38],
                    p[i + 39],
                    p[i + 40],
                    p[i + 41],
                    p[i + 42],
                    p[i + 43],
                    p[i + 44],
                    p[i + 45],
                    p[i + 46],
                    p[i + 47],
                    p[i + 48],
                    p[i + 49],
                    p[i + 50],
                    p[i + 51],
                    p[i + 52],
                    p[i + 53],
                    p[i + 54],
                    p[i + 55],
                    p[i + 56],
                    p[i + 57],
                    p[i + 58],
                    p[i + 59],
                    p[i + 60],
                    p[i + 61],
                    p[i + 62],
                    p[i + 63]
                );
                i = i + OUTPUT_BATCH;
            end
            while (i <= n) begin
                $write("%0d ", p[i]);
                i = i + 1;
            end
        end else begin
            while (i + OUTPUT_BATCH - 1 <= n) begin
                $write(
                    "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d ",
                    pinv[i + 0],
                    pinv[i + 1],
                    pinv[i + 2],
                    pinv[i + 3],
                    pinv[i + 4],
                    pinv[i + 5],
                    pinv[i + 6],
                    pinv[i + 7],
                    pinv[i + 8],
                    pinv[i + 9],
                    pinv[i + 10],
                    pinv[i + 11],
                    pinv[i + 12],
                    pinv[i + 13],
                    pinv[i + 14],
                    pinv[i + 15],
                    pinv[i + 16],
                    pinv[i + 17],
                    pinv[i + 18],
                    pinv[i + 19],
                    pinv[i + 20],
                    pinv[i + 21],
                    pinv[i + 22],
                    pinv[i + 23],
                    pinv[i + 24],
                    pinv[i + 25],
                    pinv[i + 26],
                    pinv[i + 27],
                    pinv[i + 28],
                    pinv[i + 29],
                    pinv[i + 30],
                    pinv[i + 31],
                    pinv[i + 32],
                    pinv[i + 33],
                    pinv[i + 34],
                    pinv[i + 35],
                    pinv[i + 36],
                    pinv[i + 37],
                    pinv[i + 38],
                    pinv[i + 39],
                    pinv[i + 40],
                    pinv[i + 41],
                    pinv[i + 42],
                    pinv[i + 43],
                    pinv[i + 44],
                    pinv[i + 45],
                    pinv[i + 46],
                    pinv[i + 47],
                    pinv[i + 48],
                    pinv[i + 49],
                    pinv[i + 50],
                    pinv[i + 51],
                    pinv[i + 52],
                    pinv[i + 53],
                    pinv[i + 54],
                    pinv[i + 55],
                    pinv[i + 56],
                    pinv[i + 57],
                    pinv[i + 58],
                    pinv[i + 59],
                    pinv[i + 60],
                    pinv[i + 61],
                    pinv[i + 62],
                    pinv[i + 63]
                );
                i = i + OUTPUT_BATCH;
            end
            while (i <= n) begin
                $write("%0d ", pinv[i]);
                i = i + 1;
            end
        end
        $write("\n");
        $finish(0);
    end
endmodule
