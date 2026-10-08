#!/bin/bash
# PC test of fat.c + tape.c (w64devkit gcc for Windows, called from WSL):
# builds test card images (FAT32 with MBR, FAT16 without, FAT32 with 4 KB clusters),
# lists + plays every TAP/TZX in them and compares each signal with tools/tzxref.py.
set -e
cd "$(dirname "$0")"
GCC=${W64GCC:-/mnt/c/Tools/w64devkit/w64devkit/bin/gcc.exe}
W=work
rm -rf $W && mkdir -p $W/tree
python3 -I ../tools/mktest.py $W/tree
$GCC -O2 -Wall -Wextra -o $W/host_test.exe host_test.c ../fat.c ../tape.c ../util.c
fail=0
for cfg in "32 --mbr --spc 1" "16 --spc 4" "32 --spc 8"; do
    set -- $cfg
    tag="fat$1${2:+_}${2#--}"
    img=$W/$tag.img
    python3 -I ../tools/mkimg.py $img $W/tree --fat $cfg
    mkdir -p $W/out_$tag
    if ! (cd $W && ./host_test.exe $tag.img out_$tag > $tag.log); then
        echo "  host_test reported errors:"; grep ERROR $W/$tag.log; fail=1
    fi
    tail -1 $W/$tag.log
    python3 -I compare.py $W/tree $W/$tag.log $W/out_$tag || fail=1
done
# start in the middle (pause/continue, rewind): normal block, inside a loop, a return without a call
for sb in 3 13 20; do
    mkdir -p $W/out_from$sb
    (cd $W && ./host_test.exe fat32_mbr.img out_from$sb $sb > from$sb.log) || { grep ERROR $W/from$sb.log; fail=1; }
    echo "start at block $sb:"
    python3 -I compare.py $W/tree $W/from$sb.log $W/out_from$sb $sb || fail=1
done
# saving: decoder + FAT writing, on fresh copies of the images; checked by tools/fatcheck.py
$GCC -O2 -Wall -Wextra -DHOST_TEST -o $W/save_test.exe save_test.c ../fat.c ../save.c ../util.c
python3 -I mksave.py $W
for tag in fat32_mbr fat16_spc fat32_spc; do
    cp $W/$tag.img $W/s_$tag.img
    echo "saving on $tag:"
    (cd $W && ./save_test.exe s_$tag.img save save1.tap / HELLO > s1.log && cat s1.log | sed 's/^/  /' &&
              ./save_test.exe s_$tag.img save save2.tap GAMES TWOPARTS noise > s2.log && grep -E "^status|ERROR" s2.log | sed 's/^/  /' &&
              ./save_test.exe s_$tag.img save save3.tap / NOHDR > s3.log && grep -E "^status|ERROR" s3.log | sed 's/^/  /' &&
              ./save_test.exe s_$tag.img save save1.tap / NOTHING empty > s4.log && grep -E "^status|ERROR" s4.log | sed 's/^/  /' &&
              ./save_test.exe s_$tag.img many GAMES 60 | sed 's/^/  /') || { echo "  save_test FAILED"; fail=1; }
    python3 -I ../tools/fatcheck.py $W/s_$tag.img /HELLO.TAP $W/save1.tap /GAMES/TWOPARTS.TAP $W/save2.tap \
        /NOHDR.TAP $W/save3.tap || fail=1
done
[ $fail = 0 ] && echo "HOST TEST PASSED" || { echo "HOST TEST FAILED"; exit 1; }
