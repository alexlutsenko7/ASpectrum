#!/bin/bash
# End-to-end snapshot test with the real firmware: 128K boots (F2 at 30 ms, in the ROM RAM test), name SN1,
# ENTER (saved through the SD card model), then F12 + ENTER loads SN1.Z80 back.
# Afterwards: FAT check of the card image and the saved file checked by z80ref.py.
cd "$(dirname "$0")"
W=work_sn
rm -rf $W && mkdir -p $W/tree/GAMES
python3 -I ../fw/tools/mkimg.py $W/card.img $W/tree --fat 16 --spc 1 --mb 32 > /dev/null
./run_sim.sh +define+SNAPTEST=\"$W/card.img\" +define+SN_MS=${SN_MS:-30} +define+RUN_MS=${RUN_MS:-32} "$@"
python3 -I ../fw/tools/fatcheck.py $W/card.img --get /SN1.Z80 $W/sn1.z80 &&
python3 -I ../fw/test/z80ref.py checksave $W/sn1.z80 sn_exp.dump && echo "SAVED SNAPSHOT OK"
