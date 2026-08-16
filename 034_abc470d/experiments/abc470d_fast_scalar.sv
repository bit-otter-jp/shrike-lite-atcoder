`timescale 1ns/1ps

// Experimental scalar-output control for the output batching comparison.
module abc470d_fast_scalar;
    localparam integer MAX_N = 500000;
    integer p [1:MAX_N];
    integer pinv [1:MAX_N];
    integer n, q, i, scan_result, input_type, x, y, a, b;
    reg inverted;

    initial begin
        inverted = 1'b0;
        scan_result = $fscanf(32'h80000000, "%d %d", n, q);
        for (i = 1; i <= n; i = i + 1) begin
            scan_result = $fscanf(32'h80000000, "%d", a);
            p[i] = a;
            pinv[a] = i;
        end
        for (i = 0; i < q; i = i + 1) begin
            scan_result = $fscanf(32'h80000000, "%d", input_type);
            if (input_type == 1) begin
                scan_result = $fscanf(32'h80000000, "%d %d", x, y);
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
