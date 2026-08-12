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
