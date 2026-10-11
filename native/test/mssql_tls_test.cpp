#ifdef NDEBUG
#undef NDEBUG
#endif

#include "mssql_tls.h"

#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <cassert>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

namespace {

SSL_CTX* make_server_context(const char* certificate_path = nullptr) {
  SSL_CTX* context = SSL_CTX_new(TLS_server_method());
  assert(context != nullptr);
  EVP_PKEY_CTX* key_context = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nullptr);
  assert(key_context != nullptr);
  assert(EVP_PKEY_keygen_init(key_context) == 1);
  assert(EVP_PKEY_CTX_set_rsa_keygen_bits(key_context, 2048) == 1);
  EVP_PKEY* key = nullptr;
  assert(EVP_PKEY_keygen(key_context, &key) == 1);
  EVP_PKEY_CTX_free(key_context);

  X509* certificate = X509_new();
  assert(certificate != nullptr);
  assert(X509_set_version(certificate, 2) == 1);
  assert(ASN1_INTEGER_set(X509_get_serialNumber(certificate), 1) == 1);
  assert(X509_gmtime_adj(X509_get_notBefore(certificate), 0) != nullptr);
  assert(X509_gmtime_adj(X509_get_notAfter(certificate), 86400) != nullptr);
  assert(X509_set_pubkey(certificate, key) == 1);
  X509_NAME* name = X509_get_subject_name(certificate);
  assert(X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
      reinterpret_cast<const unsigned char*>("localhost"), -1, -1, 0) == 1);
  assert(X509_set_issuer_name(certificate, name) == 1);
  X509_EXTENSION* basic_constraints = X509V3_EXT_conf_nid(
      nullptr, nullptr, NID_basic_constraints,
      const_cast<char*>("critical,CA:TRUE"));
  assert(basic_constraints != nullptr);
  assert(X509_add_ext(certificate, basic_constraints, -1) == 1);
  X509_EXTENSION_free(basic_constraints);
  X509_EXTENSION* subject_alt_name = X509V3_EXT_conf_nid(
      nullptr, nullptr, NID_subject_alt_name,
      const_cast<char*>("DNS:localhost"));
  assert(subject_alt_name != nullptr);
  assert(X509_add_ext(certificate, subject_alt_name, -1) == 1);
  X509_EXTENSION_free(subject_alt_name);
  assert(X509_sign(certificate, key, EVP_sha256()) > 0);
  assert(SSL_CTX_use_certificate(context, certificate) == 1);
  assert(SSL_CTX_use_PrivateKey(context, key) == 1);
  if (certificate_path != nullptr) {
    BIO* output = BIO_new_file(certificate_path, "w");
    assert(output != nullptr);
    assert(PEM_write_bio_X509(output, certificate) == 1);
    BIO_free(output);
  }
  X509_free(certificate);
  EVP_PKEY_free(key);
  return context;
}

void transfer_client_output(mssql_tls* client, SSL* server) {
  uint8_t bytes[16384];
  size_t written = 0;
  do {
    assert(mssql_tls_drain_encrypted(client, bytes, sizeof(bytes), &written) ==
           MSSQL_TLS_OK);
    if (written != 0) assert(BIO_write(SSL_get_rbio(server), bytes, static_cast<int>(written)) > 0);
  } while (written != 0);
}

void transfer_server_output(SSL* server, mssql_tls* client) {
  uint8_t bytes[16384];
  int read = 0;
  while ((read = BIO_read(SSL_get_wbio(server), bytes, sizeof(bytes))) > 0) {
    size_t consumed = 0;
    assert(mssql_tls_feed_encrypted(client, bytes, static_cast<size_t>(read), &consumed) ==
           MSSQL_TLS_OK);
    assert(consumed == static_cast<size_t>(read));
  }
}

SSL* make_server(SSL_CTX* context) {
  SSL* server = SSL_new(context);
  assert(server != nullptr);
  SSL_set_bio(server, BIO_new(BIO_s_mem()), BIO_new(BIO_s_mem()));
  SSL_set_accept_state(server);
  return server;
}

bool complete_handshake(mssql_tls* client, SSL* server) {
  for (int i = 0; i < 100 && !mssql_tls_is_handshake_complete(client); ++i) {
    const mssql_tls_result result = mssql_tls_handshake(client);
    if (result < 0) return false;
    assert(result == MSSQL_TLS_WANT_INPUT || result == MSSQL_TLS_WANT_OUTPUT ||
           result == MSSQL_TLS_HANDSHAKE_COMPLETE);
    transfer_client_output(client, server);
    const int server_result = SSL_do_handshake(server);
    if (server_result != 1) {
      const int server_error = SSL_get_error(server, server_result);
      if (server_error != SSL_ERROR_WANT_READ &&
          server_error != SSL_ERROR_WANT_WRITE) {
        return false;
      }
    }
    transfer_server_output(server, client);
  }
  return mssql_tls_is_handshake_complete(client) != 0;
}

}  // namespace

