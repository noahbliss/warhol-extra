# warhol device notes

What this port depends on that the code does not show: the state of the one phone it
runs on, the rules that protect it and the incident behind each, and the root cause of
every problem that took more than an afternoon. Procedures are elsewhere:

* [UPDATING.md](UPDATING.md): ROM and kernel updates.
* [REINSTALL.md](REINSTALL.md): wiping `/data` and reinstalling.
* The device tree's `docs/` and `sepolicy/README.md`: source-level design.

Where another document disagrees with this one, see
[Documents that are out of date](#documents-that-are-out-of-date).

Last reviewed 2026-09-19.

## This unit

The phone is a Global Xiaomi 17T Pro (`ro.boot.hwc=GL`). Its bootloader is unlocked
(`verifiedbootstate=orange`), and it runs an engineering firmware base that a repair
service installed after the first brick (see [History](#history)). So it has a mix of
firmware that no retail unit has:

| partition | what is on it | source |
| --- | --- | --- |
| preloader | stock, secured (SBC, SLA and DAA on) | never written |
| `lk_a` | engineering LK | CN factory package `260610.1.WPSCNXM.FACTORY` |
| `lk_b` and 20 other `_b` firmware partitions | **all zeros** | slot `_b` cannot boot |
| `vbmeta_a` | `flags=2`, algorithm NONE, no descriptors | ours; this LK rejects a vbmeta signed with our key |
| `boot_a` | Google GKI `android16-6.12-2025-09_r38` | [UPDATING.md](UPDATING.md#updating-the-kernel) |
| `init_boot_a` | stock, patched by Magisk 30.7 | |
| `vendor_boot_a` | engineering image; bootconfig without `androidboot.selinux=permissive`; recovery fragment = TWRP with every domain permissive; `modules.load.recovery` without four GKI modules | edited three times, see [SELinux](#selinux) and UPDATING.md |
| `vendor_a` | stock Global OS3.0.310.0 plus our injected `vendor_sepolicy.cil` | device tree `sepolicy/` |
| `system_dlkm_a` | Google's modules from the same GKI build (80) | UPDATING.md |
| `system_a`, `system_ext_a`, `product_a` | our LineageOS 24.0 build | UPDATING.md |
| `modem`, `mcf_ota`, `scp`, `dtbo` | Global OS3.0.310.0 | flashed one at a time; see [Firmware provenance](#firmware-provenance-check-this-first) |
| `tee gz pi_img dpm apusys ccu gpueb sspm mcupm vcp spmfw audio_dsp connsys_gnss countrycode efuse emiupfw mvpu_algo` | engineering (CN) | untouched; they work |
| `logo_a`, `logo_b` | stock CN boot logo | restored after the second brick |
| `nvdata`, `nvcfg`, `protect1`, `protect2` | IMEI and RF calibration | never formatted |

Vendor and firmware security patch level: 2026-02-01. The system SPL follows LineageOS.

### History

* **2026-09-08, first brick.** Flashing for this port left the phone in a preloader reset
  loop. A fastboot-driven mode switch is suspected to have contributed. Nothing on the host could
  reach it (see [Below fastboot](#below-fastboot-there-is-no-host-side-recovery)). A
  third-party repair service with Xiaomi's authenticated download agent recovered it by
  flashing the CN engineering factory package. It came back on slot `_a`, with slot `_b`
  blank.
* **2026-09-12, second brick.** Writing a custom boot logo to `logo_a` from TWRP put LK
  into a reset loop, although the image fit the partition with room to spare. It was
  recovered on 2026-09-13. The logo header was erased through the factory download agent,
  LK then booted without a logo, and the stock logo was written back. Custom boot logos
  are shelved for good.
* **2026-09-10 to 09-15.** Radios, sensors and the camera came back by replacing
  engineering firmware with Global firmware. SELinux went from inherited Permissive to
  native Enforcing.
* **2026-09-18.** Clean base ROM (the advanced grid moved out to a module), then the r38
  kernel.

## Rules, and why each exists

| rule | why |
| --- | --- |
| Write one partition at a time. First say which partition, why, and how to roll it back. Verify each write with an on-device `sha256sum` before writing the next. | Brick 1 came during a multi-step flashing sequence. Single, verified writes keep every failure traceable to one write and reversible. Reading back multi-GB images over `adb exec-out` can truncate, so hash on the phone. |
| Never switch boot modes from fastboot (`fastboot reboot recovery`, `reboot fastboot`, `oem` mode changes), and never `adb reboot recovery`. Use the hardware buttons. | Brick 1. `adb reboot recovery` also leaves `boot-recovery` in `misc`, and TWRP here does not clear it (see [Getting back](#getting-back-from-a-bad-state)). |
| Never write the preloader, `lk`, or `logo`. | There is no host-side recovery below LK. Brick 2 was a `logo` write. |
| Slot `_a` only. Never sideload the OTA zip or accept an Updater install. | Both install to `_b`, which has no bootloader. |
| `vbmeta_a` stays `flags=2`. | This LK refuses our own-key vbmeta, and when it refuses, TWRP goes down too. |
| A phone that does not boot gets at most two power cycles, then the button combination for fastboot. | A/B retry-count decay can switch to `_b`. A successful boot resets the counter. |
| Never format `nvdata`, `nvcfg`, `protect1` or `protect2`. | IMEI and RF calibration. They were never the cause of anything. |
| When the new image is shorter than the old one, check how far the old one extends. | The engineering `scp` ran 345,190 bytes past the Global one. A short `dd` would have left engineering firmware attached to the end. Pad the new image to the partition size and hash the whole partition. |
| Never `.bak` or `.orig` a file inside a `res/` directory of the tree. | aapt2 compiles every file there and fails on the second dot. It broke two builds. |

## Getting back from a bad state

**What a failure takes down.**

| what broke | Android | TWRP | fastboot | way back |
| --- | --- | --- | --- | --- |
| `system`, `system_ext`, `product`, `vendor` | down | up | up | TWRP, rewrite the partition |
| `init_boot` (Magisk) | down | up | up | `fastboot flash init_boot_a <backup>`\* |
| `boot_a` (kernel) or `vbmeta_a` | down | **down** | up | `fastboot flash` the saved image |
| `vendor_boot_a` | depends | likely down | up | `fastboot flash vendor_boot_a <backup>`\* |
| `lk`, preloader, `logo` | down | down | **down** | outside help |

TWRP is a ramdisk fragment in `vendor_boot` and boots `boot_a`'s kernel through the same
`vbmeta_a`, so "TWRP will still be there if Android fails" is only true for the first two
rows. Fastboot is LK itself, and it is the only thing that survives a bad kernel.

**This LK's fastboot:**

* The button combination reaches it.
* `fastboot flash boot_a` has been used from it. Other physical partitions (\* above)
  should work the same way but have not been tried.
* `fastboot boot` is not supported (`unknown command`), so there is no RAM-only trial.
* Logical partitions (`system_a` and the like) are not visible to it; write those from
  TWRP through `/dev/block/mapper/<name>_a`.

**Read the boot stage off USB** when the phone does not come back:

| USB identity | stage |
| --- | --- |
| `0e8d:2000` | BROM |
| `0e8d:0003` "MT65xx Preloader" | preloader; a repeating one is a reset loop, and on this phone a brick until proven otherwise |
| fastboot device | LK |
| adb device | Android or TWRP |

On macOS, `ioreg -rc IOUSBHostDevice` shows this. Sample as fast as it returns; polling
every 12 s turned a real 6-second loop into an apparent 36-second one.

**After a failed boot,** read `/sys/fs/pstore/console-ramoops-0` from the next successful
boot. An empty pstore after a failed slot switch means no kernel ran at all.

**The misc partition.** Its first 32 bytes are the boot-control command. When they hold
`boot-recovery`, every boot lands in TWRP. That looks like a boot loop but is not one. In
TWRP:

```bash
adb shell dd if=/dev/zero of=/dev/block/by-name/misc bs=1 count=32 conv=notrunc
adb reboot
```

Once, a plain `adb reboot` went back into recovery even so, and `adb reboot -p` (power
off; the USB host then started the phone) came up in Android. Entering TWRP with the
buttons has always left `misc` clear.

### Below fastboot there is no host-side recovery

`mtkclient` reaches BROM and reads `MT6993`, HW code `0x1471`, and the SoC and ME IDs. Then
it stops: `SBC enabled: True, SLA enabled: True, DAA enabled: True`, "Auth file is
required". The auth file is Xiaomi-signed, and no BROM exploit covers a 2025 SoC. The
factory package the repair service used includes an authenticated download agent
(`DA_BR.bin`) and an SLA tool. With them, `mtkclient` could erase sectors, which is how the
logo brick was undone. It could not write secure partitions. Copies are kept offline and
in the build host's rescue directory. Treat anything that stops LK from starting as
needing outside help.

### Saved images on the build host

All under `/run/media/local/4TB/`:

| path | what |
| --- | --- |
| `warhol-rescue/device-dump-2026-09-09/` | every partition as the repair service left it (41, sha256-verified) |
| `warhol-rescue/Magisk-v30.7.apk`, `init_boot_a.magisk30.7.img` | Magisk and the patched init_boot |
| `warhol-rescue/logo-2026-09-12/` | the stock logo (`logo_cn.bin`, populated region sha256 `a6a68474…`) |
| `warhol-rescue/flashdrive-2026-09-09/` | the repair service's factory package, `DA_BR.bin` and SLA tool |
| `warhol-stock/` | stock `super`, stock and enforcing vendor images, older vendor_boot variants |
| `warhol-los-24/builds/<name>/` | every flashed ROM build, with `SHA256SUMS` and a README |
| `warhol-los-24/gki/` | kernel builds and the pre-r38 `boot_a`, `system_dlkm_a` and `vendor_boot_a` |
| `~/Downloads/warhol_global_images_OS3.0.310.0.WPSMIXM_16.0/images/` (the Mac) | the Global fastboot ROM's firmware images |

**Only the live `vendor_boot_a` is safe to flash back** while the r38 kernel is in
`boot_a`: `gki/out/vendor_boot_a.r38ready.img` (sha256 `3dcd1574…`). Every variant in
`warhol-stock/` lists the stock kernel's `rfkill.ko` in TWRP's first stage. On r38 that
module counts as unsigned, and TWRP would not start.

## SELinux

The phone boots **natively Enforcing**, with no Magisk script and no init patch. There
are two parts:

1. **The policy.** Our device rules live in the device tree's
   `sepolicy/warhol_enforce.rules` (97 allow, 1 dontaudit). They are generated into
   `warhol_sepolicy.cil` and appended to the stock vendor image's `vendor_sepolicy.cil`
   (12,430 allow rules in total). This works without an init patch because the vendor
   image carries no precompiled policy. init therefore compiles the CIL at every boot,
   and our rules on vendor types take effect. `remote-build.sh enforce-vendor` builds the
   image, and `remote-build.sh policy-check` compiles it the way init will.
2. **The switch.** The engineering `vendor_boot` bootconfig carried
   `androidboot.selinux=permissive`; that line is removed. This is where the old
   Permissive came from, not anything in our build.

What to know:

* **Recovery shares that bootconfig.** Both vendor_boot ramdisk fragments get one
  bootconfig, so TWRP boots enforcing too. There, its GUI crash-loops and touch stays dead:
  the Goodix panel needs an `init`-domain write at early-init to leave raw mode. The fix
  makes all 273 domains in the engineering recovery's own `/sepolicy` permissive. It is
  done with `magiskpolicy` run on the phone from TWRP; the host build of `magiskpolicy`
  needs Android's linker. Do not swap in a policy compiled from our CIL: it would
  mislabel the engineering recovery's files. `getenforce` in TWRP still reads Enforcing.
* **Missing labels look like missing allow rules.** LineageOS ships a 126-line
  `system_ext_property_contexts`; stock had 900. A property only Xiaomi labeled falls
  through to `default_prop`, and vendor domains are denied reading it. The fix is a label
  in the device tree's `system_ext/private/property_contexts`, using stock's own type.
  Get stock's file from `warhol-stock/super_raw.img`. When listing affected properties,
  `grep default_prop` also matches `vendor_default_prop`; match the whole
  `[u:object_r:default_prop:s0]`.
* **Known residual denials** on a fresh `/data` first boot: `hal_miweaverse_default` →
  `/dev/miev` write, `hal_drm_widevine` → `shell_exec` execute, `device_as_webcam` →
  `videogo_device` getattr. Nothing visible depends on them.
* **`mkfs.erofs` is not byte-deterministic** for the vendor image. Compare two builds by
  their extracted CIL and trees, not by sha256.

## Root, Magisk and modules

* Magisk 30.7 is in `init_boot_a` only (slot `_b` cannot boot). Preinit storage is on
  `/metadata`. Zygisk is off unless enabled.
* In Android, `adb shell` runs as the shell user. Use `su -c '…'`, which Magisk
  pre-grants to adb. `adb root` needs `ro.secure=0` in the ROM, which
  `tools/patch_debuggable.py` sets. In TWRP, `adb shell` is already root and there is no
  `su`.
* **After every `/data` wipe** the Magisk app's "Requires additional setup" step has to be
  tapped on the phone. There is no command-line equivalent, and until then
  `magisk --install-module` fails with "Incomplete Magisk install".
* **Modules go in after the first boot, never before.** Staging anything into
  `/data/adb/modules` from TWRP before the first boot makes `/data/adb` non-empty. init
  then fails to apply the file-based encryption policy ("Directory not empty") and
  reboots into recovery, in a loop. After the first boot, `/data` is encrypted with keys
  TWRP can never have. So **the `modules-pack/` zip cannot be used on this phone**;
  install each module from the running OS instead.
* If `magisk --install-module` leaves a module in `modules_update/` after the reboot,
  place the module tree directly in `/data/adb/modules/<id>/` instead (root:root, 0755
  directories, 0644 files, no marker files), then reboot.
* A `/data` wipe erases every module, including the Play Integrity setup. The phone's
  kit lives in `warhol-los-24/warhol-modules/` on the build host.

## Firmware provenance: check this first

The engineering firmware under a Global `/vendor` has caused two multi-session hunts, and
both ended with one partition flashed from the Global ROM:

| dead | partition | fix |
| --- | --- | --- |
| all radios (the modem refused `NW_SET_RADIO_STATE` forever) | `modem` + `mcf_ota` (CN) | Global images, both from the same ROM |
| all sensors, and a black camera on the first open after boot | `scp` (engineering, built Jun 10 2026) | Global `scp.img` (built Aug 2 2026) |

When a peripheral is dead, first compare its partition with the Global ROM's image. Read
exactly the image's length from the live partition and compare sha256s. Where they differ,
compare the build date strings inside. Only then debug deeper. The camera was downstream
of the sensor hub: `libhfmanager` waits 10 s for it, which used up the camera open budget.
eSIM is the counter-example: every SIM-related partition matched Global, and the causes
were in software.

## Subsystem notes

### Radio and IMS

* **VoLTE works.** It needed three pieces, all in the build:
  * device overlay `config_device_volte_available` (and `config_device_wfc_ims_available`);
  * `config_ims_mmtel_package = com.mediatek.ims`, without which no ImsService binds;
  * a carrier config asset added by `patch_tree`, because CarrierConfig compiles its
    assets into the APK and overlays cannot reach them.
* **Debugging IMS:**
  * `setprop persist.dbg.volte_avail_ovr 1` bypasses the platform gate, which separates
    "gated" from "broken".
  * The most useful log line is `GsmCdmaPhone: useImsForCall=`.
  * Raise the `persist.log.tag.*` levels of MediaTek's IMS tags, or they log nothing.
  * Capability reaches the framework about 9 s after radio init.
  * `vendor.ril.mtk_hvolte_indicator` stays `0,0` even while VoLTE works; ignore it.
  * Only data surviving a call proves VoLTE; a working call alone does not.
* **VoWiFi does not work, for any carrier tried.** Everything above the modem is
  configured and verified. The modem never starts an ePDG tunnel, and there is no
  AP-side IWLAN attempt either. Fixing it means modem-side operator configuration we do
  not have, so it is out of scope.
* **IMS is pinned to slot 0.** MediaTek runs IMS on the main-protocol slot. AOSP's remap
  (`remapRafIfApplicable`) never fires, because the RIL reports identical RAFs for both
  phones. `persist.vendor.radio.simswitch` is an output, and the RIL rewrites it at boot.
  A framework patch that reduces the non-data phone's RAF would be the lever; it is
  untested.
* **MediaTek's telephony framework injection cannot work.** Its jars need 1,022 members
  that LineageOS keeps private, across 13 of 14 components. It is disabled in the
  overlay. `tools/scan-fwk-access.py` measures the gap.
* **OEM APKs with a `sharedUserId` must be signed with our platform key,** not kept
  presigned. `MtkImsService` with Xiaomi's signature once killed `system_server` at boot.
* **Android 17 build:** `MtkGsmMmiCode` extends a class that is `final` in AOSP. A17's ART
  verifier aborts the boot image on it, where A16's only marked it. `patch_tree` passes
  `--no-abort-on-hard-verifier-error`. Nothing loads the class. Of the pages of verifier
  errors, only the first line is real.
* **Mobile data off after a reboot, with airplane mode off:**
  `persist.radio.airplane_mode_on` is latched at 1. See the Troubleshooting table in
  UPDATING.md.
* **Every modem frame in logcat:** `setprop persist.vendor.radio.adb_log_mi 65535`, which
  takes effect live. Frames appear under tag `AT`. Set it back to `1` afterwards; it is
  very chatty.

### eSIM

OpenEUICC is the LPA, built into `/system_ext` as a privileged app. It needed five fixes,
all applied by `patch_tree` (scripts in `patches/tree/`):

| fix | symptom without it |
| --- | --- |
| `UiccPort` passes whether the channel is ES10 (ISD-R AID prefix) | every APDU returns `6881` |
| `connectSEService` deadlock | LPA hangs |
| ES10x maximum segment size 255 instead of 63 | profile download fails: this eUICC rejects a chained `initialiseSecureChannel` |
| MEP-A1 `targetPortIndex` in Enable/Disable (platform port 0 = target port 1) | enable fails with `6A80` |
| lock around the channel validity check, null checks in the JNI transmit | "Can't switch SIMs" after a successful enable (LPA crash) |

What to know:

* lpac's `reason 255` means "could not parse the reply", not a card error. Look at the
  APDUs.
* **"Unknown SM-DP+ address"** can mean that OpenEUICC's network access is off
  (`REJECT_ALL` in `dumpsys netpolicy`), because netd then refuses its DNS. Allow network
  access in its app settings.
* Updating OpenEUICC as a `/data/app` install cannot load the in-ROM `liblpac-jni.so`.
  Test changes with a Magisk overlay of the `/system_ext` files instead.
* One carrier profile's APN needed changing (`patches/tree/patch_apns_usmobile.py`).
* On the one line tested, incoming calls and SMS failed on the carrier's side. The phone
  received other traffic on the same profile.

### Sensors and display

* 48 sensors are present since the SCP fix. The proximity sensor is absent from the
  active list at idle. That is normal: the dialer subscribes to it only during a call.
* **Auto-brightness:** the panel's `DisplayDeviceConfig` is a two-point stub with no
  curve, so the framework uses a generic one. The `warhol_display_cal` module adds a
  curve, and it is not installed at present. Two things to know:
  * An `<autoBrightness>` element without `enabled="true"` turns auto-brightness off,
    because the generated parser defaults to false.
  * The underlying problem is not the curve. The under-display light sensor reads the
    panel's own light, so brightness climbs by itself. This is unsolved.
* **Fingerprint and face work:**
  * `ueventd` must import `/system_ext/etc/ueventd.rc` for the `/dev/mi_display` node.
  * SystemUI must send Xiaomi's FOD condition commands.
  * SystemUI's `pixel_pitch` must be set (56.82) for the lock-screen glyph.
  * Settings must pass its preview surface to the face HAL instead of opening the camera.

  The patches are in `patches/fod/` and `patches/settings/`. A TEE result of
  `result=0x0, oresult=0x4` means success; oresult is the origin, not an error.

### Camera

* The camera HAL (8 cameras) works with any app.
* Xiaomi's camera app is a Magisk module, `warhol_xiaomi_camera`, and its APK is not
  redistributed. Full resolution (4096×3072, Ultra HDR) needs three things together:
  * the hidden-API allowlist;
  * the app installed as a privileged app;
  * an 11-entry privapp allowlist, which includes `SYSTEM_CAMERA` and gates Xiaomi's
    MIVI camera.
* The app contacts Xiaomi's tracking and config servers on its own. The module's
  service script rejects its uid in the `oem_out` chain. If you write rules like that:
  * set `PATH` explicitly;
  * resolve the uid from `/data/system/packages.list`;
  * delete rules with the same `--reject-with` they were added with;
  * match the package name exactly.

### Google apps

* **GApps are a Magisk module and are never built into the ROM.** Build it from
  MindTheGapps with `tools/gapps-to-magisk.sh`.
  * On Android 17, GmsCore arrives as a product APEX. Magisk cannot mount an APEX, and
    apexd will not add a new one at runtime.
  * The APEX payload is plain EROFS, and the script lays its APK out as an ordinary
    priv-app.
* **Circle to Search:**
  * ASI must be a privileged app with its full privapp allowlist (module `warhol_asi`).
  * The Play Store must **not** be on the Magisk denylist. When it is, hiding hides the
    module-mounted Google app from Play, and the on-device Lens feature never downloads.
* **Native key attestation:**
  * LineageOS leaves the remote key provisioning URL unset, so the TEE never gets keys,
    and basic integrity fails.
  * The fix is one DeviceConfig value (in REINSTALL.md). It lives in `/data`.
* **Google Messages crashes at boot on Android 15+ rules.** It starts a short foreground
  service from BOOT_COMPLETED. The workaround is
  `am compat disable 296558535 com.google.android.apps.messaging`. It lives in `/data`.

### Launcher and UI

* **The advanced grid and dock feature is module-only** (`trebuchet_advgrid`), built from
  the Launcher3 fork. The base ROM's Launcher3 is pure upstream, and the build refuses
  otherwise. Keep the module installed across every flash. Booting a launcher without it
  while the saved grid is custom can trigger Launcher3's grid migration and scramble the
  home screen.
* The UI font is Google Sans Flex, applied by an RRO, not Roboto. To replace it, replace
  both `GoogleSansFlex-Regular.ttf` and `Roboto-Regular.ttf` (module `warhol_adwaita_font`).
* Fixed in source: Kyiv added to the time zone picker (`SettingsLib` `timezones.xml`), and
  the LineageOS statistics opt-in defaulted to off.

## Build facts

* The build host, paths and session settings are in UPDATING.md, "Every session".
* **A patch that silently did not apply cost eSIM once.** On 24.0, `patch_tree`'s inputs
  were missing, and every step skipped without a word. Run `patch_report.sh` on the first
  build after every resync.
* **Build 24.0 with `WARHOL_RELEASE=cp2a`.** The 23.2 value `bp4a` still resolves, but it
  builds with none of LineageOS's flag values.
* **`ro.debuggable=0` appears twice in `system.img`.** The second copy, in
  `tradeinmode.rc`, is a trigger that stops adbd. Only patch the `build.prop` line;
  `tools/patch_debuggable.py` does this, anchored on newlines.
* **Stock images are EROFS, which compresses file contents.** A grep that finds nothing
  in a raw stock image proves nothing. Extract first: `lpunpack`, then
  `fsck.erofs --extract` or `dump.erofs --cat`.
* **Building the vendor from source is not possible on Android 17.** The vendor snapshot
  mechanism is gone, and the A16 HAL blobs crash against A17 core libraries. Ship the
  stock vendor plus our policy, as above.

## Upstreaming status

Official LineageOS support is blocked on:

1. **Kernel modules built from source.** The charter allows Google's prebuilt GKI, but
   vendor modules must be built from source. Xiaomi published warhol's module and
   device-tree source as `MiCode/MTK_kernel_device_modules` and `MiCode/MTK_kernel_modules`,
   branch `bsp-warhol-w-oss`. It covers 515 of the 545 vendor modules by name. 28
   GPL-licensed Xiaomi modules have no source; a request was filed on 2026-09-18 as an
   issue on `MiCode/MTK_kernel_device_modules`. Nothing has been built from that source
   yet.
2. **An unmodified vendor image.** Ours injects CIL into the stock image. Upstream would
   build vendor from the stock blobs with `sepolicy_vndr`.
3. **Branch.** No device is official on 24.0 yet; new devices go in on 23.2.
4. **Recovery and A/B OTA validation.** This unit cannot validate either: slot `_b` has
   no bootloader, and its firmware is not retail. It would take a second, stock Global
   unit.

The closest template is LineageOS's `android_device_motorola_mt6879-common`.

## Open items

* VoWiFi (modem side; see above).
* IMS on the second SIM (MediaTek capability switch).
* Auto-brightness feedback from the panel's own light.
* The three residual vendor denials.
* Vendor and firmware SPL stuck at 2026-02-01, until a newer Xiaomi Global release is
  adopted.
* TWRP cannot sideload our OTAs (see the TWRP repository's `docs/TWRP-OTA-SIGNING.md`);
  the flash procedure does not need it.

## Documents that are out of date

These predate what they describe and have not been rewritten. Where they disagree with
this file, this file is newer:

* **Device tree `docs/FLASHING.md` and `docs/RELEASING.md`** describe flashing `super`
  from the bootloader and keeping dm-verity on with our own vbmeta key. This unit's LK
  refuses that vbmeta, so `vbmeta_a` is `flags=2` and dm-verity is off. Updates write
  the three partitions from TWRP (UPDATING.md).
* **Device tree `docs/TELEPHONY.md`** plans VoWiFi through MediaTek's framework
  injection. Injection is not viable, and VoWiFi is blocked in the modem (above).
* **Device tree `README.md`,** "Open items", says the stock GKI kernel is reused. Since
  2026-09-18 it is Google's r38.
