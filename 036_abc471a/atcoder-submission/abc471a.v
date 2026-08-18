module main;
    integer A, B;
    integer ret;
    reg nine;

    initial begin
        ret = $fscanf(32'h80000000, "%d %d", A, B);

        nine =
            (A + B == 9) ||
            (A - B == 9) ||
            (A * B == 9) ||
            (A == 9 * B);

        if (nine)
            $display("Nine");
        else
            $display("Nein");
    end
endmodule