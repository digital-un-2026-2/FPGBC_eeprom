module top_eeprom_test #(
    parameter CLK_FREQ  = 27_000_000, // 27 MHz reloj principal de la FPGBC
    parameter BAUD_RATE = 57600
)(
    input  wire clk,
    input  wire resetn,
    output wire TXD,
    inout  wire sda,
    output wire scl
);

    // =========================================================================
    // 1. TEMPORIZACIONES (Reloj a 27 MHz -> T = 37.037 ns)
    // =========================================================================
    localparam DELAY_10MS   = CLK_FREQ / 100;       // 270,000 ciclos = 10 ms (arranque UART + t_WR)
    localparam I2C_HALF_BIT = CLK_FREQ / 200_000;   // 135 ciclos = 5 us (100 kHz I2C)
    localparam UART_BIT_CNT = CLK_FREQ / BAUD_RATE; // 468 ciclos por bit a 57600 baudios

    // =========================================================================
    // 2. CONTROL DE BUS I2C OPEN-DRAIN
    // =========================================================================
    reg sda_out = 1'b1; // 1 = Alta impedancia (Z), 0 = Conduce a GND
    reg scl_reg = 1'b1;

    assign sda = sda_out ? 1'bz : 1'b0;
    assign scl = scl_reg;

    // =========================================================================
    // 3. DATOS DE PRUEBA PARA LA ST24C04
    // =========================================================================
    localparam CTRL_WRITE = 8'hA0; // Dirección dispositivo (1010_000) + Write (0)
    localparam CTRL_READ  = 8'hA1; // Dirección dispositivo (1010_000) + Read  (1)
    localparam MEM_ADDR   = 8'h00; // Posición de memoria 0x00 dentro del bloque 0
    localparam TEST_BYTE  = 8'h47; // Carácter ASCII 'G' (0x47) para escribir y verificar

    // =========================================================================
    // 4. ESTADOS DE LA FSM PRINCIPAL
    // =========================================================================
    localparam ST_BOOT_DELAY   = 5'd0;  // Espera 10 ms al arrancar para estabilizar UART
    // --- Fase 1: Escritura (Byte Write) ---
    localparam ST_WR_START     = 5'd1;
    localparam ST_WR_CTRL      = 5'd2;
    localparam ST_WR_ADDR      = 5'd3;
    localparam ST_WR_DATA      = 5'd4;
    localparam ST_WR_STOP      = 5'd5;
    // --- Fase 2: Ciclo interno de grabación de la EEPROM (t_WR <= 5 ms) ---
    localparam ST_EEPROM_WAIT  = 5'd6;
    // --- Fase 3: Lectura Aleatoria (Random Read) ---
    localparam ST_RD_START1    = 5'd7;
    localparam ST_RD_CTRL_W    = 5'd8;  // Dummy write para fijar el puntero de dirección
    localparam ST_RD_ADDR      = 5'd9;
    localparam ST_RD_RESTART   = 5'd10; // Repeated START sin soltar el bus
    localparam ST_RD_CTRL_R    = 5'd11;
    localparam ST_RD_READ_BYTE = 5'd12; // Captura los 8 bits que envía la EEPROM
    localparam ST_RD_STOP      = 5'd13;
    // --- Fase 4: Reporte por UART ---
    localparam ST_UART_PREP    = 5'd14;
    localparam ST_UART_SEND    = 5'd15;
    localparam ST_DONE         = 5'd16;

    reg [4:0]  state      = ST_BOOT_DELAY;
    reg [4:0]  next_state = ST_BOOT_DELAY;
    reg [31:0] timer      = 0;
    reg [2:0]  sub_step   = 0;

    // Registros para envío/recepción de 1 byte por I2C
    reg [7:0]  i2c_tx_byte = 8'h00;
    reg [7:0]  i2c_rx_byte = 8'h00;
    reg [3:0]  bit_idx     = 0;
    reg        ack_error   = 1'b0;

    // Sub-rutina embebida para transmitir/recibir un byte completo + bit ACK/NACK
    reg        byte_active = 1'b0;
    reg        is_read_op  = 1'b0;
    reg        send_nack   = 1'b0;

    // Registros del transmisor UART
    reg        txd_reg     = 1'b1;
    assign tTXD = txd_reg;

    reg [7:0]  msg_buf [0:15];
    reg [3:0]  msg_len     = 0;
    reg [3:0]  msg_idx     = 0;
    reg [3:0]  uart_bit    = 0;
    reg [15:0] uart_timer  = 0;
    reg [9:0]  uart_frame  = 10'h3FF;

    // =========================================================================
    // 5. MÁQUINA DE ESTADOS SÍNCRONA
    // =========================================================================
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state       <= ST_BOOT_DELAY;
            timer       <= 0;
            sub_step    <= 0;
            sda_out     <= 1'b1;
            scl_reg     <= 1'b1;
            ack_error   <= 1'b0;
            byte_active <= 1'b0;
            txd_reg     <= 1'b1;
        end else begin
            // -----------------------------------------------------------------
            // SUB-MÁQUINA DE 8 BITS + ACK/NACK (Ejecuta cuando byte_active = 1)
            // -----------------------------------------------------------------
            if (byte_active) begin
                if (timer < I2C_HALF_BIT - 1) begin
                    timer <= timer + 1;
                end else begin
                    timer <= 0;
                    case (sub_step)
                        // Fase 0: SCL en bajo -> preparar dato en SDA (o soltar SDA si es lectura)
                        3'd0: begin
                            scl_reg <= 1'b0;
                            if (bit_idx < 8) begin
                                sda_out <= is_read_op ? 1'b1 : i2c_tx_byte[7 - bit_idx];
                            end else begin
                                // 9no ciclo: si leemos, maestro envía NACK (1); si escribimos, maestro suelta SDA (1)
                                sda_out <= is_read_op ? send_nack : 1'b1;
                            end
                            sub_step <= 3'd1;
                        end
                        // Fase 1: Subir SCL (flanco de subida válido para muestreo)
                        3'd1: begin
                            scl_reg  <= 1'b1;
                            sub_step <= 3'd2;
                        end
                        // Fase 2: Mitad de SCL en alto -> muestrear SDA
                        3'd2: begin
                            if (bit_idx < 8) begin
                                if (is_read_op)
                                    i2c_rx_byte[7 - bit_idx] <= sda;
                            end else begin
                                // En escritura verificamos que la EEPROM bajó SDA (ACK = 0)
                                if (!is_read_op && (sda == 1'b1))
                                    ack_error <= 1'b1;
                            end
                            sub_step <= 3'd3;
                        end
                        // Fase 3: Bajar SCL y avanzar al siguiente bit
                        3'd3: begin
                            scl_reg  <= 1'b0;
                            sub_step <= 3'd0;
                            if (bit_idx < 8) begin
                                bit_idx <= bit_idx + 1;
                            end else begin
                                bit_idx     <= 0;
                                byte_active <= 1'b0;
                                state       <= next_state;
                            end
                        end
                    endcase
                end
            end else begin
                // -------------------------------------------------------------
                // FSM DE ALTO NIVEL (START, STOP, ESPERAS Y UART)
                // -------------------------------------------------------------
                case (state)
                    // 0. RETARDO INICIAL DE 10 MS PARA ESTABILIZAR EL PUERTO SERIAL
                    ST_BOOT_DELAY: begin
                        sda_out <= 1'b1;
                        scl_reg <= 1'b1;
                        if (timer < DELAY_10MS - 1) begin
                            timer <= timer + 1;
                        end else begin
                            timer    <= 0;
                            sub_step <= 0;
                            state    <= ST_WR_START;
                        end
                    end

                    // 1. CONDICIÓN START PARA ESCRITURA (SDA cae con SCL en alto)
                    ST_WR_START: begin
                        if (timer < I2C_HALF_BIT - 1) begin
                            timer <= timer + 1;
                        end else begin
                            timer <= 0;
                            case (sub_step)
                                3'd0: begin sda_out <= 1'b1; scl_reg <= 1'b1; sub_step <= 3'd1; end
                                3'd1: begin sda_out <= 1'b0; sub_step <= 3'd2; end
                                3'd2: begin scl_reg <= 1'b0; sub_step <= 3'd0; state <= ST_WR_CTRL; end
                            endcase
                        end
                    end

                    // 2. ENVIAR BYTE DE CONTROL ESCRITURA (0xA0)
                    ST_WR_CTRL: begin
                        i2c_tx_byte <= CTRL_WRITE;
                        is_read_op  <= 1'b0;
                        bit_idx     <= 0;
                        sub_step    <= 0;
                        next_state  <= ST_WR_ADDR;
                        byte_active <= 1'b1;
                    end

                    // 3. ENVIAR DIRECCIÓN DE MEMORIA (0x00)
                    ST_WR_ADDR: begin
                        i2c_tx_byte <= MEM_ADDR;
                        is_read_op  <= 1'b0;
                        bit_idx     <= 0;
                        sub_step    <= 0;
                        next_state  <= ST_WR_DATA;
                        byte_active <= 1'b1;
                    end

                    // 4. ENVIAR DATO A GRABAR ('G' = 0x47)
                    ST_WR_DATA: begin
                        i2c_tx_byte <= TEST_BYTE;
                        is_read_op  <= 1'b0;
                        bit_idx     <= 0;
                        sub_step    <= 0;
                        next_state  <= ST_WR_STOP;
                        byte_active <= 1'b1;
                    end

                    // 5. CONDICIÓN STOP (SDA sube con SCL en alto)
                    ST_WR_STOP: begin
                        if (timer < I2C_HALF_BIT - 1) begin
                            timer <= timer + 1;
                        end else begin
                            timer <= 0;
                            case (sub_step)
                                3'd0: begin sda_out <= 1'b0; scl_reg <= 1'b0; sub_step <= 3'd1; end
                                3'd1: begin scl_reg <= 1'b1; sub_step <= 3'd2; end
                                3'd2: begin sda_out <= 1'b1; sub_step <= 3'd0; state <= ST_EEPROM_WAIT; end
                            endcase
                        end
                    end

                    // 6. ESPERA DE GRABACIÓN INTERNA DE LA ST24C04 (t_WR max = 5 ms -> damos 10 ms)
                    ST_EEPROM_WAIT: begin
                        if (timer < DELAY_10MS - 1) begin
                            timer <= timer + 1;
                        end else begin
                            timer    <= 0;
                            sub_step <= 0;
                            state    <= ST_RD_START1;
                        end
                    end

                    // 7. START PARA DUMMY WRITE (Fijar puntero en 0x00)
                    ST_RD_START1: begin
                        if (timer < I2C_HALF_BIT - 1) begin
                            timer <= timer + 1;
                        end else begin
                            timer <= 0;
                            case (sub_step)
                                3'd0: begin sda_out <= 1'b1; scl_reg <= 1'b1; sub_step <= 3'd1; end
                                3'd1: begin sda_out <= 1'b0; sub_step <= 3'd2; end
                                3'd2: begin scl_reg <= 1'b0; sub_step <= 3'd0; state <= ST_RD_CTRL_W; end
                            endcase
                        end
                    end

                    // 8. CONTROL WRITE (0xA0)
                    ST_RD_CTRL_W: begin
                        i2c_tx_byte <= CTRL_WRITE;
                        is_read_op  <= 1'b0;
                        bit_idx     <= 0;
                        sub_step    <= 0;
                        next_state  <= ST_RD_ADDR;
                        byte_active <= 1'b1;
                    end

                    // 9. DIRECCIÓN A LEER (0x00)
                    ST_RD_ADDR: begin
                        i2c_tx_byte <= MEM_ADDR;
                        is_read_op  <= 1'b0;
                        bit_idx     <= 0;
                        sub_step    <= 0;
                        next_state  <= ST_RD_RESTART;
                        byte_active <= 1'b1;
                    end

                    // 10. REPEATED START (Sin STOP previo)
                    ST_RD_RESTART: begin
                        if (timer < I2C_HALF_BIT - 1) begin
                            timer <= timer + 1;
                        end else begin
                            timer <= 0;
                            case (sub_step)
                                3'd0: begin sda_out <= 1'b1; scl_reg <= 1'b0; sub_step <= 3'd1; end
                                3'd1: begin scl_reg <= 1'b1; sub_step <= 3'd2; end
                                3'd2: begin sda_out <= 1'b0; sub_step <= 3'd3; end
                                3'd3: begin scl_reg <= 1'b0; sub_step <= 3'd0; state <= ST_RD_CTRL_R; end
                            endcase
                        end
                    end

                    // 11. CONTROL READ (0xA1)
                    ST_RD_CTRL_R: begin
                        i2c_tx_byte <= CTRL_READ;
                        is_read_op  <= 1'b0;
                        bit_idx     <= 0;
                        sub_step    <= 0;
                        next_state  <= ST_RD_READ_BYTE;
                        byte_active <= 1'b1;
                    end

                    // 12. LEER EL BYTE DESDE LA EEPROM Y RESPONDER NACK (1)
                    ST_RD_READ_BYTE: begin
                        is_read_op  <= 1'b1;
                        send_nack   <= 1'b1; // NACK indica a la EEPROM que termina la lectura
                        bit_idx     <= 0;
                        sub_step    <= 0;
                        next_state  <= ST_RD_STOP;
                        byte_active <= 1'b1;
                    end

                    // 13. STOP FINAL DE LECTURA
                    ST_RD_STOP: begin
                        if (timer < I2C_HALF_BIT - 1) begin
                            timer <= timer + 1;
                        end else begin
                            timer <= 0;
                            case (sub_step)
                                3'd0: begin sda_out <= 1'b0; scl_reg <= 1'b0; sub_step <= 3'd1; end
                                3'd1: begin scl_reg <= 1'b1; sub_step <= 3'd2; end
                                3'd2: begin sda_out <= 1'b1; sub_step <= 3'd0; state <= ST_UART_PREP; end
                            endcase
                        end
                    end

                    // 14. PREPARAR MENSAJE DE DIAGNÓSTICO POR UART
                    ST_UART_PREP: begin
                        msg_buf[0] <= "\r";
                        msg_buf[1] <= "\n";
                        if (ack_error) begin
                            // "NO ACK\r\n"
                            msg_buf[2] <= "N"; msg_buf[3] <= "O"; msg_buf[4] <= " ";
                            msg_buf[5] <= "A"; msg_buf[6] <= "C"; msg_buf[7] <= "K";
                            msg_buf[8] <= "\r"; msg_buf[9] <= "\n";
                            msg_len    <= 4'd10;
                        end else begin
                            // "RD: X\r\n" donde X es el carácter leído (debería ser 'G')
                            msg_buf[2] <= "R"; msg_buf[3] <= "D"; msg_buf[4] <= ":";
                            msg_buf[5] <= " "; msg_buf[6] <= i2c_rx_byte;
                            msg_buf[7] <= "\r"; msg_buf[8] <= "\n";
                            msg_len    <= 4'd9;
                        end
                        msg_idx    <= 0;
                        uart_bit   <= 0;
                        uart_timer <= 0;
                        uart_frame <= {1'b1, 8'h0D, 1'b0}; // Stop(1) + Data('\r') + Start(0)
                        state      <= ST_UART_SEND;
                    end

                    // 15. TRANSMITIR CADENA POR UART (57600 8N1)
                    ST_UART_SEND: begin
                        txd_reg <= uart_frame[uart_bit];
                        if (uart_timer < UART_BIT_CNT - 1) begin
                            uart_timer <= uart_timer + 1;
                        end else begin
                            uart_timer <= 0;
                            if (uart_bit < 9) begin
                                uart_bit <= uart_bit + 1;
                            end else begin
                                uart_bit <= 0;
                                if (msg_idx + 1 < msg_len) begin
                                    msg_idx    <= msg_idx + 1;
                                    uart_frame <= {1'b1, msg_buf[msg_idx + 1], 1'b0};
                                end else begin
                                    txd_reg <= 1'b1;
                                    state   <= ST_DONE;
                                end
                            end
                        end
                    end

                    // 16. FIN DE PRUEBA
                    ST_DONE: begin
                        txd_reg <= 1'b1;
                        sda_out <= 1'b1;
                        scl_reg <= 1'b1;
                    end

                    default: state <= ST_BOOT_DELAY;
                endcase
            end
        end
    end

endmodule