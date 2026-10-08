#!/usr/bin/env bash
# Builds the Linux native TLS helper (libmssql_tls.so), runs its C++ tests, and
# installs the library under native/bin/linux-x64/.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-Release}"
build_dir="${MSSQL_NATIVE_BUILD_DIR:-$root/build/native}"
output_dir="$root/native/bin/linux-x64"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

need cmake
need ninja
need ctest

cmake_args=(
  -S "$root/native"
  -B "$build_dir"
  -G Ninja
  -DBUILD_TESTING=ON
  -DCMAKE_BUILD_TYPE="$configuration"
)

# openSUSE / some distros ship headers but CMake cannot resolve libcrypto/libssl
# without explicit paths. Prefer OPENSSL_* env overrides when set.
if [[ -n "${OPENSSL_ROOT_DIR:-}" ]]; then
  cmake_args+=(-DOPENSSL_ROOT_DIR="$OPENSSL_ROOT_DIR")
fi
if [[ -n "${OPENSSL_CRYPTO_LIBRARY:-}" ]]; then
  cmake_args+=(-DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_CRYPTO_LIBRARY")
fi
if [[ -n "${OPENSSL_SSL_LIBRARY:-}" ]]; then
  cmake_args+=(-DOPENSSL_SSL_LIBRARY="$OPENSSL_SSL_LIBRARY")
elif [[ -z "${OPENSSL_ROOT_DIR:-}" && -z "${OPENSSL_CRYPTO_LIBRARY:-}" ]]; then
  for libdir in /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/lib; do
    if [[ -e "$libdir/libcrypto.so" && -e "$libdir/libssl.so" ]]; then
      cmake_args+=(
        -DOPENSSL_ROOT_DIR=/usr
        -DOPENSSL_CRYPTO_LIBRARY="$libdir/libcrypto.so"
        -DOPENSSL_SSL_LIBRARY="$libdir/libssl.so"
      )
      break
    fi
  done
fi

echo "Configuring native TLS helper in $build_dir ..."
cmake "${cmake_args[@]}"
cmake --build "$build_dir"
ctest --test-dir "$build_dir" --output-on-failure

mkdir -p "$output_dir"
cp -f "$build_dir/libmssql_tls.so" "$output_dir/libmssql_tls.so"
echo "Installed $output_dir/libmssql_tls.so"
