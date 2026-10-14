#!/bin/bash
# esp_link (SPI link from the ESP32) inside tape_loader (Questa, Windows install, from WSL).
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
rm -rf work_esp
$Q/vlib.exe work_esp >/dev/null
$Q/vlog.exe -quiet -work work_esp ../rtl/esp_link.v ../rtl/tape_loader.v || exit 1
$Q/vlog.exe -quiet -work work_esp -sv tb_esp_link.sv || exit 1
$Q/vsim.exe -c -quiet -lib work_esp -t ps tb_esp_link -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)|Time: 0 ps'
