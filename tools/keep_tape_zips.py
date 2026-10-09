#!/usr/bin/env python3
"""keep_tape_zips.py -- in a folder tree, keep only *.tap.zip and *.tzx.zip files and delete everything else.

  python3 keep_tape_zips.py FOLDER              dry run: lists what would be deleted, changes nothing
  python3 keep_tape_zips.py FOLDER --delete     really deletes (asks for "yes" first)
  python3 keep_tape_zips.py FOLDER --delete --empty-dirs
                                                also removes folders left empty

Names are matched without regard to case (Game.TAP.ZIP is kept). All subfolders are processed.
Works on Windows (python keep_tape_zips.py D:\\Games) and in WSL / Linux."""
import argparse
import os
import sys

KEEP = (".tap.zip", ".tzx.zip")


def main():
    ap = argparse.ArgumentParser(description="Keep only *.tap.zip and *.tzx.zip files in a folder tree.")
    ap.add_argument("folder")
    ap.add_argument("--delete", action="store_true", help="really delete (default: dry run)")
    ap.add_argument("--empty-dirs", action="store_true", help="also remove folders that end up empty")
    ap.add_argument("--list", action="store_true", help="list every file that would be / is deleted")
    a = ap.parse_args()

    root = os.path.abspath(a.folder)
    if not os.path.isdir(root):
        sys.exit("not a folder: " + root)

    keep, drop, drop_bytes, by_ext = 0, [], 0, {}
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            if f.lower().endswith(KEEP):
                keep += 1
            else:
                drop.append(p)
                drop_bytes += os.path.getsize(p)
                ext = f.lower().split(".", 1)[1] if "." in f else "(no extension)"
                by_ext[ext] = by_ext.get(ext, 0) + 1

    print("folder:  %s" % root)
    print("keep:    %d files (*.tap.zip, *.tzx.zip)" % keep)
    print("delete:  %d files, %.1f MB" % (len(drop), drop_bytes / 1e6))
    for ext, n in sorted(by_ext.items(), key=lambda x: -x[1])[:25]:
        print("         %6d  .%s" % (n, ext))
    if a.list or not a.delete:
        for p in drop[:200 if not a.list else None]:
            print("  - " + os.path.relpath(p, root))
        if not a.list and len(drop) > 200:
            print("  ... (%d more; --list shows all)" % (len(drop) - 200))

    if not a.delete:
        print("\nDry run: nothing deleted. Add --delete to delete these files.")
        return
    if not drop and not a.empty_dirs:
        return
    if input("\nDelete %d files under %s? Type yes: " % (len(drop), root)).strip().lower() != "yes":
        print("Cancelled, nothing deleted.")
        return

    failed = 0
    for p in drop:
        try:
            os.remove(p)
        except OSError as e:
            failed += 1
            print("  could not delete %s: %s" % (p, e))
    print("deleted %d files%s" % (len(drop) - failed, ", %d failed" % failed if failed else ""))

    if a.empty_dirs:
        removed = 0
        for d, dirs, files in os.walk(root, topdown=False):
            if d != root and not os.listdir(d):
                try:
                    os.rmdir(d)
                    removed += 1
                except OSError:
                    pass
        print("removed %d empty folders" % removed)


if __name__ == "__main__":
    main()
