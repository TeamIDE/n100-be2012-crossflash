#!/usr/bin/env python3
"""
BE2012 -> BE2013 cross-flash driver.

Replaces the Windows-only MSMDownloadTool with `bkerler/edl` + `oppo_decrypt`
running on macOS. The patched-MSM trick works by lying in settings.xml about
the device's project ID; this tool sidesteps the same check by never
performing it — we drive the Qualcomm Firehose protocol directly using
OnePlus's own signed Firehose loader (extracted from the OOS .ops).

Usage:
    flash.py prep    <oos_zip> [--out=<dir>]    Unpack + decrypt firmware
    flash.py info    [--loader=<elf>]           Show chip info from device
    flash.py flash   <payload_dir> [--dry-run]  Cross-flash the phone
    flash.py reboot  [--loader=<elf>]           Just reboot the phone

The phone must be in EDL mode (Vol-Up + Vol-Down + USB on a powered-off
phone, or `adb reboot edl` from a working ROM) for `info`, `flash`, and
`reboot`. `prep` runs offline and is safe to repeat.
"""

import argparse
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
VENV_PY = HERE / "venv" / "bin" / "python"
EDL_BIN = HERE / "venv" / "bin" / "edl"
OPSCRYPTO = HERE / "tools" / "oppo_decrypt" / "opscrypto.py"

# OnePlus-signed Firehose programmer for the N100 (SDM460 / bengal).
# Filename encodes <MSM_ID>_<PK_HASH>_fhprg_<device>.bin per bkerler/Loaders.
N100_LOADER = HERE / "tools" / "edl" / "Loaders" / "oneplus" / \
              "0000000000515192_37cf317812121fed_fhprg_opn100.bin"


def die(msg: str, code: int = 1):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def info(msg: str):
    print(f"[*] {msg}")


def ok(msg: str):
    print(f"[+] {msg}")


def find_ops(directory: Path) -> Path:
    """Locate the .ops firmware container inside an unzipped OOS distribution."""
    candidates = sorted(directory.rglob("*.ops"))
    if not candidates:
        die(f"no .ops file found under {directory}")
    if len(candidates) > 1:
        info(f"multiple .ops found, using largest: {[str(c.name) for c in candidates]}")
        candidates.sort(key=lambda p: p.stat().st_size, reverse=True)
    return candidates[0]


def find_loader(extract_dir: Path) -> Path:
    """Locate the Qualcomm Firehose programmer inside an extracted .ops."""
    patterns = [
        "prog_firehose_ddr.elf",
        "prog_firehose_lite.elf",
        "prog_emmc_firehose*.mbn",
        "prog_firehose*.elf",
        "prog_firehose*.mbn",
    ]
    seen = []
    for pat in patterns:
        for hit in extract_dir.rglob(pat):
            if hit.is_file():
                seen.append(hit)
    if not seen:
        die(f"no Firehose loader found under {extract_dir}")
    seen.sort(key=lambda p: p.stat().st_size, reverse=True)
    return seen[0]


def list_partitions(extract_dir: Path) -> list[Path]:
    """List candidate partition images under the extracted firmware."""
    imgs = []
    for ext in ("*.img", "*.bin", "*.mbn", "*.elf"):
        for hit in extract_dir.rglob(ext):
            name = hit.name.lower()
            # edl wl maps filename stem -> partition name. Skip the Firehose
            # loader (uploaded separately via --loader) and obvious aux files.
            if name.startswith("prog_") or name.startswith("settings"):
                continue
            if name.endswith(".xml"):
                continue
            imgs.append(hit)
    return sorted(imgs)


def build_payload_dir(extract_dir: Path, payload_dir: Path) -> int:
    """
    `edl wl` is non-recursive and errors out on any file in the directory
    whose basename does not match a real partition. Stage a flat directory
    of hardlinks containing only the partition images we want flashed.
    """
    if payload_dir.exists():
        shutil.rmtree(payload_dir)
    payload_dir.mkdir(parents=True)
    n = 0
    for src in list_partitions(extract_dir):
        dst = payload_dir / src.name
        # Hardlink keeps storage flat — falls back to copy across filesystems.
        try:
            dst.hardlink_to(src)
        except OSError:
            shutil.copy2(src, dst)
        n += 1
    return n


