`timescale 1ns/1ps

// ABC470D - Inverse and Swap
// Ideal-FPGA out-of-order scheduler with optional safe normalization.
module abc470d_out_of_order #(
    parameter integer ISSUE_WIDTH = 256,
    parameter integer LOOKAHEAD = 1024,
    parameter integer ENABLE_CANCEL = 0
);
    localparam integer MAX_N = 500000;
    localparam integer MAX_Q = 500000;

    localparam [1:0] PHASE_BUILD_INVERSE = 2'd0;
    localparam [1:0] PHASE_QUERY         = 2'd1;
    localparam [1:0] PHASE_ANSWER        = 2'd2;

    integer n;
    integer q;

    integer p      [1:MAX_N];
    integer pinv   [1:MAX_N];
    integer answer [1:MAX_N];

    reg [1:0] query_type [0:MAX_Q-1];
    integer query_x      [0:MAX_Q-1];
    integer query_y      [0:MAX_Q-1];

    // Live queries remain in original input order even after OoO execution
    // creates holes in the raw query arrays.
    reg query_done    [0:MAX_Q-1];
    integer next_live [0:MAX_Q-1];
    integer prev_live [0:MAX_Q-1];
    integer live_head;
    integer live_count;
    integer admit_index;
    integer window_count;

    // Dependency graph for the first live Type-1 segment before a barrier.
    integer dependency_count [0:MAX_Q-1];
    integer next_touch_x     [0:MAX_Q-1];
    integer next_touch_y     [0:MAX_Q-1];
    integer last_touch       [1:MAX_N];
    integer touch_stamp      [1:MAX_N];
    integer dependency_epoch;
    integer barrier_index;

    // Input-index min-heap of ready queries (at most LOOKAHEAD entries).
    reg ready_flag [0:MAX_Q-1];
    integer ready_heap [0:LOOKAHEAD-1];
    integer ready_count;
    integer ready_head;

    // Fixed issue lanes and a temporary normalization-window view.
    integer issue_index [0:ISSUE_WIDTH-1];
    integer norm_index  [0:LOOKAHEAD-1];

    reg clk;
    reg inverted;
    reg [1:0] phase;
    integer logical_clock;
    integer query_clock;
    integer issue_cycles;
    integer type1_executed;
    integer type1_canceled;
    integer type2_executed;
    integer type2_eliminated;

    integer i;
    integer lane;
    integer issue_count;
    integer scan_result;
    integer input_value;
    integer input_x;
    integer input_y;
    integer swap_a;
    integer swap_b;
    integer old_admit_index;

    task ready_insert;
        input integer query_id;
        integer heap_position;
        integer parent_position;
        integer temporary;
        begin
            if (ready_flag[query_id] == 1'b0) begin
                ready_flag[query_id] = 1'b1;
                heap_position = ready_count;
                ready_heap[heap_position] = query_id;
                ready_count = ready_count + 1;
                while (heap_position > 0) begin
                    parent_position = (heap_position - 1) / 2;
                    if (
                        ready_heap[parent_position] <=
                        ready_heap[heap_position]
                    ) begin
                        heap_position = 0;
                    end else begin
                        temporary = ready_heap[parent_position];
                        ready_heap[parent_position] = ready_heap[heap_position];
                        ready_heap[heap_position] = temporary;
                        heap_position = parent_position;
                    end
                end
                ready_head = ready_heap[0];
            end
        end
    endtask

    task ready_remove;
        input integer query_id;
        integer heap_position;
        integer left_child;
        integer right_child;
        integer smaller_child;
        integer temporary;
        begin
            if (ready_flag[query_id] != 1'b0) begin
                if (query_id != ready_heap[0]) begin
                    $fdisplay(
                        32'h80000002,
                        "ERROR: ready heap removed out of input order"
                    );
                    $finish(1);
                end
                ready_flag[query_id] = 1'b0;
                ready_count = ready_count - 1;
                if (ready_count == 0) begin
                    ready_head = -1;
                end else begin
                    ready_heap[0] = ready_heap[ready_count];
                    heap_position = 0;
                    left_child = 1;
                    while (left_child < ready_count) begin
                        right_child = left_child + 1;
                        smaller_child = left_child;
                        if (
                            (right_child < ready_count) &&
                            (ready_heap[right_child] < ready_heap[left_child])
                        ) begin
                            smaller_child = right_child;
                        end
                        if (
                            ready_heap[heap_position] <=
                            ready_heap[smaller_child]
                        ) begin
                            left_child = ready_count;
                        end else begin
                            temporary = ready_heap[heap_position];
                            ready_heap[heap_position] = ready_heap[smaller_child];
                            ready_heap[smaller_child] = temporary;
                            heap_position = smaller_child;
                            left_child = 2 * heap_position + 1;
                        end
                    end
                    ready_head = ready_heap[0];
                end
            end
        end
    endtask

    task unlink_live;
        input integer query_id;
        integer before_query;
        integer after_query;
        begin
            if (query_done[query_id] == 1'b0) begin
                before_query = prev_live[query_id];
                after_query = next_live[query_id];
                if (before_query >= 0) begin
                    next_live[before_query] = after_query;
                end else begin
                    live_head = after_query;
                end
                if (after_query >= 0) begin
                    prev_live[after_query] = before_query;
                end
                query_done[query_id] = 1'b1;
                live_count = live_count - 1;
                window_count = window_count - 1;
            end
        end
    endtask

    task refill_window;
        begin
            while ((window_count < LOOKAHEAD) && (admit_index < q)) begin
                window_count = window_count + 1;
                admit_index = admit_index + 1;
            end
        end
    endtask

    task add_dependency;
        input integer query_id;
        integer position;
        integer predecessor;
        begin
            dependency_count[query_id] = 0;
            next_touch_x[query_id] = -1;
            next_touch_y[query_id] = -1;
            ready_flag[query_id] = 1'b0;

            position = query_x[query_id];
            if (touch_stamp[position] == dependency_epoch) begin
                predecessor = last_touch[position];
            end else begin
                predecessor = -1;
            end
            if (predecessor >= 0) begin
                dependency_count[query_id] = dependency_count[query_id] + 1;
                if (query_x[predecessor] == position) begin
                    next_touch_x[predecessor] = query_id;
                end else begin
                    next_touch_y[predecessor] = query_id;
                end
            end
            touch_stamp[position] = dependency_epoch;
            last_touch[position] = query_id;

            position = query_y[query_id];
            if (touch_stamp[position] == dependency_epoch) begin
                predecessor = last_touch[position];
            end else begin
                predecessor = -1;
            end
            if (predecessor >= 0) begin
                dependency_count[query_id] = dependency_count[query_id] + 1;
                if (query_x[predecessor] == position) begin
                    next_touch_x[predecessor] = query_id;
                end else begin
                    next_touch_y[predecessor] = query_id;
                end
            end
            touch_stamp[position] = dependency_epoch;
            last_touch[position] = query_id;

            if (dependency_count[query_id] == 0) begin
                ready_insert(query_id);
            end
        end
    endtask

    task rebuild_dependencies;
        integer cursor;
        begin
            dependency_epoch = dependency_epoch + 1;
            ready_count = 0;
            ready_head = -1;
            barrier_index = -1;
            cursor = live_head;
            while (
                (cursor >= 0) &&
                (cursor < admit_index) &&
                (barrier_index < 0)
            ) begin
                if (query_type[cursor] == 2'd2) begin
                    barrier_index = cursor;
                end else begin
                    add_dependency(cursor);
                    cursor = next_live[cursor];
                end
            end
        end
    endtask

    task add_newly_admitted_dependencies;
        input integer first_new_index;
        integer cursor;
        begin
            cursor = first_new_index;
            while (cursor < admit_index) begin
                if (barrier_index < 0) begin
                    if (query_type[cursor] == 2'd2) begin
                        barrier_index = cursor;
                    end else begin
                        add_dependency(cursor);
                    end
                end
                cursor = cursor + 1;
            end
        end
    endtask

    task collect_normalization_window;
        output integer collected;
        integer cursor;
        begin
            collected = 0;
            cursor = live_head;
            while (
                (cursor >= 0) &&
                (cursor < admit_index) &&
                (collected < LOOKAHEAD)
            ) begin
                norm_index[collected] = cursor;
                collected = collected + 1;
                cursor = next_live[cursor];
            end
        end
    endtask

    task normalize_window;
        integer changed;
        integer collected;
        integer slot;
        integer query_id;
        integer previous_x;
        integer previous_y;
        integer restore_x;
        integer restore_y;
        integer position;
        integer pending_type2;
        begin
            changed = 1;
            while (changed != 0) begin
                changed = 0;
                refill_window;
                collect_normalization_window(collected);

                // One pass performs cascading Type-1 cancellation inside each
                // currently surviving Type-2 segment. next_touch_* temporarily
                // stores the previous touch for restoration after a deletion.
                dependency_epoch = dependency_epoch + 1;
                for (slot = 0; slot < collected; slot = slot + 1) begin
                    query_id = norm_index[slot];
                    if (query_done[query_id] == 1'b0) begin
                        if (query_type[query_id] == 2'd2) begin
                            dependency_epoch = dependency_epoch + 1;
                        end else begin
                            position = query_x[query_id];
                            if (touch_stamp[position] == dependency_epoch) begin
                                previous_x = last_touch[position];
                            end else begin
                                previous_x = -1;
                            end
                            position = query_y[query_id];
                            if (touch_stamp[position] == dependency_epoch) begin
                                previous_y = last_touch[position];
                            end else begin
                                previous_y = -1;
                            end

                            if (
                                (previous_x >= 0) &&
                                (previous_x == previous_y) &&
                                (query_x[previous_x] == query_x[query_id]) &&
                                (query_y[previous_x] == query_y[query_id])
                            ) begin
                                restore_x = next_touch_x[previous_x];
                                restore_y = next_touch_y[previous_x];
                                position = query_x[query_id];
                                touch_stamp[position] = dependency_epoch;
                                last_touch[position] = restore_x;
                                position = query_y[query_id];
                                touch_stamp[position] = dependency_epoch;
                                last_touch[position] = restore_y;
                                unlink_live(previous_x);
                                unlink_live(query_id);
                                type1_canceled = type1_canceled + 2;
                                changed = 1;
                            end else begin
                                next_touch_x[query_id] = previous_x;
                                next_touch_y[query_id] = previous_y;
                                position = query_x[query_id];
                                touch_stamp[position] = dependency_epoch;
                                last_touch[position] = query_id;
                                position = query_y[query_id];
                                touch_stamp[position] = dependency_epoch;
                                last_touch[position] = query_id;
                            end
                        end
                    end
                end

                // Type-1 deletion can expose adjacent Type-2 runs. Cancel all
                // pairs in each run; a run with odd length leaves one barrier.
                collect_normalization_window(collected);
                pending_type2 = -1;
                for (slot = 0; slot < collected; slot = slot + 1) begin
                    query_id = norm_index[slot];
                    if (query_done[query_id] == 1'b0) begin
                        if (query_type[query_id] == 2'd2) begin
                            if (pending_type2 >= 0) begin
                                unlink_live(pending_type2);
                                unlink_live(query_id);
                                type2_eliminated = type2_eliminated + 2;
                                pending_type2 = -1;
                                changed = 1;
                            end else begin
                                pending_type2 = query_id;
                            end
                        end else begin
                            pending_type2 = -1;
                        end
                    end
                end
            end
        end
    endtask

    task release_endpoint;
        input integer query_id;
        input integer successor;
        input integer position;
        begin
            if (successor >= 0) begin
                dependency_count[successor] = dependency_count[successor] - 1;
                if (dependency_count[successor] == 0) begin
                    ready_insert(successor);
                end
            end else if (
                (touch_stamp[position] == dependency_epoch) &&
                (last_touch[position] == query_id)
            ) begin
                last_touch[position] = -1;
            end
        end
    endtask

    task emit_answer;
        begin
            for (i = 1; i <= n; i = i + 1) begin
                answer[i] = inverted ? pinv[i] : p[i];
            end
            for (i = 1; i <= n; i = i + 1) begin
                if (i > 1) begin
                    $write(" ");
                end
                $write("%0d", answer[i]);
            end
            $write("\n");
            $fdisplay(
                32'h80000002,
                {"LOGICAL_CLOCKS=%0d QUERY_CLOCKS=%0d ISSUE_CYCLES=%0d ",
                 "TYPE1_EXECUTED=%0d TYPE1_CANCELED=%0d ",
                 "TYPE2_EXECUTED=%0d TYPE2_ELIMINATED=%0d ",
                 "ISSUE_WIDTH=%0d LOOKAHEAD=%0d CANCEL=%0d SIM_TIME=%0t"},
                logical_clock,
                query_clock,
                issue_cycles,
                type1_executed,
                type1_canceled,
                type2_executed,
                type2_eliminated,
                ISSUE_WIDTH,
                LOOKAHEAD,
                ENABLE_CANCEL,
                $time
            );
            $finish(0);
        end
    endtask

    initial begin
        clk = 1'b0;
        inverted = 1'b0;
        phase = PHASE_BUILD_INVERSE;
        logical_clock = 0;
        query_clock = 0;
        issue_cycles = 0;
        type1_executed = 0;
        type1_canceled = 0;
        type2_executed = 0;
        type2_eliminated = 0;
        dependency_epoch = 0;
        ready_count = 0;
        ready_head = -1;
        barrier_index = -1;

        if (
            (ISSUE_WIDTH < 1) ||
            (LOOKAHEAD < ISSUE_WIDTH) ||
            (LOOKAHEAD > MAX_Q) ||
            ((ENABLE_CANCEL != 0) && (ENABLE_CANCEL != 1))
        ) begin
            $fdisplay(32'h80000002, "ERROR: invalid scheduler parameters");
            $finish(1);
        end

        scan_result = $fscanf(32'h80000000, "%d %d", n, q);
        if (scan_result != 2) begin
            $fdisplay(32'h80000002, "ERROR: failed to read N and Q");
            $finish(1);
        end
        if ((n < 2) || (n > MAX_N) || (q < 1) || (q > MAX_Q)) begin
            $fdisplay(32'h80000002, "ERROR: N or Q is out of range");
            $finish(1);
        end

        for (i = 1; i <= n; i = i + 1) begin
            scan_result = $fscanf(32'h80000000, "%d", input_value);
            if (scan_result != 1) begin
                $fdisplay(32'h80000002, "ERROR: failed to read P[%0d]", i);
                $finish(1);
            end
            p[i] = input_value;
        end

        for (i = 0; i < q; i = i + 1) begin
            scan_result = $fscanf(32'h80000000, "%d", input_value);
            if (scan_result != 1) begin
                $fdisplay(32'h80000002, "ERROR: failed to read query %0d", i + 1);
                $finish(1);
            end
            query_type[i] = input_value[1:0];
            if (query_type[i] == 2'd1) begin
                scan_result = $fscanf(
                    32'h80000000, "%d %d", input_x, input_y
                );
                if (scan_result != 2) begin
                    $fdisplay(
                        32'h80000002,
                        "ERROR: failed to read arguments of query %0d",
                        i + 1
                    );
                    $finish(1);
                end
                query_x[i] = input_x;
                query_y[i] = input_y;
            end else if (query_type[i] == 2'd2) begin
                query_x[i] = 0;
                query_y[i] = 0;
            end else begin
                $fdisplay(32'h80000002, "ERROR: invalid query type");
                $finish(1);
            end
        end

        forever #1 clk = ~clk;
    end

    always @(posedge clk) begin
        logical_clock = logical_clock + 1;

        case (phase)
            PHASE_BUILD_INVERSE: begin
                for (i = 1; i <= n; i = i + 1) begin
                    pinv[p[i]] = i;
                    touch_stamp[i] = 0;
                    last_touch[i] = -1;
                end
                for (i = 0; i < q; i = i + 1) begin
                    query_done[i] = 1'b0;
                    if (i == 0) begin
                        prev_live[i] = -1;
                    end else begin
                        prev_live[i] = i - 1;
                    end
                    if (i == q - 1) begin
                        next_live[i] = -1;
                    end else begin
                        next_live[i] = i + 1;
                    end
                    ready_flag[i] = 1'b0;
                end
                live_head = 0;
                live_count = q;
                if (q < LOOKAHEAD) begin
                    window_count = q;
                    admit_index = q;
                end else begin
                    window_count = LOOKAHEAD;
                    admit_index = LOOKAHEAD;
                end
                rebuild_dependencies;
                phase <= PHASE_QUERY;
            end

            PHASE_QUERY: begin
                if (ENABLE_CANCEL != 0) begin
                    normalize_window;
                    if (live_count > 0) begin
                        rebuild_dependencies;
                    end
                end

                if (live_count == 0) begin
                    // Normalization removed the complete suffix. This edge is
                    // the answer-latch clock, not an empty query clock.
                    emit_answer;
                end else if (query_type[live_head] == 2'd2) begin
                    query_clock = query_clock + 1;
                    type2_executed = type2_executed + 1;
                    inverted <= ~inverted;
                    unlink_live(live_head);
                    old_admit_index = admit_index;
                    refill_window;
                    if ((ENABLE_CANCEL == 0) && (live_count > 0)) begin
                        rebuild_dependencies;
                    end
                    if (live_count == 0) begin
                        phase <= PHASE_ANSWER;
                    end
                end else begin
                    issue_count = 0;
                    while (
                        (issue_count < ISSUE_WIDTH) &&
                        (ready_head >= 0)
                    ) begin
                        issue_index[issue_count] = ready_head;
                        ready_remove(ready_head);
                        issue_count = issue_count + 1;
                    end

                    if (issue_count == 0) begin
                        $fdisplay(
                            32'h80000002,
                            "ERROR: live Type 1 segment has no ready query"
                        );
                        $finish(1);
                    end

                    query_clock = query_clock + 1;
                    issue_cycles = issue_cycles + 1;
                    type1_executed = type1_executed + issue_count;

                    // Schedule all data-path writes from the same pre-clock
                    // state before retiring any selected scheduler entries.
                    for (lane = 0; lane < issue_count; lane = lane + 1) begin
                        i = issue_index[lane];
                        if (!inverted) begin
                            swap_a = p[query_x[i]];
                            swap_b = p[query_y[i]];
                            p[query_x[i]] <= swap_b;
                            p[query_y[i]] <= swap_a;
                            pinv[swap_a] <= query_y[i];
                            pinv[swap_b] <= query_x[i];
                        end else begin
                            swap_a = pinv[query_x[i]];
                            swap_b = pinv[query_y[i]];
                            pinv[query_x[i]] <= swap_b;
                            pinv[query_y[i]] <= swap_a;
                            p[swap_a] <= query_y[i];
                            p[swap_b] <= query_x[i];
                        end
                    end

                    for (lane = 0; lane < issue_count; lane = lane + 1) begin
                        i = issue_index[lane];
                        if (ENABLE_CANCEL == 0) begin
                            release_endpoint(
                                i,
                                next_touch_x[i],
                                query_x[i]
                            );
                            release_endpoint(
                                i,
                                next_touch_y[i],
                                query_y[i]
                            );
                        end
                        unlink_live(i);
                    end

                    old_admit_index = admit_index;
                    refill_window;
                    if (ENABLE_CANCEL == 0) begin
                        add_newly_admitted_dependencies(old_admit_index);
                    end
                    if (live_count == 0) begin
                        phase <= PHASE_ANSWER;
                    end
                end
            end

            PHASE_ANSWER: begin
                emit_answer;
            end

            default: begin
                $fdisplay(32'h80000002, "ERROR: invalid phase");
                $finish(1);
            end
        endcase
    end
endmodule
