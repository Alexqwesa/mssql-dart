#!/usr/bin/env bash
# Copy CI mssql-tls-* artifacts into package-local paths so hook/build.dart
# prefers them over a GitHub Release download (needed before the release exists).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
from="${1:-$root/native-assets}"

if [[ ! -d "$from" ]]; then
  echo "Artifact directory not found: $from" >&2
  exit 1
fi

mkdir -p "$root/native/bin/linux-x64" "$root/native/bin/windows-x64" "$root/dist/android"

linux="$from/mssql-tls-linux-x64/libmssql_tls.so"
windows="$from/mssql-tls-windows-x64/mssql_tls.dll"
android_dir="$from/mssql-tls-android"

if [[ -f "$linux" ]]; then
  cp "$linux" "$root/native/bin/linux-x64/libmssql_tls.so"
  echo "staged linux/x64 -> native/bin/linux-x64/libmssql_tls.so"
fi
if [[ -f "$windows" ]]; then
  cp "$windows" "$root/native/bin/windows-x64/mssql_tls.dll"
  echo "staged windows/x64 -> native/bin/windows-x64/mssql_tls.dll"
fi
if [[ -d "$android_dir" ]]; then
  cp -a "$android_dir"/. "$root/dist/android/"
  echo "staged android -> dist/android/"
fi

if [[ ! -f "$root/native/bin/linux-x64/libmssql_tls.so" ]]; then
  echo "Expected $linux (needed on Linux CI for dart build hooks)." >&2
  find "$from" -maxdepth 3 -type f -print >&2 || true
  exit 1
fi
