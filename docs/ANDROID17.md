# Android 17 (A17) Migration Spec & Playbook

**Audience:** developers (esp. future automated agents) continuing PixelXpert-Next on Android 17
stable and newer. This is the authoritative record of what changed in A17, how to *find* what
broke, how to *fix* it, and how to *verify* on a device. Read [ARCHITECTURE.md](ARCHITECTURE.md)
first for how the module itself works.

> Reference device for all findings below: **Pixel 10 Pro XL (`mustang`), Android 17,
> build `CP2A.260605.012`, SDK 37**, rooted with **KernelSU-Next** + LSPosed.
> Everything here was verified against that device's actual SystemUI/framework/launcher.

---

## 0. TL;DR — the mental model

A17 breakage is almost never "the whole feature crashed." It is **granular**: a hooked class was
renamed/removed, a method was renamed, or a field changed type. Because every hook goes through
`ReflectedClass.ofIfPossible(...)` / `.of(...)` and most callbacks are wrapped in
`catch (Throwable ignored) {}`, **failures are silent** — the feature just does nothing.

Three failure shapes, in order of how often they bite:

1. **Method renamed/removed** on a class that still exists → the hook attaches to *nothing*
   (`size = 0`). Runtime-only signal.
2. **Class renamed/removed** → `ofIfPossible` returns null (silent) or `.of` throws (aborts the
   whole modpack, logged as "Start Error Dump"). Static + runtime signal.
3. **Field type/shape changed** → the hook attaches and runs, but `getObjectField`/cast throws at
   call time (silently swallowed). Runtime-only, needs logging to see.

Google is aggressively migrating SystemUI to **Kotlin + Compose + a "scene" architecture** and
moving subsystems into **mainline APEX modules**. Both are the root cause of most A17 breakage.

---

## 1. The diagnostic methodology (do this for every new Android version)

This is the exact workflow that found every A17 break this cycle. Reuse it verbatim for A18+.

### 1.1 Static class audit (definitive, no device runtime needed)

Catches every **class-level** rename/removal across **all** hooked processes at once.

```bash
# 1. Extract every class our code hooks
X=app/src/main/java/sh/siava/pixelxpert/xposed
grep -rEoh 'ReflectedClass\.(of|ofIfPossible)\("[^"]+"|findClass(IfExists)?\("[^"]+"' $X \
  | grep -oE '"[^"]+"' | tr -d '"' | grep -E '^(com\.|android\.)' | sort -u > hooktargets.txt

# 2. Pull the real A17 archives from the device (see §3 for paths)
adb pull /system_ext/priv-app/SystemUIGoogle/SystemUIGoogle.apk        SystemUI.apk
adb pull /system_ext/priv-app/SettingsGoogle/SettingsGoogle.apk        settings.apk
adb pull /system_ext/priv-app/NexusLauncherRelease/NexusLauncherRelease.apk  launcher.apk
adb pull /system/framework/services.jar                                 services.jar
adb pull /system/framework/framework.jar                                framework.jar
# telecom is an APEX now — see §2.4
#   IMPORTANT: prefix adb pull of /system* paths with MSYS_NO_PATHCONV=1 in Git Bash

# 3. Extract present class descriptors from each archive
for a in SystemUI settings launcher services framework; do
  f="$a.apk"; [ -f "$f" ] || f="$a.jar"
  unzip -o -q "$f" 'classes*.dex' -d "dex_$a"
  cat "dex_$a"/classes*.dex | grep -ao 'L\(com/android\|com/google/android\|android\)/[A-Za-z0-9_/$]*;' \
    | sort -u >> present_all.txt
done
sort -u present_all.txt -o present_all.txt

# 4. Diff: any hooked class whose descriptor is absent everywhere is GONE on A17
while read c; do d="L$(echo "$c" | tr '.' '/');"
  grep -qxF "$d" present_all.txt || echo "MISSING: $c"; done < hooktargets.txt
```

