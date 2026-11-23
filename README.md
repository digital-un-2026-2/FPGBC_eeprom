# EEPROM 

## 2. Documentos de referencia
 
| Documento | Descripción | Enlace |
|---|---|---|
| Datasheet ST24C04 | Pinout, memoria, protocolo I²C, temporización y protección de escritura | [PDF](Docs/ST24C04.pdf) |
| Gowin FPGA Products Programming and Configuration Guide | Programación y configuración (SRAM/Flash, bitstream, JTAG) | [PDF](Docs/GowinFPGAProducts.pdf) |
| GW2AR Package & Pinout User Guide | Pinout EQ144, bancos de I/O, alimentación | [PDF](Docs/PinoutUserGuide.pdf) |
 
---
 
## 3. Conexiones físicas
 
### 3.1 Pines de la FPGA (`GW2AR-LV18EQ144`)
 
| Pin FPGA | Nombre | Función | I/O | Conectado a |
|:---:|---|---|---|---|
| 17 | GND | Tierra | — | EEPROM pines 1, 2, 3 y 4 |
| 23 | IOL32A | I/O bidireccional (open-drain) | `LVCMOS33` | EEPROM pin 5 (`SDA`) |
| 24 | IOL32B | Salida de reloj maestro | `LVCMOS33` | EEPROM pin 6 (`SCL`) |
| 31 | VCCIO4 | Alimentación banco 4 (3.3 V) | — | EEPROM pin 8 (`VCC`) y pull-ups |
| 28 | IOR36A | UART TX (diagnóstico) | `LVCMOS33` | FT232RL `RXD`, 57600 baudios |
 
 
### 3.2 Pines del ST24C04
 
| Pin | Nombre | Conexión | Función |
|:---:|---|---|---|
| 1 | `PRE` | GND | Sin protección de escritura por hardware |
| 2 | `E1` | GND | Bit del código de dispositivo = 0 |
| 3 | `E2` | GND | Bit del código de dispositivo = 0 |
| 4 | `VSS` | GND | Tierra |
| 5 | `SDA` | FPGA pin 23 | Datos I²C (open-drain + pull-up) |
| 6 | `SCL` | FPGA pin 24 | Reloj I²C (+ pull-up) |
| 7 | `MODE` | Sin conexión (internamente se lee como `VIH`) | `VIH` = Multibyte Write (4 B), `VIL` = Page Write (8 B). El `WC` solo existe en las versiones W04 |
| 8 | `VCC` | 3.3 V | Alimentación (3–5.5 V en ST24C04; 2.5–5.5 V en ST25C04) |
 
 
![Esquemático EEPROM - FPGA](Imagenes/EsquematicoEEPROM.png)
 
*Figura 1. Conexiones del ST24C04 hacia la FPGA GW2AR-18.*
 
---
 
## 4. Fundamentos del ST24C04
 
### 4.1 Memoria y direccionamiento
 
- 4 Kbit = **512 bytes**, divididos en dos bloques de 256 bytes (la dirección de 8 bits no alcanza para 512).
- El bloque se elige con el bit `A8` dentro del byte de control (*Device Select*): `1010 E2 E1 A8 R/W`.
| Bloque | Rango | Escritura | Lectura |
|:---:|---|:---:|:---:|
| 0 | `0x000–0x0FF` | `0xA0` | `0xA1` |
| 1 | `0x100–0x1FF` | `0xA2` | `0xA3` |
 
### 4.2 Protección de escritura
 
- El pin 7 es **siempre `MODE`** en el ST24C04 (versión C). `WC` solo existe en ST24W04/ST25W04.
- La protección de escritura es por *software + PRE*: solo protege parte del bloque 1 (`0x100–0x1FF`), entre una frontera definida en la dirección `0x1FF` (*Block Address Pointer*, bit b2 = 0) y el final de la memoria, y solo cuando `PRE = 1`.
- Con `PRE = 0` (nuestro caso) no hay protección. **Evita escribir en `0x1FF`** salvo que sepas lo que haces: es el registro de protección.
- Los chips nuevos vienen con todo en `0xFF`: si lees `0xFF`, la escritura no ocurrió.
### 4.3 Temporizaciones (VCC = 3.3 V, reloj FPGA 27 MHz)
 
