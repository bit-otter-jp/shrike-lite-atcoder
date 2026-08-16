`timescale 1ns/1ps

// ABC470D - Inverse and Swap
// Icarus/vvp wall-time version. This is intentionally a procedural program:
// no clock, raw-query storage, or synthesizable hardware structure is used.
module abc470d_fast_vvp;
    localparam integer MAX_N = 500000;
    localparam integer OUTPUT_BATCH = 64;

    integer p    [1:MAX_N];
    integer pinv [1:MAX_N];
    integer input_batch [0:OUTPUT_BATCH-1];

    integer n;
    integer q;
    integer i;
    integer j;
    integer scan_result;
    integer input_type;
    integer x;
    integer y;
    integer a;
    integer b;
    reg inverted;
    reg inverse_ready;

    initial begin
        inverted = 1'b0;
        inverse_ready = 1'b0;

        scan_result = $fscanf(32'h80000000, "%d %d", n, q);
        i = 1;
        while (i + OUTPUT_BATCH - 1 <= n) begin
            scan_result = $fscanf(
                32'h80000000,
                "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                input_batch[0],
                input_batch[1],
                input_batch[2],
                input_batch[3],
                input_batch[4],
                input_batch[5],
                input_batch[6],
                input_batch[7],
                input_batch[8],
                input_batch[9],
                input_batch[10],
                input_batch[11],
                input_batch[12],
                input_batch[13],
                input_batch[14],
                input_batch[15],
                input_batch[16],
                input_batch[17],
                input_batch[18],
                input_batch[19],
                input_batch[20],
                input_batch[21],
                input_batch[22],
                input_batch[23],
                input_batch[24],
                input_batch[25],
                input_batch[26],
                input_batch[27],
                input_batch[28],
                input_batch[29],
                input_batch[30],
                input_batch[31],
                input_batch[32],
                input_batch[33],
                input_batch[34],
                input_batch[35],
                input_batch[36],
                input_batch[37],
                input_batch[38],
                input_batch[39],
                input_batch[40],
                input_batch[41],
                input_batch[42],
                input_batch[43],
                input_batch[44],
                input_batch[45],
                input_batch[46],
                input_batch[47],
                input_batch[48],
                input_batch[49],
                input_batch[50],
                input_batch[51],
                input_batch[52],
                input_batch[53],
                input_batch[54],
                input_batch[55],
                input_batch[56],
                input_batch[57],
                input_batch[58],
                input_batch[59],
                input_batch[60],
                input_batch[61],
                input_batch[62],
                input_batch[63]
            );
            for (j = 0; j < OUTPUT_BATCH; j = j + 1) begin
                p[i + j] = input_batch[j];
            end
            i = i + OUTPUT_BATCH;
        end
        while (i <= n) begin
            scan_result = $fscanf(32'h80000000, "%d", a);
            p[i] = a;
            i = i + 1;
        end

        repeat (q) begin
            scan_result = $fscanf(32'h80000000, " %c", input_type);
            if (input_type == 8'd49) begin
                scan_result = $fscanf(32'h80000000, "%d%d", x, y);
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
            inverse_ready = 1'b1;
        end

        i = 1;
        if (inverted == 1'b0) begin
            while (i + OUTPUT_BATCH - 1 <= n) begin
                $fwrite(32'h80000001,
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
                $fwrite(32'h80000001, "%0d ", p[i]);
                i = i + 1;
            end
        end else begin
            while (i + OUTPUT_BATCH - 1 <= n) begin
                $fwrite(32'h80000001,
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
                $fwrite(32'h80000001, "%0d ", pinv[i]);
                i = i + 1;
            end
        end
        $fwrite(32'h80000001, "\n");
        $finish(0);
    end
endmodule
