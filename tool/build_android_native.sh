#!/usr/bin/env bash
# Builds the statically-linked native TLS helper for Android ABIs.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}}"
if [[ -z "$ndk" || ! -f "$ndk/build/cmake/android.toolchain.cmake" ]]; then
  echo "Set ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) to an Android NDK installation." >&2
  exit 1
fi

openssl_version="3.5.7"
openssl_archive="openssl-${openssl_version}.tar.gz"
openssl_sha256="a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8"
android_api="${MSSQL_ANDROID_API:-24}"
downloads="${MSSQL_NATIVE_DOWNLOADS:-$root/build/downloads}"
work="${MSSQL_NATIVE_BUILD_ROOT:-$root/build/android-native}"
output="${MSSQL_NATIVE_OUTPUT:-$root/dist/android}"
jobs="${MSSQL_NATIVE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"

# OpenSSL Configure looks for NDK clang on PATH; without it it falls back to
# the removed gcc wrappers (aarch64-linux-android-gcc, etc.).
host_tag="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
case "$host_tag" in
  linux-x86_64|linux-aarch64|darwin-x86_64|darwin-arm64) ;;
  linux-amd64) host_tag=linux-x86_64 ;;
  darwin-amd64) host_tag=darwin-x86_64 ;;
  *)
    # NDK prebuilts use these directory names.
    if [[ -d "$ndk/toolchains/llvm/prebuilt/linux-x86_64" ]]; then
      host_tag=linux-x86_64
    elif [[ -d "$ndk/toolchains/llvm/prebuilt/darwin-x86_64" ]]; then
      host_tag=darwin-x86_64
    elif [[ -d "$ndk/toolchains/llvm/prebuilt/darwin-arm64" ]]; then
      host_tag=darwin-arm64
    else
      echo "Could not locate NDK LLVM prebuilt toolchain under $ndk/toolchains/llvm/prebuilt" >&2
      exit 1
    fi
    ;;
esac
llvm_bin="$ndk/toolchains/llvm/prebuilt/$host_tag/bin"
if [[ ! -d "$llvm_bin" ]]; then
  echo "NDK LLVM bin directory not found: $llvm_bin" >&2
  exit 1
fi

mkdir -p "$downloads" "$work" "$output"
archive_path="$downloads/$openssl_archive"
if [[ ! -f "$archive_path" ]]; then
  curl --fail --location --retry 3 --output "$archive_path" \
    "https://github.com/openssl/openssl/releases/download/openssl-${openssl_version}/$openssl_archive"
fi
echo "$openssl_sha256  $archive_path" | sha256sum --check --status

build_abi() {
  local abi="$1"
  local openssl_target="$2"
  local source="$work/openssl-$abi"
  local prefix="$work/install/$abi"
  local cmake_build="$work/mssql-$abi"

  rm -rf "$source" "$prefix" "$cmake_build"
  mkdir -p "$source"
  tar --extract --gzip --file "$archive_path" --strip-components=1 --directory "$source"

  (
    cd "$source"
    export ANDROID_NDK_ROOT="$ndk"
    export PATH="$llvm_bin:$PATH"
    ./Configure "$openssl_target" no-shared no-tests no-apps no-module \
      -D__ANDROID_API__="$android_api" \
      --prefix="$prefix" --openssldir=/etc/ssl
    make -j"$jobs"
    make install_sw
  )

  cmake -S "$root/native" -B "$cmake_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM="android-${android_api}" \
    -DANDROID_STL=c++_static \
    -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
    -DOPENSSL_ROOT_DIR="$prefix" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE
  cmake --build "$cmake_build"
  mkdir -p "$output/$abi"
  cp "$cmake_build/libmssql_tls.so" "$output/$abi/libmssql_tls.so"
  (cd "$output/$abi" && sha256sum libmssql_tls.so > SHA256SUMS)
}

build_abi arm64-v8a android-arm64
build_abi armeabi-v7a android-arm
build_abi x86_64 android-x86_64
cp "$root/THIRD_PARTY_NOTICES.md" "$output/THIRD_PARTY_NOTICES.md"
