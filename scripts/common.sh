#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/.build}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}


resolve_latest_version() {
  local component="$1"
  local requested="$2"
  if [[ "$requested" != "latest" ]]; then
    printf '%s\n' "$requested"
    return 0
  fi

  require_cmd curl
  local tag
  case "$component" in
    openssl)
      tag="$(curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 20 \
        -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/openssl/openssl/releases/latest | \
        python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
      tag="${tag#openssl-}"
      ;;
    nghttp2)
      tag="$(curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 20 \
        -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/nghttp2/nghttp2/releases/latest | \
        python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
      tag="${tag#v}"
      ;;
    curl)
      tag="$(curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 20 \
        -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/curl/curl/releases/latest | \
        python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
      tag="${tag#curl-}"
      tag="${tag//_/.}"
      ;;
    *)
      die "Unknown component for latest version lookup: $component"
      ;;
  esac

  [[ -n "$tag" ]] || die "Could not resolve latest version for $component"
  printf '%s\n' "$tag"
}

fetch() {
  local url="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"
  if [[ ! -s "$out" ]]; then
    log "Downloading $url"
    curl -fL --retry 4 --retry-delay 2 --connect-timeout 20 -o "$out" "$url"
  fi
}

extract_tarball() {
  local archive="$1"
  local destination="$2"
  rm -rf "$destination"
  mkdir -p "$destination"
  case "$archive" in
    *.tar.gz) tar -xzf "$archive" -C "$destination" --strip-components=1 ;;
    *.tar.bz2) tar -xjf "$archive" -C "$destination" --strip-components=1 ;;
    *.tar.xz) tar -xJf "$archive" -C "$destination" --strip-components=1 ;;
    *) die "Unsupported archive: $archive" ;;
  esac
}

clean_dir() { rm -rf "$1"; mkdir -p "$1"; }

stage_headers() {
  local prefix="$1"
  local destination="$2"
  mkdir -p "$destination"
  cp -R "$prefix/include/." "$destination/"
}

archive_dir() {
  local source_dir="$1"
  local archive="$2"
  mkdir -p "$(dirname "$archive")"
  rm -f "$archive"
  (cd "$source_dir" && zip -qr "$archive" .)
}
