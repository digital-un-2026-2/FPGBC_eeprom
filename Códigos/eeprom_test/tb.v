`timescale 1ns/1ps
// Modelo simple de ST24C04 (512 B, t_WR = 10 ms, no responde mientras graba)
module st24c04(inout sda, input scl);
    reg [7:0] mem [0:511]; integer k; initial for (k=0;k<512;k=k+1) mem[k]=8'hFF;
    reg drv = 0; assign sda = drv ? 1'b0 : 1'bz;
    reg [3:0] bitc = 0; reg [7:0] sh = 0, rd = 0; reg [1:0] nb = 0;
    reg dphase = 0; reg reading = 0, sel = 0, a8 = 0, wrote = 0; reg [8:0] ptr = 0;
    realtime busy_until = 0;
    always @(negedge sda) if (scl === 1'b1) begin bitc = 0; nb = 0; reading = 0; dphase = 0; sel = 0; drv = 0; end
    always @(posedge sda) if (scl === 1'b1) begin
        if (wrote) begin busy_until = $realtime + 10_000_000; wrote = 0; end
        bitc = 0; reading = 0; sel = 0; drv = 0; end
    always @(posedge scl) begin
        if (bitc < 8) begin sh = {sh[6:0], sda === 1'b0 ? 1'b0 : 1'b1}; bitc = bitc + 1; end
        else begin bitc = 0; if (reading && dphase) begin if (sda !== 1'b0) reading = 0; else begin ptr = ptr + 1; rd = mem[ptr]; end end dphase = reading; end
    end
    always @(negedge scl) begin
        #100;
        if (bitc == 8 && !reading) begin
            if (nb == 0) begin
                if (sh[7:2] == 6'b101000 && $realtime >= busy_until) begin
                    sel = 1; a8 = sh[1]; drv = 1;
                    if (sh[0]) begin reading = 1; rd = mem[ptr]; end
                end
            end else if (sel) begin
                drv = 1;
                if (nb == 1) ptr = {a8, sh}; else begin mem[ptr] = sh; wrote = 1; ptr = ptr + 1; end
            end
            if (nb < 3) nb = nb + 1;
        end else if (reading && bitc < 8) drv = ~rd[7 - bitc];
        else drv = 0;
    end
endmodule

module tb;
    parameter TWR = 800_000;
    reg clk = 0; always #12.5 clk = ~clk;
    wire TXD, scl; tri1 sda;   // tri1 = pull-up
    eeprom_test #(.WAIT_LOOP(400_000), .WAIT_TWR(TWR)) dut(.clk(clk), .TXD(TXD), .sda(sda), .scl(scl));
    st24c04 ee(.sda(sda), .scl(scl));
    // receptor UART del testbench
    localparam real BIT = 1e9/57600; reg [7:0] c; integer i;
    initial forever begin
        @(negedge TXD); #(BIT*1.5);
        for (i=0;i<8;i=i+1) begin c[i] = TXD; #(BIT); end
        if (c >= 8'h20) $write("%c", c); else if (c == 8'h0A) $write("\n");
    end
    initial begin #75_000_000; $display("\n[fin %0t ms]", $time/1_000_000); $finish; end
endmodule
