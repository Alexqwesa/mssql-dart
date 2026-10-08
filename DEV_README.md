# Maintainer notes

Developer-facing guidance for `mssql_driver_with_native_tls`.
Consumer docs live in [README.md](README.md).

## Testing

Offline, native TLS, Docker matrix, and opt-in live SQL Server testing:

- [README_TESTS.md](README_TESTS.md) — how to run the suites
- [test/README.md](test/README.md) — coverage map by category
- [tool/README.md](tool/README.md) — `full_tests.sh` / `full_tests.ps1` and related scripts

```bash
dart test                          # offline; live tests skip without MSSQL_LIVE_TESTS=1
bash tool/full_tests.sh            # native helper + offline + live stack
bash tool/full_tests.sh --matrix   # SQL Server version matrix
```

## Install from the development branch

Use this only when testing changes that have not reached pub.dev:

```yaml
dependencies:
  mssql_driver_with_native_tls:
    git:
      url: https://github.com/Alexqwesa/mssql-dart.git
      ref: mssql_driver_with_native_tls
```

```bash
dart pub get
```

Build-hook overrides belong in the consuming application's `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    mssql_driver_with_native_tls:
      release_tag: v0.5.5   # must have matching in-package SHA-256 pins
      local_only: true      # require native/bin or dist/android; never download
      force_download: true  # ignore local helpers and download the pinned asset
```

Normally, omit `release_tag`; the hook uses `nativeTlsPinnedReleaseTag` from
the installed package. An arbitrary override is rejected unless the package
contains matching SHA-256 pins.

## Native TLS — local build

Hook resolution order at runtime:

1. `MSSQL_TLS_LIBRARY` environment override
2. Code asset from `hook/build.dart` (`DynamicLibrary.codeAsset`)
3. Platform linker name (Android `jniLibs`, or process search path)
4. Checked-out `native/bin/<platform>/` (or `dist/android/<abi>/`)

### Windows — `tool/build_native.ps1`

Dependencies:

- Visual Studio 2022 with the C++ desktop workload (needs `VsDevCmd.bat`)
- [CMake](https://cmake.org/) ≥ 3.24
- [Ninja](https://ninja-build.org/)
- OpenSSL (e.g. `choco install openssl`, or set `OPENSSL_ROOT_DIR`)

```powershell
# optional if OpenSSL is not on the default path:
# $env:OPENSSL_ROOT_DIR = 'C:\Program Files\OpenSSL-Win64'
.\tool\build_native.ps1
```

Copies `mssql_tls.dll` to `native/bin/windows-x64/`.

### Linux

Dependencies: a C++17 toolchain, CMake ≥ 3.24, Ninja, and OpenSSL headers
(`libssl-dev` on Debian/Ubuntu).

```bash
bash tool/build_native.sh
# or:
cmake -S native -B build/native -G Ninja -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/native
ctest --test-dir build/native --output-on-failure
mkdir -p native/bin/linux-x64
cp build/native/libmssql_tls.so native/bin/linux-x64/
```

### Android

Dependencies: Android NDK r27 (or compatible), CMake, Ninja, Perl, Make, curl.
The script downloads pinned OpenSSL and statically links it:

```bash
export ANDROID_NDK_HOME=/path/to/android-ndk
bash tool/build_android_native.sh
```

Outputs land in `dist/android/<abi>/`.

## Prebuilt release artifacts

The manual Release native assets workflow is the only workflow that builds the
native binaries. It records their Release tag and hashes in
`native_tls_pins.dart`, then attaches the ZIPs (with `SHA256SUMS`) to
[GitHub Releases](https://github.com/Alexqwesa/mssql-dart/releases).

The pinned native Release tag is independent of the Dart package version. A
package-only release keeps the existing pins, so both
[Publish](https://github.com/Alexqwesa/mssql-dart/actions/workflows/publish.yml)
and the consumer build hook reuse and verify those existing Release assets.

## Recommended release process

1. **Prepare release**  
   On your release branch (e.g. `mssql_driver_with_native_tls`): finalize
   native TLS source, set the plain `X.Y.Z` in `pubspec.yaml`, update
   `CHANGELOG.md`, and push. The release workflow files must exist on that
   branch (`.github/workflows/release_native_assets.yml`).

2. **Choose the release path**

   If native code or its toolchain changed, run **Release native assets**. The
   workflow builds and pins fresh helpers, creates the package tag, uploads the
   assets, and starts Publish. Pick the release branch in the UI:

   You do **not** need this on `main`. The branch dropdown is what selects
   the code that gets pinned and tagged:

   - GitHub: **Actions** → **Release native assets** → **Run workflow**
     → **Use workflow from:** `mssql_driver_with_native_tls` (not `main`)  
     → Run workflow  
   - CLI:
     ```bash
     gh workflow run release_native_assets.yml --ref mssql_driver_with_native_tls
     ```

   If native code did not change, do not run the native-assets workflow. Keep
   `nativeTlsPinnedReleaseTag` unchanged and create the package tag normally:

   ```bash
   git tag -a vX.Y.Z -m "Release vX.Y.Z"
   git push origin vX.Y.Z
   ```

   The tag-triggered Publish workflow will reuse the pinned native Release.

   **`gh workflow run` 404 / workflow missing:** the workflow file must exist
   on the **default branch** (`main`) or the API returns
   `workflow release_native_assets.yml not found on the default branch`. Copy
   `.github/workflows/release_native_assets.yml` and `native-tls-build.yml` onto `main`
   and push — that only registers the Action; you still always run it with
   `--ref` / **Use workflow from** set to the release branch.

   When run, the native-assets workflow:

   - builds fresh Windows / Linux / Android helpers
   - refuses to continue if `vX.Y.Z` already exists
   - commits pins when hashes changed (`ci: pin native TLS SHA-256 for vX.Y.Z`)
   - creates and pushes annotated tag `vX.Y.Z`
   - uploads those **same** binaries to the GitHub Release and attests them
   - starts **Publish** on that tag

3. **Publish on the package tag**
   Downloads the Release zips from `nativeTlsPinnedReleaseTag`, verifies them
   against the committed hashes, and never rebuilds them. It runs tests, then
   waits on the `pub.dev` Environment.

   Verify a downloaded asset (example):

   ```bash
   gh attestation verify mssql-tls-linux-x64.zip --owner Alexqwesa
   ```

4. **Approve publication**  
   Approve the `pub.dev` Environment deployment when ready.

5. **Publish**  
   The action publishes the tagged package. The consumer hook downloads from
   the pinned native Release, which can be older than the package tag.

## Pin tooling (optional / local)

```bash
# write / refresh pins from CI artifact directory
dart run tool/update_native_tls_pins.dart --from-dir path/to/mssql-tls-artifacts --require-all

# verify artifacts match the committed manifest (tags use --require-all)
dart run tool/update_native_tls_pins.dart --from-dir path/to/mssql-tls-artifacts --check --require-all
```