| Parámetro | Símbolo | Mín. | Máx. | Implementado |
|---|---|---|---|---|
| Frecuencia SCL | $f_{SCL}$ | — | 100 kHz (este chip no soporta 400 kHz) | 100 kHz (semiperiodo 5 µs = 135 ciclos) |
| Mantenimiento de START | $t_{HD:STA}$ | 4.0 µs | — | 5.0 µs |
| Establecimiento de STOP | $t_{SU:STO}$ | 4.7 µs | — | 5.0 µs |
| Bus libre STOP→START | $t_{BUF}$ | 4.7 µs | — | ≥ 5.0 µs |
| **Ciclo de escritura interna** | $t_{WR}$ | — | **10 ms** | 10 ms (**sin margen**; usar ≥ 15 ms o ACK polling) |
 
> **Importante ($t_{WR}$):** tras el `STOP` de una escritura, la EEPROM queda ocupada hasta 10 ms y **no responde ACK**. Hay que esperar o hacer *ACK polling* (enviar `0xA0` hasta recibir ACK) antes de la siguiente operación.
 
### 4.4 Tramas I²C
 
**Byte Write**
 
```text
[START] [0xA0] [ACK] [Addr] [ACK] [Data] [ACK] [STOP]  -> esperar t_WR
```
 
**Random Read** (dummy write + repeated START):
 
```text
[START] [0xA0] [ACK] [Addr] [ACK] [Re-START] [0xA1] [ACK] [Data leído] [NACK maestro] [STOP]
```
 
Reglas clave del protocolo:
 
- SDA solo cambia mientras SCL está en **bajo** (excepto START/STOP).
- El receptor **muestrea** SDA con SCL en **alto**.
- El 9.º pulso de cada byte es el ACK: el receptor baja SDA (`0` = ACK, `1` = NACK).
- En lectura, el maestro responde **NACK** al último byte para indicar "no quiero más".
---
 
## 5. Arquitectura del módulo de prueba (`top_eeprom_test.v`)
 
- **SDA open-drain:** nunca se fuerza un `1`; se suelta el bus.
```verilog
assign sda = sda_out ? 1'bz : 1'b0;
```
 
- **FSM:**
  1. `ST_BOOT_DELAY`: 10 ms de espera inicial (270 000 ciclos).
  2. `ST_WR_*`: Byte Write de `0x47` ('G') en `0x00`.
  3. `ST_EEPROM_WAIT`: 10 ms (**= $t_{WR}$ máx., sin margen: subir a 15–20 ms**).
  4. `ST_RD_*`: Random Read de `0x00`, termina con NACK.
  5. `ST_UART_*`: envío del resultado por TX a 57600 8N1.
---
 
## 6. Avances
 
| Etapa | Descripción | Herramientas | Estado |
|---|---|---|---|
| 1. Mapeo de pines | SDA (23), SCL (24), TXD (28) en `test.cst` | Gowin Pinout Guide | Completado |
| 2. Síntesis y P&R | `GW2AR-LV18EQ144PC8/I7` | Yosys + nextpnr-himbaechel + gowin_pack |  0 errores |
| 3. Carga en FPGA | Programación SRAM por JTAG | openFPGALoader | 100 % |
| 4. Detección I²C | `0xA0` + verificación de ACK | Bus I²C + UART (minicom) | `ACK OK` |
| 5. Escritura / lectura | Byte Write → espera → Random Read | FSM I²C + UART | 🔧 En depuración |
| 6. Integración SoC | Periférico mapeado en memoria | Verilog / bus del SoC | Pendiente |
 
---