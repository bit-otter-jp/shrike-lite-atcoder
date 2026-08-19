(* top *) module main (
    (* iopad_external_pin, clkbuf_inhibit *) input clk,
    (* iopad_external_pin *) output clk_en,
    (* iopad_external_pin *) input rst_n,

    (* iopad_external_pin *) input  spi_ss_n,
    (* iopad_external_pin *) input  spi_sck,
    (* iopad_external_pin *) input  spi_mosi,
    (* iopad_external_pin *) output spi_miso,
    (* iopad_external_pin *) output spi_miso_en
);

    assign clk_en = 1'b1;

    localparam [29:0] MOD = 30'd998244353;
    localparam [31:0] N_MAX = 32'd200000;

    localparam [7:0] CMD_NOP   = 8'h00;
    localparam [7:0] CMD_DEBUG = 8'hFD;
    localparam [7:0] CMD_START = 8'hFE;
    localparam [7:0] CMD_RESET = 8'hFF;
    localparam [7:0] RESET_ACK = 8'h5A;
    localparam [7:0] START_ACK = 8'hA5;

    localparam [2:0] P_WAIT_START     = 3'd0;
    localparam [2:0] P_WAIT_START_ACK = 3'd1;
    localparam [2:0] P_RECEIVE_N      = 3'd2;
    localparam [2:0] P_RECEIVE_K      = 3'd3;
    localparam [2:0] P_STREAM_A       = 3'd4;
    localparam [2:0] P_WAIT_RESULT    = 3'd5;
    localparam [2:0] P_SEND_REPLY     = 3'd6;

    localparam [5:0] C_IDLE                 = 6'd0;
    localparam [5:0] C_NORMALIZE            = 6'd1;
    localparam [5:0] C_INPUT_PAIR_START     = 6'd2;
    localparam [5:0] C_INPUT_PAIR_WAIT      = 6'd3;
    localparam [5:0] C_INPUT_PAIR_ADD       = 6'd4;
    localparam [5:0] C_INPUT_SQUARE_WAIT    = 6'd5;
    localparam [5:0] C_COMB_INIT            = 6'd6;
    localparam [5:0] C_COMB_CHECK           = 6'd7;
    localparam [5:0] C_NUMERATOR_START      = 6'd8;
    localparam [5:0] C_NUMERATOR_WAIT       = 6'd9;
    localparam [5:0] C_DENOMINATOR_START    = 6'd10;
    localparam [5:0] C_DENOMINATOR_WAIT     = 6'd11;
    localparam [5:0] C_POW_CHECK             = 6'd12;
    localparam [5:0] C_POW_RESULT_START      = 6'd13;
    localparam [5:0] C_POW_RESULT_WAIT       = 6'd14;
    localparam [5:0] C_POW_BASE_START        = 6'd15;
    localparam [5:0] C_POW_BASE_WAIT         = 6'd16;
    localparam [5:0] C_COEFF_SQUARE_START    = 6'd17;
    localparam [5:0] C_COEFF_SQUARE_WAIT     = 6'd18;
    localparam [5:0] C_COEFF_PAIR_1_START    = 6'd19;
    localparam [5:0] C_COEFF_PAIR_1_WAIT     = 6'd20;
    localparam [5:0] C_COEFF_PAIR_2_START    = 6'd21;
    localparam [5:0] C_COEFF_PAIR_2_WAIT     = 6'd22;
    localparam [5:0] C_FINAL_SQUARE_START    = 6'd23;
    localparam [5:0] C_FINAL_SQUARE_WAIT     = 6'd24;
    localparam [5:0] C_FINAL_PAIR_START      = 6'd25;
    localparam [5:0] C_FINAL_PAIR_WAIT       = 6'd26;
    localparam [5:0] C_FINAL_ADD             = 6'd27;
    localparam [5:0] C_K1_FINISH             = 6'd28;
    localparam [5:0] C_PUBLISH               = 6'd29;
    localparam [5:0] C_DONE                  = 6'd30;
    localparam [5:0] C_INPUT_SQUARE_ADD      = 6'd31;
    localparam [5:0] C_INPUT_PREFIX_ADD      = 6'd32;
    localparam [5:0] C_FINAL_PAIR_DOUBLE     = 6'd33;

    wire [7:0] rx_data;
    wire       rx_data_strobe;
    wire       tx_data_hold;
    reg  [7:0] tx_data;

    reg [2:0] proto_state;
    reg [5:0] calc_state;

    reg [31:0] n_reg;
    reg [31:0] k_reg;
    reg [31:0] received_count;
    reg [31:0] input_count;

    reg [31:0] rx_word_shift;
    reg [1:0]  rx_byte_count;
    reg [31:0] x_raw;
    reg [29:0] x_reg;
    reg [29:0] old_prefix;
    reg        x_busy;

    // Baseline's three streaming states.  The whole A array is never stored.
    reg [29:0] prefix_sum;
    reg [29:0] square_sum;
    reg [29:0] pair_sum;

    reg [31:0] comb_n;
    reg [31:0] comb_r;
    reg [31:0] comb_i;
    reg [29:0] numerator;
    reg [29:0] denominator;

    reg [29:0] pow_result;
    reg [29:0] pow_base;
    reg [29:0] pow_exp;
    reg        pow_context; // 0: denominator inverse, 1: (N-1) inverse

    reg [29:0] coeff_square;
    reg [29:0] coeff_pair;
    reg [29:0] coeff_pair_work;
    reg [29:0] term_square;
    reg [29:0] term_pair;
    reg [29:0] answer;

    reg        protocol_error;
    reg        reply_valid;
    reg        status_loaded;
    reg        tx_byte_active;
    reg [1:0]  reply_byte_index;

    reg        mul_start;
    reg [29:0] mul_lhs;
    reg [29:0] mul_rhs;
    wire       mul_busy;
    wire       mul_done;
    wire [29:0] mul_product;

    reg  [29:0] mod_add_a;
    reg  [29:0] mod_add_b;
    wire [30:0] mod_add_sum =
        {1'b0, mod_add_a} + {1'b0, mod_add_b};
    wire [30:0] mod_add_reduced =
        (mod_add_sum >= {1'b0, MOD}) ?
        (mod_add_sum - {1'b0, MOD}) : mod_add_sum;
    wire [29:0] mod_add_result = mod_add_reduced[29:0];

    wire control_state =
        (proto_state == P_WAIT_START) ||
        (proto_state == P_WAIT_START_ACK) ||
        (proto_state == P_WAIT_RESULT) ||
        (proto_state == P_SEND_REPLY);

    // RESET bytes are commands only outside N/K/A payload states.
    wire command_reset =
        rx_data_strobe && control_state && (rx_data == CMD_RESET);

    // V2: one top-level modular-add datapath is shared by all five users.
    // calc_state selects both operands here and the destination in the
    // sequential arithmetic FSM below.  Complete defaults prevent latches.
    always @(*) begin
        mod_add_a = 30'd0;
        mod_add_b = 30'd0;
        case (calc_state)
            C_INPUT_PAIR_ADD: begin
                mod_add_a = pair_sum;
                mod_add_b = mul_product;
            end
            C_INPUT_SQUARE_ADD: begin
                mod_add_a = square_sum;
                mod_add_b = mul_product;
            end
            C_INPUT_PREFIX_ADD: begin
                mod_add_a = old_prefix;
                mod_add_b = x_reg;
            end
            C_FINAL_PAIR_DOUBLE: begin
                mod_add_a = mul_product;
                mod_add_b = mul_product;
            end
            C_FINAL_ADD: begin
                mod_add_a = term_square;
                mod_add_b = term_pair;
            end
            default: begin
                mod_add_a = 30'd0;
                mod_add_b = 30'd0;
            end
        endcase
    end

    // These arithmetic expressions are intentionally evaluated at 32 bits.
    // Their validated value ranges are below MOD, so the multiplier operands
    // are selected explicitly instead of relying on implicit truncation.
    wire [31:0] n_minus_one_wide = n_reg - 32'd1;
    wire [29:0] n_minus_one_mod_value = n_minus_one_wide[29:0];
    wire [31:0] k_minus_one_wide = k_reg - 32'd1;
    wire [29:0] k_minus_one_mod_value = k_minus_one_wide[29:0];
    wire [31:0] comb_factor_wide = comb_n - comb_r + comb_i;
    wire [29:0] comb_factor_mod_value = comb_factor_wide[29:0];

    modular_multiplier u_modular_multiplier (
        .i_clk(clk),
        .i_rst_n(rst_n),
        .i_clear(command_reset),
        .i_start(mul_start),
        .i_lhs(mul_lhs),
        .i_rhs(mul_rhs),
        .o_busy(mul_busy),
        .o_done(mul_done),
        .o_product(mul_product)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            proto_state       <= P_WAIT_START;
            calc_state        <= C_IDLE;
            n_reg             <= 32'd0;
            k_reg             <= 32'd0;
            received_count    <= 32'd0;
            input_count       <= 32'd0;
            rx_word_shift     <= 32'd0;
            rx_byte_count     <= 2'd0;
            x_raw             <= 32'd0;
            x_reg             <= 30'd0;
            old_prefix        <= 30'd0;
            x_busy            <= 1'b0;
            prefix_sum        <= 30'd0;
            square_sum        <= 30'd0;
            pair_sum          <= 30'd0;
            comb_n            <= 32'd0;
            comb_r            <= 32'd0;
            comb_i            <= 32'd0;
            numerator         <= 30'd1;
            denominator       <= 30'd1;
            pow_result        <= 30'd1;
            pow_base          <= 30'd0;
            pow_exp           <= 30'd0;
            pow_context       <= 1'b0;
            coeff_square      <= 30'd0;
            coeff_pair        <= 30'd0;
            coeff_pair_work   <= 30'd0;
            term_square       <= 30'd0;
            term_pair         <= 30'd0;
            answer            <= 30'd0;
            protocol_error    <= 1'b0;
            reply_valid       <= 1'b0;
            status_loaded     <= 1'b0;
            tx_byte_active    <= 1'b0;
            reply_byte_index  <= 2'd0;
            mul_start         <= 1'b0;
            mul_lhs           <= 30'd0;
            mul_rhs           <= 30'd0;
            tx_data           <= 8'h00;
        end else if (command_reset) begin
            proto_state       <= P_WAIT_START;
            calc_state        <= C_IDLE;
            n_reg             <= 32'd0;
            k_reg             <= 32'd0;
            received_count    <= 32'd0;
            input_count       <= 32'd0;
            rx_word_shift     <= 32'd0;
            rx_byte_count     <= 2'd0;
            x_raw             <= 32'd0;
            x_reg             <= 30'd0;
            old_prefix        <= 30'd0;
            x_busy            <= 1'b0;
            prefix_sum        <= 30'd0;
            square_sum        <= 30'd0;
            pair_sum          <= 30'd0;
            comb_n            <= 32'd0;
            comb_r            <= 32'd0;
            comb_i            <= 32'd0;
            numerator         <= 30'd1;
            denominator       <= 30'd1;
            pow_result        <= 30'd1;
            pow_base          <= 30'd0;
            pow_exp           <= 30'd0;
            pow_context       <= 1'b0;
            coeff_square      <= 30'd0;
            coeff_pair        <= 30'd0;
            coeff_pair_work   <= 30'd0;
            term_square       <= 30'd0;
            term_pair         <= 30'd0;
            answer            <= 30'd0;
            protocol_error    <= 1'b0;
            reply_valid       <= 1'b0;
            status_loaded     <= 1'b0;
            tx_byte_active    <= 1'b0;
            reply_byte_index  <= 2'd0;
            mul_start         <= 1'b0;
            mul_lhs           <= 30'd0;
            mul_rhs           <= 30'd0;
            tx_data           <= RESET_ACK;
        end else begin
            mul_start <= 1'b0;

            // Record whether the byte actually loaded into the SPI shifter at
            // the start of this transfer was a completed STATUS.  reply_valid
            // can rise while a poll byte is already in flight, so checking it
            // only at rx_data_strobe would advance the reply one byte early.
            if (spi_ss_n) begin
                tx_byte_active <= 1'b0;
            end else begin
                if (rx_data_strobe)
                    tx_byte_active <= 1'b0;
                if (tx_data_hold && !tx_byte_active) begin
                    tx_byte_active <= 1'b1;
                    if (proto_state == P_WAIT_RESULT)
                        status_loaded <= reply_valid && tx_data[7];
                end
            end

            // SPI protocol and byte assembly run independently of arithmetic.
            case (proto_state)
                P_WAIT_START: begin
                    if (rx_data_strobe) begin
                        if (rx_data == CMD_START) begin
                            calc_state        <= C_IDLE;
                            n_reg             <= 32'd0;
                            k_reg             <= 32'd0;
                            received_count    <= 32'd0;
                            input_count       <= 32'd0;
                            rx_word_shift     <= 32'd0;
                            rx_byte_count     <= 2'd0;
                            x_raw             <= 32'd0;
                            x_reg             <= 30'd0;
                            old_prefix        <= 30'd0;
                            x_busy            <= 1'b0;
                            prefix_sum        <= 30'd0;
                            square_sum        <= 30'd0;
                            pair_sum          <= 30'd0;
                            coeff_square      <= 30'd0;
                            coeff_pair        <= 30'd0;
                            answer            <= 30'd0;
                            reply_valid       <= 1'b0;
                            status_loaded     <= 1'b0;
                            tx_byte_active    <= 1'b0;
                            reply_byte_index  <= 2'd0;
                            tx_data           <= START_ACK;
                            proto_state       <= P_WAIT_START_ACK;
                        end else if (rx_data != CMD_NOP) begin
                            protocol_error <= 1'b1;
                            tx_data        <= 8'h00;
                        end
                    end
                end

                P_WAIT_START_ACK: begin
                    if (rx_data_strobe) begin
                        if (rx_data != CMD_NOP)
                            protocol_error <= 1'b1;
                        rx_word_shift <= 32'd0;
                        rx_byte_count <= 2'd0;
                        tx_data       <= 8'h00;
                        proto_state   <= P_RECEIVE_N;
                    end
                end

                P_RECEIVE_N: begin
                    if (rx_data_strobe) begin
                        tx_data <= 8'h00;
                        if (rx_byte_count == 2'd3) begin
                            rx_word_shift <= 32'd0;
                            rx_byte_count <= 2'd0;
                            if ({rx_word_shift[23:0], rx_data} == 32'd0 ||
                                {rx_word_shift[23:0], rx_data} > N_MAX) begin
                                n_reg            <= 32'd0;
                                answer           <= 30'd0;
                                protocol_error   <= 1'b1;
                                reply_valid      <= 1'b1;
                                reply_byte_index <= 2'd0;
                                tx_data          <= 8'hC0;
                                proto_state      <= P_WAIT_RESULT;
                                calc_state       <= C_DONE;
                            end else begin
                                n_reg       <= {rx_word_shift[23:0], rx_data};
                                proto_state <= P_RECEIVE_K;
                            end
                        end else begin
                            rx_word_shift <= {rx_word_shift[23:0], rx_data};
                            rx_byte_count <= rx_byte_count + 2'd1;
                        end
                    end
                end

                P_RECEIVE_K: begin
                    if (rx_data_strobe) begin
                        tx_data <= 8'h00;
                        if (rx_byte_count == 2'd3) begin
                            rx_word_shift <= 32'd0;
                            rx_byte_count <= 2'd0;
                            if ({rx_word_shift[23:0], rx_data} == 32'd0 ||
                                {rx_word_shift[23:0], rx_data} > n_reg) begin
                                k_reg            <= 32'd0;
                                answer           <= 30'd0;
                                protocol_error   <= 1'b1;
                                reply_valid      <= 1'b1;
                                reply_byte_index <= 2'd0;
                                tx_data          <= 8'hC0;
                                proto_state      <= P_WAIT_RESULT;
                                calc_state       <= C_DONE;
                            end else begin
                                k_reg          <= {rx_word_shift[23:0], rx_data};
                                received_count <= 32'd0;
                                input_count    <= 32'd0;
                                proto_state    <= P_STREAM_A;
                            end
                        end else begin
                            rx_word_shift <= {rx_word_shift[23:0], rx_data};
                            rx_byte_count <= rx_byte_count + 2'd1;
                        end
                    end
                end

                P_STREAM_A: begin
                    if (rx_data_strobe) begin
                        tx_data <= 8'h00;
                        if (rx_byte_count == 2'd3) begin
                            rx_word_shift <= 32'd0;
                            rx_byte_count <= 2'd0;
                            if (x_busy || received_count >= n_reg) begin
                                // A completed word cannot be queued: abort this run
                                // with a sticky, pollable protocol error.
                                protocol_error   <= 1'b1;
                                reply_valid      <= 1'b1;
                                reply_byte_index <= 2'd0;
                                answer           <= 30'd0;
                                x_busy           <= 1'b0;
                                calc_state       <= C_DONE;
                                proto_state      <= P_WAIT_RESULT;
                                tx_data          <= 8'hC0;
                            end else begin
                                x_raw          <= {rx_word_shift[23:0], rx_data};
                                x_busy         <= 1'b1;
                                received_count <= received_count + 32'd1;
                                if ((received_count + 32'd1) == n_reg)
                                    proto_state <= P_WAIT_RESULT;
                            end
                        end else begin
                            rx_word_shift <= {rx_word_shift[23:0], rx_data};
                            rx_byte_count <= rx_byte_count + 2'd1;
                        end
                    end
                end

                P_WAIT_RESULT: begin
                    if (rx_data_strobe) begin
                        if (rx_data == CMD_NOP) begin
                            if (reply_valid && status_loaded) begin
                                tx_data          <= {2'b00, answer[29:24]};
                                status_loaded     <= 1'b0;
                                reply_byte_index <= 2'd0;
                                proto_state      <= P_SEND_REPLY;
                            end else if (reply_valid) begin
                                // Completion may have occurred after this SPI
                                // byte was loaded.  Keep STATUS armed for the
                                // next poll instead of overwriting it with 0.
                                tx_data <= protocol_error ? 8'hC0 : 8'h80;
                            end else begin
                                tx_data <= 8'h00;
                            end
                        end else begin
                            protocol_error <= 1'b1;
                            tx_data <= reply_valid ? 8'hC0 : 8'h00;
                        end
                    end
                end

                P_SEND_REPLY: begin
                    if (rx_data_strobe) begin
                        if (rx_data == CMD_NOP) begin
                            case (reply_byte_index)
                                2'd0: begin
                                    tx_data          <= answer[23:16];
                                    reply_byte_index <= 2'd1;
                                end
                                2'd1: begin
                                    tx_data          <= answer[15:8];
                                    reply_byte_index <= 2'd2;
                                end
                                2'd2: begin
                                    tx_data          <= answer[7:0];
                                    reply_byte_index <= 2'd3;
                                end
                                default: begin
                                    tx_data <= protocol_error ? 8'hC0 : 8'h80;
                                    reply_byte_index <= 2'd0;
                                    proto_state <= P_WAIT_RESULT;
                                end
                            endcase
                        end else begin
                            protocol_error   <= 1'b1;
                            reply_byte_index <= 2'd0;
                            tx_data          <= 8'hC0;
                            proto_state      <= P_WAIT_RESULT;
                        end
                    end
                end

                default: begin
                    proto_state       <= P_WAIT_RESULT;
                    calc_state        <= C_DONE;
                    answer            <= 30'd0;
                    protocol_error    <= 1'b1;
                    reply_valid       <= 1'b1;
                    reply_byte_index  <= 2'd0;
                    tx_data           <= 8'hC0;
                end
            endcase

            // Arithmetic controller.  All variable modular products are
            // dispatched through u_modular_multiplier.
            case (calc_state)
                C_IDLE: begin
                    if (x_busy)
                        calc_state <= C_NORMALIZE;
                end

                C_NORMALIZE: begin
                    if (rx_data_strobe && proto_state != P_STREAM_A &&
                        proto_state != P_WAIT_RESULT)
                        protocol_error <= 1'b1;

                    if (x_raw >= {2'b00, MOD}) begin
                        x_raw <= x_raw - {2'b00, MOD};
                    end else begin
                        x_reg      <= x_raw[29:0];
                        old_prefix <= prefix_sum;
                        calc_state <= C_INPUT_PAIR_START;
                    end
                end

                C_INPUT_PAIR_START: begin
                    if (!mul_busy) begin
                        mul_lhs    <= x_reg;
                        mul_rhs    <= old_prefix;
                        mul_start  <= 1'b1;
                        calc_state <= C_INPUT_PAIR_WAIT;
                    end
                end

                C_INPUT_PAIR_WAIT: begin
                    if (mul_done) begin
                        calc_state <= C_INPUT_PAIR_ADD;
                    end
                end

                C_INPUT_PAIR_ADD: begin
                    if (!mul_busy) begin
                        pair_sum  <= mod_add_result;
                        mul_lhs    <= x_reg;
                        mul_rhs    <= x_reg;
                        mul_start  <= 1'b1;
                        calc_state <= C_INPUT_SQUARE_WAIT;
                    end
                end

                C_INPUT_SQUARE_WAIT: begin
                    if (mul_done) begin
                        calc_state <= C_INPUT_SQUARE_ADD;
                    end
                end

                C_INPUT_SQUARE_ADD: begin
                    square_sum <= mod_add_result;
                    calc_state <= C_INPUT_PREFIX_ADD;
                end

                C_INPUT_PREFIX_ADD: begin
                    prefix_sum <= mod_add_result;
                    input_count <= input_count + 32'd1;
                    x_busy <= 1'b0;
                    if ((input_count + 32'd1) == n_reg) begin
                        if (k_reg == 32'd1)
                            calc_state <= C_K1_FINISH;
                        else
                            calc_state <= C_COMB_INIT;
                    end else begin
                        calc_state <= C_IDLE;
                    end
                end

                C_COMB_INIT: begin
                    comb_n      <= n_reg - 32'd1;
                    comb_i      <= 32'd1;
                    numerator   <= 30'd1;
                    denominator <= 30'd1;
                    if ((k_reg - 32'd1) <= (n_reg - k_reg))
                        comb_r <= k_reg - 32'd1;
                    else
                        comb_r <= n_reg - k_reg;
                    calc_state <= C_COMB_CHECK;
                end

                C_COMB_CHECK: begin
                    if (comb_r == 32'd0) begin
                        coeff_square <= 30'd1;
                        pow_result   <= 30'd1;
                        pow_base     <= n_minus_one_mod_value;
                        pow_exp      <= MOD - 30'd2;
                        pow_context  <= 1'b1;
                        calc_state   <= C_POW_CHECK;
                    end else if (comb_i > comb_r) begin
                        pow_result  <= 30'd1;
                        pow_base    <= denominator;
                        pow_exp     <= MOD - 30'd2;
                        pow_context <= 1'b0;
                        calc_state  <= C_POW_CHECK;
                    end else begin
                        calc_state <= C_NUMERATOR_START;
                    end
                end

                C_NUMERATOR_START: begin
                    if (!mul_busy) begin
                        mul_lhs    <= numerator;
                        mul_rhs    <= comb_factor_mod_value;
                        mul_start  <= 1'b1;
                        calc_state <= C_NUMERATOR_WAIT;
                    end
                end

                C_NUMERATOR_WAIT: begin
                    if (mul_done) begin
                        numerator  <= mul_product;
                        calc_state <= C_DENOMINATOR_START;
                    end
                end

                C_DENOMINATOR_START: begin
                    if (!mul_busy) begin
                        mul_lhs    <= denominator;
                        mul_rhs    <= comb_i[29:0];
                        mul_start  <= 1'b1;
                        calc_state <= C_DENOMINATOR_WAIT;
                    end
                end

                C_DENOMINATOR_WAIT: begin
                    if (mul_done) begin
                        denominator <= mul_product;
                        comb_i      <= comb_i + 32'd1;
                        calc_state  <= C_COMB_CHECK;
                    end
                end

                C_POW_CHECK: begin
                    if (pow_exp == 30'd0) begin
                        if (pow_context == 1'b0)
                            calc_state <= C_COEFF_SQUARE_START;
                        else
                            calc_state <= C_COEFF_PAIR_1_START;
                    end else if (pow_exp[0]) begin
                        calc_state <= C_POW_RESULT_START;
                    end else begin
                        calc_state <= C_POW_BASE_START;
                    end
                end

                C_POW_RESULT_START: begin
                    if (!mul_busy) begin
                        mul_lhs    <= pow_result;
                        mul_rhs    <= pow_base;
                        mul_start  <= 1'b1;
                        calc_state <= C_POW_RESULT_WAIT;
                    end
                end

                C_POW_RESULT_WAIT: begin
                    if (mul_done) begin
                        pow_result <= mul_product;
                        calc_state <= C_POW_BASE_START;
                    end
                end

                C_POW_BASE_START: begin
                    if (!mul_busy) begin
                        mul_lhs    <= pow_base;
                        mul_rhs    <= pow_base;
                        mul_start  <= 1'b1;
                        calc_state <= C_POW_BASE_WAIT;
                    end
                end

                C_POW_BASE_WAIT: begin
                    if (mul_done) begin
                        pow_base   <= mul_product;
                        pow_exp    <= pow_exp >> 1;
                        calc_state <= C_POW_CHECK;
                    end
                end

                C_COEFF_SQUARE_START: begin
                    if (!mul_busy) begin
                        mul_lhs    <= numerator;
                        mul_rhs    <= pow_result;
                        mul_start  <= 1'b1;
                        calc_state <= C_COEFF_SQUARE_WAIT;
                    end
                end

                C_COEFF_SQUARE_WAIT: begin
                    if (mul_done) begin
                        coeff_square <= mul_product;
                        pow_result   <= 30'd1;
                        pow_base     <= n_minus_one_mod_value;
                        pow_exp      <= MOD - 30'd2;
                        pow_context  <= 1'b1;
                        calc_state   <= C_POW_CHECK;
                    end
                end

                C_COEFF_PAIR_1_START: begin
                    if (!mul_busy) begin
                        mul_lhs    <= coeff_square;
                        mul_rhs    <= k_minus_one_mod_value;
                        mul_start  <= 1'b1;
                        calc_state <= C_COEFF_PAIR_1_WAIT;
                    end
                end

                C_COEFF_PAIR_1_WAIT: begin
                    if (mul_done) begin
                        coeff_pair_work <= mul_product;
                        calc_state      <= C_COEFF_PAIR_2_START;
                    end
                end

                C_COEFF_PAIR_2_START: begin
                    if (!mul_busy) begin
                        mul_lhs    <= coeff_pair_work;
                        mul_rhs    <= pow_result;
                        mul_start  <= 1'b1;
                        calc_state <= C_COEFF_PAIR_2_WAIT;
                    end
                end

                C_COEFF_PAIR_2_WAIT: begin
                    if (mul_done) begin
                        coeff_pair <= mul_product;
                        calc_state <= C_FINAL_SQUARE_START;
                    end
                end

                C_FINAL_SQUARE_START: begin
                    if (!mul_busy) begin
                        mul_lhs    <= coeff_square;
                        mul_rhs    <= square_sum;
                        mul_start  <= 1'b1;
                        calc_state <= C_FINAL_SQUARE_WAIT;
                    end
                end

                C_FINAL_SQUARE_WAIT: begin
                    if (mul_done) begin
                        term_square <= mul_product;
                        calc_state  <= C_FINAL_PAIR_START;
                    end
                end

                C_FINAL_PAIR_START: begin
                    if (!mul_busy) begin
                        mul_lhs    <= coeff_pair;
                        mul_rhs    <= pair_sum;
                        mul_start  <= 1'b1;
                        calc_state <= C_FINAL_PAIR_WAIT;
                    end
                end

                C_FINAL_PAIR_WAIT: begin
                    if (mul_done) begin
                        calc_state <= C_FINAL_PAIR_DOUBLE;
                    end
                end

                C_FINAL_PAIR_DOUBLE: begin
                    term_pair  <= mod_add_result;
                    calc_state <= C_FINAL_ADD;
                end

                C_FINAL_ADD: begin
                    answer     <= mod_add_result;
                    calc_state <= C_PUBLISH;
                end

                C_K1_FINISH: begin
                    coeff_square <= 30'd1;
                    coeff_pair   <= 30'd0;
                    answer       <= square_sum;
                    calc_state   <= C_PUBLISH;
                end

                C_PUBLISH: begin
                    reply_valid <= 1'b1;
                    status_loaded <= 1'b0;
                    tx_data <= protocol_error ? 8'hC0 : 8'h80;
                    calc_state <= C_DONE;
                end

                C_DONE: begin
                    // Hold the completed result until command RESET.
                end

                default: begin
                    calc_state      <= C_DONE;
                    answer          <= 30'd0;
                    protocol_error  <= 1'b1;
                    reply_valid     <= 1'b1;
                    tx_data         <= 8'hC0;
                end
            endcase
        end
    end

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
        .o_tx_data_hold(tx_data_hold)
    );

endmodule


// One shared, variable 30-bit modular multiplier.  It deliberately uses no
// Verilog '*' operator.  The add and double phases share one 31-bit adder,
// giving exactly 2 clocks/bit * 30 bits = 60 processing clocks.
module modular_multiplier (
    input             i_clk,
    input             i_rst_n,
    input             i_clear,
    input             i_start,
    input      [29:0] i_lhs,
    input      [29:0] i_rhs,
    output reg        o_busy,
    output reg        o_done,
    output reg [29:0] o_product
);

    localparam [29:0] MOD = 30'd998244353;

    reg [29:0] acc;
    reg [29:0] addend;
    reg [29:0] multiplier;
    reg [4:0]  bit_count;
    reg        phase;

    wire [30:0] adder_left = phase ? {1'b0, addend} : {1'b0, acc};
    wire [30:0] adder_right = {1'b0, addend};
    wire [30:0] adder_sum = adder_left + adder_right;
    wire [30:0] reduced_sum_wide =
        (adder_sum >= {1'b0, MOD}) ?
        (adder_sum - {1'b0, MOD}) : adder_sum;
    wire [29:0] reduced_sum = reduced_sum_wide[29:0];

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_busy     <= 1'b0;
            o_done     <= 1'b0;
            o_product  <= 30'd0;
            acc        <= 30'd0;
            addend     <= 30'd0;
            multiplier <= 30'd0;
            bit_count  <= 5'd0;
            phase      <= 1'b0;
        end else if (i_clear) begin
            o_busy     <= 1'b0;
            o_done     <= 1'b0;
            o_product  <= 30'd0;
            acc        <= 30'd0;
            addend     <= 30'd0;
            multiplier <= 30'd0;
            bit_count  <= 5'd0;
            phase      <= 1'b0;
        end else begin
            o_done <= 1'b0;
            if (!o_busy) begin
                if (i_start) begin
                    o_busy     <= 1'b1;
                    acc        <= 30'd0;
                    addend     <= i_lhs;
                    multiplier <= i_rhs;
                    bit_count  <= 5'd0;
                    phase      <= 1'b0;
                end
            end else if (!phase) begin
                if (multiplier[0])
                    acc <= reduced_sum;
                phase <= 1'b1;
            end else begin
                addend     <= reduced_sum;
                multiplier <= multiplier >> 1;
                phase      <= 1'b0;
                if (bit_count == 5'd29) begin
                    o_product <= acc;
                    o_busy    <= 1'b0;
                    o_done    <= 1'b1;
                end else begin
                    bit_count <= bit_count + 5'd1;
                end
            end
        end
    end

endmodule