Caveats: nested classes need `$` not `.` (e.g. `Foo.Bar` → `LFoo$Bar;`). A "missing"
`StatusBarIconController$IconManager` may be an intentional legacy fallback — always check the
call site before treating a miss as a bug.

### 1.2 Runtime method audit (catches renamed methods + field breakage)

The class exists but a hooked method is gone → `size = 0`. Only visible at runtime.

- Flip the debug flag: `ReflectedClass.FLAG_DEBUG_HOOKS = true`. Every hook then logs
  `... Hook to <class> before/after method <m> size = N`. **`size = 0` means the hook matched
  nothing** = that method is gone on this Android version.
- Build, install (`adb install -r`, debug keystore matches so it reinstalls over itself), then
  re-trigger hook registration by restarting the target process:
  - SystemUI: `adb shell su -c 'killall com.android.systemui'`
  - Launcher: `adb shell su -c 'kill -9 $(pgrep -f nexuslauncher)'`
  - Settings/Dialer: open the app.
  - `android`/system_server + telecom: **reboot** (can't restart in place — see §4 on the log-
    rotation problem).
- Capture: `adb logcat | grep -iE 'size = 0|Start Error Dump'`. Tag is
  **`PixelXpert Lsposed Module`**.
- **Null `ofIfPossible` classes do NOT log even with the flag** (the hook helper early-returns on
  `clazz == null` before the size log). Those are only caught by the static audit (§1.1).

### 1.3 Field-shape breakage (needs targeted logging)

When a class + method are fine but a `getObjectField`/cast throws, replace the silent
`catch (Throwable ignored) {}` with `log(..., t)` (the base `XposedModPack` extends `Logger`, so
`log()` is available). This is how the status-bar icon bug was pinpointed (see §2.1).

### 1.4 Confirm the fix target with `apkanalyzer` (find the *new* name)

Once you know a class/method/field is gone, dump the real A17 class to find its replacement:

```powershell
# Run from PowerShell; the .bat rejects /c/ style JAVA_HOME
$env:JAVA_HOME = "C:\Program Files\Microsoft\jdk-21.0.11.10-hotspot"
$aa = "$env:LOCALAPPDATA\Android\Sdk\cmdline-tools\latest\bin\apkanalyzer.bat"
& $aa dex code --class com.android.systemui.some.Class SystemUI.apk | Select-String '\.method|\.field'
```

Read the smali: field declarations (`.field public final mFoo:Ljava/util/Set;`), method
signatures (`.method public getDeviceType()I`), and even inlined constant return values
(`const/4 p0, 0x2`) are all readable this way.

---

## 2. A17 structural changes catalog (verified)

Each entry: **what changed → which feature/modpack → how we handled it.**

### 2.1 Status bar icons — `StatusIconContainer.mIgnoredSlots` field type changed
- **Was** `ArrayList<String>`; **A17** `java.util.HashSet` (`Ljava/util/Set;`, concretely `new HashSet<>()`).
- Modpack: `StatusIconTuner` (hide status-bar/QS/lockscreen icons).
- **Fix:** cast to the common supertype `Collection<String>` (works on both — `clear()/add()/contains()`
  exist on both List and Set). Shipped, device-verified. The class, constructor arg, and the
  container-id detection (`status_bar_end_side_content` / `shade_header_system_icons` /
  `system_icons_container`) are **unchanged** on A17.

### 2.2 Shade is no longer "scene"-based — lockscreen gestures
- **Gone on A17:** `scene.ui.view.SceneWindowRootView`,
  `shade.domain.interactor.ShadeInteractorSceneContainerImpl`.
- **Present on A17 (the legacy shade is what A17 stable actually uses):**
  `shade.NotificationShadeWindowView` (touch root, overrides `dispatchTouchEvent`),
  `shade.domain.interactor.ShadeInteractorImpl` (exposes the same `isAnyExpanded()` StateFlow),
  `shade.NotificationPanelViewController` (still instantiated).
