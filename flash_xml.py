#!/usr/bin/env python3
"""
XML-driven cross-flash driver.

The previous flash.py used `edl wl` which does exact-basename matching against
GPT partition names. That fails on this firmware because the .ops ships
slot-less filenames (e.g., `boot.img`) but the device's GPT uses slot-suffixed
labels (e.g., `boot_a`, `boot_b`). The canonical mapping is in the firmware's
own settings.xml — every <program> element pairs a target `label` with a
source `filename` and a `physical_partition_number` (LUN).

This driver parses settings.xml and either prints the plan or executes it.

Usage:
    flash_xml.py plan    <extract_dir>           Print partition plan, exit
    flash_xml.py backup  [--out=<dir>]           Read device-unique partitions
    flash_xml.py flash   <extract_dir> [--dry-run] [--yes]
    flash_xml.py reset   [--loader=<path>]

`extract_dir` is the opscrypto extract/ folder produced by `flash.py prep`
(it contains settings.xml plus all the partition images).
"""

import argparse
import shlex
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
VENV_PY = HERE / "venv" / "bin" / "python"
EDL_BIN = HERE / "venv" / "bin" / "edl"

N100_LOADER = HERE / "tools" / "edl" / "Loaders" / "oneplus" / \
              "0000000000515192_37cf317812121fed_fhprg_opn100.bin"

# Device-unique partitions worth backing up before a cross-flash.
# These cannot be recovered from the BE2013 firmware zip because the
# contents are written at the factory or by the OS at runtime.
# Format: (partition_label, lun).
BACKUP_TARGETS = [
    ("persist",   0),  # WLAN/BT MAC, sensor calibration
    ("ssd",       0),  # secure storage descriptor
    ("misc",      0),  # bootloader control block (BCB)
    ("keystore",  0),  # encrypted system keys
    ("frp",       0),  # factory reset protection state
    ("carrier",   0),  # CURRENT T-Mobile carrier config (saved in case we want to restore)
    ("param",     0),  # device parameters
    ("config",    0),  # device config
    ("modemst1",  5),  # modem nonvolatile state (IMEI persistence)
    ("modemst2",  5),  # modem nonvolatile state mirror
    ("fsg",       5),  # factory image (sometimes IMEI backup)
    ("fsc",       5),  # factory check
    ("modem_a",   0),  # NON-HLOS modem firmware, slot A
    ("modem_b",   0),  # NON-HLOS modem firmware, slot B
]


def die(msg, code=1):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def info(msg):
    print(f"[*] {msg}")


def ok(msg):
    print(f"[+] {msg}")


@dataclass
class Entry:
    label: str          # GPT partition name on the device, e.g. "boot_a"
    lun: int            # physical_partition_number
    filename: str       # source image in extract/, e.g. "boot.img"
    size_bytes: int     # SizeInByteInSrc from the XML
    sparse: bool        # whether the image is Android-sparse (super.img is)


# Labels in settings.xml that edl does NOT recognize as partitions.
# `PrimaryGPT` and `BackupGPT` are MSM-tool conceptual names for the partition
# table itself. edl has a special `gpt` partition for writing the table, but
# the BE2012 hardware already has the same GPT layout as BE2013 (identical
# devices), so re-writing the GPT is unnecessary and high-risk. Skip them.
SKIP_LABELS = {"PrimaryGPT", "BackupGPT"}


def parse_settings_xml(settings_xml: Path) -> list[Entry]:
    """
    Walk every <ProgramN> section in settings.xml and yield Entry rows
    for each <program> that has a non-empty filename and label.

    The XML structure:
      <Setting>
        <Program0>
          <program label="persist" physical_partition_number="0" ...>
            <Image filename="persist.img" SizeInByteInSrc="33554432" ... />
          </program>
          ...
        </Program0>
        <Program1>...</Program1>
        ...
      </Setting>
    """
    tree = ET.parse(settings_xml)
    root = tree.getroot()
    entries: list[Entry] = []
    for section in root:
        if not section.tag.startswith("Program"):
            continue
        for program in section:
            label = program.get("label", "").strip()
            try:
                lun = int(program.get("physical_partition_number", "0"))
            except ValueError:
                lun = 0
            for image in program:
                fname = image.get("filename", "").strip()
                if not fname or not label:
                    continue
                if label in SKIP_LABELS:
                    continue
                try:
                    sz = int(image.get("SizeInByteInSrc", "0"))
                except ValueError:
                    sz = 0
                sparse = image.get("sparse", "false").lower() == "true"
                entries.append(Entry(
                    label=label, lun=lun, filename=fname,
                    size_bytes=sz, sparse=sparse,
                ))
    return entries


