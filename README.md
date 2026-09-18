# warhol-extra

Everything for the LineageOS 24.0 (Android 17) port to the Xiaomi 17T Pro (**warhol**,
MT6993) that does not belong in the device or vendor trees
([`android_device_xiaomi_warhol`](https://github.com/noahbliss/android_device_xiaomi_warhol),
[`android_vendor_xiaomi_warhol`](https://github.com/noahbliss/android_vendor_xiaomi_warhol)):
the build scripts, the patches this port applies to other LineageOS projects, and the Magisk
modules for optional features.

## Layout

| path | what it is |
| --- | --- |
| `remote/` | `remote-build.sh` and friends: sync, patch, build, sign on the Linux build host (see `remote/README.md`) |
| `docker/` | the older macOS/colima build environment |
| `docs/` | `UPDATING.md` (ROM and kernel updates), `REINSTALL.md` (wipe, reinstall, Google restore), `DEVICE-NOTES.md` (this phone's state, rules, and every hard-won finding) |
| `tools/` | the update tools (`update_check.sh`, `resync.sh`, `patch_report.sh`, `save_build.sh`, `policy_check.sh`), GKI kernel updates (`gki_update.py`, `cpio_drop.py`), flashing (`flash_three.sh`), post-flash checks, debuggable-props patch, GApps as a Magisk module (`gapps-to-magisk.sh`), APEX keys, IMS extraction |
| `patches/<area>/` | git-format patches for other LineageOS projects (FOD, face enrollment, SystemUI, Launcher3) with their `BASE_COMMIT` |
| `patches/tree/` | the scripted fixes `remote-build.sh` applies to the source tree: eSIM (OpenEUICC/lpac, telephony), APNs, status-bar and Messaging cutout, Kyiv timezone, stats default off |
| `magisk-modules/` | optional features as Magisk modules |
| `modules-pack/` | a TWRP-flashable zip that stages modules before first boot; **boot-loops warhol**, see its README |

`remote-build.sh` expects this repo at `$WARHOL_ROOT/warhol-extra` (override with
`WARHOL_EXTRA`) and refuses to patch the tree without it.

## Keeping the ROM current

[`docs/UPDATING.md`](docs/UPDATING.md) is the update procedure: check for a new security
patch level, resync, build, verify every warhol fix applied, check the boot-time SELinux
policy, flash, verify, and roll back if needed. Run it at least quarterly. Its
"Updating the kernel" section moves the phone to a newer Google GKI build of the same KMI
generation, checked against every vendor module first.

Before any work on the phone itself, read [`docs/DEVICE-NOTES.md`](docs/DEVICE-NOTES.md):
it has been bricked twice, and the rules there are why it has not been a third time.
[`docs/REINSTALL.md`](docs/REINSTALL.md) is the wipe-and-reinstall procedure.

## Modules

Modules hold features that stay **out of the base ROM** on purpose: personal preferences,
Google components, and proprietary apps.

| module | what it does |
| --- | --- |
| `warhol_adwaita_font` | Adwaita Sans as the UI font (OFL) |
| `warhol_display_cal` | a smooth auto-brightness curve for this panel (`/vendor` DisplayDeviceConfig overlay) |
| `trebuchet_advgrid` | advanced grid, dock toggle, icon size, empty-first-page removal; built from the Launcher3 fork (see its README) |
| `warhol_xiaomi_camera` | Xiaomi's camera app as a second camera, with the hidden-API and privapp policy it needs |
| `warhol_aicore`, `warhol_asi` | Google AiCore and Android System Intelligence (for Circle to Search) |

The camera, AiCore and ASI modules are **scaffolding only**: their APKs are Xiaomi's or
Google's and are not redistributed. Each module's README says where to extract the APK from
the stock firmware. `build-zips.sh` zips every module under `magisk-modules/`.

## License

Scripts and module code are Apache-2.0 (see `LICENSE`). Bundled third-party assets keep
their own licenses (Adwaita Sans: OFL).
