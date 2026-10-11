#!/usr/bin/env bash
# Builds statically-OpenSSL-linked macOS and iOS TLS helper dylibs.
#
# Default: build every Apple slice. CI may pass individual target names:
#   macos-arm64 macos-x64 ios-device-arm64 ios-sim-arm64 ios-sim-x64
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Apple native helpers must be built on macOS with Xcode installed." >&2
  exit 1
fi

openssl_version="3.5.7"
openssl_archive="openssl-${openssl_version}.tar.gz"
openssl_sha256="a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8"
macos_min="${MSSQL_MACOS_MIN:-12.0}"
ios_min="${MSSQL_IOS_MIN:-15.0}"
downloads="${MSSQL_NATIVE_DOWNLOADS:-$root/build/downloads}"
work="${MSSQL_APPLE_BUILD_ROOT:-$root/build/apple-native}"
output="${MSSQL_NATIVE_OUTPUT:-$root/dist}"
jobs="${MSSQL_NATIVE_JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(
    macos-arm64
    macos-x64
    ios-device-arm64
    ios-sim-arm64
    ios-sim-x64
  )
fi

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

for command in cmake ninja make perl curl shasum xcrun otool install_name_tool; do
  need "$command"
done
xcodebuild -version

mkdir -p "$downloads" "$work" "$output/macos" "$output/ios"
archive_path="$downloads/$openssl_archive"
if [[ ! -f "$archive_path" ]]; then
  curl --fail --location --retry 3 --output "$archive_path" \
    "https://github.com/openssl/openssl/releases/download/openssl-${openssl_version}/$openssl_archive"
fi
echo "$openssl_sha256  $archive_path" | shasum -a 256 --check --status

build_slice() {
  local name="$1"
  local openssl_target sdk architecture deployment_flag destination

  case "$name" in
    macos-arm64)
      openssl_target=darwin64-arm64-cc
      sdk=macosx
      architecture=arm64
      deployment_flag="-mmacosx-version-min=$macos_min"
      destination="$output/macos/arm64"
      ;;
    macos-x64)
      openssl_target=darwin64-x86_64-cc
      sdk=macosx
      architecture=x86_64
      deployment_flag="-mmacosx-version-min=$macos_min"
      destination="$output/macos/x86_64"
      ;;
    ios-device-arm64)
      openssl_target=ios64-xcrun
      sdk=iphoneos
      architecture=arm64
      deployment_flag="-mios-version-min=$ios_min"
      destination="$output/ios/iphoneos/arm64"
      ;;
    ios-sim-arm64)
      openssl_target=iossimulator-arm64-xcrun
      sdk=iphonesimulator
      architecture=arm64
      deployment_flag="-mios-simulator-version-min=$ios_min"
      destination="$output/ios/iphonesimulator/arm64"
      ;;
    ios-sim-x64)
      openssl_target=iossimulator-xcrun
      sdk=iphonesimulator
      architecture=x86_64
      deployment_flag="-mios-simulator-version-min=$ios_min"
      destination="$output/ios/iphonesimulator/x86_64"
      ;;
    *)
      echo "Unknown Apple target '$name'." >&2
      exit 64
      ;;
  esac

  local source="$work/source-$name"
  local prefix="$work/install-$name"
  local cmake_build="$work/mssql-$name"
  rm -rf "$source" "$prefix" "$cmake_build"
  mkdir -p "$source" "$destination"
  tar --extract --gzip --file "$archive_path" --strip-components=1 --directory "$source"

  echo "Building OpenSSL $openssl_version for $name ..."
  (
    cd "$source"
    CFLAGS="$deployment_flag" ./Configure "$openssl_target" \
      no-shared no-tests no-apps no-module \
      --prefix="$prefix" --openssldir="$prefix/ssl"
    make -j"$jobs"
    make install_sw
  )

  local openssl_include="$prefix/include"
  local openssl_crypto="$prefix/lib/libcrypto.a"
  local openssl_ssl="$prefix/lib/libssl.a"
  if [[ ! -f "$openssl_crypto" ]]; then
    openssl_crypto="$prefix/lib64/libcrypto.a"
    openssl_ssl="$prefix/lib64/libssl.a"
  fi
  if [[ ! -f "$openssl_include/openssl/ssl.h" || \
        ! -f "$openssl_crypto" || ! -f "$openssl_ssl" ]]; then
    echo "OpenSSL install for $name is incomplete under $prefix." >&2
    exit 1
  fi

  local sdk_path
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local deployment_target
  if [[ "$sdk" == macosx ]]; then
    deployment_target="$macos_min"
  else
    deployment_target="$ios_min"
  fi
  local run_tests=OFF
  local host_arch
  host_arch="$(uname -m)"
  if [[ "$sdk" == macosx && "$host_arch" == "$architecture" ]]; then
    run_tests=ON
  fi

  # macOS runners still ship Bash 3.2, where expanding an empty array under
  # `set -u` fails. Keep this array non-empty and append the iOS-only CMake
  # system setting instead of expanding a separate possibly-empty array.
  local cmake_args=(
    -S "$root/native"
    -B "$cmake_build"
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES="$architecture"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target"
    -DCMAKE_OSX_SYSROOT="$sdk_path"
    -DBUILD_TESTING="$run_tests"
    -DOPENSSL_ROOT_DIR="$prefix"
    -DOPENSSL_INCLUDE_DIR="$openssl_include"
    -DOPENSSL_CRYPTO_LIBRARY="$openssl_crypto"
    -DOPENSSL_SSL_LIBRARY="$openssl_ssl"
    -DOPENSSL_USE_STATIC_LIBS=TRUE
  )
  if [[ "$sdk" != macosx ]]; then
    cmake_args+=(-DCMAKE_SYSTEM_NAME=iOS)
  fi
  cmake "${cmake_args[@]}"
  cmake --build "$cmake_build"
  if [[ "$run_tests" == ON ]]; then
    ctest --test-dir "$cmake_build" --output-on-failure
  fi

  local library="$destination/libmssql_tls.dylib"
  cp "$cmake_build/libmssql_tls.dylib" "$library"
  install_name_tool -id '@rpath/libmssql_tls.dylib' "$library"
  (cd "$destination" && shasum -a 256 libmssql_tls.dylib > SHA256SUMS)

  file "$library"
  otool -L "$library"
  if otool -L "$library" | grep -Eq '/(opt/homebrew|usr/local)/|apple-native'; then
    echo "$library contains a non-system dynamic dependency." >&2
    exit 1
  fi
}

for target in "${targets[@]}"; do
  build_slice "$target"
done

cp "$root/THIRD_PARTY_NOTICES.md" "$output/macos/THIRD_PARTY_NOTICES.md"
cp "$root/THIRD_PARTY_NOTICES.md" "$output/ios/THIRD_PARTY_NOTICES.md"
echo "Apple native helpers are under $output/macos and $output/ios."
