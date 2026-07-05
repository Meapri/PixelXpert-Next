# Adding a new modpack (customization)

A **modpack** is one customization: a class that hooks a target app and reacts to its own
settings. Thanks to the compile-time annotation processor, you only write the class and add
its settings — registration is automatic. See [ARCHITECTURE.md](ARCHITECTURE.md) §2 for how
the machinery works.

## Steps

### 1. Create the class

Put it under the package for your target app, e.g.
`app/src/main/java/sh/siava/pixelxpert/xposed/modpacks/systemui/MyFeature.java`.

```java
package sh.siava.pixelxpert.xposed.modpacks.systemui;

import static sh.siava.pixelxpert.xposed.XPrefs.Xprefs;

import android.content.Context;
import io.github.libxposed.api.XposedModuleInterface.PackageReadyParam;
import sh.siava.pixelxpert.xposed.XposedModPack;
import sh.siava.pixelxpert.xposed.annotations.SystemUIModPack;
// import sh.siava.pixelxpert.xposed.utils.toolkit.ReflectedClass; // adjust to actual package

@SystemUIModPack                       // target app = com.android.systemui, main process
public class MyFeature extends XposedModPack {

    private boolean myFeatureEnabled = false;

    public MyFeature(Context context) { super(context); }

    @Override
    public void onPreferenceUpdated(String... Key) {
        // Called once at load (Key is empty) and again on each relevant change.
        myFeatureEnabled = Xprefs.getBoolean("MyFeatureEnabled", false);
    }

    @Override
    public void onPackageLoaded(PackageReadyParam PRParam) throws Throwable {
        ReflectedClass.of("com.android.systemui.some.TargetClass")
            .after("someMethod")
            .run(param -> {
                if (!myFeatureEnabled) return;
                // read/modify param.args, param.thisObject, param.getResult()/setResult(...)
            });
    }
}
```

### 2. Pick the right annotation

| Annotation | Target app |
| --- | --- |
| `@SystemUIModPack` | `com.android.systemui` |
| `@FrameworkModPack` | `android` (system_server) |
| `@SettingsModPack` | `com.android.settings` |
| `@LauncherModPack` | `com.google.android.apps.nexuslauncher` |
| `@DialerModPack` | `com.google.android.dialer` |
| `@TelecomServerModPack` | `com.android.server.telecom` |
| `@CommonModPack` | every hooked package |

Modifiers (optional):
- `@ChildProcessModPack(processNameContains = "screenshot")` — only run in a child process
  whose name contains that substring. Add `@MainProcessModPack` too if it should run in
  **both** main and child.
- `@ModPackPriority(priority = 10)` — lower loads earlier (default 99).

If your target app isn't in the table, it must also be added to
`app/src/main/resources/META-INF/xposed/scope.list` (and a matching `@BaseModPack`
annotation created) so LSPosed injects into it.

### 3. Add the setting(s)

1. Define the key's default and a UI control in the relevant
   `app/src/main/res/xml/<screen>_prefs.xml` (e.g. a `MaterialSwitchPreference` with
   `android:key="MyFeatureEnabled"`). Use the **same key** you read via `Xprefs`.
2. Add user-facing strings in `app/src/main/res/values/strings.xml` (translations flow
   through Crowdin — English is the source).

### 4. Build

```bash
./gradlew assembleDebug
```

The annotation processor regenerates `xposed/ModPacks` including your class — no manual
registration. Confirm it appears in `app/build/generated/sources/…/ModPacks.java`.

### 5. Test on device

Install, enable in LSPosed for the target app's scope, reboot / restart SystemUI, toggle
your setting. See [ARCHITECTURE.md](ARCHITECTURE.md) §3 for why some changes need a
SystemUI/device restart.

## Gotchas

- **Reflection targets drift between Android versions.** Class/method names under
  `com.android.systemui.*` change across QPRs — this is the #1 source of breakage and the
  main Phase-A maintenance task. Wrap risky lookups defensively and log failures (the base
  class extends `Logger`).
- **Cache prefs in `onPreferenceUpdated`, don't read `Xprefs` inside a hot hook callback.**
- **Child vs main process**: if your hook never fires, check whether the class actually
  loads in the main process or a `:child` process, and set the process annotations
  accordingly.