def find_settings_xml(extract_dir: Path) -> Path:
    candidates = list(extract_dir.rglob("settings.xml"))
    if not candidates:
        die(f"settings.xml not found under {extract_dir}")
    return candidates[0]


def filter_skip(entries: list[Entry]) -> list[Entry]:
    """
    Filter out entries we should NOT flash during a cross-region overlay.
    - userdata.img: would wipe user data; the bootloader regenerates this
      on first boot anyway, so writing the tiny factory userdata.img is fine,
      but we still want explicit visibility.
    - persist.img: contains device-unique IMEI/calibration. If the BE2013
      persist.img happens to be empty/region-neutral it's safe, but to be
      conservative we *skip* it by default. Override with --include-persist.
    - gpt_main*/gpt_backup*: writing the partition table is the biggest
      brick risk in a cross-flash. Skip unless --include-gpt.

    No filtering happens here yet — we return the list as-is and document
    the policy at the call site. This stub exists so the policy is easy
    to add later.
    """
    return entries


def cmd_plan(args):
    extract_dir = Path(args.extract_dir).resolve()
    if not extract_dir.is_dir():
        die(f"not a directory: {extract_dir}")
    settings = find_settings_xml(extract_dir)
    info(f"parsing {settings}")

    entries = parse_settings_xml(settings)
    by_lun: dict[int, list[Entry]] = {}
    for e in entries:
        by_lun.setdefault(e.lun, []).append(e)

    total = 0
    for lun in sorted(by_lun):
        print(f"\n== LUN {lun} ({len(by_lun[lun])} writes) ==")
        for e in by_lun[lun]:
            present = (extract_dir / e.filename).is_file()
            marker = "  " if present else "??"
            sparse = " sparse" if e.sparse else ""
            print(f"  {marker} {e.label:<22} <- {e.filename:<28} ({e.size_bytes:>12,} B{sparse})")
            total += e.size_bytes
    print(f"\nTotal: {len(entries)} writes, {total:,} bytes")

    missing = [e for e in entries if not (extract_dir / e.filename).is_file()]
    if missing:
        print(f"\nWARNING: {len(missing)} entries reference missing files:")
        for e in missing[:10]:
            print(f"  {e.filename} (label={e.label})")
        if len(missing) > 10:
            print(f"  ...")


def cmd_flash(args):
    extract_dir = Path(args.extract_dir).resolve()
    if not extract_dir.is_dir():
        die(f"not a directory: {extract_dir}")
    settings = find_settings_xml(extract_dir)
    info(f"parsing {settings}")

    entries = parse_settings_xml(settings)
    entries = [e for e in entries if (extract_dir / e.filename).is_file()]
    if args.skip_lun:
        skip = {int(s) for s in args.skip_lun.split(",")}
        before = len(entries)
        entries = [e for e in entries if e.lun not in skip]
        info(f"--skip-lun {sorted(skip)}: filtered {before - len(entries)} entries")
    if args.only_lun:
        keep = {int(s) for s in args.only_lun.split(",")}
        before = len(entries)
        entries = [e for e in entries if e.lun in keep]
        info(f"--only-lun {sorted(keep)}: kept {len(entries)} of {before}")
    info(f"plan: {len(entries)} partition writes across LUNs "
         f"{sorted(set(e.lun for e in entries))}")

    loader = Path(args.loader).resolve() if args.loader else N100_LOADER
    if not loader.is_file():
        die(f"loader not found: {loader}")
    info(f"using loader: {loader}")

    if not args.yes and not args.dry_run:
        print()
        print("This will OVERWRITE every listed partition on the connected phone")
        print("with images from the Global BE2013 firmware. Phone must be in EDL.")
        print()
        ans = input("Proceed? type YES: ").strip()
        if ans != "YES":
            die("aborted by user", code=2)

    if args.dry_run:
        info("DRY RUN: --skipwrite will be passed on every write")

    failed: list[tuple[Entry, str]] = []
    for i, ent in enumerate(entries, 1):
        src = str(extract_dir / ent.filename)
        info(f"[{i}/{len(entries)}] LUN {ent.lun}  {ent.label}  <-  {ent.filename}")
        edl_args = ["w", ent.label, src, "--lun", str(ent.lun)]
        if args.dry_run:
            edl_args.append("--skipwrite")
        rc = _edl(*edl_args, loader=loader)
        if rc != 0:
            failed.append((ent, f"edl exit {rc}"))

    info("resetting phone out of EDL")
    _edl("reset", loader=loader)

    if failed:
        print()
        print(f"FAILED writes: {len(failed)}")
        for ent, why in failed:
            print(f"  LUN {ent.lun}  {ent.label}  ({ent.filename})  -- {why}")
        sys.exit(1)

    ok("flash complete")
    print()
    print("Next steps:")
    print("  1. Phone reboots automatically. First boot 5-10 min.")
    print("  2. Confirm: adb shell getprop ro.product.name  -> OnePlusN100")
    print("  3. Enable Developer Options + USB debugging + OEM Unlock toggle.")
    print("  4. adb reboot bootloader && fastboot oem unlock")
    print("  5. Run the UBports Installer DMG.")


