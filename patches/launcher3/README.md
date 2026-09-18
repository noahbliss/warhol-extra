# Launcher3 patches — upstreamable, not device-specific

Both fixes here are **plain upstream Launcher3 bugs**. Nothing about them is
warhol-specific: no device config, no vendor blob, no partition layout. Any device
that builds Launcher3 with the relevant aconfig flag **off** hits them. They are
split out as separate patches so they can be offered upstream later without having
to be re-derived from `patch_tree()`.

Base commit these were taken against:
`15a56ccd09bbfa89f40b5afb84263841f400f0d3` ("Automatic translation import"),
LineageOS `lineage-23.2` / `packages/apps/Launcher3`. See `BASE_COMMIT`.

They are currently *applied* by `patch_tree()` in `remote/remote-build.sh` as
idempotent in-place edits, because `repo sync` reverts AOSP repos. These `.patch`
files are the canonical record of what those edits do.

## 0001 — TaskView eagerly touches an uninitialized DI container

Crash, on every swipe-up-to-home from inside an app:

```
android.view.InflateException: Binary XML file line #18 in
  com.android.launcher3:layout/task: Error inflating class <unknown>
Caused by: kotlin.UninitializedPropertyAccessException:
  Recents dependencies are not initialized.
  Call `RecentsDependencies.maybeInitialize` before using this container.
    at RecentsDependencies$Companion.getInstance(RecentsDependencies.kt:297)
    at com.android.quickstep.views.TaskView.<init>(TaskView.kt)
    at RecentsView.getTaskViewFromPool -> showCurrentTask
       -> onGestureAnimationStart -> AbsSwipeUpHandler.onActivityInit
```

`TaskView` initializes two DI-backed properties **eagerly** in its constructor:

```kotlin
private val dispatcherProvider: DispatcherProvider = RecentsDependencies.get(context)
private val coroutineScope: CoroutineScope = RecentsDependencies.get(context)
```

but `RecentsView` only calls `RecentsDependencies.maybeInitialize()` **inside**
`if (enableRefactorTaskThumbnail())`. With the flag off the container is never
initialized, so constructing any `TaskView` throws.

Both properties are only *used* inside `enableRefactorTaskThumbnail()` guards
(`TaskView.onAttachedToWindow` and `TaskView.cancelJobs`), so making them `by lazy`
is behavior-preserving: nothing touches the container until the flag path runs,
and that path only runs after `RecentsView` has initialized it.

The `viewModel` property declared immediately *above* these two is already
wrapped in `if (enableRefactorTaskThumbnail())`, so the eager pair reads as an
oversight inside the same block rather than a deliberate choice. That is the
strongest argument for the minimal fix.

**A reviewer may prefer the other fix** — hoisting `maybeInitialize()` out of the
flag check in `RecentsView` so the container always exists. That is a larger
behavioral change (it constructs the DI graph unconditionally), which is why the
lazy version was chosen here. Worth offering both and letting upstream pick.

Proposed commit message:

    Launcher3: don't touch RecentsDependencies before it is initialized

    TaskView initializes dispatcherProvider and coroutineScope eagerly in its
    constructor via RecentsDependencies.get(), but RecentsView only calls
    RecentsDependencies.maybeInitialize() when enableRefactorTaskThumbnail() is
    true. With the flag off the container is never initialized and constructing a
    TaskView throws UninitializedPropertyAccessException, which surfaces as an
    InflateException on layout/task and breaks swipe-up-to-home entirely.

    Both properties are only read inside enableRefactorTaskThumbnail() guards, so
    make them lazy. No behavior change when the flag is on.

## 0002 — an integer resource passed to getDimensionPixelSize

Crash at gesture **end**, once 0001 is applied:

```
android.content.res.Resources$NotFoundException:
  Resource ID #0x7f0a0049 type #0x10 is not valid
    at Resources.getDimensionPixelSize(Resources.java:863)
    at ScalingWorkspaceRevealAnim.<init>(ScalingWorkspaceRevealAnim.kt:189)
    at LauncherSwipeHandlerV2...playScalingRevealAnimation
    at AbsSwipeUpHandler.animateGestureEnd -> handleNormalGestureEnd
```

`quickstep/res/values/config.xml` declares

```xml
<integer name="max_depth_blur_radius">23</integer>
<dimen    name="max_depth_blur_radius_enhanced">30dp</dimen>
```

and the code hands whichever it picked to `getDimensionPixelSize()`. With
`all_apps_blur` and `enable_overview_background_wallpaper_blur` both off it takes
the `R.integer` branch; type `0x10` is `TYPE_INT_DEC`, so the lookup throws. Fix is
unambiguous: read the integer with `getInteger()` and leave the dimen branch alone.

Proposed commit message:

    Launcher3: read max_depth_blur_radius with getInteger

    ScalingWorkspaceRevealAnim selects between a dimen and an integer resource and
    passes both to getDimensionPixelSize(). max_depth_blur_radius is declared as
    <integer>, so with all_apps_blur and enable_overview_background_wallpaper_blur
    both disabled this throws Resources$NotFoundException (type 0x10,
    TYPE_INT_DEC) and crashes the launcher at the end of every swipe-up-to-home.

    Read the integer with getInteger() and keep getDimensionPixelSize() for the
    enhanced dimen.

## Reproducing without warhol

Neither bug needs this device, which is what makes them worth sending upstream.
Both need only the flags off, which is the default:

```
device_config get launcher_overview com.android.launcher3.enable_refactor_task_thumbnail   # null
```

