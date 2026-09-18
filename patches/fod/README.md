# warhol optical fingerprint (FOD)

LineageOS replaces Xiaomi's system partition, and two things the fingerprint stack
needs lived there. Without either one the sensor never lights and never sees a
finger: enrollment hangs at the first touch and unlock never fires. The vendor HAL,
the TEE and the goodix TA are all healthy the whole time.

The runtime fix was proven on device on 2026-09-18: enrollment completed, and
unlock matches in 8-13 ms.

## 1. ueventd: `/dev/mi_display`

Stock's system `ueventd.rc` has

    subsystem mi_display
        devname uevent_devpath
        dirname /dev/mi_display
    /dev/mi_display/*   0666 root graphics

and LineageOS's does not, so the display-feature node lands at `/dev/disp_feature`,
root:root 0600. mfp-daemon's local-HBM path opens `/dev/mi_display/disp_feature`
(ioctl 0x440e) and fails with `setLocalHBM, invalid parameter`.

On Android 12+ ueventd reads only `/system/etc/ueventd.rc`, which imports
`/vendor/etc/ueventd.rc` (stock; it lacks the rule) and `/odm/etc/ueventd.rc`
(does not exist). warhol keeps the stock vendor, so the rule has to come from a
partition we build:

* `0001-ueventd-import-system_ext-rules.patch` (system/core) adds
  `import /system_ext/etc/ueventd.rc`. A missing file is skipped, as with odm.
* `rootdir/etc/ueventd.rc` in the device tree carries the rule and is installed to
  `/system_ext/etc/ueventd.rc`.

`vendor_file_contexts` already labels the node `vendor_displayfeature_device`, and
`/system_ext/etc` is `system_file`, the same label as `/system/etc/ueventd.rc`, so
no sepolicy change is needed on either side.

## 2. FOD condition updates

`vendor.xiaomi.hardware.fingerprintextension.IXiaomiFingerprint/default` (served by
mfp-daemon) has `int extCmd(int cmd, int param)` as transaction 1. Commands 1-8
feed `FodEngineCore::fingerprintConditionUpdate(stateIndex, value)`. MIUI's
framework sends these conditions and AOSP has nothing equivalent, so the daemon
logs `skip enable lhbm as fingerprint is idle` forever.

From the daemon's `checkFodTouchStatus` (it logs
`FP gxzwAnim colorfade lockoutmode powermode TouchEnable`):

| cmd | condition | effect |
|-----|-----------|--------|
| 1 | gxzwAnim, the FOD UI is showing | master gate: touch FOD is off unless it is 1 |
| 2 | colorfade | while powermode is 2 and colorfade is 1, touch FOD holds its last state |
| 3 | powermode | when it is not 2, touch FOD follows gxzwAnim alone |
| 4 | FP state | 1 or 3 = running: arms LHBM and (when powermode is 2) touch FOD. Anything else = stopped: logs `LHBM_TARGET_BRIGHTNESS_OFF_AUTH_STOP` and turns LHBM off |
| 5 | lockoutmode | while powermode is 2 and colorfade is 0, nonzero forces touch FOD on |

LHBM additionally requires the HAL to be inside an enroll or authenticate session,
so an armed sensor outside one does nothing.

`0002-SystemUI-Xiaomi-FOD-condition-updates.patch` (frameworks/base) adds
`XiaomiFodConditionNotifier`, driven from `UdfpsController`'s overlay show/hide,
which brackets every UDFPS operation (enrollment, keyguard, BiometricPrompt):

* shown:  `extCmd(4, 1)`, then `extCmd(1, 1)`
* hidden: `extCmd(1, 0)`, then `extCmd(4, 2)`

The calls run on SystemUI's single-threaded biometrics executor, so they stay in
order, and they look the binder up each time because a daemon restart replaces
it. The notifier is off unless `config_xiaomiFodConditionUpdates` is true, which
warhol's SystemUI overlay sets. The stock vendor policy already allows
`platform_app` (SystemUI) to find `vendor_hal_fingerprint_service_xiaomi` and
binder-call `hal_fingerprint_default`; MIUI's own SystemUI used it the same way.

## Runtime equivalent (root, lost on reboot)

    mkdir -p /dev/mi_display
    mknod /dev/mi_display/disp_feature c 503 0
    chown root:graphics /dev/mi_display/disp_feature
    chmod 0666 /dev/mi_display/disp_feature
    restorecon -R /dev/mi_display
    setprop ctl.restart mfp-daemon
    service call vendor.xiaomi.hardware.fingerprintextension.IXiaomiFingerprint/default 1 i32 4 i32 1
    service call vendor.xiaomi.hardware.fingerprintextension.IXiaomiFingerprint/default 1 i32 1 i32 1

(503:0 is this boot's major:minor. Check it with `ls -l /dev/disp_feature`.)

## Related, not in these patches

The lock-screen fingerprint glyph was garbled because SystemUI's `pixel_pitch` was
unset (default -1). It is set in `overlay/frameworks/base/packages/SystemUI/res/values/dimens.xml`.
