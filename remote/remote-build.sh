#!/usr/bin/env bash
# =============================================================================
# remote-build.sh — LineageOS 23.2 for warhol, on the Debian box.
#
#     ./remote-build.sh sync     repo init + sync   (long; run under tmux)
#     ./remote-build.sh build    lunch + mka bacon  (long; run under tmux)
#     ./remote-build.sh sepolicy  m selinux_policy only (cheap policy check)
#     ./remote-build.sh apex-sign  re-sign with our APEX keys + build a signed OTA
#     ./remote-build.sh shell    interactive shell in the build container
#     ./remote-build.sh status   where things stand
#
# EVERYTHING lives on the 4TB drive. The root filesystem has ~31 GB free, which a
# 120 GB tree and a 60 GB out/ would obliterate, so the container store, the
# source tree, ccache and TMPDIR are all pointed at /run/media/local/4TB.
#
# The container store is deliberately SEPARATE from ~/.local/share/containers.
# That store already holds ~293 GB of ROCm toolbox images belonging to other work
# on this machine; a shared graphroot would put our layers on the root filesystem
# and mix our images in with theirs.
#
# The 4TB is LUKS (dm-crypt) so its /dev/mapper name is a UUID that changes
# nothing useful for us -- always address it by mount point, never by device.
#
# Unlike the macOS host this replaces, this machine is native x86_64 with 32 cores
# and 124 GB of RAM: no Rosetta, so no spurious segfaults, and no reason to hold
# parallelism down to -j4.
# =============================================================================
set -euo pipefail

# WARHOL_ROOT / WARHOL_BRANCH let this script drive a SECOND tree without touching
# the working one -- e.g. a lineage-24.0 port at /run/media/local/4TB/warhol-los-24
# while 23.2 stays buildable and flashable as the fallback. Everything the script
# reads lives under $P, so a second root needs: src/ (new), device/ (a copy, so the
# two can diverge), its own tmp/, and symlinks for keys/ ccache/ containers/ back to
# this root -- the platform key MUST be shared or platform-signed apps stop matching.
P="${WARHOL_ROOT:-/run/media/local/4TB/warhol-los}"
# Build tooling, the patches for other projects and the module sources live in the
# warhol-extra repo (github.com/noahbliss/warhol-extra), checked out next to the tree.
WX="${WARHOL_EXTRA:-$P/warhol-extra}"
BRANCH="${WARHOL_BRANCH:-lineage-23.2}"

# The three LineageOS helper repos in the local manifest below are DEAD WEIGHT in this
# port: nothing in the device tree references them outside comments, and
# module-info.json for build 9 installs ZERO modules from hardware/xiaomi,
# hardware/mediatek or device/mediatek. On a version bump they are worse than dead --
# soong analyzes every Android.bp in the tree, so a 23.2-era hardware/xiaomi in an
# Android 17 tree can fail analysis for a repo we never use. hardware/xiaomi has no
# lineage-24.0 branch at all. Set WARHOL_NO_LEGACY_DEPS=1 to omit all three.
NO_LEGACY_DEPS="${WARHOL_NO_LEGACY_DEPS:-}"

# The release config must follow the branch, and getting it wrong does not fail the
# build -- it builds the wrong thing. LineageOS declares exactly one config per branch
# in vendor/lineage/release/release_configs/: bp4a.textproto on lineage-23.2,
# cp2a.textproto on lineage-24.0. Google's build/release still ships the whole bp*
# series on the 24.0 tree, so `lineage_warhol-bp4a-userdebug` there still resolves --
# and picks up 0 LineageOS flag values instead of cp2a's. That is section 14's bug
# class (bp2a vs bp4a) in a new guise.
REL="${WARHOL_RELEASE:-bp4a}"
IMAGE=lineage-warhol-build
JOBS="${JOBS:-28}"          # 32 cores; leave a few for the rest of the machine

export CONTAINERS_STORAGE_CONF="$P/containers/storage.conf"
export TMPDIR="$P/tmp"

# Bail early rather than silently writing to the root filesystem.
mountpoint -q /run/media/local/4TB || { echo "ERROR: 4TB is not mounted (LUKS locked?)" >&2; exit 1; }

# --- DEVICE TREE BIND MOUNT (advisory only) ---------------------------------
# THE BUILD DOES NOT NEED THIS. run() passes the device tree into the container
# directly with `-v "$P/device/xiaomi/warhol:/aosp/device/xiaomi/warhol"`, so a
# containerized build works whether or not the host bind mount exists. Nothing
# host-side in this script reads src/device/xiaomi/warhol either.
#
# It matters only if you run `lunch`/`get_build_var` BY HAND on the host, where
# build/make locates a product by finding AndroidProducts.mk on a real path. When
# the mount is missing there, the failure names the wrong thing entirely:
#     error: Cannot locate config makefile for product "lineage_warhol".
#     panic: ... android/soong/ui/build.getProductReleaseConfigMaps
# A Go stack trace in the release-config code, for a missing mount. Cost real
# time on 2026-09-10 while validating the bp4a switch.
#
# So: warn, never sudo, never exit. An earlier version of this guard ran
# `sudo mount --bind` and `exit 1`, which risked hanging a tmux build on a
# password prompt after a host reboot for no benefit.
DT_DST="$P/src/device/xiaomi/warhol"
if ! mountpoint -q "$DT_DST" 2>/dev/null; then
    echo "note: device tree not bind-mounted at $DT_DST" >&2
    echo "      harmless for this script (the container mounts it with -v)." >&2
    echo "      needed only for host-side lunch/get_build_var:" >&2
    echo "        sudo mount --bind $P/device/xiaomi/warhol $DT_DST" >&2
fi
# ---------------------------------------------------------------------------

