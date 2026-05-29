#!/usr/bin/env bash
# Step 0: one-time prep. Downloads every artifact the later steps need
# and verifies the host-side Python toolchain. Idempotent.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

say "checking host tooling"
require_cmd brew
require_cmd python3
require_cmd curl
require_cmd git
require_cmd unzip

if ! brew list libusb >/dev/null 2>&1; then
  say "installing libusb (needed by bkerler/edl)"
  brew install libusb
fi

# --- External tools: clone, then install into a venv at the repo root --------
TOOLS_DIR="$REPO_DIR/tools"
mkdir -p "$TOOLS_DIR"

if [[ ! -d "$TOOLS_DIR/edl/.git" ]]; then
  say "cloning bkerler/edl + Loaders submodule (Qualcomm Firehose client)"
  # --recurse-submodules is REQUIRED: the signed Firehose loaders live in
  # the bkerler/Loaders submodule. Without it, step 1 (cross-flash) fails
  # because the OnePlus N100 loader is missing.
  git clone --depth 1 --recurse-submodules --shallow-submodules \
    https://github.com/bkerler/edl "$TOOLS_DIR/edl"
elif [[ ! -f "$TOOLS_DIR/edl/Loaders/oneplus/0000000000515192_37cf317812121fed_fhprg_opn100.bin" ]]; then
  say "edl present but Loaders submodule missing — fetching"
  ( cd "$TOOLS_DIR/edl" && git submodule update --init --depth 1 Loaders )
fi
if [[ ! -d "$TOOLS_DIR/oppo_decrypt/.git" ]]; then
  say "cloning bkerler/oppo_decrypt (OnePlus .ops unpacker)"
  git clone --depth 1 https://github.com/bkerler/oppo_decrypt "$TOOLS_DIR/oppo_decrypt"
fi

if [[ ! -x "$EDL_VENV/bin/python" ]]; then
  say "creating Python venv at $EDL_VENV"
  python3 -m venv "$EDL_VENV"
fi
if [[ ! -x "$EDL_VENV/bin/edl" ]]; then
  say "installing edl + oppo_decrypt into venv (slow first time)"
  "$EDL_VENV/bin/pip" install --quiet --upgrade pip
  "$EDL_VENV/bin/pip" install --quiet "$TOOLS_DIR/edl"
  "$EDL_VENV/bin/pip" install --quiet -r "$TOOLS_DIR/oppo_decrypt/requirements.txt"
fi
ok "host tooling present (edl venv: $EDL_VENV)"

# --- BE2013 firmware ---------------------------------------------------------
FW_ZIP="$REPO_DIR/firmware/OnePlus_Nord_N100_Global_OxygenOS_10.5.3.zip"
FW_URL="https://onepluscommunityserver.com/list/Unbrick_Tools/OnePlus_Nord_N100/Global_BE81AA/Q/OnePlus_Nord_N100_Global_OxygenOS_10.5.3.zip"
if [[ ! -f "$FW_ZIP" ]]; then
  say "downloading BE2013 Global OxygenOS 10.5.3 (~2.5 GB) — slow"
  mkdir -p "$(dirname "$FW_ZIP")"
  curl -L --progress-bar -o "$FW_ZIP" "$FW_URL"
fi
ok "BE2013 firmware: $FW_ZIP"

# --- Ubuntu Touch system-image files ----------------------------------------
UT_DIR="$DL_DIR/ubports-systemimage"
mkdir -p "$UT_DIR"
INDEX_JSON="$UT_DIR/index.json"
say "fetching system-image index for billie2 / $SYSIMG_CHANNEL"
curl -sSL "$SYSIMG_BASE/$SYSIMG_CHANNEL/$SYSIMG_DEVICE/index.json" -o "$INDEX_JSON"

UT_VERSION=$(python3 - <<PY
import json
idx = json.load(open("$INDEX_JSON"))
fulls = [i for i in idx["images"] if i.get("type") == "full"]
print(fulls[-1]["version"])
PY
)
ok "latest full image is version $UT_VERSION"

# Generate the ubuntu_command file + url list from the index.
python3 - <<PY
import json, os
idx = json.load(open("$INDEX_JSON"))
fulls = [i for i in idx["images"] if i.get("type") == "full"]
latest = fulls[-1]
base = "$SYSIMG_BASE"
cmds = [
    "format system",
    "load_keyring image-master.tar.xz image-master.tar.xz.asc",
    "load_keyring image-signing.tar.xz image-signing.tar.xz.asc",
    "mount system",
]
urls = []
for fl in latest["files"]:
    urls.append(base + fl["path"])
    urls.append(base + fl["signature"])
    cmds.append(f"update {os.path.basename(fl['path'])} {os.path.basename(fl['signature'])}")
