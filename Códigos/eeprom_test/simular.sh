#!/bin/bash
# Simulación con el modelo de la EEPROM (tarda ~5 s)
iverilog -g2012 -o sim tb.v eeprom_test.v && vvp sim
