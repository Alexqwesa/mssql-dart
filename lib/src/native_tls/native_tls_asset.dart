// Shared identifiers for the native TLS code asset registered by hook/build.dart.

/// Asset name portion of [nativeTlsAssetId].
const String nativeTlsAssetName = 'src/native_tls/native_tls_loader.dart';

/// Full asset id opened via `DynamicLibrary.codeAsset`.
const String nativeTlsAssetId = 'package:mssql_native/$nativeTlsAssetName';

/// GitHub repository that hosts tagged native TLS release zips.
const String nativeTlsReleaseRepo = 'Alexqwesa/mssql-dart';
