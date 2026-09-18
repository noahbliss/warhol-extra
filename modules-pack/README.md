# modules-pack

**Do not flash this on warhol.** It stages Magisk modules into `/data/adb/modules` from
TWRP before the first boot, which boot-loops this phone:

* The first boot applies the file-based encryption policy to `/data/adb`, which must be
  empty.
* With modules staged there, init fails with "Directory not empty" and reboots into
  recovery, every time. Formatting `/data` again ends the loop.
* After the first boot, `/data` is encrypted with keys TWRP can never have, so there is
  no later point at which TWRP could stage modules either.

Install modules from the running OS after the first boot instead:
[docs/REINSTALL.md](../docs/REINSTALL.md), steps 5 and 6.

The pack, its `build.sh` and its smoke test (`test/`) are kept as a working reference for
devices where TWRP stages into an unencrypted or decryptable `/data`.
