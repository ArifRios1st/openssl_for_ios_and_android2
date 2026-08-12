#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

OPENSSL_VERSION="${OPENSSL_VERSION:-4.0.1}"
NGHTTP2_VERSION="${NGHTTP2_VERSION:-1.70.0}"
CURL_VERSION="${CURL_VERSION:-8.21.0}"
MIN_IOS_VERSION="${MIN_IOS_VERSION:-13.0}"

[[ "$(uname -s)" == "Darwin" ]] || die "iOS build must run on macOS"
require_cmd xcrun
require_cmd clang
require_cmd make
require_cmd perl
require_cmd curl
require_cmd zip
require_cmd xcodebuild
require_cmd lipo

DOWNLOAD_DIR="${BUILD_DIR}/downloads"
SRC_DIR="${BUILD_DIR}/src/ios"
OUT_DIR="${DIST_DIR}/ios"
rm -rf "$SRC_DIR" "$OUT_DIR"
mkdir -p "$SRC_DIR" "$OUT_DIR"

OPENSSL_ARCHIVE="${DOWNLOAD_DIR}/openssl-${OPENSSL_VERSION}.tar.gz"
NGHTTP2_ARCHIVE="${DOWNLOAD_DIR}/nghttp2-${NGHTTP2_VERSION}.tar.gz"
CURL_ARCHIVE="${DOWNLOAD_DIR}/curl-${CURL_VERSION}.tar.gz"
fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" "$OPENSSL_ARCHIVE"
fetch "https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VERSION}/nghttp2-${NGHTTP2_VERSION}.tar.gz" "$NGHTTP2_ARCHIVE"
fetch "https://github.com/curl/curl/releases/download/curl-$(echo "$CURL_VERSION" | tr . _)/curl-${CURL_VERSION}.tar.gz" "$CURL_ARCHIVE"

build_ios_arch() {
  local sdk="$1" arch="$2" slice="$3"
  local sdk_path
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local target_triple
  target_triple="$(xcrun --sdk "$sdk" --find clang)"
  local target_host
  local platform_target
  if [[ "$sdk" == "iphoneos" ]]; then
    target_host="aarch64-ios-darwin"
    platform_target="arm64-apple-ios${MIN_IOS_VERSION}"
  else
    target_host="aarch64-ios-darwin"
    platform_target="arm64-apple-ios${MIN_IOS_VERSION}-simulator"
  fi
  local slice_root="${BUILD_DIR}/prefix/ios/${slice}"
  local openssl_prefix="${slice_root}/openssl"
  local nghttp2_prefix="${slice_root}/nghttp2"
  local curl_prefix="${slice_root}/curl"
  local log_dir="${BUILD_DIR}/logs/ios/${slice}"

  clean_dir "$slice_root"
  clean_dir "$log_dir"
  mkdir -p "$openssl_prefix" "$nghttp2_prefix" "$curl_prefix"

  export SDKROOT="$sdk_path"
  export CC="$target_triple"
  export CXX="$(xcrun --sdk "$sdk" --find clang++)"
  export CFLAGS="-arch ${arch} -target ${platform_target} -isysroot ${sdk_path} -miphoneos-version-min=${MIN_IOS_VERSION} -fPIC -O2"
  export CXXFLAGS="$CFLAGS"
  export CPPFLAGS=""
  export LDFLAGS="-arch ${arch} -target ${platform_target} -isysroot ${sdk_path} -miphoneos-version-min=${MIN_IOS_VERSION}"

  log "[${slice}] OpenSSL ${OPENSSL_VERSION}"
  local openssl_src="${SRC_DIR}/openssl-${slice}"
  extract_tarball "$OPENSSL_ARCHIVE" "$openssl_src"
  pushd "$openssl_src" >/dev/null
  if [[ "$sdk" == "iphoneos" ]]; then
    ./Configure ios64-xcrun no-shared no-tests no-apps \
      --prefix="$openssl_prefix" --libdir=lib \
      >"${log_dir}/openssl-configure.log" 2>&1
  else
    ./Configure iossimulator-arm64-xcrun no-shared no-tests no-apps \
      --prefix="$openssl_prefix" --libdir=lib \
      >"${log_dir}/openssl-configure.log" 2>&1
  fi
  make -j"$JOBS" >"${log_dir}/openssl-build.log" 2>&1
  make install_sw >"${log_dir}/openssl-install.log" 2>&1
  popd >/dev/null

  log "[${slice}] nghttp2 ${NGHTTP2_VERSION}"
  local nghttp2_src="${SRC_DIR}/nghttp2-${slice}"
  extract_tarball "$NGHTTP2_ARCHIVE" "$nghttp2_src"
  pushd "$nghttp2_src" >/dev/null
  ./configure \
    --host="${target_host}" \
    --prefix="$nghttp2_prefix" \
    --libdir="$nghttp2_prefix/lib" \
    --disable-shared --enable-static --disable-app --disable-threads \
    >"${log_dir}/nghttp2-configure.log" 2>&1
  make -j"$JOBS" >"${log_dir}/nghttp2-build.log" 2>&1
  make install >"${log_dir}/nghttp2-install.log" 2>&1
  popd >/dev/null

  log "[${slice}] cURL ${CURL_VERSION}"
  local curl_src="${SRC_DIR}/curl-${slice}"
  extract_tarball "$CURL_ARCHIVE" "$curl_src"
  pushd "$curl_src" >/dev/null
  export CPPFLAGS="-I${openssl_prefix}/include -I${nghttp2_prefix}/include"
  export LDFLAGS="-arch ${arch} -isysroot ${sdk_path} -miphoneos-version-min=${MIN_IOS_VERSION} -L${openssl_prefix}/lib -L${nghttp2_prefix}/lib"
  ./configure \
    --host="${target_host}" \
    --prefix="$curl_prefix" --libdir="$curl_prefix/lib" \
    --disable-shared --enable-static \
    --with-openssl="$openssl_prefix" --with-nghttp2="$nghttp2_prefix" \
    --without-libpsl --without-libidn2 --without-brotli --without-zstd --without-libssh2 \
    --disable-ldap --disable-ldaps \
    >"${log_dir}/curl-configure.log" 2>&1
  make -j"$JOBS" >"${log_dir}/curl-build.log" 2>&1
  make install >"${log_dir}/curl-install.log" 2>&1
  popd >/dev/null
}

