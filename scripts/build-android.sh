#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

API="${1:-${ANDROID_API:-23}}"
NDK_VERSION="${2:-${ANDROID_NDK_VERSION:-27.2.12479018}}"
OPENSSL_VERSION="${OPENSSL_VERSION:-4.0.1}"
NGHTTP2_VERSION="${NGHTTP2_VERSION:-1.70.0}"
CURL_VERSION="${CURL_VERSION:-8.21.0}"

[[ "$API" =~ ^[0-9]+$ ]] || die "Android API must be numeric"
(( API >= 21 )) || die "Android API must be >= 21 for this build"

if [[ -z "${ANDROID_NDK_ROOT:-}" ]]; then
  if [[ -n "${ANDROID_SDK_ROOT:-}" && -d "${ANDROID_SDK_ROOT}/ndk/${NDK_VERSION}" ]]; then
    ANDROID_NDK_ROOT="${ANDROID_SDK_ROOT}/ndk/${NDK_VERSION}"
  elif [[ -n "${ANDROID_HOME:-}" && -d "${ANDROID_HOME}/ndk/${NDK_VERSION}" ]]; then
    ANDROID_NDK_ROOT="${ANDROID_HOME}/ndk/${NDK_VERSION}"
  fi
fi

[[ -d "${ANDROID_NDK_ROOT:-}" ]] || die "ANDROID_NDK_ROOT does not point to an installed NDK"

case "$(uname -s)" in
  Darwin)
    candidates=("darwin-arm64" "darwin-x86_64")
    ;;
  Linux)
    candidates=("linux-x86_64" "linux-arm64")
    ;;
  *)
    die "Android build is supported on macOS and Linux"
    ;;
esac

HOST_TAG=""
for candidate in "${candidates[@]}"; do
  if [[ -d "${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/${candidate}/bin" ]]; then
    HOST_TAG="$candidate"
    break
  fi
done

[[ -n "$HOST_TAG" ]] || die "NDK LLVM toolchain not found. Available hosts: $(find "${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort | tr '\n' ' ')"
TOOLCHAIN_BIN="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/${HOST_TAG}/bin"
export PATH="${TOOLCHAIN_BIN}:${PATH}"
log "Using NDK host toolchain: ${HOST_TAG}"

require_cmd curl
require_cmd tar
require_cmd make
require_cmd perl
require_cmd zip

log "Android API=${API}, NDK=${NDK_VERSION}, root=${ANDROID_NDK_ROOT}"

DOWNLOAD_DIR="${BUILD_DIR}/downloads"
SRC_DIR="${BUILD_DIR}/src/android"
OUT_DIR="${DIST_DIR}/android"
rm -rf "$SRC_DIR" "$OUT_DIR"
mkdir -p "$SRC_DIR" "$OUT_DIR"

OPENSSL_ARCHIVE="${DOWNLOAD_DIR}/openssl-${OPENSSL_VERSION}.tar.gz"
NGHTTP2_ARCHIVE="${DOWNLOAD_DIR}/nghttp2-${NGHTTP2_VERSION}.tar.gz"
CURL_ARCHIVE="${DOWNLOAD_DIR}/curl-${CURL_VERSION}.tar.gz"
fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" "$OPENSSL_ARCHIVE"
fetch "https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VERSION}/nghttp2-${NGHTTP2_VERSION}.tar.gz" "$NGHTTP2_ARCHIVE"
fetch "https://github.com/curl/curl/releases/download/curl-$(echo "$CURL_VERSION" | tr . _)/curl-${CURL_VERSION}.tar.gz" "$CURL_ARCHIVE"

abis=("armeabi-v7a" "arm64-v8a" "x86" "x86_64")
archs=("arm" "arm64" "x86" "x86_64")
targets=("armv7a-linux-androideabi" "aarch64-linux-android" "i686-linux-android" "x86_64-linux-android")
openssl_targets=("android-arm" "android-arm64" "android-x86" "android-x86_64")