- Modpack: `ScreenGestures` (double-tap-to-sleep on lockscreen, hold-screen-for-torch).
- **Fix:** hook `NotificationShadeWindowView.dispatchTouchEvent` in addition to the (now-dead)
  `SceneWindowRootView`, via a shared handler; capture the shade interactor from *either*
  `ShadeInteractorSceneContainerImpl` (old) or `ShadeInteractorImpl` (A17). Shipped,
  device-verified (all chain hooks attach `size ≥ 1`).
- **Note:** the *other* legacy path in `ScreenGestures.setHooks()` (reads
  `mPulsingWakeupGestureHandler` off `NotificationShadeWindowViewController`) is **dead on A17** —
  that field is gone — hence the `catch (…) //probably 17QPR1+`. Don't rely on it.

### 2.3 Taskbar enable — `LauncherDisplayInfo.isTablet()` replaced
- **Was** `boolean isTablet()`; **A17** `int getDeviceType()` returning
  `TYPE_PHONE=0, TYPE_MULTI_DISPLAY=1, TYPE_TABLET=2, TYPE_DESKTOP=3` (3 is new in A17).
- Modpack: `TaskbarActivator` (force the taskbar on/off on phones).
- **Fix:** also hook `getDeviceType()` → return `2` (TABLET) when the taskbar should be on, `0`
  (PHONE) when off; keep the old `isTablet` hook for pre-A17. Shipped, device-verified (the
  Android "swipe up to show taskbar" onboarding popup appears = taskbar enabled on the phone).
- **Not restorable (A17 removed the methods, no replacement):**
  `TaskbarActivityContext.getLeftCornerRadius`/`getRightCornerRadius` (taskbar corner-radius
  override) and `TaskbarProfile.getHeight` (`TaskbarProfile` is now a data class with no getter —
  height is a constructor int). Those hooks now no-op harmlessly; the overrides silently don't apply.

### 2.4 Telecom is a mainline APEX now — call vibration (**UNSOLVED, see §5**)
- Telecom moved to APEX `com.android.telephonycore` (`javalib/{framework,service}-telecom.jar`).
  `com.android.server.telecom` is a 15-class **shim** with **no process**.
- `InCallController` (with unchanged `onCallStateChanged(Call,int,int)`) runs inside
  **`system_server`** (verified via `grep -a service-telecom /proc/<pid>/maps`), **not**
  `com.android.phone`. So the modpack target must be `@FrameworkModPack` (`android`), which is
  already in `scope.list`.
- **The wall:** `InCallController` lives in an **isolated APEX classloader** that none of the
  reachable loaders (default / framework / system / context) can see. The bridge that bootstraps
  it, `TelecomLoaderService$TelecomMainlineInit.init(Context)`, *is* reachable (in `services.jar`).
- **Candidate fix (on branch `diag/a17-audit`, not shipped):** watch
  `dalvik.system.BaseDexClassLoader` construction and grab the loader that can load
  `InCallController`. Unverified — see §5 for why.

### 2.5 SystemUI method renames that turned out benign (don't "fix" these)
- `settingslib.fuelgauge.BatteryStatus.getChargingSpeed` → gone, but the code already falls back to
  `calculateChargingSpeed` (present). Fine.
- `NotificationPanelViewController.startUnlockHintAnimation` → gone because A17 **removed the
  unlock-hint animation entirely** (no `*UnlockHint*` strings remain in SystemUI). The
  `DisableUnlockHintAnimation` toggle is therefore obsolete — nothing to disable. Do not fabricate
  a fix.
- `NotificationPanelViewController.createTouchHandler` → gone, but the instance is also captured via
  the constructor hook. Fine.
- `FooterView.updateColors` → renamed to `updateColors$2` (Compose synthetic); the regex hook
  `after(Pattern.compile("updateColors.*"))` still catches it. Fine.

### 2.6 Screenshot managed-profile — restructured to coroutines
- `screenshot.ScreenshotPolicyImpl.isManagedProfile` → gone. A17 uses
  `screenshot.data.repository.ProfileTypeRepositoryImpl.getProfileType(int, Continuation)` (a
  **suspend** fn returning a `ProfileType` enum: NONE/PRIVATE/WORK/CLONE/COMMUNAL).