# --pids-limit=0 is NOT optional. Podman defaults every container to 2048 PIDs,
# and an AOSP build at -j28 blows through that the moment metalava starts: its
# Kotlin coroutine dispatcher spawns workers per core, and the JVM reports the
# limit as a misleading
#     java.lang.OutOfMemoryError: unable to create native thread
# with pthread_create failing EAGAIN -- which reads as memory exhaustion but is a
# PID cap. It cost three build attempts to spot, because each retry died on a
# DIFFERENT metalava target and so never tripped a same-target-twice check.
# The host allows ~510k processes; there is no reason for the container to cap it.
# Patches to the AOSP tree itself. These are re-applied before every build because
# `repo sync` reverts them, and they are written to be idempotent.
# Install the release signing keys into the tree before building.
#
# The canonical copy lives at $P/keys, OUTSIDE the source tree, for two reasons:
# a tree wipe or fresh sync would otherwise take the keys with it, and CI must be
# able to provision keys independently of source. The build expects them at
# vendor/lineage-priv/keys, which vendor/lineage/config/common.mk auto-includes a
# keys.mk from, and whose PATH is what makes gen_build_prop.py stamp release-keys.
install_keys() {
    local src="$P/keys" dst="$P/src/vendor/lineage-priv/keys"
    [ -d "$src" ] || { echo "NOTE: no key store at $src; build will use test keys"; return 0; }
    mkdir -p "$dst"
    cp -u "$src"/*.* "$dst"/ 2>/dev/null
    chmod 600 "$dst"/*.pk8 "$dst"/avb.pem 2>/dev/null
    # APEX keys, one payload key and one container pair per APEX. These are only
    # read by sign_target_files_apks, which runs INSIDE the container, and the
    # container mounts the tree and not the key store -- so they have to be here
    # rather than referenced from $P/keys. See tools/gen-apex-keys.sh.
    if [ -d "$src/apex" ]; then
        mkdir -p "$dst/apex"
        cp -u "$src/apex"/* "$dst/apex"/ 2>/dev/null
        chmod 600 "$dst/apex"/*.pk8 "$dst/apex"/*.pem 2>/dev/null
        chmod 644 "$dst/apex"/*.x509.pem 2>/dev/null
    fi
    # keys.conf maps the @RELEASE seinfo tag to testkey.x509.pem, while apps are
    # signed with the default certificate (releasekey). They must be the SAME key
    # or nothing signed by the platform matches @RELEASE and apps get the wrong
    # SELinux seinfo. Missing it fails the build outright:
    #   Path vendor/lineage-priv/keys/testkey.x509.pem does not exist or is not a file!
    if [ -f "$dst/releasekey.x509.pem" ] && [ ! -f "$dst/testkey.x509.pem" ]; then
        cp "$dst/releasekey.pk8" "$dst/testkey.pk8"
        cp "$dst/releasekey.x509.pem" "$dst/testkey.x509.pem"
        chmod 600 "$dst/testkey.pk8"
    fi
}

# The copy of this script that runs lives at $P/remote-build.sh, while the source
# of truth is remote/remote-build.sh inside the device tree at
# $P/device/xiaomi/warhol. They are separate files and they drift silently -- a
# patch_tree fix sat in the tree for a whole build cycle while the deployed copy
# ran the old logic, and the build failed on exactly the thing the fix addressed.
# Warn rather than auto-copy: replacing the running script mid-run is worse.
check_deployed() {
    local tree="$WX/remote/$(basename "$0")"
    [ -f "$tree" ] || return 0
    cmp -s "$tree" "$0" && return 0
    echo "WARNING: $(basename "$0") differs from the copy in warhol-extra." >&2
    echo "         deploy it before trusting this run:" >&2
    echo "           cp $tree $0" >&2
}

patch_tree() {
    # Every patch below is skipped quietly when its input is missing, which is how
    # three of them once no-opped for a whole build. Refuse to run without the repo.
    [ -d "$WX/patches/tree" ] || {
        echo "ERROR: warhol-extra not found at $WX (set WARHOL_EXTRA)" >&2; exit 1; }
    # OpenEUICC's lpac-jni compiles its C sources straight out of two git
    # submodules (estkme-group/lpac and DaveGamble/cJSON). `sync-s="true"` on the
    # project in local_manifests did NOT fetch them on repo 2.66, and
    # `repo sync --fetch-submodules` is deprecated and equally silent about doing
    # nothing -- the submodule directories simply stay empty. Soong's srcs globs
    # then match zero files and liblpac-jni fails to build, with nothing pointing
    # at the real cause. Fetch them with git, idempotently.
    local oe="$P/src/packages/apps/OpenEUICC"
    if [ -d "$oe/.git" ] && \
       ! compgen -G "$oe/libs/lpac-jni/src/main/jni/lpac/euicc/*.c" >/dev/null; then
        git -C "$oe" submodule update --init --recursive --depth 1 \
            && echo "patched: OpenEUICC lpac-jni submodules fetched"
    fi

    # A privileged in-ROM LPA cannot talk ES10 to a MEP eUICC without this.
    # PhoneInterfaceManager (CMD_TRANSMIT_APDU_LOGICAL_CHANNEL) calls the DEPRECATED
    # 8-arg UiccPort.iccTransmitApduLogicalChannel, which hardcoded
    # false /*isEs10Command*/. That flag reaches the radio HAL as msg.isEs10 and tells
    # the modem to route the APDU to the ISD-R instead of the enabled profile's
    # context. AOSP's own eUICC stack always sets it true (ApduCommand.java:63), but
    # every third-party caller got false -- so on warhol (MEP_A1) a correctly formed
    # ES10 STORE DATA came back SW 6881 "logical channel not supported" on a channel
    # that had opened with SW 9000 and a valid ISD-R FCI. The patch derives the flag
    # from the AID the channel was opened against.
    # frameworks/opt/telephony is a synced project, so repo sync reverts this.
    if [ -f "$WX/patches/tree/patch_uiccport.py" ]; then
        python3 "$WX/patches/tree/patch_uiccport.py" \
            && echo "patched: UiccPort isEs10Command derived from channel AID"
    fi

    # OpenEUICC deadlocks its own UI on this device. connectSEService() holds a
    # non-reentrant Mutex across the SEService constructor, but the executor it passes
    # is inline, so when the platform SecureElement service is already running (warhol
    # registers eSE1) onConnected fires SYNCHRONOUSLY from that constructor and blocks
    # on the Mutex the enclosing block still holds. The framework's EuiccService path
    # targets the internal eUICC (non-removable) and never takes the OMAPI branch, so
    # profile lookup worked while the app UI span forever -- it enumerates every port
    # and hits the removable physical SIM in slot 0, which does take that branch.
    # packages/apps/OpenEUICC is a synced project, so repo sync reverts this.
    if [ -f "$WX/patches/tree/patch_seservice.py" ]; then
        python3 "$WX/patches/tree/patch_seservice.py" \
            && echo "patched: OpenEUICC connectSEService deadlock"
    fi

    # warhol's eUICC slot is MEP_A1, and AOSP's own LPA adds targetPortIndex [2] to
    # ES10c Enable/DisableProfile in exactly that case (EuiccPort.java:315, port index
    # + 1 per PortUtils.convertToHalPortIndex). lpac never emits it, which is why every
    # EnableProfile it built came back 6A80. Adds the field as an option and tries the
    # pre-MEP form first, since an app cannot see the MEP mode.
    # Touches the lpac submodule as well as packages/apps/OpenEUICC; both are synced.
    if [ -f "$WX/patches/tree/patch_es10c_mep.py" ]; then
        python3 "$WX/patches/tree/patch_es10c_mep.py" \
            && echo "patched: lpac ES10c targetPortIndex (MEP-A1)"
    fi

    # warhol's internal eUICC is MEP-A1 and rejects a chained initialiseSecureChannel
    # (the profile-install BPP's first ES10x block) at the default MSS of 63 ("Most
    # Compatible", for removable eUICCs), so every download failed. 255 ("High
    # Efficiency") sends block 0 as one APDU and installs succeed. Bakes 255 as the
    # source default so a data-wipe cannot regress the old dev-menu-only fix.
    # app-common is a synced project, so repo sync reverts this.
    if [ -f "$WX/patches/tree/patch_esim_mss.py" ]; then
        python3 "$WX/patches/tree/patch_esim_mss.py" \
            && echo "patched: OpenEUICC ES10x MSS default 63 -> 255"
    fi

    # OpenEUICC's LocalProfileAssistantImpl.valid checks `finalized` OUTSIDE the
    # object lock, then reads eID (native es10cGetEid) under it. During an eSIM
    # enable, the channel manager races valid() against close()/destroyContext(),
    # so es10cGetEid ran on a freed lpac context and apdu_interface_transmit()
    # dereferenced a null interface -> SIGSEGV killed the LPA -> Settings showed a
    # bogus "Can't switch SIMs" even though the profile enabled. Moves the finalized
    # check under the lock and null-guards the JNI transmit callback.
    # Touches app-common (Kotlin) and the lpac submodule (C); both are synced.
    if [ -f "$WX/patches/tree/patch_esim_uaf.py" ]; then
        python3 "$WX/patches/tree/patch_esim_uaf.py" \
            && echo "patched: OpenEUICC/lpac eSIM-enable use-after-free"
    fi

    # warhol runs SELinux Enforcing natively on the STOCK A16 engineering vendor (a
    # from-source A17 vendor is unbuildable). The stock vendor boots a tail of denials
    # in VENDOR-declared domains (mtk_hal_*, ccci_*, rild, hal_*_default, vendor_init,
    # netutils_wrapper, ...). Those rules live in
    # device/xiaomi/warhol/sepolicy/warhol_enforce.rules and are INJECTED into the stock
    # vendor.img vendor_sepolicy.cil at image-assembly time -- see that directory's
    # README.md + inject_vendor_sepolicy.sh, or run: ./remote-build.sh enforce-vendor.
    # init recompiles the split policy at boot (secilc -N, no /vendor precompiled
    # policy), so the rules resolve natively: NO init patch and NO /system_ext copy.
    # Here we only keep the generated CIL in sync with the rule source (both tracked in
    # the device tree, so this survives repo sync).
    if [ -f "$P/device/xiaomi/warhol/sepolicy/patch_sepolicy_enforce.py" ]; then
        python3 "$P/device/xiaomi/warhol/sepolicy/patch_sepolicy_enforce.py"
    fi

    # vendor/apn ships only US Mobile's LEGACY "pwg" APN for PLMN 310240, gid-matched
    # and roaming_protocol="IP". On a current Light Speed line roaming abroad that
    # yields NO_SUITABLE_DATA_PROFILE, then ESM cause 33 SERVICE_OPTION_NOT_SUBSCRIBED
    # on PDP activation, which rejects the LTE attach with EMM cause 19 and drops the
    # UE to 3G. Adds the "wholesale" default APN and an ims/xcap APN (310240 has none).
    # vendor/apn is a synced project, so repo sync reverts this.
    if [ -f "$WX/patches/tree/patch_apns_usmobile.py" ]; then
        python3 "$WX/patches/tree/patch_apns_usmobile.py"
    fi

    # Messaging declares targetSdkVersion=34, below the Android 15 edge-to-edge
    # cutoff, so its windows get LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT and are
    # inset away from the cutout edge. In landscape warhol's cutout is on a
    # short edge, so that inset shows up as a ~125 px black bar that SystemUI
    # (shortEdges) draws its status bar across. Sets shortEdges on
    # BugleBaseTheme, matching LineageParts/Recorder/Launcher3 in this tree.
    # packages/apps/Messaging is a synced project, so repo sync reverts this.
    if [ -f "$WX/patches/tree/patch_messaging_cutout.py" ]; then
        python3 "$WX/patches/tree/patch_messaging_cutout.py"
    fi

    # A hole in the middle of a LONG edge must not indent the status bar. warhol's
    # portrait top-center cutout becomes a left-edge cutout in landscape at y=600..680
    # while the bar is y=0..84, but shareShortEdge() extended the cutout to full height
    # before testing, so the bar picked up a spurious 125 px left margin -- the clock sat
    # 66 px further from the edge than the battery. Require a real intersection.
    # frameworks/base is a synced project, so repo sync reverts this.
    if [ -f "$WX/patches/tree/patch_sbinsets.py" ]; then
        python3 "$WX/patches/tree/patch_sbinsets.py" \
            && echo "patched: SystemUI status bar cutout insets"
    fi

    # openeuicc-deps pins sdk_version: "37" on all 12 of its prebuilts, because
    # upstream builds against the newest AOSP (their README says compilation is
    # "only tested against the latest AOSP release version"). Neither of our trees
    # can satisfy that pin, for different reasons, and both fail identically at
    # soong BOOTSTRAP, before compiling anything:
    #   - lineage-23.2 (Android 16 / API 36): prebuilts/sdk/37 exists but is an
    #     empty placeholder -- 37/public/ holds only api/, no android.jar.
    #   - lineage-24.0 (Android 17 / API 37): prebuilts/sdk/37 is absent entirely.
    #     A pre-release tree (CP2A) has not finalized its own API level, so in-tree
    #     code targets "current", not "37". Verified 2026-09-12.
    #   error: prebuilts/openeuicc-deps/Android.bp:46:16: module
    #     "OpenEUICC_com.google.guava_listenablefuture" variant "android_common":
    #     sdk_version: invalid sdk version "37",
    #     "prebuilts/sdk/37/public/android.jar" does not exist
    # 36 is deliberate rather than "current": it matches PRODUCT_SHIPPING_API_LEVEL,
    # and these are prebuilt jars where sdk_version only picks the API surface to
    # dex against. Revisit if the tree ever finalizes 37.
    # The prebuilt MediaTek boot jars carry classes that cannot verify against an
    # AOSP framework: MtkGsmMmiCode extends com.android.internal.telephony.gsm.
    # GsmMmiCode, which LineageOS declares "public final". MediaTek compiled it
    # against a stock framework where it was not final.
    #
    # A16's dex2oat marked the class erroneous and carried on; A17's verifies the
    # erroneous class's methods and hard-aborts, which kills the ENTIRE boot image
    # and is the only thing standing between this tree and a complete build.
    #
    # Verified identical across both trees (so none of these is the cause): the jars,
    # the 24-entry boot classpath, the dex2oat flags, and GsmMmiCode's own bytecode.
    # The delta is inside ART's verifier between A16 and A17.
    #
    # Dropping the abort is parity, not new risk: the shipping 23.2 build already has
    # this class unverifiable in its boot image, with voice/SMS/data all working. ART
    # itself passes --no-abort-on-hard-verifier-error on device, in odrefresh.cc,
    # when it regenerates the boot image. Erroneous classes stay erroneous and throw
    # only if loaded; MTK telephony injection is disabled, so nothing loads this one.
    #
    # COST, deliberate: the flag is global to the boot image, so build-time hard-
    # verifier checking is off for AOSP's own boot jars too. Narrower alternatives
    # are strip-the-class-from-the-jar (risks cascading unresolved refs from
    # MtkGsmCdmaPhone) or de-final GsmMmiCode (likely just surfaces the next A17
    # incompatibility in the subclass's method bodies).
    #
    # 23.2 does not need this and must not get it.
    local bootjars="$P/src/build/soong/java/dexpreopt_bootjars.go"
    if [ "$BRANCH" != "lineage-23.2" ] && [ -f "$bootjars" ] \
       && grep -q 'Flag("--abort-on-hard-verifier-error")' "$bootjars"; then
        sed -i 's/Flag("--abort-on-hard-verifier-error")/Flag("--no-abort-on-hard-verifier-error")/' "$bootjars"
        echo "patched: boot image --no-abort-on-hard-verifier-error (A17 MTK prebuilt jars)"
    fi

    local oedeps="$P/src/prebuilts/openeuicc-deps/Android.bp"
    if [ -f "$oedeps" ] && grep -q 'sdk_version: "37"' "$oedeps"; then
        sed -i 's/sdk_version: "37"/sdk_version: "36"/g' "$oedeps"
        echo "patched: openeuicc-deps sdk_version 37 -> 36"
    fi

    # VoLTE/VoWiFi, carrier half. isVolteEnabledByPlatform() (ImsManager.java:822) is
    #     config_device_volte_available AND carrier_volte_available_bool AND isGbaValid()
    # The device bools are set in the device tree overlay
    # (overlay/frameworks/base/core/res/res/values/config.xml), but the carrier bools
    # default FALSE (CarrierConfigManager.java:11830 and :11844) and Kyivstar UA
    # (MCC/MNC 25503) ships no asset upstream. Without this the dialer falls back to
    # CSFB even with the modem fully IMS-registered -- measured on device 2026-09-12.
    #
    # This has to be a tree patch rather than an overlay: CarrierConfig compiles its
    # assets INTO the APK, and PRODUCT_PACKAGE_OVERLAYS only merges res/, not assets/.
    # DefaultCarrierConfigService resolves carrier_config_mccmnc_<mccmnc>.xml.
    local ccassets="$P/src/packages/apps/CarrierConfig/assets"
    if [ -d "$ccassets" ] && [ ! -f "$ccassets/carrier_config_mccmnc_25503.xml" ]; then
        cat > "$ccassets/carrier_config_mccmnc_25503.xml" <<'CCEOF'
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<carrier_config_list>
    <carrier_config>
        <boolean name="carrier_volte_available_bool" value="true" />
        <boolean name="carrier_wfc_ims_available_bool" value="true" />
        <boolean name="editable_wfc_mode_bool" value="true" />
    </carrier_config>
</carrier_config_list>
CCEOF
        echo "patched: added carrier_config_mccmnc_25503.xml (Kyivstar VoLTE/VoWiFi)"
    fi

    local allow="$P/src/build/soong/scripts/check_boot_jars/package_allowed_list.txt"
    if [ -f "$allow" ] && ! grep -qF 'com\.xiaomi' "$allow"; then
        # Only packages on this list may appear in a boot classpath jar:
        #   Error: mediatek-ims-common.jar contains class com.xiaomi.ims.XmImsFactory,
        #   whose package "com.xiaomi.ims" is ... not in the allow list
        # Xiaomi built their own IMS factory into MediaTek's jar. LineageOS already
        # allows com.mediatek, mediatek and vendor.mediatek here; com.xiaomi is the
        # only package in our seven boot jars that is missing (android.telephony,
        # also present, is covered by the existing "android\..*" entry).
        # The list path is hardcoded in build/soong/java/boot_jars.go, so there is
        # no device-tree way to extend it.
        printf '\n# warhol: Xiaomi classes shipped inside MediaTek system_ext boot jars\ncom\\.xiaomi\ncom\\.xiaomi\\..*\n' >> "$allow"
        echo "patched: com.xiaomi added to the boot jar package allow list"
    fi

    # Launcher3/Trebuchet crashes on EVERY swipe-up-to-home while the aconfig flag
    # enable_refactor_task_thumbnail is OFF -- which it is: there is no
    # device_config override, so the built-in default applies.
    #
    # TaskView.kt initialises two DI-backed properties EAGERLY in its constructor:
    #     private val dispatcherProvider: DispatcherProvider = RecentsDependencies.get(context)
    #     private val coroutineScope: CoroutineScope = RecentsDependencies.get(context)
    # but RecentsView.java only calls RecentsDependencies.maybeInitialize() INSIDE
    #     if (enableRefactorTaskThumbnail()) { ... }
    # so with the flag off the container is never initialised, and constructing a
    # TaskView throws. It surfaces as a useless inflate error that hides the cause:
    #     InflateException: Binary XML file line #18 in
    #       com.android.launcher3:layout/task: Error inflating class <unknown>
    #     Caused by: kotlin.UninitializedPropertyAccessException:
    #       Recents dependencies are not initialized.
    #         at RecentsDependencies$Companion.getInstance(RecentsDependencies.kt:297)
    #         at TaskView.<init>(TaskView.kt)
    #         at RecentsView.getTaskViewFromPool -> showCurrentTask
    #            -> onGestureAnimationStart -> AbsSwipeUpHandler.onActivityInit
    # The gesture handler never completes, so this also produced the paired
    # "Input dispatching timed out (PointerEventDispatcher0)" ANR.
    #
    # Both properties are only USED inside enableRefactorTaskThumbnail() guards
    # (TaskView.onAttachedToWindow and TaskView.cancelJobs), so making them lazy is
    # sufficient and behavior-preserving: nothing touches the container until the
    # flag path runs, and that path only runs after RecentsView has initialised it.
    local tv="$P/src/packages/apps/Launcher3/quickstep/src/com/android/quickstep/views/TaskView.kt"
    if [ -f "$tv" ] && grep -q '= RecentsDependencies.get(context)$' "$tv"; then
        sed -i \
          -e 's|^\( *\)private val dispatcherProvider: DispatcherProvider = RecentsDependencies.get(context)$|\1private val dispatcherProvider: DispatcherProvider by lazy { RecentsDependencies.get(context) }|' \
          -e 's|^\( *\)private val coroutineScope: CoroutineScope = RecentsDependencies.get(context)$|\1private val coroutineScope: CoroutineScope by lazy { RecentsDependencies.get(context) }|' \
          "$tv"
        echo "patched: TaskView DI properties made lazy (swipe-up-to-home crash)"
    fi

    # Launcher3: ScalingWorkspaceRevealAnim passes an INTEGER resource to
    # getDimensionPixelSize on the flag-off path, so swipe-up-to-home crashes the
    # launcher at gesture END. (The TaskView fix above cures gesture START; this is
    # the second, independent bug on the same gesture.)
    #     Resources$NotFoundException: Resource ID #0x7f0a0049 type #0x10 is not valid
    #       at Resources.getDimensionPixelSize(Resources.java:863)
    #       at ScalingWorkspaceRevealAnim.<init>(ScalingWorkspaceRevealAnim.kt:189)
    #       at LauncherSwipeHandlerV2...playScalingRevealAnimation
    #       at AbsSwipeUpHandler.animateGestureEnd -> handleNormalGestureEnd
    # quickstep/res/values/config.xml declares
    #     <integer name="max_depth_blur_radius">23</integer>
    #     <dimen   name="max_depth_blur_radius_enhanced">30dp</dimen>
    # With all_apps_blur and enable_overview_background_wallpaper_blur both off we
    # take the integer branch, and type 0x10 is TYPE_INT_DEC. Read the integer with
    # getInteger; leave the dimen path byte-identical.
    local swra="$P/src/packages/apps/Launcher3/quickstep/src/com/android/quickstep/util/ScalingWorkspaceRevealAnim.kt"
    if [ -f "$swra" ]; then
        python3 - "$swra" <<'PYSWRA'
import sys
p = sys.argv[1]
s = open(p).read()
old = """            var maxBlurRadius =
                launcher.resources.getDimensionPixelSize(
                    if (Flags.allAppsBlur() || Flags.enableOverviewBackgroundWallpaperBlur()) {
                        R.dimen.max_depth_blur_radius_enhanced
                    } else {
                        R.integer.max_depth_blur_radius
                    }
                )
"""
new = """            var maxBlurRadius =
                if (Flags.allAppsBlur() || Flags.enableOverviewBackgroundWallpaperBlur()) {
                    launcher.resources.getDimensionPixelSize(R.dimen.max_depth_blur_radius_enhanced)
                } else {
                    launcher.resources.getInteger(R.integer.max_depth_blur_radius)
                }
"""
if new in s:
    pass
elif old in s:
    open(p, "w").write(s.replace(old, new, 1))
    print("patched: ScalingWorkspaceRevealAnim uses getInteger for max_depth_blur_radius")
else:
    sys.stderr.write("WARNING: ScalingWorkspaceRevealAnim pattern not found; verify upstream\n")
PYSWRA
    fi

    # Trebuchet's "Advanced grid & dock" is an OPTIONAL feature: it ships as the
    # trebuchet_advgrid Magisk module and goes upstream as an optional change, and it is
    # NEVER part of the base ROM. So patch_tree does not apply it. ROM builds check that
    # it is absent (assert_no_advgrid), and `advgrid-module` builds the module from the
    # advgrid branch of packages/apps/Launcher3.

    # frameworks/base: the timezone picker (Setup Wizard + Settings > Date & time)
    # is populated from the static curated res/xml/timezones.xml, which had NO Ukraine
    # entry, so Europe/Kyiv was unselectable. frameworks/base is a synced project;
    # re-apply the one-line add idempotently. (Upstream candidate: tmp/upstream/.)
    local kyiv_r="$P/src/frameworks/base"
    local kyiv_patch="$WX/patches/tree/warhol-kyiv-timezone.patch"
    if [ -f "$kyiv_patch" ] && [ -d "$kyiv_r/.git" ]; then
        if git -C "$kyiv_r" apply --reverse --check "$kyiv_patch" 2>/dev/null; then
            : # already applied
        elif git -C "$kyiv_r" apply --check "$kyiv_patch" 2>/dev/null; then
            git -C "$kyiv_r" apply "$kyiv_patch" \
                && echo "patched: Europe/Kyiv timezone"
        else
            echo "WARNING: Kyiv timezone patch does not apply cleanly; skipping" >&2
        fi
    fi

    # vendor/lineage: default LineageOS stats collection to OFF for the warhol build
    # (local policy, NOT upstream). vendor/lineage is a synced project; re-apply
    # idempotently.
    local stats_r="$P/src/vendor/lineage"
    local stats_patch="$WX/patches/tree/warhol-stats-default-off.patch"
    if [ -f "$stats_patch" ] && [ -d "$stats_r/.git" ]; then
        if git -C "$stats_r" apply --reverse --check "$stats_patch" 2>/dev/null; then
            : # already applied
        elif git -C "$stats_r" apply --check "$stats_patch" 2>/dev/null; then
            git -C "$stats_r" apply "$stats_patch" \
                && echo "patched: stats collection default off"
        else
            echo "WARNING: stats-default-off patch does not apply cleanly; skipping" >&2
        fi
    fi

    # Settings: face enrollment opens the front camera for its own preview, but warhol's
    # face HAL (mifaced) runs on that SAME RGB camera, so cameraserver evicts mifaced the
    # moment Settings connects ("evicting conflicting client for camera ID 1") and
    # enrollment fails instantly. Adds config_faceEnrollHalPreview: when true (warhol
    # overlay), Settings does not open the camera and instead passes the preview surface
    # to FaceManager#enroll, which reaches the HAL as FaceEnrollOptions.surfacePreview.
    # Kept in the device tree (not tmp/) so it cannot be lost. Settings is synced.
    local faceprev_r="$P/src/packages/apps/Settings"
    local faceprev_patch="$WX/patches/settings/0001-Settings-face-HAL-draws-enrollment-preview.patch"
    if [ -f "$faceprev_patch" ] && [ -d "$faceprev_r/.git" ]; then
        if git -C "$faceprev_r" apply --reverse --check "$faceprev_patch" 2>/dev/null; then
            : # already applied
        elif git -C "$faceprev_r" apply --check "$faceprev_patch" 2>/dev/null; then
            git -C "$faceprev_r" apply "$faceprev_patch" \
                && echo "patched: Settings face HAL draws enrollment preview"
        else
            echo "WARNING: Settings face HAL preview patch does not apply cleanly; skipping" >&2
        fi
    fi

    # FOD: the two synced-project halves of the warhol optical fingerprint fix; see
    # device/xiaomi/warhol/patches/fod/README.md. system/core imports ueventd rules
    # from /system_ext (the device's /dev/mi_display rule is there), and SystemUI
    # sends Xiaomi's FOD condition updates on UDFPS overlay show/hide. repo sync
    # reverts both, so they are kept in the device tree rather than in tmp/.
    local fod_pair fod_r fod_patch
    for fod_pair in "system/core:0001-ueventd-import-system_ext-rules.patch" \
                    "frameworks/base:0002-SystemUI-Xiaomi-FOD-condition-updates.patch"; do
        fod_r="$P/src/${fod_pair%%:*}"
        fod_patch="$WX/patches/fod/${fod_pair#*:}"
        [ -f "$fod_patch" ] && [ -d "$fod_r/.git" ] || continue
        if git -C "$fod_r" apply --reverse --check "$fod_patch" 2>/dev/null; then
            : # already applied
        elif git -C "$fod_r" apply --check "$fod_patch" 2>/dev/null; then
            git -C "$fod_r" apply "$fod_patch" && echo "patched: FOD ${fod_pair#*:}"
        else
            echo "WARNING: FOD patch ${fod_pair#*:} does not apply cleanly; skipping" >&2
        fi
    done

    # SystemUI: the right and center status-bar clocks declare an EXACT height of
    # status_bar_system_icons_height, which is SHORTER than the line height of
    # their own 14sp text. gravity=center_vertical then splits the overflow and
    # the parent clips it, so the clock renders LOW with its bottom sheared off.
    # Measured on warhol: clock_right bounds [1075,22][1196,61] -- a 39px box for
    # text needing ~49px at 14sp with density 3.0.
    # The LEFT clock in status_bar.xml already does this correctly:
    #     android:layout_height="wrap_content"
    #     android:minHeight="@dimen/status_bar_system_icons_height"
    # so mirror it for the other two. This is parent-height independent and fixes
    # both the home and the keyguard status bar, which both include system_icons.
    python3 - "$P/src/frameworks/base/packages/SystemUI/res/layout" <<'PYCLOCK'
import sys, os, re
d = sys.argv[1]
targets = [("system_icons.xml", "clock_right"), ("status_bar.xml", "clock_center")]
EXACT = 'android:layout_height="@dimen/status_bar_system_icons_height"'
for fn, cid in targets:
    p = os.path.join(d, fn)
    if not os.path.isfile(p):
        sys.stderr.write("WARNING: %s missing; verify upstream\n" % fn)
        continue
    lines = open(p).read().split("\n")
    anchor = next((i for i, l in enumerate(lines) if '@+id/' + cid + '"' in l), None)
    if anchor is None:
        sys.stderr.write("WARNING: %s not found in %s; verify upstream\n" % (cid, fn))
        continue
    win = range(anchor, min(anchor + 12, len(lines)))
    if any("minHeight" in lines[i] for i in win):
        continue
    hit = next((i for i in win if EXACT in lines[i]), None)
    if hit is None:
        sys.stderr.write("WARNING: %s height line not found in %s; verify upstream\n" % (cid, fn))
        continue
    indent = re.match(r"\s*", lines[hit]).group(0)
    lines[hit] = (indent + 'android:layout_height="wrap_content"\n'
                  + indent + 'android:minHeight="@dimen/status_bar_system_icons_height"')
    open(p, "w").write("\n".join(lines))
    print("patched: %s height wrap_content+minHeight (clipped status-bar clock)" % cid)
PYCLOCK

    # THE RADIO FIX. Enable telephony's `dynamic_modem_shutdown` aconfig flag.
    #
    # Symptom: no cellular at all, "SIM absent", and the vendor RIL spinning on
    # NW_SET_RADIO_STATE_REQ ~7/s forever. The modem is fine - it answers AT,
    # reports its firmware and IMEI, and this same SIM worked on both the CN
    # engineering ROM and the original global ROM.
    #
    # Root cause, end to end:
    #   1. The RIL fires its initial radioStateChanged ~3 ms BEFORE the framework
    #      registers its callbacks, so it is dropped:
    #          E RILC: radioStateChanged: radioModemServiceImpl[0].modemIndication == NULL
    #   2. The framework therefore never learns the radio state and sits at
    #      RADIO_POWER_UNAVAILABLE(2). It WANTS the radio on and has no reason not
    #      to - it says so itself:
    #          SST-0: setPowerStateToDesired: mDesiredPowerState=true,
    #                 getRadioState=2, mRadioPowerOffReasons=[], ... pending
    #   3. But ServiceStateTracker.setPowerStateToDesired() only issues
    #      setRadioPower(true) when the state is RADIO_POWER_OFF - or when
    #      mFeatureFlags.dynamicModemShutdown() is true, which is the one path that
    #      permits power-on from RADIO_POWER_UNAVAILABLE.
    #   4. That flag is ENABLED in build/release/aconfig/trunk_staging but is NOT
    #      SET for bp4a, so it compiles to false. `RADIO_POWER on = true` is sent
    #      exactly zero times, the modem stays at EFUN:0/CFUN:0 (verified over AT),
    #      the SIM is never powered, card type stays -1, isValidSim fails,
    #      GET_SIM_STATUS is rejected, and the framework reports SIM absent.
    #
    # The flag is a PURPOSE_BUGFIX flag whose description is literally "Allow
    # shutdown and turn on the modem while the overall system is on", so enabling
    # it is the intended mechanism rather than a workaround. Values mirror
    # trunk_staging (ENABLED), but READ_ONLY: bp4a sets allow_read_write=false, so a
    # READ_WRITE value fails the build with "has permission READ_WRITE, but allow_read_write is false".
    #
    # It lives under AOSP build/ so it cannot go in the device tree; the package
    # dir globs *_flag_values.textproto, so dropping one file in is sufficient and
    # no Android.bp edit is needed.
    # Two corrections made on 2026-09-11 while bringing up the lineage-24.0 tree:
    #
    # 1. The release config is now $REL, not a hardcoded bp4a. Google's build/release
    #    still ships the whole bp* series on the 24.0 tree, so the old path EXISTS
    #    there and this step wrote into it happily -- a release config the build never
    #    reads. For THE radio fix, silently inert is the worst possible outcome.
    #
    # 2. On Android 17 the flag is GONE and both behaviors it guarded are
    #    unconditional, verified in frameworks/opt/telephony on lineage-24.0:
    #      flags/misc.aconfig                  - no dynamic_modem_shutdown declaration
    #      ServiceStateTracker.java:2563-2567  - turn-on at RADIO_POWER_UNAVAILABLE,
    #                                            no longer flag-guarded
    #      ServiceStateTracker.java:2755       - mDeviceShuttingDown = false, likewise
    #    So the fix is upstream-permanent there.
    #
    #    A value for a deleted flag is INERT, not fatal -- AOSP itself still ships
    #    orphaned dynamic_modem_shutdown values in build/release/aconfig/trunk_staging
    #    and .../cp1a on that branch (cp2a is cleaned up, which is a small corroboration
    #    that cp2a is the maintained config). But inert is precisely the failure being
    #    guarded against here: an orphan means a fix nobody is applying any more, with
    #    no error to notice. Gate on the declaration and say so out loud when skipping.
    local flagdecl="$P/src/frameworks/opt/telephony/flags/misc.aconfig"
    local aconfdir="$P/src/build/release/aconfig/$REL/com.android.internal.telephony.flags"
    local flagfile="$aconfdir/dynamic_modem_shutdown_flag_values.textproto"
    if [ -f "$flagdecl" ] && ! grep -q "dynamic_modem_shutdown" "$flagdecl"; then
        echo "note: dynamic_modem_shutdown is not declared in this tree; Android 17 made"
        echo "      both behaviors unconditional, so skipping the radio aconfig step is correct"
    elif [ -d "$aconfdir" ] && [ ! -f "$flagfile" ]; then
        cat > "$flagfile" <<'PYFLAG'
flag_value {
  package: "com.android.internal.telephony.flags"
  name: "dynamic_modem_shutdown"
  state: ENABLED
  permission: READ_ONLY
}
PYFLAG
        echo "patched: enabled aconfig dynamic_modem_shutdown for $REL (radio power fix)"
    elif [ ! -d "$aconfdir" ]; then
        echo "WARNING: $aconfdir missing; verify the release config is still bp4a" >&2
    fi
}

