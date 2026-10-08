#!/bin/bash
# Build the loader CPU firmware -> build/fw0..3.hex (byte lanes of the RAM image,
# loaded by rtl/tape_loader.v at FPGA configuration).
# Toolchain: xPack riscv-none-elf-gcc for Windows (C:\Tools\xpack-riscv-none-elf-gcc),
# called from WSL. GCC_EXEC_PREFIX is needed because, started from WSL, gcc.exe
# cannot find its own install directory.
set -e
cd "$(dirname "$0")"
RAM_WORDS=${RAM_WORDS:-8192}                 # 32 KB, must match RAM_WORDS in tape_loader.v
XP=${XPACK:-/mnt/c/Tools/xpack-riscv-none-elf-gcc}
export GCC_EXEC_PREFIX='C:/Tools/xpack-riscv-none-elf-gcc/lib/gcc/'
export WSLENV=GCC_EXEC_PREFIX
CC=$XP/bin/riscv-none-elf-gcc.exe
OBJCOPY=$XP/bin/riscv-none-elf-objcopy.exe
SIZE=$XP/bin/riscv-none-elf-size.exe

mkdir -p build
$CC -march=rv32imc -mabi=ilp32 -Os -g -Wall -Wextra -ffreestanding -nostdlib \
    -fno-tree-loop-distribute-patterns -ffunction-sections -fdata-sections \
    -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Wl,--defsym=RAM_SIZE=$((RAM_WORDS * 4)) -T link.ld \
    -Wl,-Map=build/fw.map -o build/fw.elf \
    start.S main.c sd.c fat.c tape.c save.c osd.c util.c rv_libc.c -lgcc
$OBJCOPY -O binary build/fw.elf build/fw.bin
$SIZE build/fw.elf
python3 -I tools/bin2lanes.py build/fw.bin $RAM_WORDS build/fw
echo "firmware: $(stat -c %s build/fw.bin) bytes of code + constants, RAM $((RAM_WORDS * 4)) bytes"