- The *main* insecure-screenshot path (secure layers via `ScreenCaptureInternal.CaptureArgs`
  `mSecureContentPolicy`) still works. The managed-profile bypass is a niche sub-feature; hooking a
  suspend fn is fragile and unverifiable without a work profile — left obsolete on purpose.

---

## 3. A17 device paths & tools (Pixel, `mustang`)

| What | Path |
| --- | --- |
| SystemUI (Google) | `/system_ext/priv-app/SystemUIGoogle/SystemUIGoogle.apk` |
| Settings (Google) | `/system_ext/priv-app/SettingsGoogle/SettingsGoogle.apk` |
| Launcher (Nexus) | `/system_ext/priv-app/NexusLauncherRelease/NexusLauncherRelease.apk` |
| Framework | `/system/framework/framework.jar` |
| system_server services | `/system/framework/services.jar` |
| Telecom (mainline) | `/apex/com.android.telephonycore/javalib/service-telecom.jar` |
| Telecom shim (no process) | `/system/priv-app/TelecomShim/TelecomShim.apk` |
| LSPosed scope DB | `/data/adb/lspd/config/modules_config.db` |
| App prefs (device-protected) | `/data/user_de/0/sh.siava.pixelxpert/shared_prefs/sh.siava.pixelxpert_preferences.xml` |

Tooling notes (Windows dev box):
- `adb` at `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`.
- **`adb pull` of any `/system*` path must be prefixed `MSYS_NO_PATHCONV=1`** in Git Bash, or the
  path is mangled to `C:\Program Files\Git\system…`.
- `apkanalyzer` (in cmdline-tools) needs a Windows-form `JAVA_HOME`; run it from **PowerShell**.
- Root: `su -c '…'` works only after granting the shell root in the KernelSU-Next manager
  (returns `uid=0 … context u:r:ksu:s0`).
- Read a class from a dex: `apkanalyzer dex code --class <fqcn> <apk|jar>`. It also reads jars.

---

## 4. Testing & verification workflow

1. **Build** (Git Bash, see [BUILDING.md](BUILDING.md)): `sh ./gradlew assembleDebug`.
2. **Install:** `adb install -r app/build/outputs/apk/debug/PixelXpert.apk` (debug keystore ⇒
   reinstalls over the running build; no uninstall needed).
3. **Re-trigger hooks** by restarting the target process (§1.2). Only `android`/telecom need a
   full **reboot**.
4. **Flip a pref for testing** without the UI: the RemotePreferences bridge only notifies the hook
   process when the *app* writes, so external edits need a target-process restart to be re-read via
   `XPrefs.init`. Steps: `am force-stop sh.siava.pixelxpert`, edit the prefs XML with `sed`
   (insert `<boolean name="Key" value="true"/>` or `<string name="Key">1</string>` before
   `</map>`), restart the target process. **Revert after testing.** (Example: setting
   `taskBarMode`=1 made the taskbar onboarding appear, proving §2.3.)
5. **Scope:** editing `modules_config.db` directly does **not** propagate to the LSPosed daemon
   without a **reboot** (or a manager toggle). Add packages to `scope.list` in-repo; on device,
   reboot after a DB edit.

### The log-rotation trap (important)
`FLAG_DEBUG_HOOKS = true` is extremely verbose and rotates the logcat buffer within seconds, so
**early-boot `system_server` logs are usually gone before you can dump them.** Mitigations that
were tried: `persist.logd.size` up to 32M, on-device `logcat -f`, live-stream from
`wait-for-device`. None reliably captured the earliest system_server hook registration. For
`android`-process verification, prefer an **explicit unconditional `log()`** in the modpack (not
gated by `FLAG_DEBUG_HOOKS`, so far lower volume) and dump the buffer immediately at
`boot_completed`. This is an open pain point — see §5.

---

## 5. Known-hard / open problems