* Build Launcher3/Quickstep with those flags at their defaults.
* Launch any app, then swipe up from the bottom edge to go home.
  `input swipe <cx> <maxY-30> <cx> <maxY/2> 120` works over adb.
* **It does not reproduce from the home screen** — the gesture only builds a
  `TaskView` when there is a task to show.

A **Cuttlefish** repro would strengthen the submission considerably and the tree
already carries `device/google/cuttlefish`. Confirming there before submitting
turns "it broke on my Xiaomi" into "it breaks on the reference target".

## Why nobody upstream has hit these

The flags are not off by accident, and they are not off everywhere. Both bugs need
`enable_refactor_task_thumbnail`, `all_apps_blur` and
`enable_overview_background_wallpaper_blur` at their **declaration** defaults, and
none of the three declares a `default:` block (`aconfig/launcher_overview.aconfig`,
`aconfig/launcher.aconfig`), so the default is DISABLED. The release configs then
override:

    build/release/aconfig/trunk_staging/com.android.launcher3/  all three ENABLED (READ_WRITE)
    build/release/aconfig/bp3a/com.android.launcher3/           all three ENABLED (READ_ONLY)
    build/release/aconfig/bp4a/com.android.launcher3/           23 launcher3 flag files, none of the three

So on `trunk_staging` and `bp3a` — what Google builds and tests — the crashing
branches are unreachable. On `bp4a`, which is what LineageOS 23.2 builds, all three
fall back to DISABLED and both crashes are live for **every** device on the branch,
not just this one. That is the argument to put in the review: it is not a
device-specific defect, it is the flag-off path of the current release config.

## Where to submit — verified 2026-09-11

**LineageOS only.** Host `review.lineageos.org`, project
`LineageOS/android_packages_apps_Launcher3` (confirmed present via the Gerrit
projects query), branch `lineage-23.2`:

    # one-time, per clone
    scp -p -P 29418 <LOS_USER>@review.lineageos.org:hooks/commit-msg .git/hooks/commit-msg
    chmod +x .git/hooks/commit-msg

    git push ssh://<LOS_USER>@review.lineageos.org:29418/LineageOS/android_packages_apps_Launcher3 \
        HEAD:refs/for/lineage-23.2

No CLA — LineageOS has none. A Gerrit account plus an SSH key is the whole gate.
Later patchsets: amend and push the same refspec; Gerrit matches on `Change-Id`.

**Not AOSP — there is nothing to patch there.** Read directly from
`android.googlesource.com/platform/packages/apps/Launcher3`, branch `main`:
`TaskView.kt` contains no `RecentsDependencies`, no `dispatcherProvider`, no
`coroutineScope` and no `TaskViewModel`, and `ScalingWorkspaceRevealAnim.kt`
contains no blur code at all — no `max_depth_blur_radius`, no
`getDimensionPixelSize`. The two blur flags are absent from AOSP's aconfig
declarations too. This file's earlier claim that AOSP is "where the bugs actually
live" was **wrong**; do not spend a CLA'd review on code that does not exist.

**Both bugs are already gone on `lineage-24.0`** — by rewrite, not by fix:
`TaskView.kt` there is Dagger-based (`@Inject lateinit var coroutineScope`,
`@Inject lateinit var viewModel`) with no eager `RecentsDependencies.get()`, and
`ScalingWorkspaceRevealAnim.kt` there reads the dimen unconditionally
(`getDimensionPixelSize(R.dimen.max_depth_blur_radius_enhanced)`) with the flag
branch deleted. So both patches are **stable-branch backfixes**: they buy
`lineage-23.2` users a working swipe-up-to-home and change nothing on the
development branch. State that in the review — it is the honest framing and it
pre-empts the "why not 24.0?" round-trip.

**Still broken at `lineage-23.2` HEAD** (re-read today, not inferred from
BASE_COMMIT): both eager declarations are present verbatim, `viewModel` is still
the only flag-guarded one of the three, and the
`getDimensionPixelSize(if (...) dimen else integer)` conditional is unchanged.
Both patches still apply.

**Upload hooks.** `PREUPLOAD.cfg` on `lineage-23.2` runs `ktfmt
--kotlinlang-style` (tool `${REPO_ROOT}/external/ktfmt/ktfmt.sh`), `bpfmt -d`
and a checkstyle hook — there is no commit-message hook, so `Bug:`/`Test:`
trailers are convention, not a gate. Ran the tree's own ktfmt
(`prebuilts/build-tools/common/framework/ktfmt.jar` under `prebuilts/jdk/jdk21`)
over both patched files:

* `TaskView.kt` — **no change**. The 100-column `by lazy` line sits exactly at
  kotlinlang's 100-column limit and passes.
* `ScalingWorkspaceRevealAnim.kt` — ktfmt **did** rewrap 0002's own hunk,
  collapsing the wrapped `getDimensionPixelSize(\n R.dimen...\n)` call onto one
  96-column line. **0002 has been regenerated in that form** (previous copy kept
  as `0002-....patch.bak-prektfmt`), and ktfmt is now a no-op on both files.

Submit under your own git identity; these files carry none deliberately.

## If you would rather patch_tree consumed these files directly

`patch_tree()` currently reimplements both edits inline. Pointing it at these
patches with `git apply --check && git apply` would give a single source of truth.
The tradeoff: the inline edits are idempotent and tolerate surrounding context
drift across a `repo sync`, whereas `git apply` fails when context moves. Keep the
inline form while the tree is moving; switch once it settles.