build_one() {
  local abi="$1" arch="$2" target="$3" openssl_target="$4"
  local compiler="${target}${API}-clang"
  local cxx="${target}${API}-clang++"
  local prefix_root="${OUT_DIR}/${abi}"
  local openssl_prefix="${BUILD_DIR}/prefix/android/openssl-${abi}"
  local nghttp2_prefix="${BUILD_DIR}/prefix/android/nghttp2-${abi}"
  local curl_prefix="${BUILD_DIR}/prefix/android/curl-${abi}"
  local log_dir="${BUILD_DIR}/logs/android/${abi}"

  command -v "$compiler" >/dev/null 2>&1 || die "Compiler not found: $compiler"

  clean_dir "$prefix_root"
  clean_dir "$openssl_prefix"
  clean_dir "$nghttp2_prefix"
  clean_dir "$curl_prefix"
  clean_dir "$log_dir"

  export CC="$compiler"
  export CXX="$cxx"
  export AR="llvm-ar"
  export RANLIB="llvm-ranlib"
  export STRIP="llvm-strip"
  export CFLAGS="-fPIC -O2"
  export CXXFLAGS="-fPIC -O2"
  export CPPFLAGS="-D__ANDROID_API__=${API}"
  export LDFLAGS=""

  # --------------------------------------------------------------------------
  # OpenSSL
  # --------------------------------------------------------------------------
  log "[${abi}] OpenSSL ${OPENSSL_VERSION}"
  local openssl_src="${SRC_DIR}/openssl-${abi}"
  extract_tarball "$OPENSSL_ARCHIVE" "$openssl_src"
  pushd "$openssl_src" >/dev/null
  ./Configure "$openssl_target" \
    -D__ANDROID_API__="${API}" \
    no-shared \
    no-tests \
    no-apps \
    --prefix="$openssl_prefix" \
    --libdir=lib \
    >"${log_dir}/openssl-configure.log" 2>&1
  make -j"$JOBS" >"${log_dir}/openssl-build.log" 2>&1
  make install_sw >"${log_dir}/openssl-install.log" 2>&1
  popd >/dev/null

  # --------------------------------------------------------------------------
  # nghttp2
  # --------------------------------------------------------------------------
  log "[${abi}] nghttp2 ${NGHTTP2_VERSION}"
  local nghttp2_src="${SRC_DIR}/nghttp2-${abi}"
  extract_tarball "$NGHTTP2_ARCHIVE" "$nghttp2_src"
  pushd "$nghttp2_src" >/dev/null
  ./configure \
    --host="$target" \
    --prefix="$nghttp2_prefix" \
    --libdir="$nghttp2_prefix/lib" \
    --disable-shared \
    --enable-static \
    --disable-app \
    --disable-threads \
    >"${log_dir}/nghttp2-configure.log" 2>&1
  make -j"$JOBS" >"${log_dir}/nghttp2-build.log" 2>&1
  make install >"${log_dir}/nghttp2-install.log" 2>&1
  popd >/dev/null

  # --------------------------------------------------------------------------
  # cURL
  # --------------------------------------------------------------------------
  log "[${abi}] cURL ${CURL_VERSION}"
  local curl_src="${SRC_DIR}/curl-${abi}"
  extract_tarball "$CURL_ARCHIVE" "$curl_src"
  pushd "$curl_src" >/dev/null
  export CPPFLAGS="-I${openssl_prefix}/include -I${nghttp2_prefix}/include -D__ANDROID_API__=${API}"
  export LDFLAGS="-L${openssl_prefix}/lib -L${nghttp2_prefix}/lib"
  ./configure \
    --host="$target" \
    --prefix="$curl_prefix" \
    --libdir="$curl_prefix/lib" \
    --disable-shared \
    --enable-static \
    --with-openssl="$openssl_prefix" \
    --with-nghttp2="$nghttp2_prefix" \
    --without-libpsl \
    --without-libidn2 \
    --without-brotli \
    --without-zstd \
    --without-libssh2 \
    --disable-ldap \
    --disable-ldaps \
    >"${log_dir}/curl-configure.log" 2>&1
  make -j"$JOBS" >"${log_dir}/curl-build.log" 2>&1
  make install >"${log_dir}/curl-install.log" 2>&1
  popd >/dev/null

  mkdir -p "${prefix_root}/lib" "${prefix_root}/include"
  cp -f "${openssl_prefix}/lib/libcrypto.a" "${prefix_root}/lib/"
  cp -f "${openssl_prefix}/lib/libssl.a" "${prefix_root}/lib/"
  cp -f "${nghttp2_prefix}/lib/libnghttp2.a" "${prefix_root}/lib/"
  cp -f "${curl_prefix}/lib/libcurl.a" "${prefix_root}/lib/"
  cp -R "${openssl_prefix}/include/." "${prefix_root}/include/"
  cp -R "${nghttp2_prefix}/include/." "${prefix_root}/include/"
  cp -R "${curl_prefix}/include/." "${prefix_root}/include/"

  cat >"${prefix_root}/BUILD-INFO.txt" <<INFO
OpenSSL: ${OPENSSL_VERSION}
nghttp2: ${NGHTTP2_VERSION}
cURL: ${CURL_VERSION}
Android API: ${API}
Android NDK: ${NDK_VERSION}
ABI: ${abi}
INFO
}