### 5.1 Hooking classes in isolated mainline-APEX classloaders (CallVibrator)
Mainline modules (telecom, and likely more subsystems over time) load their impl classes under a
dedicated APEX `PathClassLoader` that the standard `ReflectedClass` lookups can't see. Reaching
them needs either:
- the **BaseDexClassLoader-construction watcher** (candidate on `diag/a17-audit`): hook
  `dalvik.system.BaseDexClassLoader.<init>` and, for each new loader, try `loadClass(target)`; the
  apex loader will succeed. Risk: it runs in `system_server` and touches every classloader
  construction; unverified because (a) early-boot logs rotate and (b) confirming behavior needs a
  real phone call.
- or a **bridge hook**: `TelecomLoaderService$TelecomMainlineInit.init(Context)` is reachable and
  is where the apex loader is created — hooking it to capture the loader is the more surgical
  option if the watcher proves too risky.

**Guidance:** do not ship system_server classloader hooks without (1) verifying the hook attaches
via a low-volume explicit log, and (2) confirming no boot regression across several reboots. This
subsystem is a nice-to-have (call vibration); weigh the risk.

### 5.2 Verifying framework/system_server method hooks
Because system_server can't be restarted in place and its boot logs rotate, method-level
verification there is unreliable at runtime. **Fall back to the static method check:** grep every
hooked method name from `modpacks/android/*` against `services.jar` + `framework.jar` dex. If the
name string is absent from both, it's gone. (Done this cycle: all 21 framework method names
present ⇒ no framework method breakage on A17.)

---

## 6. Fix patterns (reusable idioms)

- **Version-robust class lookup:** prefer `ofIfPossible` + a fallback chain
  (`if (X.getClazz()==null) X = ofIfPossible(alt);`) and **guard every use with
  `if (X.getClazz()!=null)`**. A missing `ofIfPossible` class silently no-ops; a missing `.of`
  class **aborts the whole modpack** — reserve `.of` for classes you're sure survive.
- **Multi-version targeting:** a modpack may carry two `@BaseModPack`-derived annotations (e.g.
  `@TelecomServerModPack @FrameworkModPack`) — the annotation processor registers it once per
  target, so it loads in both the old and new host process. Used for CallVibrator.
- **Field type drift:** cast to the widest workable supertype (`Collection` over `ArrayList`/`Set`)
  instead of the concrete type.
- **Method renames with a synthetic suffix** (Compose, e.g. `updateColors$2`): a regex hook
  `after(Pattern.compile("name.*"))` survives them where an exact-name hook won't.
- **Shared touch/gesture logic across old+new view roots:** extract the callback into one private
  method and hook it from both the legacy and A17 classes (see `ScreenGestures.handleShadeWindowTouch`).
- **Don't fabricate fixes for removed features:** if A17 deleted the underlying behavior (unlock
  hint animation), the toggle is simply obsolete. Say so; don't invent a hook.

---

## 7. Current A17 status (2026-07-05)

| Feature | Status |
| --- | --- |
| Status-bar icon hiding | ✅ Fixed & device-verified |
| Lockscreen double-tap-to-sleep / hold-for-torch | ✅ Fixed & device-verified |
| Taskbar enable on phone | ✅ Fixed & device-verified |
| Taskbar corner-radius / height overrides | ⚪ Obsolete (A17 removed the methods) |
| Unlock-hint-animation toggle | ⚪ Obsolete (A17 removed the animation) |
| Charging speed / footer color / screenshot secure-layers | 🟢 Work via existing fallbacks |
| Screenshot managed-profile bypass | ⚪ Obsolete (coroutine restructure) |
| Call vibration | ⚠️ Diagnosed, unsolved (APEX classloader) — see §5.1 |
| Framework / Settings / Dialer mods | 🟢 No breakage found (static + runtime audit) |

Verified fixes live on `canary`. The diagnostic build (`FLAG_DEBUG_HOOKS` on, extra logging) and
the CallVibrator watcher attempt live on `diag/a17-audit`.
