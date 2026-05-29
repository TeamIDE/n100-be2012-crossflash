# Hire TeamIDE

This repo is what we ship for free. If you need work like it for a
device, port, or rescue project you can't get to yourself, hire us.

## What we did here, concretely

Took a **carrier-locked OnePlus Nord N100 BE2012** — a phone the
official UBports installer literally rejects with *"device not
supported"* — and turned it into a working Ubuntu Touch daily driver,
entirely from macOS. Along the way:

- **Replaced the Windows-only MSMDownloadTool** with a macOS-native
  driver around `bkerler/edl` and the OnePlus signed Firehose loader.
  No more "borrow a Windows PC to flash."
- **Bypassed the carrier OEM-unlock gate** by mapping the five Android
  shim apps holding `sys.oem_unlock_allowed=0` and removing them
  surgically via `pm uninstall --user 0`.
- **Defeated the recovery's 2012-era gpg 1.4.13** (which can't verify
  modern SHA512 signatures on UT images) by patching
  `system-image-upgrader` on-device with `magiskboot`-repacked
  recovery — without recompiling anything.
- **Tracked down a silent ofono SIM-init blocker** that left `Modem.Features`
  stuck at `['sim']` on every install. Diagnosed in disassembly,
  fixed with a three-byte binary patch to `/usr/sbin/ofonod` that
  hijacks the `sim_pin_query_cb` error path. SIM state machine
  advances, IMSI reads, `NetworkRegistration` comes up, full feature
  set rolls out.
- **Wrote it all up as a reproducible installer.** Six scripts, 18
  files, ~230 KB. Anyone with a BE2012, a Mac, and a USB cable can
  follow the steps.

## What you can hire us to do

### Device rescue & enablement
You bought the wrong SKU. Your fleet has a model whose bootloader
nobody's unlocked. Your community port works on one variant and
silently fails on another. We figure out *why* and ship the fix as
something your team can run.

### Halium / Ubuntu Touch / Sailfish bringup
New device, missing driver, broken modem, flaky sensor. We work in
the Halium tree, `ofono-binder-plugin`, `libgbinder-radio`, `lxc-android`,
and the AppArmor/Click confinement layer. Comfortable in QML +
Lomiri.Components for the app side too.

### Qualcomm EDL / Firehose work
Custom Firehose loaders, patched MSM-style cross-flashing, EDL-rooted
recovery of devices everyone else considers bricked. We've used the
Sahara handshake enough to know what fails and how to fix it.

### Reverse engineering low-level system components
Binary analysis with capstone, ARM64 patch derivation against a moving
target, symbol-less symbol hunting via string xrefs. The ofonod patch
in this repo is representative. We document the offsets, the *why*,
and the re-derivation procedure.

### macOS-native tooling for traditionally Windows-only workflows
Most of mobile device modding assumes a Windows host. We don't. If
your team is on Macs and your vendor docs say "use this .exe,"
we replace the .exe.

## Other things we've built

This installer is one of many. A few others:

- **[Group Bluetooth Audio](https://teamide.dev/products/group-audio)** —
  macOS app that plays synchronized audio to multiple Bluetooth speakers,
  headphones, or wired outputs at once, with drift correction and
  per-device volume control. Same pattern you see in this repo: a
  problem the OS won't solve for you, solved natively on macOS,
  shipped as a tool real people use.
- **[Full product list](https://teamide.dev/products)** — everything
  currently shipping.
- **[Portfolio](https://dcherrera-portfolio-main.teamide.dev/)** —
  longer-form case studies and prior work.

## Engagement options

- **Spike (1–3 days).** Targeted diagnosis or proof-of-concept. You
  bring a clear question; we come back with an evidence-backed
  answer and a small repro.
- **Fixed-scope project (1–6 weeks).** Reproducible installer like
  this one, a clean port, an upstream-quality patch series. Defined
  deliverables, milestone-based.
- **Embedded consulting (retainer).** We work alongside your team
  for an agreed slice of the week. Best when there's ongoing
  unknown-unknowns work.
- **Open-source sponsorship.** Fund a specific upstream effort —
  the next device on UBports' supported list, an `ofono-binder-plugin`
  fix for an entire class of modem quirks. Listed publicly,
  delivered to upstream maintainers, not to a private repo.

## Why TeamIDE

- **We ship reproducibly.** The README is the contract. If a third
  party with the same hardware can't follow the steps, we haven't
  finished. (This repo is the demo.)
- **We document what's load-bearing and what's incidental.** "EHPLMN
  patch was cosmetic, PIN-auth hijack was the actual fix" — that
  kind of clarity, in the writeup, not just the code.
- **We respect upstream.** Where a binary patch is a stopgap, we say
  so and point at the upstream-quality fix. We'd rather close the
  vulnerability than monetize it.

## Contact

[teamide.dev/contact](https://teamide.dev/contact) for project
inquiries and engagement scoping.

For quick questions, lower-stakes chatter, or just to see what we're
working on, find us in [Discord](https://discord.gg/YVcsHXSCYG).

For open issues against *this specific repo*, please use
[GitHub issues](https://github.com/dcherrera/n100-be2012-crossflash/issues) —
keeps the technical thread public and discoverable.

If you want to back ongoing work financially (not hire us for a
project), that's at [teamide.dev/support](https://teamide.dev/support).
