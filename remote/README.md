# Building warhol on the Debian build host

The macOS path (`docker/`) still works, but it is the slow, fragile one: Rosetta
segfaults host tools at random and a 24 GiB VM starves a 36 GiB laptop. This
directory is the build host equivalent — native x86_64, 32 cores, 124 GB RAM.

## Layout on the host

Everything lives on the 4TB drive. The root filesystem has ~31 GB free, which a
120 GB tree and a 60 GB `out/` would obliterate:

```
/run/media/local/4TB/warhol-los/
├── containers/   podman graphroot + runroot  (image pulls land here, not on /)
├── src/          the LineageOS tree
├── device/xiaomi/warhol/   android_device_xiaomi_warhol, bind-mounted into the build
├── warhol-extra/           this repo (scripts, patches for other projects, modules)
├── ccache/  tmp/  out/
```

Two things to know about that drive:

* It is **LUKS**, so `/dev/mapper/...` is a UUID that identifies nothing useful.
  Always address it by mount point. `remote-build.sh` refuses to run if it is not
  mounted, rather than silently filling the root filesystem when the volume is
  locked.
* The host's normal podman store (`~/.local/share/containers`) already holds
  ~293 GB of unrelated images. We use a **project-scoped** `storage.conf` so our
  layers land on the 4TB and the existing images are left alone. Every podman
  command here needs `CONTAINERS_STORAGE_CONF` set; the scripts do it for you.

## Scripts

| script | what it does |
| --- | --- |
| `remote-build.sh` | one stage: `sync`, `config`, `build`, `apex-sign`, `shell`, `status` |
| `pipeline.sh` | runs sync → config → build unattended, with retries |
| `probe.sh` | prints one compact line describing the whole pipeline |
| `watch-pipeline.sh` | polls `probe.sh` and emits a line per meaningful change |

### Deploying script changes

The scripts that *run* live at `$P/remote-build.sh` and `$P/bin/`, while the
source of truth is this directory and `../tools/` in warhol-extra. They are
separate files and they drift silently — a `patch_tree` fix once sat in the tree
for a whole build cycle while the deployed copy ran the old logic, and the build
failed on exactly the thing the fix addressed. `remote-build.sh` now warns when it
differs from the tree copy, but the deploy is manual:

```bash
scp remote/remote-build.sh   user@build-host:/run/media/local/4TB/warhol-los/
scp tools/*.sh               user@build-host:/run/media/local/4TB/warhol-los/bin/
```

Two more live in `$P/bin` on the host, deployed from `../tools/`:

| script | what it does |
| --- | --- |
| `gen-apex-keys.sh` | `gen` the per-APEX key pairs, `verify` them, `verify-signed` a build |
| `build-super.sh` | assemble a flashable `super.img` from built + stock partitions |

### The release sequence

```bash
./remote-build.sh build                                     # mka bacon
./remote-build.sh apex-sign                                 # re-sign + signed OTA
./bin/build-super.sh --target-files out/warhol-signed-target_files.zip
./bin/gen-apex-keys.sh verify-signed                        # 34/34, or it is not done
```

`apex-sign` exists because `PRODUCT_DEFAULT_DEV_CERTIFICATE` re-signs APKs during
the build but never touches APEXes that carry their own in-tree keys — 33 of the
36 here were still on AOSP's public ones. It builds `target-files-package` first,
because `bacon` does not leave a target_files zip behind.

**Keys live in `$P/keys`, outside the tree**, and `install_keys` copies them in at
build time — including `keys/apex`, because `sign_target_files_apks` runs inside
the container and the container mounts the tree, not the key store.

Long-running work goes in the **`warhol-los`** tmux session, never the host's
existing session `0`:

```bash
tmux attach -t warhol-los          # window: pipeline
./remote-build.sh status
cat out/STATUS
```

## Why a pipeline and a watcher rather than running mka by hand

Because a 150,000-target build fails in the middle and nobody notices. The
pipeline retries a failed stage but **stops when the same target fails twice**,
since that is deterministic and a retry only burns another Soong analysis. It
writes `out/STATUS` at every transition so a watcher can distinguish "still
working" from "finished" from "broken" without parsing logs.

`watch-pipeline.sh` deliberately emits on failure signatures as well as progress —
a crashed pipeline (`alive=no` while `state=running`), an unreachable host, and a
finished build all produce output. A watcher that only reports success is
indistinguishable from a watcher that has silently died.