def cmd_prep(args):
    oos_zip = Path(args.oos_zip).resolve()
    if not oos_zip.is_file():
        die(f"not a file: {oos_zip}")

    out = Path(args.out or (HERE / "firmware" / "extracted")).resolve()
    out.mkdir(parents=True, exist_ok=True)

    info(f"unzipping {oos_zip.name} -> {out}")
    with zipfile.ZipFile(oos_zip) as z:
        z.extractall(out)
    ok(f"unzipped {oos_zip.name}")

    ops_path = find_ops(out)
    ok(f"found firmware container: {ops_path.relative_to(out)}")

    info(f"decrypting .ops with opscrypto (this takes a minute)")
    extract_subdir = ops_path.parent / "extract"
    if extract_subdir.exists():
        info(f"removing stale extract dir: {extract_subdir}")
        shutil.rmtree(extract_subdir)

    # opscrypto.py writes to ./extract/ relative to current working directory
    result = subprocess.run(
        [str(VENV_PY), str(OPSCRYPTO), "decrypt", str(ops_path)],
        cwd=ops_path.parent,
        check=False,
    )
    if result.returncode != 0:
        die(f"opscrypto exited {result.returncode}")
    if not extract_subdir.exists():
        die(f"opscrypto did not produce {extract_subdir}")
    ok(f"decrypted to: {extract_subdir}")

    try:
        loader = find_loader(extract_subdir)
        ok(f"firehose loader in firmware: {loader.relative_to(extract_subdir)} ({loader.stat().st_size:,} bytes)")
    except SystemExit:
        info(f"no Firehose loader in firmware; will use bundled {N100_LOADER.name}")

    payload_dir = extract_subdir.parent / "flash_payload"
    n = build_payload_dir(extract_subdir, payload_dir)
    ok(f"staged {n} partition images into: {payload_dir}")

    imgs = sorted(payload_dir.iterdir())
    for img in imgs[:30]:
        print(f"      {img.name} ({img.stat().st_size:,} bytes)")
    if len(imgs) > 30:
        print(f"      ... +{len(imgs) - 30} more")

    print()
    ok(f"prep done.")
    print(f"  next, with phone in EDL:")
    print(f"    ./flash.py info")
    print(f"    ./flash.py flash {payload_dir} --dry-run")
    print(f"    ./flash.py flash {payload_dir}")


def cmd_info(args):
    loader = Path(args.loader).resolve() if args.loader else N100_LOADER
    if not loader.is_file():
        die(f"loader not found: {loader}")

    info(f"using loader: {loader}")
    info(f"connecting to phone in EDL (printgpt will upload the loader)")
    # If the bootrom rejects the loader signature, or Firehose rejects the
    # connection for region/project-ID reasons, we learn it here without
    # writing anything.
    result = subprocess.run(
        [str(EDL_BIN), "printgpt", "--loader", str(loader), "--memory", "emmc"],
        cwd=HERE,
    )
    sys.exit(result.returncode)


def cmd_flash(args):
    payload_dir = Path(args.payload_dir).resolve()
    if not payload_dir.is_dir():
        die(f"not a directory: {payload_dir}")

    loader = Path(args.loader).resolve() if args.loader else N100_LOADER
    if not loader.is_file():
        die(f"loader not found: {loader}")
    info(f"using firehose loader: {loader}")

    imgs = sorted(p for p in payload_dir.iterdir() if p.is_file())
    if not imgs:
        die(f"no images in payload dir: {payload_dir} — did you run prep?")
    info(f"about to flash {len(imgs)} partition images from {payload_dir}")

    if not args.yes and not args.dry_run:
        print()
        print("This will overwrite every listed partition on the connected phone.")
        print("The phone must be in EDL mode (Qualcomm HS-USB QDLoader 9008).")
        print()
        ans = input("Proceed? type YES: ").strip()
        if ans != "YES":
            die("aborted by user", code=2)

    cmd = [
        str(EDL_BIN),
        "wl", str(payload_dir),
        "--loader", str(loader),
        "--memory", "emmc",
    ]
    if args.dry_run:
        cmd.append("--skipwrite")
        info("DRY RUN: --skipwrite passed; nothing will actually be written")

    info(f"running: {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=HERE)
    if result.returncode != 0:
        die(f"edl exited {result.returncode}", code=result.returncode)

    ok("flash complete")
    print()
    print("Next steps:")
    print("  1. Phone should reboot automatically. First boot 5-10 min.")
    print("  2. Walk through Global OOS setup, enable Developer Options,")
    print("     toggle OEM Unlock (should now be ungreyed) + USB debugging.")
    print("  3. `adb reboot bootloader` then `fastboot oem unlock`.")
    print("  4. Run the UBports Installer DMG normally.")


def cmd_reboot(args):
    loader = Path(args.loader).resolve() if args.loader else N100_LOADER
    cmd = [str(EDL_BIN), "reset", "--loader", str(loader)]
    result = subprocess.run(cmd, cwd=HERE)
    sys.exit(result.returncode)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    p_prep = sub.add_parser("prep", help="unpack OOS zip + decrypt .ops")
    p_prep.add_argument("oos_zip", help="path to OnePlus_Nord_N100_Global_OxygenOS_*.zip")
    p_prep.add_argument("--out", help="output directory (default: firmware/extracted)")
    p_prep.set_defaults(func=cmd_prep)

    p_info = sub.add_parser("info", help="show chip info from phone in EDL")
    p_info.add_argument("--loader", help=f"override loader path (default: {N100_LOADER.name})")
    p_info.set_defaults(func=cmd_info)

    p_flash = sub.add_parser("flash", help="cross-flash the phone")
    p_flash.add_argument("payload_dir", help="path to firmware/extracted/.../flash_payload (built by prep)")
    p_flash.add_argument("--loader", help=f"override loader path (default: {N100_LOADER.name})")
    p_flash.add_argument("--dry-run", action="store_true", help="use --skipwrite (no writes)")
    p_flash.add_argument("--yes", action="store_true", help="skip confirmation prompt")
    p_flash.set_defaults(func=cmd_flash)

    p_reboot = sub.add_parser("reboot", help="reboot phone out of EDL")
    p_reboot.add_argument("--loader", help=f"override loader path (default: {N100_LOADER.name})")
    p_reboot.set_defaults(func=cmd_reboot)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
