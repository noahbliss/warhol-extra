# Wiping and reinstalling warhol

How to wipe `/data`, put a known-good build back, and restore apps and data from Google's
cloud backup. Routine updates do not need any of this; they keep `/data`
([UPDATING.md](UPDATING.md)). Wipe only when you have to: after a failed branch bump, when
the signing keys are lost, or when `/data` itself is broken.

**Nothing on the phone can be backed up from TWRP.** `/data` is metadata-encrypted with
keys bound to the boot chain, and TWRP can never read it (see the TWRP repository's
`docs/ENCRYPTION.md`). What survives a wipe is what the apps themselves back up:
Google's device backup, Photos, each app's own cloud sync. Check those before you start.
2FA seeds and hardware security keys have to be re-enrolled, not restored.

Everything runs from the build host (awe), with the phone plugged into it, in the session
set up by UPDATING.md, "Every session". Steps marked **[phone]** need someone at the
device.

Last run end to end: 2026-09-17. Reviewed against the phone's state on 2026-09-19.

## 0. Rules for this procedure

The full list, with the reason for each, is in
[DEVICE-NOTES.md](DEVICE-NOTES.md#rules-and-why-each-exists). The ones that matter here:

* Write one partition at a time, and verify each on the phone before the next.
* Enter TWRP with the button combination only, never `adb reboot recovery`.
* Slot `_a` only. Never sideload the OTA zip.
* At most two power cycles of a phone that does not boot; then fastboot.

## 1. What changes, and what does not

**Written:** `system_a`, `system_ext_a` and `product_a` (if the build is not already on
the phone), then `/data` is formatted.

**Not touched,** and all of it survives a `/data` wipe:

| partition | holds |
| --- | --- |
| `boot_a`, `system_dlkm_a` | the GKI kernel and its modules |
| `vendor_boot_a` | TWRP, and the enforcing bootconfig |
| `vendor_a` | stock vendor plus our SELinux policy |
| `init_boot_a` | Magisk |
| `vbmeta_a` | `flags=2` |
| `lk`, preloader, firmware | |
| `nvdata`, `nvcfg`, `protect1`, `protect2` | IMEI and RF calibration |

SELinux stays Enforcing, because that comes from `vendor` and `vendor_boot`, not from
`/data`. eSIM profiles live on the eUICC chip and survive as well.

**Lost with `/data`:** every Magisk module and the Magisk app's setup, every setting
below that is marked "lives in `/data`", and your accounts.

## 2. What you need

* **The build:** `builds/<name>/` with its `SHA256SUMS`. As of 2026-09-19 the phone runs
  `builds/20260918-clean-base`.
* **Magisk:** `/run/media/local/4TB/warhol-rescue/Magisk-v30.7.apk`. It must be the
  version `init_boot_a` was patched with.
* **Modules,** in `warhol-modules/`:

  | module | zip | notes |
  | --- | --- | --- |
  | GApps | `MindTheGapps-17.0.0-arm64-20260828_065753-magisk.zip` | install first; built by `tools/gapps-to-magisk.sh` |
  | Xiaomi camera | `warhol_xiaomi_camera.zip` | the privileged version (2026-09-17) |
  | UI font | `adwaita_font.zip` | |
  | AiCore | `warhol_aicore-v1.zip` | Circle to Search |
  | ASI | `warhol_asi-v1.zip` | Circle to Search |
  | advanced grid | the newest `trebuchet_advgrid_v<N>.zip` (v9 on 2026-09-19) | must match the build's Launcher3 |
  | auto-brightness curve | `warhol_display_cal.zip` | optional; not installed on 2026-09-19, see DEVICE-NOTES.md |

  Any Play Integrity or root-hiding modules you use are your own; they are not part of
  this kit.

**Do not use `warhol-modules-pack.zip`.** It stages modules before the first boot, and
on this phone that is a boot loop (step 5).

## 3. Flash the build, and boot it before wiping

Skip this step if the phone already runs the build you are reinstalling.

1. **[phone]** Enter TWRP with the button combination.
2. Write the three partitions:
   ```bash
   bash warhol-extra/tools/flash_three.sh builds/<name>     # ends with ALL_VERIFIED
   adb reboot
   ```
3. **Boot it while `/data` is still intact.** Check that it reaches the launcher,
   `getenforce` says Enforcing, and `adb shell su -c id` works. If it does not boot
   cleanly, stop here: TWRP and fastboot are intact, and the old data is too. Fix
   forward or flash the previous build. The wipe is the one step that cannot be undone.

## 4. Format `/data`

1. **[phone]** Enter TWRP with the button combination.
2. Format, then reboot:
   ```bash
   adb shell twrp format data
   adb reboot
   ```

Use `format data`, not a wipe from the GUI. The first boot has to find an empty `/data`
to set up encryption.

## 5. First boot, then Magisk

**Put nothing into `/data/adb` before this boot.** init applies the encryption policy to
`/data/adb` on the first boot, and that needs the directory empty. With modules already
staged there it fails ("Directory not empty") and reboots into recovery, every time. The
fix for that loop is to format again.

1. **[phone]** Get through setup far enough to turn on Developer options and USB
   debugging. Skip the Google account and restore for now; GApps are not installed yet.
2. Install the Magisk app:
   ```bash
   adb install /run/media/local/4TB/warhol-rescue/Magisk-v30.7.apk
   ```
3. **[phone]** Open Magisk, accept "Requires additional setup", and let it reboot. This
   has no command-line equivalent. Check afterwards that
   `adb shell su -c 'magisk -V'` prints `30700`.

## 6. Modules

GApps first:

```bash
cd warhol-modules
for z in MindTheGapps-17.0.0-arm64-20260828_065753-magisk.zip warhol_xiaomi_camera.zip \
         adwaita_font.zip warhol_aicore-v1.zip warhol_asi-v1.zip trebuchet_advgrid_v9.zip; do
    adb push "$z" /data/local/tmp/ && adb shell su -c "magisk --install-module /data/local/tmp/$z"
done
adb reboot
```

After the reboot, `adb shell su -c 'ls /data/adb/modules'` should list each of them, with
no `disable`, `remove` or `update` file inside. If one is still sitting in
`/data/adb/modules_update/`, move it to `/data/adb/modules/<id>/` by hand
(root:root, 0755 directories, 0644 files) and reboot again.

Then install your own Play Integrity setup, if you use one. Two things from this port
matter for it:

* **The Play Store must not be on the Magisk denylist.** If it is, Circle to Search never
  activates.
* **Remote key provisioning is off in LineageOS** until the URL is set. Without it, native
  key attestation and basic integrity fail. It lives in `/data`:
  ```bash
  adb shell su -c 'device_config put remote_key_provisioning_native url "https://remoteprovisioning.googleapis.com/v1"'
  ```

## 7. Restore from Google's backup

The restore screens that setup offers ("Copy apps & data", then a backup from the cloud)
**hang forever on this ROM** at "Just a few moments…". Re-arming the setup wizard does not
help either. The restore works from the command line instead:

1. **Turn off key-attestation modules** for the duration, if you run any. Key recovery is
   attestation-gated. Put a `disable` file in each module's directory and reboot; turn
   them back on at the end.
2. **Sign in to the Google account** in Settings. Check that GmsCore's checkin succeeds;
   clearing GmsCore's data earlier can leave an account with a token but no credential.
   If so, remove the account and sign in again.
3. **Turn on the backup service:**
   ```bash
   adb shell bmgr enable true; adb shell bmgr activate true; adb shell bmgr autorestore true
   ```
4. **Set GmsCore's backup account.** Run
   `adb shell am start -n com.google.android.gms/.backup.SetBackupAccountActivity`, pick
   the account, and turn backup on. `adb shell dumpsys backup` should then show the
   account for `com.google.android.gms/.backup.BackupTransportService`.
5. **Mark the device provisioned,** and restart Play, which caches the flag:
   ```bash
   adb shell settings put global device_provisioned 1
   adb shell settings put secure user_setup_complete 1
   adb shell am force-stop com.android.vending
   ```
6. **Recover the backup's encryption key.** Grant GmsCore the Bluetooth permissions the
   flow needs, then start the restore flow directly:
   ```bash
   for p in BLUETOOTH_CONNECT BLUETOOTH_SCAN BLUETOOTH_ADVERTISE; do
       adb shell pm grant com.google.android.gms android.permission.$p
   done
   adb shell am start -a com.google.android.apps.pixelmigrate.ACTION_CLOUD_RESTORE_FLOW \
       -n com.google.android.apps.restore/com.google.android.apps.pixelmigrate.cloudrestore.component.CloudRestoreFlowActivity
   ```
   **[phone]** Pick the old device's **encrypted** backup, and enter that device's
   screen-lock PIN or password when asked. The log shows
   `Key recovery using key retrieval client was successful`. The screen then hangs on
   "Just a few moments…"; leave it.
7. **Find the restore token.** `adb shell bmgr list sets` now lists the backups. The
   token is the old device's Android ID in hex. The restore flow logs it as
   `onDeviceSelected(). device.androidId = <decimal>`; convert it with `printf %x`.
8. **Restore:**
   ```bash
   adb shell bmgr restore <token> --monitor
   ```
   This restores system data at once: SMS and MMS, call log, Wi-Fi networks and
   settings. It also records the backup as this device's ancestral set. That makes Play
   start its own restore service, which reinstalls every app from the backup and
   restores each app's data as it installs. Keep the phone on Wi-Fi and power until the
   "Installing apps" notification reaches its total.

A restore also brings back the old device's brightness mode, often manual. Set it back to
automatic afterwards.

## 8. Settings that live in `/data`

Re-apply these after every wipe:

* **Google Messages** crashes at boot without this override:
  ```bash
  adb shell am compat disable 296558535 com.google.android.apps.messaging
  ```
* **OpenEUICC** needs network access for eSIM downloads. If Settings shows its mobile
  data access as off, allow it; an eSIM download otherwise fails as
  "Unknown SM-DP+ address".
* **eSIM:** the profile is still on the chip. Enable it in Settings > SIMs.
* **Fingerprint, face and screen lock:** enroll again.
* **Mobile data off** although airplane mode is off: see UPDATING.md, Troubleshooting.

## 9. Verify

```bash
bash warhol-extra/tools/postflash_check.sh        # 16 pass, after the first PIN unlock
```

Then check by hand:

* SELinux Enforcing
* 48 sensors, auto-brightness and proximity during a call
* a call with data still up (VoLTE), and SMS both ways
* mobile data on both SIMs
* Xiaomi camera at full resolution on every lens
* fingerprint and face unlock
* the home screen grid and dock
* the UI font
* Circle to Search

## 10. If a step fails

| failure | what to do |
| --- | --- |
| the new build does not boot (step 3) | `/data` is intact. In TWRP, flash the previous `builds/` directory with `flash_three.sh`. |
| boot loop into TWRP after the format | something was staged into `/data/adb`, or `/data` was not formatted cleanly. Run `twrp format data` again. |
| every boot lands in TWRP | the `misc` partition holds `boot-recovery`; see DEVICE-NOTES.md, "Getting back from a bad state". |
| Magisk broken | `fastboot flash init_boot_a /run/media/local/4TB/warhol-rescue/init_boot_a.magisk30.7.img` |
| Android and TWRP both hang at the logo | the kernel or `vbmeta`, not this procedure. See UPDATING.md, "Updating the kernel". |

Never answer a boot failure by power-cycling again and again.
