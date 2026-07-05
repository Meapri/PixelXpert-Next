# PixelXpert-Next — Architecture

Orientation for developers continuing the project. This describes how the module is
structured and how its pieces talk to each other, with concrete file references so you
can jump straight into the code.

> This is a fork continuing the archived upstream `siavash79/PixelXpert`. The design
> below is inherited from upstream; this doc simply makes it explicit.

---

## 1. The big picture

PixelXpert is **one APK that plays three roles**, running in **different processes**:

| Role | Where it runs | What it does |
| --- | --- | --- |
| **Settings app** | Its own app process (`sh.siava.pixelxpert`) | UI to toggle features; talks to the root service; runs the in-app updater |
| **Xposed hooks** | Injected into *other* apps' processes (SystemUI, `android`/system_server, Launcher, Settings, Dialer…) | The actual customizations, done by hooking framework classes at runtime |
| **Root service** | A root process spawned via Magisk/libsu | Privileged work: LSPosed DB edits, shell commands, root file ops |

Because these live in **separate processes**, most of the architecture is about
**cross-process communication**: how settings reach the hooks, and how the hooks reach
root. Two mechanisms carry that:

- **RemotePreferences** (a `ContentProvider`) — pushes settings changes from the app into
  the hook processes.
- **AIDL services** — let the app and the hooks call the root/proxy services.

```
        ┌─────────────────────────┐
        │  Settings app process   │
        │  (sh.siava.pixelxpert)  │
        │                         │
        │  PixelXpert (Application)│
        │  SettingsActivity/UI    │
        │  RemotePrefProvider  ───┼───────────── ContentProvider ──────────┐
        │  PixelXpertProxy (AIDL) │                                        │
        │  RootProvider bind ─────┼── libsu ──┐                            │
        └─────────────────────────┘           │                           │
                                              ▼                           ▼
                                 ┌───────────────────┐      ┌──────────────────────────┐
                                 │  Root process     │      │  Hooked app process       │
                                 │  RootProvider     │      │  (e.g. com.android.systemui)│
                                 │  (IRootProvider-  │      │                            │
                                 │   Service, sqlite)│      │  XPLauncher (entry)        │
                                 └───────────────────┘      │  XPrefs (reads prefs)      │
                                                            │  running modpacks          │
                                                            └──────────────────────────┘
```

---

## 2. The hook / modpack system (the heart of the project)

Every customization is a **modpack**: a class that hooks one target app. Modpacks are
**auto-discovered at compile time** by a custom annotation processor — you never register
them by hand.

### 2.1 Entry point

- Xposed init file: `app/src/main/resources/META-INF/xposed/java_init.list` → declares
  `sh.siava.pixelxpert.xposed.XPLauncher`.
- Scope (which apps LSPosed injects into):
  `app/src/main/resources/META-INF/xposed/scope.list`
  (systemui, `android`, nexuslauncher, settings, dialer, kernelsu, ksunext).
- [`XPLauncher`](../app/src/main/java/sh/siava/pixelxpert/xposed/XPLauncher.java) extends
  the libxposed `XposedModule`. Key methods:
  - `onSystemServerStarting` — captures the framework classloader.
  - `onPackageReady(PackageReadyParam)` — **the main hook point**, fires per loaded
    package. It grabs a `Context`, initializes `XPrefs`, then calls `loadModPacks()`.

### 2.2 Modpack base class

[`XposedModPack`](../app/src/main/java/sh/siava/pixelxpert/xposed/XposedModPack.java) —
every modpack extends this:

```java
public abstract class XposedModPack extends Logger {
    protected Context mContext;
    public XposedModPack(Context context) { mContext = context; }

    public abstract void onPreferenceUpdated(String... Key);          // settings changed
    public abstract void onPackageLoaded(PackageReadyParam PRParam);  // register hooks here
}
```

- `onPackageLoaded` — where you install your Xposed hooks (via the `ReflectedClass`
  toolkit, see §2.5).
- `onPreferenceUpdated` — called once at load (empty `Key`) and again whenever a relevant
  setting changes (`Key[0]` = the changed key). Cache pref values in fields here.

### 2.3 How modpacks are registered (annotation processor)

You mark a modpack with an annotation naming its target app. A compile-time processor
scans for these and **generates** `ModPacks.getModPacks()` — a flat registry list. No
manual wiring.