ADVGRID_BRANCH="${WARHOL_ADVGRID_BRANCH:-lineage-24.0}"
ADVGRID_MARKER="src/com/android/launcher3/LauncherPrefs.kt"

# Refuse to build ROM images while Launcher3 carries the advanced-grid feature (the
# advgrid branch checked out, or its patch applied by hand). It belongs in the
# trebuchet_advgrid module only.
assert_no_advgrid() {
    local l3="$P/src/packages/apps/Launcher3"
    if grep -q 'ADV_GRID_ENABLED' "$l3/$ADVGRID_MARKER" 2>/dev/null; then
        echo "ERROR: packages/apps/Launcher3 contains the advanced-grid feature, which must" >&2
        echo "       not go into the base ROM. Check out the upstream revision first:" >&2
        echo "         git -C $l3 checkout --detach <manifest revision>" >&2
        echo "       (the feature lives on branch $ADVGRID_BRANCH; build it with advgrid-module)" >&2
        exit 1
    fi
}

run() {
    check_deployed
    install_keys
    patch_tree
    podman run --rm -i --pids-limit=0 --ulimit nofile=65536:65536 "$@" \
        -v "$P/src:/aosp" \
        -v "$P/ccache:/ccache" \
        -v "$P/device/xiaomi/warhol:/aosp/device/xiaomi/warhol" \
        -v "$P/tmp:/tmp" \
        -w /aosp "$IMAGE" bash -lc "${CMD}"
}

