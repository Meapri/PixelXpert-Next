# PixelXpert-Next

**A community continuation of [PixelXpert](https://github.com/siavash79/PixelXpert) by @siavash79 & @ElTifo, which was archived by its original authors.**

The upstream project was [shut down indefinitely](https://xdaforums.com/t/closed-mod-xposed-magisk-android-16-compatible-pixel-xpert-system-modifications-for-pixel-phones-12.4421743/post-90634455). PixelXpert-Next picks it up from the last `canary` state to keep it building and working on current Android/Pixel firmware. All credit for the original work belongs to the upstream authors and contributors.

> **Status:** Early — this fork has just been rewired for independent builds/updates. Phase A = keep it compiling and working on the latest Pixel stock firmware. Phase B (later) = new customizations.

<hr>

PixelXpert is a mixed **Xposed + Magisk** module that enables customizations not available in AOSP, hooking into the system framework and SystemUI on **Google Pixel stock firmware**.

### Features
Customizations across:
- Status bar
- Quick Settings panel
- Lock screen
- Notifications
- Gesture Navigations
- Phone & Dialer
- Hotspot
- Package Manager
- Screen properties
<hr>

### Compatibility
**ONLY** compatible with Google Pixel devices on **stock Pixel firmware**. Custom ROMs (PixelExperience, etc.) and non-Pixel stock ROMs (OneUI, MIUI, …) are not supported. This fork targets **Android 16 (compileSdk/minSdk 36)** and newer, continuing from upstream's final canary line.

For older Android versions, use the upstream releases:
- Android 12/12.1 & 13 (up to Nov 2022): [v2.4.1](https://github.com/siavash79/PixelXpert/releases/tag/v2.4.1)
- Android 13 QPR3 → 16 (June 2025): [v4.3.0](https://github.com/siavash79/PixelXpert/releases/tag/v4.3.0)
<hr>

### Prerequisites
- Compatible Pixel stock ROM (see Compatibility)
- Rooted with Magisk 24.2+ or KernelSU
- LSPosed (Zygisk preferred). For Android 14+ use the [LSPosed fork by JingMatrix](https://github.com/JingMatrix/LSPosed/releases)
<hr>

### How to install
1. Build the Magisk module zip (see Building below) — no prebuilt releases are published for this fork yet
2. Install the zip in Magisk/KernelSU
3. Reboot
4. Open the PixelXpert app and apply changes

For KernelSU, grant root access to PixelXpert manually (it isn't requested automatically as in Magisk).
<hr>

### Building
Requires **JDK 21** and the **Android SDK (Platform 36, build-tools)**. No NDK compilation is needed. The Xposed API jar is bundled under `app/lib/`.

```
./gradlew assembleDebug        # debug APK
./gradlew buildCanary -Pchannel=canary   # canary Magisk module (as CI does)
```

Release/canary builds are signed via `ReleaseKey.properties` + a keystore; see `.github/workflows/makeCanaryRelease.yml` for the CI pipeline.
<hr>

### Credits
Original PixelXpert by **@siavash79 & @ElTifo**, with UI by @Mahmud0808 and many contributors. Built on Magisk (@topjohnwu), Xposed (@rovo89), LSPosed, and others. See upstream for the full credit list. This fork exists only to continue their open-source work.
<hr>

### License
Same license as upstream — see [LICENSE](LICENSE).
