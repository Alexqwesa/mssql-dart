import 'package:http/http.dart' as http;
import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Offline Azure AD token response parsing (no network).
///
/// Complements Login7 FedAuth encode tests — token acquisition HTTP is mocked
/// by feeding synthetic [http.Response] bodies into [AzureAdAuth.extractAccessToken].
void main() {
  group('AzureAdAuth.extractAccessToken', () {
    test('reads access_token from 200 JSON body', () {
      final token = AzureAdAuth.extractAccessToken(
        http.Response('{"access_token":"abc.def.ghi","token_type":"Bearer"}', 200),
      );
      expect(token, equals('abc.def.ghi'));
    });

    test('fromToken stores bearer for FedAuth path', () {
      final auth = AzureAdAuth.fromToken('preacquired');
      expect(auth.bearerToken, equals('preacquired'));
    });

    test('non-200 throws StateError', () {
      expect(
        () => AzureAdAuth.extractAccessToken(
          http.Response('{"error":"invalid_client"}', 401),
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('401'),
        )),
      );
    });

    test('missing access_token throws StateError', () {
      expect(
        () => AzureAdAuth.extractAccessToken(
          http.Response('{"token_type":"Bearer"}', 200),
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('access_token'),
        )),
      );
    });
  });
}