# Filled into the local manifest unless WARHOL_NO_LEGACY_DEPS is set. See the note
# above NO_LEGACY_DEPS for why omitting them is the safer default on a new branch.
if [ -n "$NO_LEGACY_DEPS" ]; then
    LEGACY_DEPS="  <!-- hardware/mediatek, hardware/xiaomi and device/mediatek/sepolicy_vndr
       deliberately omitted: unreferenced by this device tree and zero installed
       modules, so on a new platform branch they are analysis risk for no gain. -->"
else
    LEGACY_DEPS="  <project name=\"LineageOS/android_hardware_mediatek\"
           path=\"hardware/mediatek\" remote=\"github\" revision=\"$BRANCH\" />
  <project name=\"LineageOS/android_hardware_xiaomi\"
           path=\"hardware/xiaomi\" remote=\"github\" revision=\"$BRANCH\" />
  <project name=\"LineageOS/android_device_mediatek_sepolicy_vndr\"
           path=\"device/mediatek/sepolicy_vndr\" remote=\"github\" revision=\"$BRANCH\" />"
fi

case "${1:-status}" in
sync)
    mkdir -p "$P/src"
    CMD='
set -e
if [ ! -d .repo ]; then
  repo init --depth=1 -u https://github.com/LineageOS/android.git -b '"$BRANCH"' --git-lfs