- Meta-annotations (the `annotations/` Gradle module):
  `BaseModPack(targetPackage=…)`, `MainProcessModPack`, `ChildProcessModPack(processNameContains=…)`,
  `ModPackPriority(priority=…)`, and the `ModPackData` value class.
- Convenience annotations you actually use, in
  [`xposed/annotations/`](../app/src/main/java/sh/siava/pixelxpert/xposed/annotations):
  `@SystemUIModPack` (`com.android.systemui`), `@FrameworkModPack` (`android`),
  `@SettingsModPack`, `@LauncherModPack`, `@DialerModPack`, `@TelecomServerModPack`,
  `@KSUModPack`, `@KSUNextModPack`, `@CommonModPack` (all packages).
- Processor:
  [`AnnotationProcessor`](../annotationProcessor/src/main/java/sh/siava/pixelxpert/annotationprocessor/AnnotationProcessor.java)
  — uses JavaPoet to emit `sh.siava.pixelxpert.xposed.ModPacks` (found after a build under
  `app/build/generated/sources/…/ModPacks.java`). It sorts by `@ModPackPriority` (lower =
  earlier).

### 2.4 Package & process matching

`XPLauncher.loadModPacks()` walks `ModPacks.getModPacks()` and instantiates a modpack when
**both** match:

1. **Package**: `targetPackage` equals the loaded package, OR is empty (`@CommonModPack`),
   OR is `android` while in `system_server`.
2. **Process**: the current process name `contains` the modpack's `childProcessName`
   (empty string ⇒ main process ⇒ matches anything).

This is how a modpack can target, say, only the `com.android.systemui:screenshot` child
process (see `ScreenshotManager` with `@ChildProcessModPack(processNameContains="screenshot")`).

### 2.5 Doing the actual hook

Inside `onPackageLoaded`, hooks are written with the project's reflection toolkit
(`ReflectedClass`, under `xposed/utils/`), e.g.:

```java
ReflectedClass.of("com.android.systemui.qs.tiles.FlashlightTileWithLevel")
    .after("handleUpdateState")
    .run(param -> { /* read/modify param.args, param.thisObject, param.setResult(...) */ });
```

Good reference modpacks:
- `xposed/modpacks/systemui/FlashlightTile.java` — simple main-process SystemUI hook.
- `xposed/modpacks/systemui/ScreenshotManager.java` — child-process targeting.
- `xposed/modpacks/android/PackageManager.java` — framework/system_server hook.

> **Adding a new customization is Phase B's bread and butter — see
> [ADDING_A_MODPACK.md](ADDING_A_MODPACK.md) for a step-by-step recipe.**

---

## 3. Settings flow (app → hooks)

Settings toggled in the app must reach hook code running in *another app's* process. The
bridge is **RemotePreferences over a ContentProvider**.

1. **UI → storage.** Preference screens are XML under `app/src/main/res/xml/*.xml`, built
   with custom Material preference widgets (`MaterialSwitchPreference`,
   `MaterialRangeSliderPreference`, …). Each has an `android:key`. Fragments extend
   [`ControlledPreferenceFragmentCompat`](../app/src/main/java/sh/siava/pixelxpert/utils/ControlledPreferenceFragmentCompat.java)
   and read/write the app's device-protected SharedPreferences
   (`sh.siava.pixelxpert_preferences`, see `Constants.java`).
2. **Provider.** [`RemotePrefProvider`](../app/src/main/java/sh/siava/pixelxpert/utils/RemotePrefProvider.java)
   (authority `sh.siava.pixelxpert`, declared in `AndroidManifest.xml`) exposes that prefs
   file across process boundaries.
3. **Hook side reads.** [`XPrefs`](../app/src/main/java/sh/siava/pixelxpert/xposed/XPrefs.java)
   holds a static `Xprefs` (`ExtendedRemotePreferences`) initialized from `XPLauncher`. It
   registers a change listener; when a pref changes it calls `loadEverything(pkg, key)`,
   which invokes **every running modpack's** `onPreferenceUpdated(key)`.
4. **Modpack caches value.** Each modpack re-reads `Xprefs.getBoolean(...)` /
   `getSliderInt(...)` into its fields and reacts.

```
UI widget → SharedPreferences → RemotePrefProvider (ContentProvider)
   → XPrefs listener (in hook process) → loadEverything() → modpack.onPreferenceUpdated()
```

Some setting changes require restarting SystemUI or the device; the UI surfaces this via
`StateManager` LiveData and the FABs in `SettingsActivity` (`AppUtils.restart("systemui"|"system")`).

