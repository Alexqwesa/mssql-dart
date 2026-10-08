#!/usr/bin/env bash
# Pack CI mssql-tls-* dirs into release-binaries/*.zip and flattened libs for
# attestations. Usage: tool/pack_release_native_tls.sh [native-assets-dir]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
from="${1:-$root/native-assets}"
out="${2:-$root/release-binaries}"

mkdir -p "$out"
# zip runs after cd into each asset dir. A relative output path would be
# resolved there (native-assets/mssql-tls-android/release-binaries/...),
# which does not exist, so zip exits 15.
out="$(cd "$out" && pwd)"

for asset in "$from"/*; do
  [[ -d "$asset" ]] || continue
  name="$(basename "$asset")"
  (cd "$asset" && zip -r "$out/${name}.zip" .)
  case "$name" in
    mssql-tls-linux-x64)
      cp "$asset/libmssql_tls.so" "$out/linux-x64-libmssql_tls.so"
      ;;
    mssql-tls-windows-x64)
      cp "$asset/mssql_tls.dll" "$out/windows-x64-mssql_tls.dll"
      ;;
    mssql-tls-android)
      cp "$asset/arm64-v8a/libmssql_tls.so" "$out/android-arm64-v8a-libmssql_tls.so"
      cp "$asset/armeabi-v7a/libmssql_tls.so" "$out/android-armeabi-v7a-libmssql_tls.so"
      cp "$asset/x86_64/libmssql_tls.so" "$out/android-x86_64-libmssql_tls.so"
      ;;
  esac
done
ls -la "$out"