fi
mkdir -p .repo/local_manifests
cat > .repo/local_manifests/warhol.xml <<XML
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
'"$LEGACY_DEPS"'  <remote name="typeblog" fetch="https://gitea.angry.im/PeterCxy/" />
  <!-- eSIM: privileged OpenEUICC as the LPA. Upstream ships a real AOSP
       Android.bp (module name OpenEUICC, system_ext, certificate: platform,
       privileged, with its own privapp allowlist prebuilt_etc), so this is a
       source integration and not a re-signed prebuilt. sync-s pulls the two
       lpac-jni submodules (lpac, cJSON); without it liblpac-jni has no srcs.
       openeuicc-deps supplies the zxing/okio/guava prebuilts the app needs and
       AOSP does not carry. -->
  <project name="OpenEUICC" path="packages/apps/OpenEUICC"
           remote="typeblog" revision="master" sync-s="true" />
  <project name="android_prebuilts_openeuicc-deps" path="prebuilts/openeuicc-deps"
           remote="typeblog" revision="master" />
</manifest>
XML
for a in 1 2 3 4; do
  echo "=== repo sync attempt $a  $(date) ==="
  repo sync -c -j8 --force-sync --no-clone-bundle --no-tags --optimized-fetch --prune && break
  echo "=== retrying in 20s ==="; sleep 20
