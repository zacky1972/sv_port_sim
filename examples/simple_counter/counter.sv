module Counter (
    input  bit         clk,
    input  bit         rst_n,
    input  bit         enable,
    output logic [7:0] count
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= 8'h00;
        end else if (enable) begin
            count <= count + 8'd1;
        end
    end
endmodule