for i in "${!abis[@]}"; do
  build_one "${abis[$i]}" "${archs[$i]}" "${targets[$i]}" "${openssl_targets[$i]}"
done

cat >"${OUT_DIR}/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.18)

# Prebuilt Android OpenSSL/nghttp2/cURL package.
# Usage from an Android CMake project:
#   add_subdirectory(/path/to/android-package ${CMAKE_BINARY_DIR}/openssl_android)
#   target_link_libraries(app PRIVATE openssl_android::curl)

if(NOT ANDROID)
  message(FATAL_ERROR "This package is intended for an Android CMake build")
endif()

set(_PACKAGE_ROOT "${CMAKE_CURRENT_LIST_DIR}")
set(_ABI "${ANDROID_ABI}")
if(NOT _ABI)
  message(FATAL_ERROR "ANDROID_ABI is required")
endif()

set(_LIB_DIR "${_PACKAGE_ROOT}/${_ABI}/lib")
set(_INC_DIR "${_PACKAGE_ROOT}/${_ABI}/include")
if(NOT EXISTS "${_LIB_DIR}")
  message(FATAL_ERROR "Unsupported Android ABI: ${_ABI}")
endif()

foreach(_lib IN ITEMS crypto ssl nghttp2 curl)
  if(NOT EXISTS "${_LIB_DIR}/lib${_lib}.a")
    message(FATAL_ERROR "Missing prebuilt library: ${_LIB_DIR}/lib${_lib}.a")
  endif()
endforeach()

function(_openssl_android_import name file)
  if(NOT TARGET ${name})
    add_library(${name} STATIC IMPORTED GLOBAL)
    set_target_properties(${name} PROPERTIES
      IMPORTED_LOCATION "${_LIB_DIR}/lib${file}.a"
      INTERFACE_INCLUDE_DIRECTORIES "${_INC_DIR}"
    )
  endif()
endfunction()

_openssl_android_import(openssl_android::crypto crypto)
_openssl_android_import(openssl_android::ssl ssl)
_openssl_android_import(openssl_android::nghttp2 nghttp2)
_openssl_android_import(openssl_android::curl curl)

# Compatibility aliases commonly used by consumers.
if(NOT TARGET OpenSSL::Crypto)
  add_library(OpenSSL::Crypto ALIAS openssl_android::crypto)
endif()
if(NOT TARGET OpenSSL::SSL)
  add_library(OpenSSL::SSL ALIAS openssl_android::ssl)
endif()

set_target_properties(openssl_android::ssl PROPERTIES
  INTERFACE_LINK_LIBRARIES "openssl_android::crypto;\$<LINK_ONLY:dl>;\$<LINK_ONLY:log>"
)
set_target_properties(openssl_android::nghttp2 PROPERTIES
  INTERFACE_LINK_LIBRARIES "\$<LINK_ONLY:dl>"
)
set_target_properties(openssl_android::curl PROPERTIES
  INTERFACE_LINK_LIBRARIES "openssl_android::ssl;openssl_android::crypto;openssl_android::nghttp2;\$<LINK_ONLY:dl>;\$<LINK_ONLY:log>"
)