done
repo sync -c -j8 --no-clone-bundle --no-tags --optimized-fetch >/dev/null 2>&1 || {
  echo "!!! sync STILL incomplete" >&2; exit 1; }
echo "=== SYNC OK ==="; du -sh /aosp
'
    run ;;
config)
    CMD='
set -e
. build/envsetup.sh
lunch lineage_warhol-'"$REL"'-userdebug
echo "=== LUNCH OK ==="
m nothing
echo "=== CONFIG OK ==="
'
    run ;;
sepolicy)
    # Compile SELinux policy only. Builds the CIL, runs the neverallow checks and the
    # property_contexts tests -- everything a policy change needs verified -- without
    # the ~12 min / ~57 GB cost of a full image build on a shared machine.
    CMD='
set -e
. build/envsetup.sh
lunch lineage_warhol-'"$REL"'-userdebug
m selinux_policy -j'"$JOBS"'
echo "=== SEPOLICY OK ==="
ls -la out/target/product/warhol/system_ext/etc/selinux/ 2>/dev/null || true
'
    run ;;
apex-sign)
    assert_no_advgrid
    # Re-sign the build with our own APEX keys and produce a signed OTA.
    #
    # PRODUCT_DEFAULT_DEV_CERTIFICATE re-signs APKs during the build, but APEXes
    # that carry their own in-tree keys are untouched by it -- 33 of the 36 in this
    # build were still on AOSP's public dev keys. Changing them after the fact is
    # what sign_target_files_apks is for, and it is the same mechanism LineageOS's
    # own release pipeline uses.
    #
    # The mapping list is generated from META/apexkeys.txt of the actual build by
    # tools/gen-apex-keys.sh, so a new APEX in a future Android release cannot
    # silently stay on a public key.
    APEX_ARGS="$("$P/bin/gen-apex-keys.sh" container-args)" || {
        echo "!!! could not build the APEX key mapping; run 'gen-apex-keys.sh gen' first" >&2
        exit 1; }
    CMD='
