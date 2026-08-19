module main;
    localparam signed [63:0] MOD = 64'd998244353;
    localparam integer STDIN = 32'h8000_0000;

    integer n;
    integer k;
    integer i;
    integer scan_result;

    reg signed [63:0] value;
    reg signed [63:0] prefix_sum;
    reg signed [63:0] square_sum;
    reg signed [63:0] pair_twice;
    reg signed [63:0] choose_once;
    reg signed [63:0] choose_pair;
    reg signed [63:0] inverse_n_minus_one;
    reg signed [63:0] answer;

    function automatic signed [63:0] mod_pow;
        input signed [63:0] base_input;
        input signed [63:0] exponent_input;
        reg signed [63:0] base;
        reg signed [63:0] exponent;
        reg signed [63:0] result;
        begin
            base = base_input % MOD;
            exponent = exponent_input;
            result = 64'd1;

            while (exponent > 0) begin
                if (exponent[0]) begin
                    result = (result * base) % MOD;
                end
                base = (base * base) % MOD;
                exponent = exponent >> 1;
            end

            mod_pow = result;
        end
    endfunction

    // Computes C(input_n - 1, input_k - 1).  All factorial factors are
    // smaller than MOD because N <= 200000 < MOD.
    function automatic signed [63:0] combination_n_minus_one;
        input integer input_n;
        input integer input_k;
        integer r;
        integer j;
        reg signed [63:0] numerator;
        reg signed [63:0] denominator;
        begin
            r = input_k - 1;
            if (r > input_n - input_k) begin
                r = input_n - input_k;
            end

            numerator = 64'd1;
            denominator = 64'd1;
            for (j = 1; j <= r; j = j + 1) begin
                numerator = (numerator * (input_n - 1 - r + j)) % MOD;
                denominator = (denominator * j) % MOD;
            end

            combination_n_minus_one =
                (numerator * mod_pow(denominator, MOD - 2)) % MOD;
        end
    endfunction

    initial begin
        scan_result = $fscanf(STDIN, "%d %d", n, k);
        if (scan_result != 2) begin
            $finish(0);
        end

        prefix_sum = 64'd0;
        square_sum = 64'd0;
        for (i = 0; i < n; i = i + 1) begin
            scan_result = $fscanf(STDIN, "%d", value);
            // Ai <= 1e9 < 2*MOD, so one subtraction is enough here.
            if (value >= MOD) begin
                value = value - MOD;
            end
            prefix_sum = prefix_sum + value;
            if (prefix_sum >= MOD) begin
                prefix_sum = prefix_sum - MOD;
            end
            square_sum = (square_sum + value * value) % MOD;
        end

        choose_once = combination_n_minus_one(n, k);

        // C(N-2,K-2) = C(N-1,K-1) * (K-1) / (N-1).
        // Handle K=1 (and therefore the possible N=1 case) separately.
        if (k == 1) begin
            choose_pair = 64'd0;
        end else begin
            inverse_n_minus_one = mod_pow(n - 1, MOD - 2);
            choose_pair = (choose_once * (k - 1)) % MOD;
            choose_pair = (choose_pair * inverse_n_minus_one) % MOD;
        end

        pair_twice = ((prefix_sum * prefix_sum) % MOD
                      - square_sum + MOD) % MOD;
        answer = ((choose_once * square_sum) % MOD
                  + (choose_pair * pair_twice) % MOD) % MOD;

        $display("%0d", answer);
        $finish(0);
    end
endmodule