add_library(openssl_android::all INTERFACE IMPORTED GLOBAL)
set_target_properties(openssl_android::all PROPERTIES
  INTERFACE_LINK_LIBRARIES "openssl_android::curl;openssl_android::nghttp2;openssl_android::ssl;openssl_android::crypto"
)
CMAKE

cat >"${OUT_DIR}/Android.mk" <<'ANDROIDMK'
# Prebuilt Android OpenSSL/nghttp2/cURL package.
# Usage from your app's Android.mk: include /path/to/package/Android.mk
# Then link with: LOCAL_STATIC_LIBRARIES += curl_static

LOCAL_PATH := $(call my-dir)
OPENSSL_ANDROID_ROOT := $(LOCAL_PATH)

include $(CLEAR_VARS)
LOCAL_MODULE := crypto_static
LOCAL_SRC_FILES := $(TARGET_ARCH_ABI)/lib/libcrypto.a
LOCAL_EXPORT_C_INCLUDES := $(OPENSSL_ANDROID_ROOT)/$(TARGET_ARCH_ABI)/include
include $(PREBUILT_STATIC_LIBRARY)

include $(CLEAR_VARS)
LOCAL_MODULE := ssl_static
LOCAL_SRC_FILES := $(TARGET_ARCH_ABI)/lib/libssl.a
LOCAL_EXPORT_C_INCLUDES := $(OPENSSL_ANDROID_ROOT)/$(TARGET_ARCH_ABI)/include
LOCAL_STATIC_LIBRARIES := crypto_static
include $(PREBUILT_STATIC_LIBRARY)

include $(CLEAR_VARS)
LOCAL_MODULE := nghttp2_static
LOCAL_SRC_FILES := $(TARGET_ARCH_ABI)/lib/libnghttp2.a
LOCAL_EXPORT_C_INCLUDES := $(OPENSSL_ANDROID_ROOT)/$(TARGET_ARCH_ABI)/include
include $(PREBUILT_STATIC_LIBRARY)

include $(CLEAR_VARS)
LOCAL_MODULE := curl_static
LOCAL_SRC_FILES := $(TARGET_ARCH_ABI)/lib/libcurl.a
LOCAL_EXPORT_C_INCLUDES := $(OPENSSL_ANDROID_ROOT)/$(TARGET_ARCH_ABI)/include
LOCAL_STATIC_LIBRARIES := ssl_static crypto_static nghttp2_static
include $(PREBUILT_STATIC_LIBRARY)
ANDROIDMK

cat >"${OUT_DIR}/ANDROID-IMPORT.md" <<'ANDROIDDOC'
# Android prebuilt import

This package contains static libraries for `armeabi-v7a`, `arm64-v8a`, `x86`, and `x86_64`.

## CMake

Add the package as a subdirectory and link the aggregate target:

```cmake
add_subdirectory(path/to/openssl-for-android ${CMAKE_BINARY_DIR}/openssl-for-android)
target_link_libraries(my_app PRIVATE openssl_android::all)
```

Or link cURL explicitly:

```cmake
target_link_libraries(my_app PRIVATE openssl_android::curl)
```

The package selects `${ANDROID_ABI}` automatically.

## Android.mk

Include the package's `Android.mk` from your application's `Android.mk`:

```make
include $(LOCAL_PATH)/../openssl-for-android/Android.mk
```

Then link the prebuilt modules:

```make
LOCAL_STATIC_LIBRARIES += curl_static ssl_static crypto_static nghttp2_static
```

The headers are exported from `$(TARGET_ARCH_ABI)/include`.
ANDROIDDOC

cat >"${OUT_DIR}/BUILD-INFO.txt" <<INFO
OpenSSL: ${OPENSSL_VERSION}
nghttp2: ${NGHTTP2_VERSION}
cURL: ${CURL_VERSION}
Android API: ${API}
Android NDK: ${NDK_VERSION}
ABIs: ${abis[*]}
Package includes: CMakeLists.txt, Android.mk
INFO

ARCHIVE="${DIST_DIR}/openssl-for-android-api-${API}-ndk-${NDK_VERSION}.zip"
archive_dir "$OUT_DIR" "$ARCHIVE"
log "Android build complete: $ARCHIVE"