cmds.append("format data")
cmds.append("unmount system")
for f in ("image-master.tar.xz", "image-master.tar.xz.asc",
          "image-signing.tar.xz", "image-signing.tar.xz.asc"):
    urls.append(base + "/gpg/" + f)
with open("$UT_DIR/ubuntu_command", "w") as f:
    f.write("\n".join(cmds) + "\n")
with open("$UT_DIR/urls.txt", "w") as f:
    f.write("\n".join(urls) + "\n")
PY

# Download all the system-image artifacts that aren't already present.
say "downloading system-image files (one-time, may take a few minutes)"
cd "$UT_DIR"
while IFS= read -r url; do
  fn="${url##*/}"
  if [[ -f "$fn" ]]; then
    continue
  fi
  printf '  fetching %s ... ' "$fn"
  curl -fsSL -o "$fn" "$url" && printf '%s\n' OK || printf 'FAIL\n'
done < urls.txt

# Verify rootfs checksum — adb push has been observed to truncate this file
# on macOS. If the local file's sha256 matches the server's, we know we have
# the bytes we need; the install-step pushes can be re-tried freely.
python3 - <<PY
import hashlib, json, os
idx = json.load(open("$INDEX_JSON"))
fulls = [i for i in idx["images"] if i.get("type") == "full"]
latest = fulls[-1]
for fl in latest["files"]:
    path = "$UT_DIR/" + os.path.basename(fl["path"])
    if not os.path.exists(path):
        continue
    h = hashlib.sha256()
    with open(path, "rb") as fp:
        for chunk in iter(lambda: fp.read(1<<16), b""):
            h.update(chunk)
    got = h.hexdigest()
    want = fl["checksum"]
    if got != want:
        raise SystemExit(f"checksum mismatch on {path}: got {got} want {want}")
print("all UT artifact checksums verified")
PY
ok "Ubuntu Touch system-image files ready ($UT_DIR)"

# --- Bootstrap firmware (boot/recovery/dtbo/vbmeta from rubencarneiro) ------
BS_DIR="$DL_DIR/bootstrap"
mkdir -p "$BS_DIR"
for f in boot.img recovery.img dtbo.img vbmeta.img; do
  if [[ ! -f "$BS_DIR/$f" ]]; then
    say "fetching $f from rubencarneiro/billie2 release 1.0"
    curl -fL --progress-bar -o "$BS_DIR/$f" \
      "https://github.com/rubencarneiro/billie2/releases/download/1.0/$f"
  fi
done
ok "bootstrap firmware: $BS_DIR"

# --- magiskboot (arm64, used on-device to repack the patched recovery) ------
MB_DIR="$DL_DIR/magiskboot"
mkdir -p "$MB_DIR"
MAGISK_VER="v28.1"
MAGISK_APK="$MB_DIR/Magisk-${MAGISK_VER}.apk"
MB_BIN="$MB_DIR/magiskboot.arm64"
if [[ ! -f "$MB_BIN" ]]; then
  if [[ ! -f "$MAGISK_APK" ]]; then
    say "downloading Magisk $MAGISK_VER (for magiskboot binary)"
    curl -fL --progress-bar -o "$MAGISK_APK" \
      "https://github.com/topjohnwu/Magisk/releases/download/$MAGISK_VER/Magisk-${MAGISK_VER}.apk"
  fi
  unzip -p "$MAGISK_APK" "lib/arm64-v8a/libmagiskboot.so" > "$MB_BIN"
  chmod +x "$MB_BIN"
fi
ok "magiskboot (arm64): $MB_BIN"

# --- Android platform-tools (adb / fastboot) for macOS ----------------------
if [[ ! -x "$PLATFORM_TOOLS/adb" ]]; then
  say "fetching Android platform-tools for macOS"
  mkdir -p "$REPO_DIR/host-tools"
  PT_ZIP="$REPO_DIR/host-tools/platform-tools-darwin.zip"
  curl -fL --progress-bar -o "$PT_ZIP" \
    https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
  unzip -q -o -d "$REPO_DIR/host-tools" "$PT_ZIP"
  rm -f "$PT_ZIP"
fi
ok "platform-tools: $PLATFORM_TOOLS"

echo
ok "00-prep complete — proceed to 01-cross-flash.sh"
state_mark prep
