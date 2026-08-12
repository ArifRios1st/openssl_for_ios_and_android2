# OpenSSL for iOS and Android — rebuilt

Clean rebuild of the old `openssl_for_ios_and_android` project. The old project is used only as a reference; this repository does not copy its CI workflow or build implementation.

## What changed

- GitHub Actions uses `workflow_dispatch`, so an Android build can be triggered with:
  - **Android API level**
  - **Android NDK version**
  - target (`android`, `ios`, or `both`)
  - OpenSSL / nghttp2 / cURL versions
- Android uses the side-by-side NDK installed by `sdkmanager` instead of the obsolete `ndk-bundle` path.
- Build scripts use the NDK LLVM toolchain directly and pass `-D__ANDROID_API__=<api>` to OpenSSL.
- `set -u` / undefined environment-variable failures from the old scripts are removed.
- Every build step fails immediately on a real compile/configure error; no `|| true` masking of failed builds.
- Modern GitHub Actions versions (`checkout@v4`, `upload-artifact@v4`) are used.
- Dependencies are downloaded into a temporary build directory and are not committed to the repository.
- Android output is packaged per ABI and also as one combined archive.

## CI

Open **Actions → Build Libraries → Run workflow** and choose:

- `target`: `android`, `ios`, or `both`
- `android_api`: for example `23`, `26`, `29`, `35`
- `ndk_version`: an Android SDK side-by-side NDK package version, for example `27.2.12479018`
- component versions as required

The Android build currently produces `armeabi-v7a`, `arm64-v8a`, `x86`, and `x86_64`.

## Local Android build

```bash
export ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/27.2.12479018"
./scripts/build-android.sh 23 27.2.12479018
```

The second argument is informational/validation input; `ANDROID_NDK_ROOT` remains the source of truth for local builds.

## Local iOS build

Run on macOS with Xcode command-line tools installed:

```bash
./scripts/build-ios.sh
```

The iOS script builds arm64 device libraries and arm64 simulator libraries, then creates XCFrameworks for OpenSSL, nghttp2, and cURL.

## Output

```text
dist/
  android/
    <abi>/lib/libcrypto.a
    <abi>/lib/libssl.a
    <abi>/lib/libnghttp2.a
    <abi>/lib/libcurl.a
    <abi>/include/...
  ios/
    OpenSSL.xcframework
    nghttp2.xcframework
    cURL.xcframework
```

## Security / reproducibility

The versions are explicit workflow inputs instead of being silently tied to a 2020-era toolchain. For production use, pin dependency checksums in `config/checksums.env` after deciding which exact dependency versions are approved.
