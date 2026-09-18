# Updating the warhol ROM

How to rebuild warhol on current LineageOS sources and put the result on the phone
without touching `/data`. Do it **at least quarterly** to pick up Android security fixes;
check monthly.

A routine update takes a few minutes of hands-on time and roughly half an hour of machine
time. The September 2026 resync took 2 minutes and the incremental build took 14. A
quarter's worth of upstream changes will take longer.

This phone's state, its safety rules and the reason for each are in
[DEVICE-NOTES.md](DEVICE-NOTES.md). Wiping and reinstalling is [REINSTALL.md](REINSTALL.md).

## What an update covers, and what it does not

| layer | where it comes from | level on 2026-09-18 | updated by this procedure |
| --- | --- | --- | --- |
| system, system_ext, product | LineageOS source, built here | SPL 2026-09-01 | **yes** |
| vendor, odm, vendor_dlkm | stock Xiaomi Global OS3.0.310.0, plus our injected SELinux policy | vendor SPL 2026-02-01 | no |
| kernel, system_dlkm | Google's certified GKI in `boot`, Google's modules in `system_dlkm` | `android16-6.12-2025-09_r38`, released 2026-09-03 | no: [Updating the kernel](#updating-the-kernel) |
| firmware (modem, TEE, LK, preloader, SCP) | stock / engineering firmware | | no |
| Magisk | patched `init_boot` | 30.7 | no |
| Google apps | MindTheGapps module, then Play | | Play updates them |

This procedure keeps the Android framework and everything else LineageOS builds current.
It does **not** move the kernel or the vendor blobs, and those age:

* **The kernel** has its own procedure, [Updating the kernel](#updating-the-kernel). It
  writes `boot` and `system_dlkm`, so each run needs its own decision.
* **The vendor blobs** would have to come from the vendor, odm and vendor_dlkm partitions
  of a newer Xiaomi Global release, with our policy re-injected. There is no procedure for
  that yet.

## Cadence

* Google publishes the Android Security Bulletin on the first Monday of each month, and
  LineageOS merges it into its current branch. Run `update-check` monthly. It is free and
  read-only.
* Rebuild at least once a quarter. Rebuild sooner if a bulletin fixes something critical
  and remotely reachable (media, Bluetooth, Wi-Fi, the modem stack).
* LineageOS opens a new minor branch with each Android quarterly platform release
  (24.0, 24.1, ...). Once it moves, fixes stop landing on the old branch, so some
  quarterly updates are a **branch bump** (see below), not a routine update.
  `update-check` tells you which one you face.
* In the same monthly check, run `gki_update.py list` to see whether Google released a
  newer kernel on the phone's line. The kernel is updated separately; see
  [Updating the kernel](#updating-the-kernel).

## One-time prerequisites

* **Back up the signing keys.** They are in `/run/media/local/4TB/warhol-los/keys`, and the
  24.0 tree's `keys/` is a symlink to that directory. If they are lost, no future build can
  be installed over the existing `/data`. Platform-signed apps would stop matching, so
  every update would need a data wipe. Keep an encrypted copy off the build host.
* **Do not delete the old 23.2 root** (`/run/media/local/4TB/warhol-los`). The 24.0 tree
  symlinks `keys/`, `ccache/` and `containers/` into it.

## Every session

On the build host (awe):

```bash
export B=/run/media/local/4TB/warhol-los-24
export WARHOL_ROOT=$B WARHOL_BRANCH=lineage-24.0 WARHOL_RELEASE=cp2a WARHOL_NO_LEGACY_DEPS=1
cd $B
```

`remote-build.sh`'s built-in defaults still describe the 23.2 tree, so these exports are
not optional. Plug the phone into awe; every phone step below runs from there.

## Routine update (same branch)

**1. Is one due?**

```bash
./remote-build.sh update-check
```

This compares the SPL on the phone, in the tree and upstream, and names the newest
LineageOS branch. If the verdict says the branch moved, go to
[Moving to a new LineageOS branch](#moving-to-a-new-lineageos-branch).

**2. Preview the resync.**

```bash
./remote-build.sh resync --check
```

It lists dirty projects without changing anything. Dirty is normal here: `patch_tree`
edits these projects in place, and the next build re-applies every edit:

* build/soong, frameworks/base, frameworks/opt/telephony, system/core
* packages/apps/CarrierConfig, Messaging, OpenEUICC (and its lpac submodule), Settings
* prebuilts/openeuicc-deps, vendor/apn, vendor/lineage

Anything else in that list was edited by hand. Commit it somewhere first, or know that it
will be stashed.

**3. Resync.**

```bash
./remote-build.sh resync 2>&1 | tee resync-$(date +%Y%m%d).log
```

Never use `sync` on this tree; it now refuses. `resync` does the following:

* writes `rollback/<stamp>/project-heads.txt`;
* stashes the dirty projects;
* runs `repo sync` in the build container;
* pins OpenEUICC back to `9a537a2`, the revision the eSIM fixes were validated on;
* prints the SPL change and whether Launcher3 moved.

To move OpenEUICC on purpose, set `WARHOL_OPENEUICC_PIN` and retest eSIM from scratch:
download, enable, disable, switch.

**4. Build.**

```bash
nohup ./remote-build.sh build > build-$(date +%Y%m%d-%H%M).log 2>&1 &
tail -f build-*.log     # wait for "=== BUILD OK ===" and the "patching debuggable props" lines
```

The build refuses to run if Launcher3 carries the advanced-grid feature. That feature ships
only as a Magisk module.

**5. Did every warhol fix apply?**

```bash
bash warhol-extra/tools/patch_report.sh build-<stamp>.log     # expect "0 missing"
```

`patch_tree` skips a fix quietly when upstream code moved under it. That is how a ROM once
shipped with eSIM dead. This check compares the log against
`tools/patch_tree.expected`. A `MISSING` line means that fix is not in this build. Update
its script in `patches/tree/`, rebuild, and do not flash until the report is clean. If
upstream merged the fix itself, delete the patch and its line in `patch_tree.expected`.
The report is only meaningful for the first build after a resync; on rebuilds most steps
print "already patched" instead.

**6. Archive the build.**

```bash
./remote-build.sh save-build $(date +%Y%m%d)-<tag>        # e.g. 20261215-q4
```

This copies the flashable images to `builds/<name>/` and writes `SHA256SUMS` and a
`README`. The README records the source revisions and the SPL. It also records the
rollback: the archived build whose build time matches what the phone runs now. Flash
from `builds/`, never from `tmp/flash`.

**7. Check the SELinux policy the phone will compile at boot.** The phone must be booted
and attached.

```bash
./remote-build.sh policy-check builds/<name>        # expect two PASS lines
```

Nothing precompiles warhol's policy, so init compiles platform plus vendor CIL at every
boot. A policy that does not compile is a boot loop. This check reproduces that step on
the build host:

* It pulls the vendor side from the phone and keeps a copy in `builds/<name>/vendor-selinux/`.
  For offline reruns, point `WARHOL_VENDOR_SELINUX` at that copy.
* It compiles the phone's current system policy as a control.
* **Control PASS and new FAIL** means the build would not boot. Do not flash it (see
  [Troubleshooting](#troubleshooting)).

**8. Rebuild the advanced-grid module, if Launcher3 moved.** The resync output prints the
exact rebase commands:

```bash
git -C src/packages/apps/Launcher3 rebase --onto <new> <old> lineage-24.0
git -C src/packages/apps/Launcher3 checkout -q --detach <new>
./remote-build.sh advgrid-module v<next>             # -> warhol-modules/trebuchet_advgrid_v<next>.zip
adb push warhol-modules/trebuchet_advgrid_v<next>.zip /data/local/tmp/
adb shell su -c 'magisk --install-module /data/local/tmp/trebuchet_advgrid_v<next>.zip'
```

Install it **before** flashing. Magisk activates it at the next boot, so the new module
and the new ROM appear together. The module replaces the whole launcher APK, so it must
match the ROM's Launcher3. Never uninstall it across a flash, or Launcher3 migrates the
custom grid and scrambles the home screen. If Launcher3 did not move, keep the installed
module.

**9. Flash.** Boot the phone into TWRP by hand. Never use `adb reboot recovery`: it leaves
`boot-recovery` in the misc partition, TWRP does not clear it, and every later boot lands
in recovery. Then:

```bash
bash warhol-extra/tools/flash_three.sh builds/<name>     # ends with ALL_VERIFIED
adb reboot
```

`flash_three.sh` refuses to run unless all of these hold:

* the images match `SHA256SUMS`;
* the phone is in recovery on slot `_a`;
* nothing on the dynamic partitions is mounted;
* each image fits its partition.

It writes `system`, `system_ext` and `product` through TWRP's dm mapper nodes, one at a
time. Each one is verified with an on-device sha256 before the next is written. It writes
nothing else.

**10. Verify.** Enter the PIN first. Until that first unlock the user profile stays locked,
BOOT_COMPLETED has not fired, and the launcher and Messages checks read as failures. Then:

```bash
bash warhol-extra/tools/postflash_check.sh         # 16 pass
```

Then test by hand:

* fingerprint and face unlock
* a phone call (VoLTE)
* SMS
* mobile data on both SIMs
* camera (front and rear)
* eSIM

If mobile data stays off after the flash, see
[Troubleshooting](#troubleshooting).

**11. Publish.** Commit changes in `warhol-extra` and the device tree as
`warhol <warhol@localhost>`. If Launcher3 moved, the rebased advanced-grid branch goes to
the fork with a force-push, because the rebase rewrote its two commits. Before any push,
confirm that `git log --format='%an <%ae>'` shows only `warhol <warhol@localhost>`.

**12. Tidy up.**

* Keep the last two or three `builds/` directories, including the one you rolled back
  from. Each is about 1.9 GB.
* Keep the older `trebuchet_advgrid_v*.zip` files. A rollback past a Launcher3 change
  needs the module built for that launcher.

## Moving to a new LineageOS branch

For example 24.0 to 24.1. **This has not been exercised on 24.x yet.** The steps below
come from the 23.2 to 24.0 move, so expect to adjust them.

A branch bump is one-way for `/data`. The first boot upgrades system databases, and an
older build cannot read them back. **Make sure your own backups are current before
flashing.** TWRP cannot back up `/data` on this phone.

1. **Resync the current branch first** with `./remote-build.sh resync`. This snapshots the
   tree and stashes local edits, so the bump starts clean.
2. **Point the checkout at the new branch.** Run `./remote-build.sh shell`, then inside it
   `repo init -b lineage-24.1`, then exit. Then point the local manifest's sepolicy_vndr at
   the new branch:
   ```bash
   sed -i 's/revision="lineage-24.0"/revision="lineage-24.1"/' src/.repo/local_manifests/warhol.xml
   ```
3. **Update the session settings.** Set `WARHOL_BRANCH=lineage-24.1`. Set
   `WARHOL_RELEASE` to the release config `update-check` printed for the new branch; it
   was `bp4a` on 23.2 and `cp2a` on 24.0. **Getting this wrong does not fail the build.
   It quietly builds with none of LineageOS's flag values.**
4. **Sync.** Run `./remote-build.sh resync`. It syncs to the new branch and re-pins
   OpenEUICC.
5. **Move our own repositories:**
   * **Device tree:** `git checkout -b lineage-24.1`. Set the sepolicy_vndr revision in
     `lineage.dependencies` to `lineage-24.1`.
   * **Launcher3:** `git checkout -b lineage-24.1 lineage-24.0`, then rebase it onto the
     new upstream. Export `WARHOL_ADVGRID_BRANCH=lineage-24.1`.
   * **warhol-extra:** update the defaults that name the branch:
     `grep -rn 'lineage-24.0\|cp2a' warhol-extra`.
6. **Build, expecting breakage.** Several fixes patch code that changes between platform
   releases: eSIM in telephony, SystemUI, Settings, FOD. Work through `patch_report.sh`
   until it is clean.
7. **Check the policy, and check it harder.** Run `policy-check` as usual. The vendor side
   stays on mapping `202504`, so the new platform must still ship
   `system/etc/selinux/mapping/202504.cil`. `policy-check` fails if it does not.
8. **Check GApps.** MindTheGapps must match the Android version. A quarterly release keeps
   the same major version, so the installed module stays valid.
9. **Flash and verify as usual,** then do the full hand-test list. A branch bump changes far
   more than a routine update.

A new Android major version (LineageOS 25) is a port, not an update. Build it in a
second tree, as 24.0 was, and keep the working tree as the fallback.

## Updating the kernel

The kernel is Google's certified GKI boot image, unmodified. Xiaomi ships it the same way.
Google keeps releasing fixed builds of each release line. Every build on the phone's line,
`android16-6.12-2025-09_rN`, keeps KMI generation 5, so Xiaomi's 579 vendor modules still
load on it unchanged. That means an update writes only two partitions:

* `boot_a` gets Google's new image. The phone's own vbmeta blob is copied in verbatim, so
  the boot patch level the TEE sees does not change. The copied blob no longer matches the
  image, just as with a Magisk-patched image; `vbmeta` is `flags=2`, so nothing checks it.
* `system_dlkm_a` gets Google's modules from the same build. Each GKI build signs its
  modules with a key generated for that build, so the old modules would not load on the
  new kernel. Xiaomi's selection of modules is kept.

Later release lines (2025-12 onwards) are KMI generation 6. Xiaomi's modules do not load on
them: 2026-06_r27 fails 13,649 symbol CRCs across 545 modules. Moving to one needs a Xiaomi
firmware built for generation 6.

The phone ran the stock `2025-09_r32` until 2026-09-18 and has run `r38` since. The r38
update fixed binder and eventpoll use-after-frees, Bluetooth and HID out-of-bounds reads,
and TLB-invalidation errata of the Arm C1 cores this SoC uses.

**1. Is one due?** Check monthly, alongside `update-check`. This is read-only:

```bash
python3 warhol-extra/tools/gki_update.py list
```

It shows the phone's release line and marks newer builds on it as candidates. Google
publishes about one build a month. Its release notes are linked from the
[release page](https://source.android.com/docs/core/architecture/kernel/gki-android16-6_12-release-builds).

**2. Build and check.** The phone must be booted into Android and attached. `build` reads
the live `boot_a`, `system_dlkm_a`, `vendor_boot_a` and `/vendor_dlkm`, and writes nothing
to the phone:

```bash
python3 warhol-extra/tools/gki_update.py build 2025-09_r<N>
```

It downloads Google's certified image and that build's modules and symbol lists into
`gki/`. It stops at the first failed check:

* The new kernel has the phone's KMI generation, and it is newer than the running one.
* The system_dlkm recipe (depmod, `mkfs.erofs`, `avbtool`) rebuilds the live partition
  byte for byte, apart from avbtool's version string. So the new image differs from the
  live one only in its modules.
* Every symbol import of every vendor module (about 34,000) has the same CRC in the new
  kernel as in the running one. The same check is first run against the running kernel as
  a control, and it must find 0 mismatches there.
* No symbol that a vendor module imports has disappeared, for example because Google
  dropped a module. r38 dropped `tls.ko`; nothing on warhol used it.
* No module list in `vendor_boot` names a module signed with the running kernel's key.
  Under the new kernel such a module counts as unsigned and is refused. First-stage init
  treats any listed module that fails to load as fatal, and TWRP uses `boot_a`'s kernel,
  so TWRP would not start. See [the one-time vendor_boot change](#the-one-time-vendor_boot-change).

It also prints the kernel config changes, for information. `--check-only` runs every check,
reports all failures and builds nothing; use it to see why a release is refused.

The result goes to `gki/builds/<tag>/`:

* `boot_a.img` and `system_dlkm_a.img`
* `rollback/`, which holds copies of both live partitions
* `SHA256SUMS`
* `README.txt`, which has the exact commands for the steps below

`gki/work/<tag>/` is scratch space and can be deleted afterwards.

Run on the release the phone already runs, `build` reproduces the flashed images exactly.
That is how the tool was tested.

**3. Flash `boot_a` from fastboot.** Like every write to `boot`, this and the next step need
explicit approval, given for this update. Hold the button combination for fastboot, then:

```bash
fastboot flash boot_a gki/builds/<tag>/boot_a.img
```

This bootloader does not support `fastboot boot`, so there is no RAM-only trial. Do not
switch modes from fastboot either (`fastboot reboot recovery` and the like). Use the
buttons.

**4. Write `system_dlkm_a` from TWRP.** Enter TWRP with the button combination. TWRP runs on
`boot_a`'s kernel, so TWRP coming up is the first test of the new kernel. Then:

```bash
python3 warhol-extra/tools/gki_update.py write-dlkm gki/builds/<tag>
```

It refuses unless all of these hold:

* the phone is in TWRP on slot `_a`;
* TWRP runs the new kernel;
* `boot_a` is exactly this build's `boot_a.img`;
* `system_dlkm` is not mounted.

It pushes the image, checks its sha256 on the phone, writes
`/dev/block/mapper/system_dlkm_a`, verifies the result with an on-device sha256, and
test-mounts it.

**5. Boot and verify.** `adb reboot`, enter the PIN, then:

```bash
bash warhol-extra/tools/postflash_check.sh                          # 16 pass
adb shell uname -r                                                  # the new build's ab number
adb shell su -c 'dmesg | grep -c "disagrees about version"'         # 0
```

Then test by hand the list from step 10 of the routine update. The vendor modules are what
breaks if anything is wrong, so do not skip fingerprint, face unlock, camera, Wi-Fi,
Bluetooth, a call, and auto-brightness (sensors).

**If the new kernel does not come up** (Android or TWRP hangs at the logo or loops), do not
power-cycle more than twice: slot `_b` has no bootloader. Instead:

1. Hold the button combination for fastboot, which does not depend on the kernel. Then run
   `fastboot flash boot_a gki/builds/<tag>/rollback/boot_a.img`.
2. If `system_dlkm_a` was already written, enter TWRP, which is back on the old kernel, and
   run `gki_update.py write-dlkm gki/builds/<tag> --rollback`.

### The one-time vendor_boot change

Stock `vendor_boot` listed Xiaomi's copies of `rfkill.ko` and `libarc4.ko` in
`modules.load.recovery`. These are GKI modules signed by the stock kernel's key, loaded in
TWRP's first stage. On 2026-09-18, those two were removed from that list on the phone, along
with `cfg80211.ko` and `mac80211.ko`, which need them. Normal boot never listed them: it
loads them from `system_dlkm` in second stage. With that change, `vendor_boot` no longer
depends on the kernel build, and the `build` check above keeps it that way.

If `vendor_boot` is ever replaced (a stock image, a new TWRP), `build` stops on this check.
The same edit, from the build host with the phone booted:

```bash
H=$B/src/out/host/linux-x86/bin; mkdir vb && cd vb
adb exec-out "su -c 'cat /dev/block/by-name/vendor_boot_a'" > live.img
$H/unpack_bootimg --boot_img live.img --out u --format mkbootimg > args
$H/lz4 -dc u/vendor_ramdisk00 > rd00.cpio
python3 $B/warhol-extra/tools/cpio_drop.py rd00.cpio rd00.new \
    lib/modules/modules.load.recovery libarc4.ko rfkill.ko cfg80211.ko mac80211.ko
$H/lz4 -l -12 --favor-decSpeed rd00.new rd00.new.lz4
eval python3 $B/src/system/tools/mkbootimg/mkbootimg.py \
    "$(sed 's#u/vendor_ramdisk00#rd00.new.lz4#' args)" --vendor_boot new.img
```

Check the dropped modules against the recovery list first. Nothing that stays in the list
may depend on them (`modules.dep` in the same ramdisk). `new.img` is shorter than the
partition; writing it is a `vendor_boot` write, which needs its own approval. Write it from
Android with `dd`, and verify it with an on-device sha256 over the image's length. The
`lz4` flags and the unpack arguments reproduce the stock image byte for byte. So first
repack the unmodified `u/vendor_ramdisk00` the same way, and compare the result with the
start of the live image: `cmp -n $(stat -c %s check.img) check.img live.img`.

## Rolling back

* **Images, same branch:** flash the previous `builds/` directory the same way. Its path is
  in the new build's README. The trebuchet module must match that build's Launcher3;
  reinstall the older module zip if the launcher changed.
* **Tree:** `resync` recorded every project's pre-sync HEAD. To go back to it:
  ```bash
  ./remote-build.sh resync --restore rollback/<stamp>/project-heads.txt
  ```
  This checks each project out at its recorded commit inside the build container, and
  leaves working-tree edits alone. Pre-sync local edits are in `git stash list` as
  `warhol-pre-resync-<stamp>`. `resync --snapshot` takes a snapshot without syncing, for
  example before experimenting in the tree.
* **Across a branch bump:** expect to need a data wipe. Follow
  [REINSTALL.md](REINSTALL.md) instead.
* **Kernel:** see the end of step 5 in [Updating the kernel](#updating-the-kernel).
  `gki/builds/<tag>/rollback/` holds both partitions as they were before that update.

## Troubleshooting

| symptom | cause and fix |
| --- | --- |
| `patch_report.sh` shows `MISSING` | upstream changed the code a fix targets. The log line printed near it usually says which anchor failed. Fix the script in `patches/tree/`. |
| `policy-check`: control PASS, new FAIL | the new platform policy no longer provides something our vendor CIL uses; the `secilc` error names the line in `vendor_sepolicy.cil`. The fix belongs in `device/xiaomi/warhol/sepolicy/warhol_enforce.rules`, and the vendor image must then be rebuilt (`./remote-build.sh enforce-vendor`) and flashed. That flash is a separate step and needs its own explicit approval. |
| `policy-check`: both FAIL | the vendor-side copy or the tool is wrong, not the build. Re-pull with the phone attached. |
| boot loop after flashing | boot TWRP by hand and flash the rollback `builds/` directory. TWRP lives in `vendor_boot`, which this procedure never touches, but it runs on `boot_a`'s kernel. If TWRP hangs too, the kernel is at fault: see [Updating the kernel](#updating-the-kernel). If every boot lands in TWRP although the ROM is fine, the misc partition holds a stale `boot-recovery`: in TWRP, `dd if=/dev/zero of=/dev/block/by-name/misc bs=1 count=32 conv=notrunc`, then `adb reboot`. |
| mobile data off after the flash, airplane mode off | `persist.radio.airplane_mode_on` latched at 1. Run `adb shell setprop persist.radio.airplane_mode_on 0`, then toggle airplane mode on and off. |
| home screen scrambled or launcher crashing | the trebuchet module does not match the ROM's Launcher3. Install the module built for this ROM (step 8). |
| `resync` stops at a stash or `repo sync` error | nothing has been synced yet if the stash failed; fix that project by hand and rerun. `repo sync` retries four times; network failures just need a rerun. |

## Rules this procedure keeps

Each rule below cost a brick, a lost feature, or a near miss:

* **A ROM update writes only `system`, `system_ext` and `product`.** A kernel update writes
  only `boot_a` and `system_dlkm_a`, and each of those writes needs explicit approval.
  `vendor_boot` holds TWRP and is written only with its own approval. Never write
  `vbmeta`, `init_boot`, `lk`, the preloader, `nvdata`, `nvcfg` or `protect1/2`. `vbmeta`
  must stay `flags=2` for this unit's bootloader.
* **Every write is verified with an on-device sha256,** and only slot `_a` is written.
* **A phone that does not boot gets at most two power cycles,** then the button combination
  for fastboot. Slot `_b` has no bootloader, and nothing below fastboot can reach this unit.
* **Never sideload the OTA zip, and never accept an update from the LineageOS Updater
  app.** Both install to the inactive slot `_b`, which has no bootloader on this unit.
* **Never `adb reboot recovery`.** Boot TWRP with the buttons.
* **Never `remote-build.sh sync` an existing tree.** It now refuses; use `resync`.
* **The advanced-grid feature stays out of the base ROM,** and Google components are never
  baked in. Both are Magisk modules.
* **Everything published is authored `warhol <warhol@localhost>`,** with no real names.

## Tool reference

All tools live in `warhol-extra/tools/`. The `remote-build.sh` subcommands run the same
scripts with the session's settings.

| command | what it does | changes anything? |
| --- | --- | --- |
| `remote-build.sh update-check` | SPL on phone / tree / upstream, newest branch, verdict | no |
| `remote-build.sh resync --check` | what a resync would stash and sync | no |
| `remote-build.sh resync` | snapshot, stash, `repo sync`, re-pin OpenEUICC | the tree |
| `remote-build.sh resync --snapshot` / `--restore <heads>` | record / restore every project's HEAD | `rollback/` / the tree |
| `remote-build.sh build` | `mka bacon`, then debuggable-prop patching into `tmp/flash` | `out/`, `tmp/flash` |
| `patch_report.sh <log>` | every warhol fix applied? | no |
| `remote-build.sh save-build <name>` | archive `tmp/flash` into `builds/<name>` with sums and README | `builds/` |
| `remote-build.sh policy-check <dir>` | compile the boot-time SELinux policy against the phone's vendor | no |
| `remote-build.sh advgrid-module <ver>` | build the trebuchet_advgrid Magisk module | `warhol-modules/` |
| `flash_three.sh <dir>` | write the three partitions from TWRP, verified | **the phone** |
| `postflash_check.sh` | 16 read-only checks on the booted phone | no |
| `gki_update.py list` | the phone's kernel and newer builds on its release line | no |
| `gki_update.py build <tag> [--check-only]` | download a GKI release, check it against the vendor modules, build `boot_a` and `system_dlkm_a` | `gki/` |
| `gki_update.py write-dlkm <dir> [--rollback]` | write `system_dlkm_a` from TWRP, verified | **the phone** |
| `cpio_drop.py` | remove modules from one list inside a vendor ramdisk | no (writes a file) |
| `gapps-to-magisk.sh <MindTheGapps zip>` | repack GApps as a Magisk module (see [REINSTALL.md](REINSTALL.md)) | no (writes a file) |
