#include "mssql_tls.h"

#include <cassert>
#include <cstdint>
#include <vector>

int main() {
  const mssql_tls_config config = {
      "localhost", nullptr, nullptr, 1, 0, 16383};
  mssql_tls* tls = mssql_tls_create(&config);
  assert(tls != nullptr);

  const std::vector<uint8_t> packet(8, 0);
  assert(mssql_tls_write_packet(tls, packet.data(), packet.size()) ==
         MSSQL_TLS_INVALID_STATE);

  const mssql_tls_result handshake = mssql_tls_handshake(tls);
  assert(handshake == MSSQL_TLS_WANT_INPUT ||
         handshake == MSSQL_TLS_WANT_OUTPUT ||
         handshake == MSSQL_TLS_HANDSHAKE_COMPLETE);

  std::vector<uint8_t> ciphertext(16384);
  size_t written = 0;
  assert(mssql_tls_drain_encrypted(
             tls, ciphertext.data(), ciphertext.size(), &written) ==
         MSSQL_TLS_OK);
  assert(written > 0);
  assert(ciphertext[0] == 0x16);  // TLS handshake record.

  mssql_tls_destroy(tls);
  return 0;
}
