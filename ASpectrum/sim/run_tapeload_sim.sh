#!/bin/bash
# End-to-end: 128K boots, "Tape Loader" from the menu, F12 + ENTER in the SD browser,
# the ROM loads load.tzx (10 BORDER 4) through the SD tape loader in turbo. ~70 min.
cd "$(dirname "$0")"
mkdir -p work_tl/tree
python3 -I mk_load_tzx.py work_tl/tree/load.tzx
python3 -I ../fw/tools/mkimg.py work_tl/card.img work_tl/tree --fat 16 --spc 1 > /dev/null
./run_sim.sh +define+TAPELOAD=\"work_tl/card.img\" +define+TL_MS=${TL_MS:-190} +define+RUN_MS=${RUN_MS:-700} "$@"
