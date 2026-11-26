// Prueba EEPROM ST24C04 de la FPGBC (reloj 40 MHz, pin 11)
// Escribe 0x47 en la dirección 0x00 una vez y luego lee e imprime cada segundo:
//   "RD: 0x47"        -> todo bien
//   "NACK paso N"     -> la EEPROM no respondió en el byte N
//      1=A0(escritura) 2=dir 3=dato 4=A0(lectura) 5=dir 6=A1
module eeprom_test #(
    parameter CLK_FREQ  = 40_000_000,   // FPGBC: oscilador de 40 MHz
    parameter BAUD_RATE = 57600,
    parameter WAIT_TWR  = CLK_FREQ / 50, // 20 ms (> t_WR = 10 ms)
    parameter WAIT_LOOP = CLK_FREQ       // 1 s entre lecturas
)(
    input  wire clk,
    output wire TXD,
    inout  wire sda,
    output wire scl
);
    localparam I2C_HALF_BIT = CLK_FREQ / 200_000;   // 5 us por sub-paso
    localparam UART_BIT_CNT = CLK_FREQ / BAUD_RATE;

    // Reset interno al encender (la FPGBC no tiene botón de reset)
    reg [7:0] por = 0;
    wire resetn = &por;
    always @(posedge clk) if (!resetn) por <= por + 1;

    reg sda_out = 1'b1;           // 1 = suelta (Z), 0 = baja a GND
    reg scl_reg = 1'b1;
    assign sda = sda_out ? 1'bz : 1'b0;
    assign scl = scl_reg;

    localparam CTRL_WRITE = 8'hA0, CTRL_READ = 8'hA1;
    localparam MEM_ADDR   = 8'h00, TEST_BYTE = 8'h47;

    localparam ST_BOOT=0, ST_WR_START=1, ST_WR_CTRL=2, ST_WR_ADDR=3, ST_WR_DATA=4,
               ST_WR_STOP=5, ST_EEPROM_WAIT=6, ST_RD_START1=7, ST_RD_CTRL_W=8,
               ST_RD_ADDR=9, ST_RD_RESTART=10, ST_RD_CTRL_R=11, ST_RD_READ=12,
               ST_RD_STOP=13, ST_UART_PREP=14, ST_UART_SEND=15, ST_LOOP=16;

    reg [4:0]  state = ST_BOOT, next_state = ST_BOOT;
    reg [31:0] timer = 0;
    reg [2:0]  sub_step = 0;
    reg [7:0]  tx_byte = 0, rx_byte = 0;
    reg [3:0]  bit_idx = 0;
    reg        byte_active = 0, is_read = 0;
    reg [2:0]  paso = 0;          // byte actual (1..6)
    reg [2:0]  nack_paso = 0;     // primer byte sin ACK (0 = ninguno)

    reg        txd_reg = 1'b1;
    assign TXD = txd_reg;
    reg [7:0]  msg [0:15];
    reg [3:0]  msg_len = 0, msg_idx = 0, uart_bit = 0;
    reg [15:0] uart_timer = 0;
    reg [9:0]  uart_frame = 10'h3FF;

    function [7:0] hex; input [3:0] n; hex = (n < 10) ? "0" + n : "A" + n - 10; endfunction

    // Lanza el envío/recepción de un byte
    task send_byte; input [7:0] b; input rd; input [2:0] p; input [4:0] nxt; begin
        tx_byte <= b; is_read <= rd; paso <= p; next_state <= nxt;
        bit_idx <= 0; sub_step <= 0; byte_active <= 1;
    end endtask

    always @(posedge clk) begin
        if (!resetn) begin
            state <= ST_BOOT; timer <= 0; sub_step <= 0; sda_out <= 1; scl_reg <= 1;
            byte_active <= 0; txd_reg <= 1; nack_paso <= 0;
        end else if (byte_active) begin
            // ---------- 8 bits + ACK, 4 sub-pasos por bit ----------
            if (timer < I2C_HALF_BIT - 1) timer <= timer + 1;
            else begin
                timer <= 0;
                case (sub_step)
                0: begin scl_reg <= 0;
                         if (bit_idx < 8) sda_out <= is_read ? 1'b1 : tx_byte[7 - bit_idx];
                         else             sda_out <= 1'b1;   // escritura: soltar para ACK; lectura: NACK
                         sub_step <= 1; end
                1: begin scl_reg <= 1; sub_step <= 2; end
                2: begin
                     if (bit_idx < 8) begin if (is_read) rx_byte[7 - bit_idx] <= sda; end
                     else if (!is_read && sda && nack_paso == 0) nack_paso <= paso;
                     sub_step <= 3; end
                3: begin scl_reg <= 0; sub_step <= 0;
                     if (bit_idx < 8) bit_idx <= bit_idx + 1;
                     else begin bit_idx <= 0; byte_active <= 0; state <= next_state; end
                   end
                endcase
            end
        end else begin
            case (state)
            ST_BOOT, ST_EEPROM_WAIT, ST_LOOP: begin
                sda_out <= 1; scl_reg <= 1;
                if (timer < (state == ST_LOOP ? WAIT_LOOP : WAIT_TWR) - 1) timer <= timer + 1;
                else begin
                    timer <= 0; sub_step <= 0;
                    if (state == ST_BOOT) state <= ST_WR_START;
                    else begin nack_paso <= 0; state <= ST_RD_START1; end
                end
            end
            // START: SDA cae con SCL en alto
            ST_WR_START, ST_RD_START1: begin
                if (timer < I2C_HALF_BIT - 1) timer <= timer + 1;
                else begin timer <= 0;
                    case (sub_step)
                    0: begin sda_out <= 1; scl_reg <= 1; sub_step <= 1; end
                    1: begin sda_out <= 0; sub_step <= 2; end
                    default: begin scl_reg <= 0; sub_step <= 0;
                             state <= (state == ST_WR_START) ? ST_WR_CTRL : ST_RD_CTRL_W; end
                    endcase
                end
            end
            ST_WR_CTRL:   send_byte(CTRL_WRITE, 0, 1, ST_WR_ADDR);
            ST_WR_ADDR:   send_byte(MEM_ADDR,   0, 2, ST_WR_DATA);
            ST_WR_DATA:   send_byte(TEST_BYTE,  0, 3, ST_WR_STOP);
            ST_RD_CTRL_W: send_byte(CTRL_WRITE, 0, 4, ST_RD_ADDR);
            ST_RD_ADDR:   send_byte(MEM_ADDR,   0, 5, ST_RD_RESTART);
            ST_RD_CTRL_R: send_byte(CTRL_READ,  0, 6, ST_RD_READ);
            ST_RD_READ:   send_byte(8'hFF,      1, 7, ST_RD_STOP);
            // STOP: SDA sube con SCL en alto
            ST_WR_STOP, ST_RD_STOP: begin
                if (timer < I2C_HALF_BIT - 1) timer <= timer + 1;
                else begin timer <= 0;
                    case (sub_step)
                    0: begin sda_out <= 0; scl_reg <= 0; sub_step <= 1; end
                    1: begin scl_reg <= 1; sub_step <= 2; end
                    default: begin sda_out <= 1; sub_step <= 0;
                             state <= (state == ST_WR_STOP) ? ST_EEPROM_WAIT : ST_UART_PREP; end
                    endcase
                end
            end
            // Repeated START
            ST_RD_RESTART: begin
                if (timer < I2C_HALF_BIT - 1) timer <= timer + 1;
                else begin timer <= 0;
                    case (sub_step)
                    0: begin sda_out <= 1; scl_reg <= 0; sub_step <= 1; end
                    1: begin scl_reg <= 1; sub_step <= 2; end
                    2: begin sda_out <= 0; sub_step <= 3; end
                    default: begin scl_reg <= 0; sub_step <= 0; state <= ST_RD_CTRL_R; end
                    endcase
                end
            end
            ST_UART_PREP: begin
                msg[0] <= 8'h0D; msg[1] <= 8'h0A;
                if (nack_paso != 0) begin   // "NACK paso N"
                    msg[2] <= "N"; msg[3] <= "A"; msg[4] <= "C"; msg[5] <= "K"; msg[6] <= " ";
                    msg[7] <= "p"; msg[8] <= "a"; msg[9] <= "s"; msg[10] <= "o"; msg[11] <= " ";
                    msg[12] <= "0" + nack_paso; msg_len <= 13;
                end else begin              // "RD: 0xHH"
                    msg[2] <= "R"; msg[3] <= "D"; msg[4] <= ":"; msg[5] <= " ";
                    msg[6] <= "0"; msg[7] <= "x";
                    msg[8] <= hex(rx_byte[7:4]); msg[9] <= hex(rx_byte[3:0]); msg_len <= 10;
                end
                msg_idx <= 0; uart_bit <= 0; uart_timer <= 0;
                uart_frame <= {1'b1, 8'h0D, 1'b0};
                state <= ST_UART_SEND;
            end
            ST_UART_SEND: begin
                txd_reg <= uart_frame[uart_bit];
                if (uart_timer < UART_BIT_CNT - 1) uart_timer <= uart_timer + 1;
                else begin
                    uart_timer <= 0;
                    if (uart_bit < 9) uart_bit <= uart_bit + 1;
                    else begin
                        uart_bit <= 0;
                        if (msg_idx + 1 < msg_len) begin
                            msg_idx <= msg_idx + 1;
                            uart_frame <= {1'b1, msg[msg_idx + 1], 1'b0};
                        end else begin txd_reg <= 1; timer <= 0; state <= ST_LOOP; end
                    end
                end
            end
            default: state <= ST_BOOT;
            endcase
        end
    end
endmodule
