# Building PixelXpert-Next

## Requirements

- **JDK 21** (to run Gradle; app code targets JVM 17).
- **Android SDK**: Platform 36, `build-tools;36.0.0`, `platform-tools`.
- **No NDK / CMake** — the `ndk { abiFilters }` block only filters prebuilt PyTorch `.so`
  files; nothing is compiled natively. The Xposed API is a bundled jar (`app/lib/api-82.jar`).

## First-time setup

1. **Clone with submodules** (or init after cloning):
   ```bash
   git clone --recurse-submodules https://github.com/Meapri/PixelXpert-Next.git
   # or, if already cloned:
   git submodule update --init --recursive
   ```
   `:Submodules:RangeSliderPreference` **must** be populated, or Gradle fails with
   `No matching variant of project :Submodules:RangeSliderPreference … No variants exist.`

2. **Point Gradle at the SDK** — create `local.properties` (gitignored) in the repo root:
   ```properties
   sdk.dir=C\:\\Users\\<you>\\AppData\\Local\\Android\\Sdk
   ```

## Build

```bash
./gradlew assembleDebug          # debug APK → app/build/outputs/apk/debug/PixelXpert.apk
./gradlew buildCanary -Pchannel=canary   # canary Magisk module zip (what CI runs)
```

## Windows notes

These are the exact steps used to bootstrap a fresh Windows machine (no Android Studio):

```powershell
winget install Microsoft.OpenJDK.21
# Android SDK via cmdline-tools:
#   download commandlinetools-win-*.zip → %LOCALAPPDATA%\Android\Sdk\cmdline-tools\latest\
#   accept licenses + install packages (feed "y" via a file on stdin — piping a single
#   "y" only accepts one of several licenses):
sdkmanager --sdk_root="%LOCALAPPDATA%\Android\Sdk" --licenses < yes.txt
sdkmanager --sdk_root="%LOCALAPPDATA%\Android\Sdk" "platform-tools" "platforms;android-36" "build-tools;36.0.0" < yes.txt
```

- **Use Git Bash to run Gradle**, not `cmd`/PowerShell wrappers:
  ```bash
  JAVA_HOME="/c/Program Files/Microsoft/jdk-21.0.11.10-hotspot" \
  ANDROID_HOME="/c/Users/<you>/AppData/Local/Android/Sdk" \
  sh ./gradlew assembleDebug --console=plain
  ```
  (`cmd /c "cd /d … && gradlew.bat"` was unreliable in practice.)
- Don't pipe Gradle to `| tail` when you care about pass/fail — the pipe's exit code hides
  Gradle's. Redirect to a file and check `$?` instead.

## Release / signing

Release and canary builds are signed from `ReleaseKey.properties` (gitignored) + a keystore.
CI (`.github/workflows/makeCanaryRelease.yml`) supplies these from GitHub Actions secrets
(`SIGNING_KEY`, `ALIAS`, `KEY_STORE_PASSWORD`, `KEY_PASSWORD`, plus Telegram secrets for the
release announcement). Those secrets are **not yet configured for this fork** — automated
releases will not work until they are. Debug builds sign with the standard debug key and
need none of this.
