# warhol-extra

Extra bits for the LineageOS 24 (Android 17) port to the Xiaomi 17T Pro (**warhol**, MT6993)
that don't belong in the device or vendor trees — mostly Magisk modules that customize a running
build. The device/vendor trees live in `android_device_xiaomi_warhol` and
`android_vendor_xiaomi_warhol`.

All modules default to **off / stock behavior** unless noted, and each is reversible by disabling
the module in Magisk. A `/data` wipe removes `/data/adb/modules`, so re-flash these afterward.

## Modules

### `magisk-modules/warhol_display_cal`
First-pass auto-brightness calibration. The stock `DisplayDeviceConfig` on this panel is a bare
2-point linear stub with no `<autoBrightness>` curve, so the framework falls back to a generic
lux→brightness curve that over/undershoots. This overlays `/vendor/etc/displayconfig/display_id_*.xml`
with a smooth 14-point lux→brightness curve (and `enabled="true"`, which the generated DDC parser
requires explicitly). Tune the curve to taste.

### `magisk-modules/warhol_selinux_enforce`
Flips SELinux to **Enforcing** early (in `post-fs-data`, before zygote/system_server) instead of the
~46s-into-boot the naive approach gives. The device's `vendor_boot` bootconfig forces
`androidboot.selinux=permissive` (inherited eng image), so this applies allow-rules for the eng-vendor
boot-denial surface via `magiskpolicy --live` and then `setenforce 1`. Includes bootloop self-heal
(auto-reverts to permissive after 2 failed enforcing boots) and a `touch /data/adb/no_enforce`
kill-switch. Rules cover the captured boot denial surface only.

### `magisk-modules/warhol_adwaita_font`
Replaces the system UI font with **Adwaita Sans** (GNOME's Inter-based variable font, full weight
axis). The LineageOS build renders in Google Sans Flex via an RRO overlay, so this overlays both
`/product/fonts/GoogleSansFlex-Regular.ttf` (body/headline) and `/system/fonts/Roboto-Regular.ttf`
(`sans-serif`). Personal preference; not something LineageOS would ship. Adwaita Sans is licensed
under the SIL Open Font License (see `magisk-modules/warhol_adwaita_font/LICENSE-Adwaita`).

## Launcher

The Trebuchet (Launcher3) changes — arbitrary grid up to 15×17, a dock toggle that reclaims the
hotseat row, and an icon-size lever — are maintained as a proper source fork of LineageOS Trebuchet
(see the `android_packages_apps_*` fork), which is the upstreamable form. A prebuilt Magisk overlay
of that build can be produced from the fork for devices that aren't rebuilding the ROM.

## License

Module code here is Apache-2.0 (matching AOSP/LineageOS). Bundled third-party assets keep their own
licenses (Adwaita Sans: OFL).
