# Build fixes compared with the legacy project

## 1. Obsolete NDK discovery

The old CI pointed `ANDROID_NDK_ROOT` at `ndk-bundle`. Modern Android SDKs use side-by-side NDK packages. The new workflow installs the exact requested package with `sdkmanager` and exports its absolute path.

## 2. API level is explicit

The Android build receives the requested API level and passes `-D__ANDROID_API__=<api>` to OpenSSL. This follows the current OpenSSL Android build guidance and avoids the old `CROSS_SYSROOT` approach.

## 3. Undefined variable failures

The legacy scripts used `set -u` and later expanded variables such as `LDFLAGS` before guaranteeing that they existed. The rebuilt scripts initialize `CPPFLAGS`, `CFLAGS`, `CXXFLAGS`, and `LDFLAGS` before use.

## 4. Failed commands were masked

The old CI moved artifacts with `|| true` and several shell functions continued after failed `make` commands. The new scripts use `set -Eeuo pipefail` and each configure/build/install command is a hard failure.

## 5. Deprecated Actions

The old workflow used `actions/checkout@v1`, `actions/upload-artifact@v1`, `actions/create-release@v1`, and `actions/upload-release-asset@v1`. The rebuilt workflow uses current checkout/upload-artifact actions and lets GitHub Actions retain build artifacts instead of relying on the removed release-upload pattern.

## 6. OpenSSL Android toolchain

The current OpenSSL Android notes require an explicit Android target and an NDK LLVM toolchain on `PATH`; for older API levels, `-D__ANDROID_API__=N` is the supported mechanism. The rebuilt script follows that model.
