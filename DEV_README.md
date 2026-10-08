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

The manual Release native assets workflow is the only workflow that builds the native
binaries. It pins their hashes and attaches the ZIPs (with `SHA256SUMS`) to
[GitHub Releases](https://github.com/Alexqwesa/mssql-dart/releases) before it
starts [Publish](https://github.com/Alexqwesa/mssql-dart/actions/workflows/publish.yml)
on the new tag. Publish does not rebuild the binaries; it downloads and verifies
those existing Release assets. The consumer hook downloads the same assets.

## Recommended release process

1. **Prepare release**  
   On your release branch (e.g. `mssql_driver_with_native_tls`): finalize
   native TLS source, set the plain `X.Y.Z` in `pubspec.yaml`, update
   `CHANGELOG.md`, and push. The release workflow files must exist on that
   branch (`.github/workflows/release_native_assets.yml`).

2. **Run Release native assets (manual) — pick the branch in the UI**
   You do **not** need this on `main`. The branch dropdown is what selects
   the code that gets pinned and tagged:

   - GitHub: **Actions** → **Release native assets** → **Run workflow**
     → **Use workflow from:** `mssql_driver_with_native_tls` (not `main`)  
     → Run workflow  
   - CLI:
     ```bash
     gh workflow run release_native_assets.yml --ref mssql_driver_with_native_tls
     ```

   **`gh workflow run` 404 / workflow missing:** the workflow file must exist
   on the **default branch** (`main`) or the API returns
   `workflow release_native_assets.yml not found on the default branch`. Copy
   `.github/workflows/release_native_assets.yml` and `native-tls-build.yml` onto `main`
   and push — that only registers the Action; you still always run it with
   `--ref` / **Use workflow from** set to the release branch.

   The workflow then:
   - builds Windows / Linux / Android helpers from that branch tip
   - refuses to continue if `vX.Y.Z` already exists
   - commits pins when hashes changed (`ci: pin native TLS SHA-256 for vX.Y.Z`)
   - creates and pushes annotated tag `vX.Y.Z`
   - uploads those **same** binaries to the GitHub Release and attests them
   - starts **Publish** on that tag

3. **Publish on the tag**
   Verifies the GitHub Release zips against the committed pins (not a rebuild —
   native builds are not bit-reproducible). Runs tests, then waits on the
   `pub.dev` Environment.

   Verify a downloaded asset (example):

   ```bash
   gh attestation verify mssql-tls-linux-x64.zip --owner Alexqwesa
   ```

4. **Approve publication**  
   Approve the `pub.dev` Environment deployment when ready.

5. **Publish**  
   The action publishes the tagged package; Release zips are already online for
   the download hook.

## Pin tooling (optional / local)

```bash
# write / refresh pins from CI artifact directory
dart run tool/update_native_tls_pins.dart --from-dir path/to/mssql-tls-artifacts --require-all

# verify artifacts match the committed manifest (tags use --require-all)
dart run tool/update_native_tls_pins.dart --from-dir path/to/mssql-tls-artifacts --check --require-all
```
