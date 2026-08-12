# OpenSSL for iOS and Android — rebuilt

Clean rebuild of the old `openssl_for_ios_and_android` project. The old project is used only as a reference; this repository does not copy its CI workflow or build implementation.

## What changed

- GitHub Actions uses `workflow_dispatch`, so a build can be triggered with:
  - target (`android`, `ios`, or `both`)
  - Android API level
  - Android NDK version
  - OpenSSL / nghttp2 / cURL versions
  - minimum iOS version
- The default target is now **both**, so iOS is not silently skipped on a normal Run workflow.
- Android uses the side-by-side NDK installed by `sdkmanager` instead of the obsolete `ndk-bundle` path.
- Android uses the NDK LLVM toolchain and passes `-D__ANDROID_API__=<api>` to OpenSSL.
- Build scripts are invoked through `bash`, so executable-bit problems do not block CI.
- The workflow uploads **only the final ZIP package**, avoiding the previous ZIP-inside-ZIP artifact layout.
- A successful run automatically creates a GitHub Release with a generated title and a release table containing library, version, platform support, and architecture support. The old `pull commit` column is intentionally omitted.
- Android output contains `armeabi-v7a`, `arm64-v8a`, `x86`, and `x86_64`.
- Android release ZIP includes `CMakeLists.txt` and `Android.mk` for direct integration of the prebuilt static libraries.
- iOS output contains arm64 device and arm64 simulator XCFramework slices.

## CI

Open **Actions → Build Libraries → Run workflow** and choose:

- `target`: `android`, `ios`, or `both` (default: `both`)
- `android_api`: for example `23`, `26`, `29`, `35`
- `ndk_version`: an Android SDK side-by-side NDK package version, for example `27.2.12479018`
- component versions as required

If `target=android`, the iOS job is intentionally shown as **Skipped**. If you want both platforms, select `both`.

## Release

After the selected build jobs finish successfully, the `release` job publishes the final ZIP package(s) directly to GitHub Releases.

Examples of generated release titles:

- `[Only Android] OpenSSL-4.0.1, nghttp2-1.70.0 and cURL-8.21.0`
- `[Only iOS] OpenSSL-4.0.1, nghttp2-1.70.0 and cURL-8.21.0`
- `[Android + iOS] OpenSSL-4.0.1, nghttp2-1.70.0 and cURL-8.21.0`

The release body uses this format:

| library | version | platform support | arch support |
|---|---|---|---|
| OpenSSL | 4.0.1 | Android | armeabi-v7a, arm64-v8a, x86, x86_64 |
| nghttp2 | 1.70.0 | Android | armeabi-v7a, arm64-v8a, x86, x86_64 |
| cURL | 8.21.0 | Android | armeabi-v7a, arm64-v8a, x86, x86_64 |

For iOS releases, the platform column shows the configured minimum iOS version and the architecture column shows arm64 device/simulator.

## Android integration

Every Android release ZIP contains:

```text
CMakeLists.txt
Android.mk
ANDROID-IMPORT.md
armeabi-v7a/{include,lib}/
arm64-v8a/{include,lib}/
x86/{include,lib}/
x86_64/{include,lib}/
```

### CMake

Add the extracted package as a subdirectory. The package automatically selects the library directory matching `ANDROID_ABI`:

```cmake
add_subdirectory(
    /path/to/openssl-for-android
    ${CMAKE_BINARY_DIR}/openssl-for-android
)

target_link_libraries(my_app PRIVATE openssl_android::all)
```

For cURL only:

```cmake
target_link_libraries(my_app PRIVATE openssl_android::curl)
```

The package also exposes `OpenSSL::Crypto` and `OpenSSL::SSL` compatibility aliases.

### Android.mk

Include the package `Android.mk` from your application's `Android.mk`:

```make
include $(LOCAL_PATH)/../openssl-for-android/Android.mk
```

Then add the required static modules:

```make
LOCAL_STATIC_LIBRARIES += curl_static ssl_static crypto_static nghttp2_static
```

The package exports the ABI-specific headers automatically.

## Local Android build

```bash
export ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/27.2.12479018"
bash ./scripts/build-android.sh 23 27.2.12479018
```

## Local iOS build

Run on macOS with Xcode command-line tools installed:

```bash
bash ./scripts/build-ios.sh
```