# Build device + Apple Silicon simulator. The two slices can be consumed by
# an XCFramework without requiring a legacy x86_64 simulator slice.
build_ios_arch iphoneos arm64 device-arm64
build_ios_arch iphonesimulator arm64 simulator-arm64

make_xcframework() {
  local output_name="$1" prefix_name="$2" libname="$3"
  local device_prefix="${BUILD_DIR}/prefix/ios/device-arm64/${prefix_name}"
  local simulator_prefix="${BUILD_DIR}/prefix/ios/simulator-arm64/${prefix_name}"
  local device_lib="${device_prefix}/lib/${libname}"
  local simulator_lib="${simulator_prefix}/lib/${libname}"
  local framework="${OUT_DIR}/${output_name}.xcframework"
  local log_file="${BUILD_DIR}/logs/ios/xcframework-${output_name}.log"

  [[ -f "$device_lib" ]] || die "Missing iOS device library: $device_lib"
  [[ -f "$simulator_lib" ]] || die "Missing iOS simulator library: $simulator_lib"
  [[ -d "${device_prefix}/include" ]] || die "Missing iOS device headers: ${device_prefix}/include"
  [[ -d "${simulator_prefix}/include" ]] || die "Missing iOS simulator headers: ${simulator_prefix}/include"

  log "${output_name}: device library"
  lipo -info "$device_lib"
  log "${output_name}: simulator library"
  lipo -info "$simulator_lib"

  rm -rf "$framework"
  if ! xcodebuild -create-xcframework \
    -library "$device_lib" -headers "${device_prefix}/include" \
    -library "$simulator_lib" -headers "${simulator_prefix}/include" \
    -output "$framework" >"$log_file" 2>&1; then
    cat "$log_file" >&2
    die "Failed to create ${output_name}.xcframework"
  fi

  [[ -d "$framework" ]] || die "XCFramework was not created: $framework"
}

make_xcframework OpenSSL openssl libssl.a
make_xcframework OpenSSL-Crypto openssl libcrypto.a
make_xcframework nghttp2 nghttp2 libnghttp2.a
make_xcframework cURL curl libcurl.a
cat >"${OUT_DIR}/BUILD-INFO.txt" <<INFO
OpenSSL: ${OPENSSL_VERSION}
nghttp2: ${NGHTTP2_VERSION}
cURL: ${CURL_VERSION}
Minimum iOS: ${MIN_IOS_VERSION}
Slices: iphoneos-arm64, iphonesimulator-arm64
INFO

ARCHIVE="${DIST_DIR}/openssl-for-ios-${OPENSSL_VERSION}.zip"
archive_dir "$OUT_DIR" "$ARCHIVE"
log "iOS build complete: $ARCHIVE"