set -e
. build/envsetup.sh
lunch lineage_warhol-'"$REL"'-userdebug
# bacon does not leave a target_files zip behind; this target is what produces it.
mka target-files-package -j'"$JOBS"'
TF=out/target/product/warhol/obj/PACKAGING/target_files_intermediates/lineage_warhol-target_files.zip
ls -la "$TF"
# The releasetools are BUILT host binaries. The .py files under
# build/make/tools/releasetools/ are their sources, are not executable, and
# running one directly gives "No such file or directory".
./out/host/linux-x86/bin/sign_target_files_apks \
    -o -d vendor/lineage-priv/keys '"$APEX_ARGS"' \
    "$TF" out/warhol-signed-target_files.zip
echo "=== SIGNED TARGET_FILES OK ==="
./out/host/linux-x86/bin/ota_from_target_files --block \
    out/warhol-signed-target_files.zip out/lineage-warhol-signed.zip
echo "=== SIGNED OTA OK ==="
ls -la out/lineage-warhol-signed.zip
'
    run ;;
enforce-vendor)
    # Bake the from-source device sepolicy into the STOCK vendor.img -> the actual
    # flashable ENFORCING vendor (see device/xiaomi/warhol/sepolicy/README.md). HOST
    # post-build step (uses the build-tree erofs tools + plat_file_contexts), not a
    # container build; needs a prior full/vendor build so plat_file_contexts exists.
    #   ./remote-build.sh enforce-vendor [stock_vendor.img] [out.img]
    python3 "$P/device/xiaomi/warhol/sepolicy/patch_sepolicy_enforce.py"
    EV_STOCK="${2:-$P/../warhol-stock/vendor_a.img}"
    EV_PLATFC="$P/src/out/target/product/warhol/system/etc/selinux/plat_file_contexts"
    EV_OUT="${3:-$P/src/out/target/product/warhol/vendor-enforcing.img}"
    "$P/device/xiaomi/warhol/sepolicy/inject_vendor_sepolicy.sh" \
        --stock-vendor "$EV_STOCK" --plat-fc "$EV_PLATFC" --out "$EV_OUT"
    echo "=== ENFORCE-VENDOR OK: $EV_OUT ==="
    ;;
