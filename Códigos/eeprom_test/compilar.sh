#!/bin/bash
# Uso (dentro de "pixi shell"):  ./compilar.sh
set -e
yosys -q -p "read_verilog eeprom_test.v; synth_gowin -top eeprom_test -json e.json"
yowasp-nextpnr-himbaechel-gowin --json e.json --write e_pnr.json \
  --device GW2AR-LV18EQ144PC8/I7 --vopt family=GW2A-18C --vopt cst=eeprom_test.cst --freq 40
gowin_pack -d GW2A-18C -o eeprom_test.fs e_pnr.json
openFPGALoader -c ft232 --write-sram eeprom_test.fs
