module main;
    localparam signed [63:0] MOD = 64'd998244353;
    localparam integer STDIN = 32'h8000_0000;

    integer n;
    integer k;
    integer i;
    integer scan_result;

    reg signed [63:0] x;
    reg signed [63:0] prefix_sum;
    reg signed [63:0] pair_sum;
    reg signed [63:0] square_sum;
    reg signed [63:0] choose_single;
    reg signed [63:0] choose_pair;
    reg signed [63:0] inverse_n_minus_one;
    reg signed [63:0] pair_term;
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

    // Compute C(input_n - 1, input_k - 1) from a numerator product,
    // a denominator product, and the denominator's modular inverse.
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
        pair_sum = 64'd0;
        square_sum = 64'd0;

        // Keep the three sums from the mathematical derivation explicitly.
        for (i = 0; i < n; i = i + 1) begin
            scan_result = $fscanf(STDIN, "%d", x);
            x = x % MOD;

            pair_sum = (pair_sum + prefix_sum * x) % MOD;
            prefix_sum = (prefix_sum + x) % MOD;
            square_sum = (square_sum + x * x) % MOD;
        end

        choose_single = combination_n_minus_one(n, k);

        // C(N-2,K-2) = C(N-1,K-1) * (K-1) / (N-1).
        // For K=1 there is no pair contribution.
        if (k == 1) begin
            choose_pair = 64'd0;
        end else begin
            inverse_n_minus_one = mod_pow(n - 1, MOD - 2);
            choose_pair = (choose_single * (k - 1)) % MOD;
            choose_pair = (choose_pair * inverse_n_minus_one) % MOD;
        end

        // answer = C(N-1,K-1) * square_sum
        //        + 2 * C(N-2,K-2) * pair_sum
        pair_term = (choose_pair * pair_sum) % MOD;
        answer = ((choose_single * square_sum) % MOD
                  + (2 * pair_term) % MOD) % MOD;

        $display("%0d", answer);
        $finish(0);
    end
endmodule
