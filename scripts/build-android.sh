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
  Darwin) HOST_TAG="darwin-arm64"; [[ "$(uname -m)" == "x86_64" ]] && HOST_TAG="darwin-x86_64" ;;
  Linux) HOST_TAG="linux-x86_64" ;;
  *) die "Android build is supported on macOS and Linux" ;;
esac

TOOLCHAIN_BIN="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/${HOST_TAG}/bin"
[[ -d "$TOOLCHAIN_BIN" ]] || die "NDK LLVM toolchain not found: $TOOLCHAIN_BIN"
export PATH="${TOOLCHAIN_BIN}:${PATH}"

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

cat >"${OUT_DIR}/BUILD-INFO.txt" <<INFO
OpenSSL: ${OPENSSL_VERSION}
nghttp2: ${NGHTTP2_VERSION}
cURL: ${CURL_VERSION}
Android API: ${API}
Android NDK: ${NDK_VERSION}
ABIs: ${abis[*]}
INFO

ARCHIVE="${DIST_DIR}/openssl-for-android-api-${API}-ndk-${NDK_VERSION}.zip"
archive_dir "$OUT_DIR" "$ARCHIVE"
log "Android build complete: $ARCHIVE"
