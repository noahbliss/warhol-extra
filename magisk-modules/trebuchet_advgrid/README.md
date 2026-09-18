# trebuchet_advgrid

Optional Trebuchet features, kept out of the base ROM on purpose: an advanced grid
(up to 15x17), a dock toggle that gives the dock row back to the grid, an icon-size
setting, and removal of an empty first page. The module replaces the whole
`Launcher3QuickStep` APK, so it is built from source rather than stored here:

- source: branch `lineage-24.0` of github.com/noahbliss/android_packages_apps_Launcher3,
  based on the LineageOS revision the ROM uses
- build: `./remote-build.sh advgrid-module v9` (see `remote/remote-build.sh`), which
  builds the APK, writes `module.prop` and zips the module

Rebuild it whenever a LineageOS resync moves Launcher3, after rebasing the branch.