int main() {
  const mssql_tls_config config = {"localhost", nullptr, nullptr, 1, 0, 16383};
  mssql_tls* client = mssql_tls_create(&config);
  assert(client != nullptr);
  const std::vector<uint8_t> packet(8, 0);
  assert(mssql_tls_write_packet(client, packet.data(), packet.size()) == MSSQL_TLS_INVALID_STATE);
  uint8_t pre_handshake_plaintext = 0;
  size_t pre_handshake_size = 1;
  assert(mssql_tls_read_plaintext(client, &pre_handshake_plaintext, 1,
                                  &pre_handshake_size) ==
         MSSQL_TLS_INVALID_STATE);
  assert(pre_handshake_size == 0);
  assert(mssql_tls_retry_write(client) == MSSQL_TLS_INVALID_STATE);
  assert(mssql_tls_has_pending_write(client) == 0);

  SSL_CTX* server_context = make_server_context();
  SSL* server = make_server(server_context);

  // Complete a full in-memory TLS handshake, exercising the same BIO pumping
  // used by the Dart TDS PRELOGIN bridge.
  assert(complete_handshake(client, server));
  assert(SSL_is_init_finished(server));

  size_t certificate_size = 0;
  assert(mssql_tls_peer_certificate_der(client, nullptr, 0, &certificate_size) ==
         MSSQL_TLS_PACKET_TOO_LARGE);
  std::vector<uint8_t> certificate(certificate_size);
  assert(mssql_tls_peer_certificate_der(client, certificate.data(), certificate.size(), &certificate_size) ==
         MSSQL_TLS_OK);
  assert(certificate_size == certificate.size());

  const uint8_t request[] = {0x12, 0x34, 0x56};
  assert(mssql_tls_write_packet(client, request, sizeof(request)) == MSSQL_TLS_OK);
  assert(mssql_tls_has_pending_write(client) == 0);
  transfer_client_output(client, server);
  uint8_t received[sizeof(request)] = {};
  size_t received_size = 0;
  assert(SSL_read_ex(server, received, sizeof(received), &received_size) == 1);
  assert(received_size == sizeof(request));
  assert(std::memcmp(received, request, sizeof(request)) == 0);

  const uint8_t response[] = {0xaa, 0xbb};
  size_t response_size = 0;
  assert(SSL_write_ex(server, response, sizeof(response), &response_size) == 1);
  transfer_server_output(server, client);
  uint8_t plaintext[sizeof(response)] = {};
  size_t plaintext_size = 0;
  assert(mssql_tls_read_plaintext(client, plaintext, sizeof(plaintext), &plaintext_size) == MSSQL_TLS_OK);
  assert(plaintext_size == sizeof(response));
  assert(std::memcmp(plaintext, response, sizeof(response)) == 0);

  mssql_tls_destroy(client);
  SSL_free(server);
  SSL_CTX_free(server_context);

  // A caller-provided PEM root continues to use OpenSSL chain + hostname
  // validation on every platform, including Apple.
  const std::filesystem::path ca_path =
      std::filesystem::temp_directory_path() / "mssql_tls_test_ca.pem";
  server_context = make_server_context(ca_path.string().c_str());
  server = make_server(server_context);
  const std::string ca_file = ca_path.string();
  const mssql_tls_config custom_ca = {
      "localhost", ca_file.c_str(), nullptr, 0, 1, 16383};
  client = mssql_tls_create(&custom_ca);
  assert(client != nullptr);
  assert(complete_handshake(client, server));
  mssql_tls_destroy(client);
  SSL_free(server);
  SSL_CTX_free(server_context);

  // The same trusted certificate must fail for a different hostname.
  server_context = make_server_context(ca_path.string().c_str());
  server = make_server(server_context);
  const mssql_tls_config wrong_hostname = {
      "not-localhost.example", ca_file.c_str(), nullptr, 0, 1, 16383};
  client = mssql_tls_create(&wrong_hostname);
  assert(client != nullptr);
  assert(!complete_handshake(client, server));
  mssql_tls_destroy(client);
  SSL_free(server);
  SSL_CTX_free(server_context);

  // With no explicit root, the generated certificate is unknown to both the
  // OpenSSL defaults and the Apple system Keychain.
  server_context = make_server_context();
  server = make_server(server_context);
  const mssql_tls_config unknown_ca = {
      "localhost", nullptr, nullptr, 0, 1, 16383};
  client = mssql_tls_create(&unknown_ca);
  assert(client != nullptr);
  assert(!complete_handshake(client, server));
  const uint8_t rejected_request = 0x01;
  assert(mssql_tls_write_packet(client, &rejected_request, 1) ==
         MSSQL_TLS_INVALID_STATE);
  uint8_t rejected_plaintext = 0;
  size_t rejected_plaintext_size = 1;
  assert(mssql_tls_read_plaintext(client, &rejected_plaintext, 1,
                                  &rejected_plaintext_size) ==
         MSSQL_TLS_INVALID_STATE);
  assert(rejected_plaintext_size == 0);
  mssql_tls_destroy(client);
  SSL_free(server);
  SSL_CTX_free(server_context);
  std::filesystem::remove(ca_path);
  return 0;
}