def _edl(*args, loader: Path) -> int:
    """
    Shell out to the `edl` CLI with the given args, plus loader + memory.
    Each call is one Sahara session (~1 second overhead) — fine for backup
    and for small partitions, dominated by transfer time for big ones.

    --devicemodel=20882 is the N100 T-Mobile projid (found in the device's
    param partition). Without it, the OnePlus signing module init returns
    None and signed-partition writes (xbl/abl/boot/modem) crash with
    `AttributeError: 'NoneType' object has no attribute 'generatetoken'`.
    """
    cmd = [str(EDL_BIN), *args, "--loader", str(loader),
           "--memory", "emmc", "--devicemodel", "20882"]
    result = subprocess.run(cmd, cwd=HERE)
    return result.returncode


def cmd_backup(args):
    out_dir = Path(args.out).resolve() if args.out else \
              (HERE / "backup" / "be2012_pre_crossflash")
    out_dir.mkdir(parents=True, exist_ok=True)

    loader = Path(args.loader).resolve() if args.loader else N100_LOADER
    if not loader.is_file():
        die(f"loader not found: {loader}")

    info(f"backing up {len(BACKUP_TARGETS)} device-unique partitions")
    info(f"output directory: {out_dir}")
    info(f"using loader: {loader}")
    info(f"phone must be in EDL (Qualcomm 9008) now — script will wait")

    failed: list[tuple[str, int, str]] = []
    for i, (label, lun) in enumerate(BACKUP_TARGETS, 1):
        dst = out_dir / f"{label}.img"
        info(f"[{i}/{len(BACKUP_TARGETS)}] reading LUN {lun}  {label}  ->  {dst.name}")
        rc = _edl("r", label, str(dst), "--lun", str(lun), loader=loader)
        if rc != 0:
            failed.append((label, lun, f"edl exit {rc}"))
            continue
        if not dst.is_file() or dst.stat().st_size == 0:
            failed.append((label, lun, "no/empty file produced"))
            continue
        ok(f"saved {dst.stat().st_size:,} bytes")

    info("resetting phone out of EDL")
    _edl("reset", loader=loader)

    if failed:
        print()
        print(f"FAILED reads: {len(failed)}")
        for label, lun, why in failed:
            print(f"  LUN {lun}  {label}  -- {why}")
        print()
        print("Some partitions may not exist on this firmware variant — that's fine.")
        print("Inspect the backup directory and decide if the saved set is enough.")
        sys.exit(1)

    print()
    ok(f"backup complete. {len(BACKUP_TARGETS)} partitions saved to {out_dir}")


def cmd_reset(args):
    loader = Path(args.loader).resolve() if args.loader else N100_LOADER
    cmd = [str(EDL_BIN), "reset", "--loader", str(loader)]
    result = subprocess.run(cmd, cwd=HERE)
    sys.exit(result.returncode)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    p_plan = sub.add_parser("plan", help="parse settings.xml, print partition plan")
    p_plan.add_argument("extract_dir", help="opscrypto extract/ folder")
    p_plan.set_defaults(func=cmd_plan)

    p_flash = sub.add_parser("flash", help="cross-flash via Firehose")
    p_flash.add_argument("extract_dir", help="opscrypto extract/ folder")
    p_flash.add_argument("--loader", help=f"override loader (default: {N100_LOADER.name})")
    p_flash.add_argument("--dry-run", action="store_true",
                         help="upload loader, walk the plan, but pass --skipwrite")
    p_flash.add_argument("--yes", action="store_true", help="skip confirmation")
    p_flash.add_argument("--skip-lun", help="comma-separated LUNs to exclude")
    p_flash.add_argument("--only-lun", help="comma-separated LUNs to include")
    p_flash.set_defaults(func=cmd_flash)

    p_backup = sub.add_parser("backup", help="read device-unique partitions to a backup dir")
    p_backup.add_argument("--loader", help=f"override loader (default: {N100_LOADER.name})")
    p_backup.add_argument("--out", help="output directory (default: backup/be2012_pre_crossflash)")
    p_backup.set_defaults(func=cmd_backup)

    p_reset = sub.add_parser("reset", help="reset phone out of EDL")
    p_reset.add_argument("--loader", help=f"override loader (default: {N100_LOADER.name})")
    p_reset.set_defaults(func=cmd_reset)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