vendor)
    # Build the from-source vendor + odm images. NOTE: the from-source vendor is NOT
    # flashable on warhol (A17 has no vendor snapshot for the A16 MTK HAL blobs); this
    # target is kept for policy/analysis only. The FLASHED enforcing vendor comes from
    # `enforce-vendor` above (stock vendor + injected sepolicy). odm is flashed as-is.
    CMD='
set -e
. build/envsetup.sh
lunch lineage_warhol-'"$REL"'-userdebug
m vendorimage odmimage -j'"$JOBS"'
echo "=== VENDOR OK ==="
ls -la out/target/product/warhol/vendor.img out/target/product/warhol/odm.img 2>/dev/null || true
'
    run ;;
module)
    # Build ONE soong/make module and leave it in out/target/product/warhol/, without
    # the ~12 min / ~57 GB of a full image build. Used to iterate on a single app --
    #     ./remote-build.sh module OpenEUICC
    # -- whose apk can then be adb install -r'd over the in-ROM copy and backed out
    # with `pm uninstall -k --user 0`, so no partition is written to test a change.
    MOD="${2:-}"
    [ -n "$MOD" ] || { echo "usage: $0 module <soong-module-name>" >&2; exit 1; }
    CMD='
set -e
. build/envsetup.sh
lunch lineage_warhol-'"$REL"'-userdebug
m '"$MOD"' -j'"$JOBS"'
echo "=== MODULE OK ==="
find out/target/product/warhol -name "'"$MOD"'.apk" -newermt "-30 minutes" -exec ls -la {} + 2>/dev/null || true
'
    run ;;
build)
    assert_no_advgrid
    CMD='
set -e
. build/envsetup.sh
lunch lineage_warhol-'"$REL"'-userdebug
mka bacon -j'"$JOBS"'
echo "=== BUILD OK ==="
ls -la out/target/product/warhol/*.zip 2>/dev/null || true
'
    run
    # The build emits ro.secure=1 / ro.debuggable=0 / ro.adb.secure=1 even at
    # userdebug, because the release config signs with release-keys -- and it is
    # ro.secure=0, not ro.debuggable, that grants `adb root`. This writes prop-patched
    # copies of the three images to tmp/flash: FLASH FROM THERE, not from out/.
    # The 24.0 tree never carried this script (it existed only under warhol-los), so
    # every 24.0 flash before 2026-09-12 silently shipped ro.secure=1. Magisk root is
    # unaffected either way; this is purely about adbd running as root.
    if [ -f "$WX/tools/patch_debuggable.py" ]; then
        echo "=== patching debuggable props -> $P/tmp/flash ==="
        WARHOL_ROOT="$P" python3 "$WX/tools/patch_debuggable.py"
    fi
    ;;
advgrid-module)
    # Build the trebuchet_advgrid Magisk module from the advgrid branch:
    #     ./remote-build.sh advgrid-module v9
    # Launcher3 is switched to the branch only for this build and is always put back
    # on the upstream revision it was on, so the next ROM build stays clean. The
    # branch must already be rebased onto that revision (after a resync, rebase it
    # first); the module replaces the whole Launcher3QuickStep APK, so it has to match
    # the ROM's upstream Launcher3.
    AG_VER="${2:-}"
    [ -n "$AG_VER" ] || { echo "usage: $0 advgrid-module <version, e.g. v9>" >&2; exit 1; }
    AG_L3="$P/src/packages/apps/Launcher3"
    [ -z "$(git -C "$AG_L3" status --porcelain)" ] || {
        echo "ERROR: $AG_L3 has uncommitted changes" >&2; exit 1; }
    AG_UP="$(git -C "$AG_L3" rev-parse HEAD)"
    if grep -q 'ADV_GRID_ENABLED' "$AG_L3/$ADVGRID_MARKER"; then
        echo "ERROR: Launcher3 HEAD already contains the feature; check out upstream first" >&2
        exit 1
    fi
    git -C "$AG_L3" merge-base --is-ancestor "$AG_UP" "$ADVGRID_BRANCH" || {
        echo "ERROR: $ADVGRID_BRANCH is not based on upstream ${AG_UP:0:10}; rebase it:" >&2
        echo "         git -C $AG_L3 rebase --onto ${AG_UP:0:10} <old upstream> $ADVGRID_BRANCH" >&2
        exit 1; }
    trap 'git -C "$AG_L3" checkout -q --detach "$AG_UP" && echo "Launcher3 back on upstream ${AG_UP:0:10}"' EXIT
    git -C "$AG_L3" checkout -q "$ADVGRID_BRANCH"
    echo "=== building $ADVGRID_BRANCH $(git -C "$AG_L3" rev-parse --short HEAD) on upstream ${AG_UP:0:10} ==="
    CMD='
set -e
. build/envsetup.sh
lunch lineage_warhol-'"$REL"'-userdebug
m Launcher3QuickStep -j'"$JOBS"'
'
    run
    AG_APK="$P/src/out/target/product/warhol/system_ext/priv-app/Launcher3QuickStep/Launcher3QuickStep.apk"
    AG_SRC="$P/warhol-modules/trebuchet_advgrid_${AG_VER}_src"
    AG_DIR="$AG_SRC/system/system_ext/priv-app/Launcher3QuickStep"
    rm -rf "$AG_SRC" && mkdir -p "$AG_DIR"
    cp -p "$AG_APK" "$AG_DIR/" && touch "$AG_DIR/.replace"
    cat > "$AG_SRC/module.prop" <<PROP
id=trebuchet_advgrid
name=Trebuchet Advanced Grid and Dock
version=$AG_VER
versionCode=${AG_VER#v}
author=warhol
description=Optional Trebuchet launcher: advanced grid up to 15x17, icon scale, and a dock toggle (all default off). Built from $ADVGRID_BRANCH $(git -C "$AG_L3" rev-parse --short HEAD) on LineageOS upstream ${AG_UP:0:10}. Overlays system Launcher3QuickStep.
PROP
    python3 - "$AG_SRC" "$P/warhol-modules/trebuchet_advgrid_${AG_VER}.zip" <<'PYZIP'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for f in files:
            full = os.path.join(root, f)
            z.write(full, os.path.relpath(full, src))
print("=== MODULE ZIP OK: %s ===" % out)
PYZIP
    ;;
shell)
    CMD='exec bash'
    podman run --rm -it --pids-limit=0 --ulimit nofile=65536:65536 \
        -v "$P/src:/aosp" -v "$P/ccache:/ccache" \
        -v "$P/device/xiaomi/warhol:/aosp/device/xiaomi/warhol" \
        -v "$P/tmp:/tmp" -w /aosp "$IMAGE" bash -l ;;
status)
    echo "=== disks ==="
    df -h /run/media/local/4TB / | sed 1d
    echo "=== tree ==="
    du -sh "$P/src" 2>/dev/null || echo "  (no tree yet)"
    echo "=== out ==="
    du -sh "$P/src/out" 2>/dev/null || echo "  (no out yet)"
    echo "=== tmux ==="
    tmux ls 2>/dev/null || echo "  (no sessions)"
    ;;
*) echo "usage: $0 [sync|config|sepolicy|module <name>|advgrid-module <ver>|build|shell|status]" >&2; exit 1 ;;
esac