---

## 4. Root service & privileged work

Two AIDL services, both defined under `app/src/main/aidl/sh/siava/pixelxpert/`:

| AIDL | Impl | Runs in | Used for |
| --- | --- | --- | --- |
| `IRootProviderService` | [`RootProvider`](../app/src/main/java/sh/siava/pixelxpert/service/RootProvider.java) (extends libsu `RootService`) | **root** process | `checkLSPosedDB`, `activateInLSPosed`, `isPackageInstalled`, `getFileSystemService` |
| `IPixelXpertProxy` | [`PixelXpertProxy`](../app/src/main/java/sh/siava/pixelxpert/service/PixelXpertProxy.java) | app process | `runRootCommand`, `extractSubject` (MLKit/PyTorch subject segmentation) |

- The **app** binds the root service in `PixelXpert.connectRootService()` via
  `RootService.bind(...)` (libsu, backed by Magisk), waiting up to 5s for the binder.
- The **hooks** bind `PixelXpertProxy` from `XPLauncher` (`connectRootService()` /
  `enqueueProxyCommand(...)`), so hook code can request root commands without holding root
  itself. `PixelXpertProxy.ensureSecurity()` whitelists callers.
- `RootProvider` edits the **LSPosed SQLite DB** (`/data/adb/lspd/config/modules_config.db`)
  using the bundled `sqlite3` binary (`MagiskModBase/sqlite3`) to self-activate the module
  in scope. (Note: automated activation is disabled with official LSPosed — see
  CanaryChangelog; JingMatrix's fork is recommended.)

---

## 5. In-app updater

- [`UpdateFragment`](../app/src/main/java/sh/siava/pixelxpert/ui/fragments/UpdateFragment.java)
  fetches a channel JSON, compares `versionCode` against `BuildConfig.VERSION_CODE`
  (or a pending `/data/adb/modules_update/PixelXpert/module.prop`), and downloads the module
  zip via Android `DownloadManager`, then installs it (`AppUtils.installDoubleZip`).
- Channel JSONs (now pointing at **our** fork after the de-upstreaming pass):
  - canary → `raw.githubusercontent.com/Meapri/PixelXpert-Next/canary/latestCanary.json`
  - stable → `.../stable/latestStable.json`
- The Magisk-manager update path uses `MagiskModBase/module.prop`'s `updateJson` →
  `MagiskModuleUpdate_Xposed.json`.
- PyTorch runtime assets (the `.so` + `u2net.ptl` model, kept out of the APK to shrink it)
  are downloaded on demand by
  [`PyTorchSegmentor`](../app/src/main/java/sh/siava/pixelxpert/utils/PyTorchSegmentor.java)
  from our canary branch (`app/lib/…`, `app/pytorchModel/…`).

> All of the above URLs were repointed from `siavash79/PixelXpert` to
> `Meapri/PixelXpert-Next`. If you rename the repo or change the default branch, grep for
> `Meapri/PixelXpert-Next` and update these together.

---

## 6. Module structure & build

- Gradle modules (`settings.gradle.kts`): `:app`, `:annotations`,
  `:annotationProcessor`, `:Submodules:RangeSliderPreference` (git submodule).
- `:app` — the Android app; `compileSdk/target/minSdk = 36` (Android 16), JVM 17, Hilt +
  KSP, view binding, AIDL. Xposed API is a `compileOnly` jar at `app/lib/api-82.jar`.
- Build & environment details: see [BUILDING.md](BUILDING.md).

### Key file map

| Concern | File |
| --- | --- |
| Xposed entry | `xposed/XPLauncher.java`, `resources/META-INF/xposed/java_init.list` |
| Modpack base | `xposed/XposedModPack.java` |
| Annotations | `annotations/…`, `xposed/annotations/…` |
| Registry generator | `annotationProcessor/…/AnnotationProcessor.java` → generated `xposed/ModPacks` |
| Prefs bridge | `utils/RemotePrefProvider.java`, `xposed/XPrefs.java`, `utils/ExtendedSharedPreferences.java` |
| App entry | `PixelXpert.java` (`@HiltAndroidApp`), `ui/activities/SettingsActivity.java` |
| Root/AIDL | `service/RootProvider.java`, `service/PixelXpertProxy.java`, `aidl/…` |
| Updater | `ui/fragments/UpdateFragment.java` |
| Modpacks | `xposed/modpacks/{systemui,android,launcher,settings,dialer,allApps,ksu}/` |
