> **Not included here:** `MiuiCamera.apk` is Xiaomi's proprietary app and is not
> redistributed. Extract it from the stock Global `product` image
> (`/priv-app/MiuiCamera/MiuiCamera.apk`) and place it at
> `system/priv-app/MiuiCamera/MiuiCamera.apk` in this module before zipping.

# MiuiCamera stock as a second camera app (WS2)

Installs the **unmodified stock MiuiCamera** (6.3.008790.1, `com.android.camera`,
arm64) on LineageOS 24.0 / Android 17 (warhol) as a second camera app next to
Aperture, together with the per-package hidden-API exemption it needs to launch.

## What is in the zip

```
system/app/MiuiCamera/MiuiCamera.apk                  <- PLACEHOLDER, see below
system/etc/sysconfig/miuicamera-hiddenapi.xml          <- the launch fix
system/etc/default-permissions/miuicamera-defaults.xml <- camera/mic/location grants
module.prop, customize.sh
alt-privapp/                                           <- optional priv-app variant (inactive)
```

No `system.prop`, no `.rc` files. The hidden-API exemption is policy, not a
property: `SystemConfig` reads the sysconfig XML at boot and PackageManager
turns it into `HIDDEN_API_ENFORCEMENT_DISABLED` for this package at scan time.
No property can do that per-package (a global `hidden_api_policy` setting
exists but was deliberately not used - see OUT/shim-design.md).

## The APK is included (v1.0)

`system/app/MiuiCamera/MiuiCamera.apk` is the real stock Global-ROM APK,
extracted from `warhol-stock/product_a.img` (`/priv-app/MiuiCamera/`,
EROFS) on the build host. Provenance is exact: its `classes.dex`,
`classes2.dex`, `classes7.dex` and `AndroidManifest.xml` sha256-match the
files this whole analysis was performed on. If you ever replace it, check
first:

```
tools/verify-apk.sh /path/to/MiuiCamera.apk     # package must be com.android.camera
tools/build-module.sh /path/to/MiuiCamera.apk   # copies it in and re-zips
```

`customize.sh` refuses to install a placeholder-sized or structurally invalid
APK. The stock `oat/arm64/MiuiCamera.{odex,vdex}` next to the APK in the ROM
image are deliberately NOT shipped — they are compiled against HyperOS's boot
image and would be ignored at best.

## Install

1. Copy the rebuilt zip to the phone, install it in the Magisk app, reboot.
   (The module is systemless: remove it in Magisk + reboot to fully undo.)
2. Two "Camera" entries will be in the launcher. Aperture stays wherever it
   was; any IMAGE_CAPTURE default you had set is untouched - this module
   registers no preferred-activity. If a chooser now appears for camera
   intents, that is Android asking, not this module grabbing.
3. First launch of MiuiCamera: expect the runtime permission flow (or the
   default grants above) and a first frame.

## Why the sysconfig file is the fix (short version)

MiuiCamera wraps its resources at app start ("ResGuard",
`Pe/*` + `Ik/c` classes) by reflecting into `android.app.ResourcesManager`.
On AOSP 17 those members are greylisted at `max-target-o`, so for this
targetSdk-35 app they are invisible to reflection and the app dies at first
Activity creation with exactly:
`NoSuchMethodException: Method getOrCreateActivityResourcesStructLocked with
parameters [interface android.os.IBinder] not found in null`.
The method exists; it is only hidden-API-blocked. A system-partition install
of `com.android.camera` plus `hidden-api-whitelisted-app` disables enforcement
for that one package and the hook resolves. Full chain of evidence:
`OUT/crash-path.md`, design and fallbacks: `OUT/shim-design.md`.

## Known limits (measured or inferred - labeled)

- Signature/privileged permissions are NOT granted in this layout. Measured
  cost table in OUT/shim-design.md. `MANAGE_EXTERNAL_STORAGE` and
  `WRITE_SETTINGS` carry the `preinstalled` flag and are granted to system
  image apps automatically.
- The app's dex references native libs that are not in the base APK's
  `lib/arm64-v8a` (arcsoft/morpho/mimoji/CNamaSDK...). Inference: these are
  feature paths, guarded by availability checks; if a specific mode
  (beauty/mimoji/panorama) crashes, that is why. Not launch-relevant.
- HAL-side client gating (WS1's `sessionparams.clientName` question) may still
  hand this app a degraded pipeline even when it launches fine - that is
  WS1's problem, not fixed by anything in this module.

## Do NOT

- Flash the zip while the placeholder APK is in it (the installer aborts, but
  do not bypass customize.sh).
- Use the priv-app variant without reading alt-privapp/README.md
  (boot-halting allowlist enforcement).
- Expect the module to survive an OTA that re-checks system apps: it is
  systemless and OTA-transparent, but if a future ROM ships its own
  `com.android.camera`, uninstall this first (customize.sh checks).
