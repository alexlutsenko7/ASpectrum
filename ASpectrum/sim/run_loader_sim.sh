#!/bin/bash
# SD tape loader simulation (Questa, Windows install, called from WSL):
# firmware build -> test card image (FAT16, see fw/tools) -> tb_tape_loader.
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
W=work_loader
set -e
../fw/build.sh > /dev/null
rm -rf $W && mkdir -p $W/tree
python3 -I ../fw/tools/mktest.py $W/tree
python3 -I ../fw/tools/mkimg.py $W/card.img $W/tree --fat 16 --spc 1 > /dev/null
python3 -I ../fw/tools/tzxref.py $W/tree/short.tzx > $W/short_ref.txt
python3 -I ../fw/test/mksave.py $W
set +e
rm -rf work_l
$Q/vlib.exe work_l > /dev/null
$Q/vlog.exe -quiet -work work_l ../rtl/picorv32/picorv32.v ../rtl/tape_loader.v || exit 1
$Q/vlog.exe -quiet -work work_l -sv +define+IMAGE=\"$W/card.img\" +define+REF=\"$W/short_ref.txt\" +define+SAVE_TAP=\"$W/save1.tap\" \
    sd_card_model.sv tb_tape_loader.sv || exit 1
$Q/vsim.exe -c -quiet -lib work_l -t ps tb_tape_loader -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)'
echo "card image after the save:"
python3 -I ../fw/tools/fatcheck.py $W/card.img /SAVE0001.TAP $W/save1.tap && echo "SAVED FILE OK"
