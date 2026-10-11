#include "mssql_tls.h"

#include <openssl/err.h>
#include <openssl/ssl.h>

#include <algorithm>
#include <memory>
#include <string>
#include <vector>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#endif

struct mssql_tls {
  SSL_CTX* context = nullptr;
  SSL* ssl = nullptr;
  std::vector<uint8_t> pending_write;
  std::string error;
  size_t maximum_packet = 16383;
#ifdef __APPLE__
  bool verify_with_apple_trust = false;
  bool apple_trust_complete = false;
  bool verify_hostname = true;
  std::string server_name;
#endif

  ~mssql_tls() {
    SSL_free(ssl);
    SSL_CTX_free(context);
  }
};

#ifdef __APPLE__
static void set_apple_error(mssql_tls* tls, CFErrorRef error) {
  tls->error = "Apple certificate trust evaluation failed";
  if (error == nullptr) return;
  CFStringRef description = CFErrorCopyDescription(error);
  if (description == nullptr) return;
  char buffer[1024] = {};
  if (CFStringGetCString(description, buffer, sizeof(buffer),
                         kCFStringEncodingUTF8)) {
    tls->error += ": ";
    tls->error += buffer;
  }
  CFRelease(description);
}

static bool append_apple_certificate(CFMutableArrayRef certificates,
                                     X509* certificate) {
  const int length = i2d_X509(certificate, nullptr);
  if (length <= 0) return false;
  std::vector<uint8_t> der(static_cast<size_t>(length));
  unsigned char* cursor = der.data();
  if (i2d_X509(certificate, &cursor) != length) return false;
  CFDataRef data = CFDataCreate(kCFAllocatorDefault, der.data(), length);
  if (data == nullptr) return false;
  SecCertificateRef apple_certificate =
      SecCertificateCreateWithData(kCFAllocatorDefault, data);
  CFRelease(data);
  if (apple_certificate == nullptr) return false;
  CFArrayAppendValue(certificates, apple_certificate);
  CFRelease(apple_certificate);
  return true;
}

static bool verify_apple_peer(mssql_tls* tls) {
  X509* leaf = SSL_get1_peer_certificate(tls->ssl);
  if (leaf == nullptr) {
    tls->error =
        "Apple certificate trust evaluation failed: no peer certificate";
    return false;
  }

  CFMutableArrayRef certificates = CFArrayCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
  if (certificates == nullptr) {
    X509_free(leaf);
    tls->error = "Apple certificate trust evaluation failed: unable to "
                 "allocate certificate chain";
    return false;
  }

  bool encoded = append_apple_certificate(certificates, leaf);
  STACK_OF(X509)* chain = SSL_get_peer_cert_chain(tls->ssl);
  if (encoded && chain != nullptr) {
    for (int i = 0; i < sk_X509_num(chain); ++i) {
      X509* certificate = sk_X509_value(chain, i);
      if (certificate != nullptr && X509_cmp(certificate, leaf) != 0 &&
          !append_apple_certificate(certificates, certificate)) {
        encoded = false;
        break;
      }
    }
  }
  X509_free(leaf);
  if (!encoded) {
    CFRelease(certificates);
    tls->error = "Apple certificate trust evaluation failed: unable to "
                 "encode certificate chain";
    return false;
  }

  SecPolicyRef policy = nullptr;
  CFStringRef hostname = nullptr;
  if (tls->verify_hostname) {
    hostname = CFStringCreateWithCString(
        kCFAllocatorDefault, tls->server_name.c_str(), kCFStringEncodingUTF8);
    if (hostname != nullptr) {
      policy = SecPolicyCreateSSL(true, hostname);
    }
  } else {
    policy = SecPolicyCreateBasicX509();
  }

  SecTrustRef trust = nullptr;
  OSStatus status = errSecParam;
  if (policy != nullptr) {
    status = SecTrustCreateWithCertificates(certificates, policy, &trust);
  }
  CFErrorRef error = nullptr;
  const bool valid = status == errSecSuccess && trust != nullptr &&
                     SecTrustEvaluateWithError(trust, &error);
  if (!valid) set_apple_error(tls, error);

  if (error != nullptr) CFRelease(error);
  if (trust != nullptr) CFRelease(trust);
  if (policy != nullptr) CFRelease(policy);
  if (hostname != nullptr) CFRelease(hostname);
  CFRelease(certificates);
  return valid;
}
#endif

static mssql_tls_result result(mssql_tls* tls, int ssl_result) {
  const int error = SSL_get_error(tls->ssl, ssl_result);
  if (error == SSL_ERROR_WANT_READ) return MSSQL_TLS_WANT_INPUT;
  if (error == SSL_ERROR_WANT_WRITE) return MSSQL_TLS_WANT_OUTPUT;
  if (error == SSL_ERROR_ZERO_RETURN) return MSSQL_TLS_PEER_CLOSED;
  unsigned long code = ERR_get_error();
  tls->error = code == 0 ? "OpenSSL operation failed" : ERR_error_string(code, nullptr);
  return MSSQL_TLS_ERROR;
}

extern "C" mssql_tls* mssql_tls_create(const mssql_tls_config* config) {
  if (config == nullptr || config->server_name == nullptr) return nullptr;
  auto tls = std::make_unique<mssql_tls>();
  tls->maximum_packet = config->maximum_plaintext_packet == 0
      ? 16383 : config->maximum_plaintext_packet;
  if (tls->maximum_packet > 16383) return nullptr;
  tls->context = SSL_CTX_new(TLS_client_method());
  if (tls->context == nullptr) return nullptr;
  if (config->trust_server_certificate) SSL_CTX_set_verify(tls->context, SSL_VERIFY_NONE, nullptr);
  else {
    const bool has_custom_roots = config->ca_file != nullptr || config->ca_path != nullptr;
#ifdef __APPLE__
    if (!has_custom_roots) {
      // OpenSSL does not read the Apple system Keychain. Complete the TLS
      // handshake first, then evaluate its peer chain with SecTrust.
      SSL_CTX_set_verify(tls->context, SSL_VERIFY_NONE, nullptr);
      tls->verify_with_apple_trust = true;
      tls->verify_hostname = config->verify_hostname != 0;
      tls->server_name = config->server_name;
    } else
#endif
    {
      SSL_CTX_set_verify(tls->context, SSL_VERIFY_PEER, nullptr);
      if (has_custom_roots) {
        if (SSL_CTX_load_verify_locations(tls->context, config->ca_file,
                                          config->ca_path) != 1) {
          return nullptr;
        }
      } else if (SSL_CTX_set_default_verify_paths(tls->context) != 1) {
        return nullptr;
      }
    }
  }
  tls->ssl = SSL_new(tls->context);
  if (tls->ssl == nullptr) return nullptr;
  if (SSL_set_tlsext_host_name(tls->ssl, config->server_name) != 1) {
    return nullptr;
  }
  if (!config->trust_server_certificate && config->verify_hostname &&
#ifdef __APPLE__
      !tls->verify_with_apple_trust &&
#endif
      SSL_set1_host(tls->ssl, config->server_name) != 1) return nullptr;
  if (SSL_set_max_send_fragment(tls->ssl,
                                static_cast<long>(tls->maximum_packet)) != 1) {
    return nullptr;
  }
  BIO* input = BIO_new(BIO_s_mem());
  BIO* output = BIO_new(BIO_s_mem());
  if (input == nullptr || output == nullptr) {
    BIO_free(input);
    BIO_free(output);
    return nullptr;
  }
  SSL_set_bio(tls->ssl, input, output);
  SSL_set_connect_state(tls->ssl);
  return tls.release();
}

extern "C" void mssql_tls_destroy(mssql_tls* tls) {
  delete tls;
}

extern "C" mssql_tls_result mssql_tls_handshake(mssql_tls* tls) {
  if (tls == nullptr) return MSSQL_TLS_INVALID_ARGUMENT;
  const int value = SSL_do_handshake(tls->ssl);
  if (value == 1) {
#ifdef __APPLE__
    if (tls->verify_with_apple_trust && !tls->apple_trust_complete) {
      if (!verify_apple_peer(tls)) return MSSQL_TLS_ERROR;
      tls->apple_trust_complete = true;
    }
#endif
    return MSSQL_TLS_HANDSHAKE_COMPLETE;
  }
  return result(tls, value);
}

extern "C" mssql_tls_result mssql_tls_feed_encrypted(mssql_tls* tls, const uint8_t* data, size_t length, size_t* consumed) {
  if (tls == nullptr || (data == nullptr && length != 0) || consumed == nullptr) return MSSQL_TLS_INVALID_ARGUMENT;
  const int written = BIO_write(SSL_get_rbio(tls->ssl), data, static_cast<int>(length));
  *consumed = written > 0 ? static_cast<size_t>(written) : 0;
  return written >= 0 ? MSSQL_TLS_OK : MSSQL_TLS_ERROR;
}

extern "C" mssql_tls_result mssql_tls_drain_encrypted(mssql_tls* tls, uint8_t* output, size_t capacity, size_t* written) {
  if (tls == nullptr || written == nullptr || (output == nullptr && capacity != 0)) return MSSQL_TLS_INVALID_ARGUMENT;
  const int read = BIO_read(SSL_get_wbio(tls->ssl), output, static_cast<int>(capacity));
  *written = read > 0 ? static_cast<size_t>(read) : 0;
  if (read <= 0 && BIO_should_retry(SSL_get_wbio(tls->ssl))) return MSSQL_TLS_OK;
  return read >= 0 ? MSSQL_TLS_OK : MSSQL_TLS_ERROR;
}

extern "C" mssql_tls_result mssql_tls_write_packet(mssql_tls* tls, const uint8_t* packet, size_t length) {
  if (tls == nullptr || packet == nullptr || length == 0) return MSSQL_TLS_INVALID_ARGUMENT;
  if (length > tls->maximum_packet) return MSSQL_TLS_PACKET_TOO_LARGE;
  if (!SSL_is_init_finished(tls->ssl) || !tls->pending_write.empty()) return MSSQL_TLS_INVALID_STATE;
  tls->pending_write.assign(packet, packet + length);
  return mssql_tls_retry_write(tls);
}

extern "C" mssql_tls_result mssql_tls_retry_write(mssql_tls* tls) {
  if (tls == nullptr || tls->pending_write.empty()) return MSSQL_TLS_INVALID_STATE;
  size_t written = 0;
  const int value = SSL_write_ex(tls->ssl, tls->pending_write.data(), tls->pending_write.size(), &written);
  if (value == 1 && written == tls->pending_write.size()) {
    tls->pending_write.clear();
    return MSSQL_TLS_OK;
  }
  return result(tls, value);
}

extern "C" int mssql_tls_has_pending_write(const mssql_tls* tls) {
  return tls != nullptr && !tls->pending_write.empty();
}

extern "C" mssql_tls_result mssql_tls_read_plaintext(mssql_tls* tls, uint8_t* output, size_t capacity, size_t* written) {
  if (tls == nullptr || written == nullptr || (output == nullptr && capacity != 0)) return MSSQL_TLS_INVALID_ARGUMENT;
  size_t read = 0;
  const int value = SSL_read_ex(tls->ssl, output, capacity, &read);
  *written = read;
  return value == 1 ? MSSQL_TLS_OK : result(tls, value);
}

extern "C" mssql_tls_result mssql_tls_peer_certificate_der(
    mssql_tls* tls, uint8_t* output, size_t capacity, size_t* written) {
  if (tls == nullptr || written == nullptr || (output == nullptr && capacity != 0)) {
    return MSSQL_TLS_INVALID_ARGUMENT;
  }
  X509* certificate = SSL_get1_peer_certificate(tls->ssl);
  if (certificate == nullptr) {
    *written = 0;
    return MSSQL_TLS_PEER_CLOSED;
  }
  const int required = i2d_X509(certificate, nullptr);
  if (required <= 0) {
    X509_free(certificate);
    return MSSQL_TLS_ERROR;
  }
  *written = static_cast<size_t>(required);
  if (output == nullptr || capacity < *written) {
    X509_free(certificate);
    return MSSQL_TLS_PACKET_TOO_LARGE;
  }
  unsigned char* cursor = output;
  const int encoded = i2d_X509(certificate, &cursor);
  X509_free(certificate);
  return encoded == required ? MSSQL_TLS_OK : MSSQL_TLS_ERROR;
}

extern "C" int mssql_tls_is_handshake_complete(const mssql_tls* tls) {
  if (tls == nullptr || !SSL_is_init_finished(tls->ssl)) return 0;
#ifdef __APPLE__
  if (tls->verify_with_apple_trust && !tls->apple_trust_complete) return 0;
#endif
  return 1;
}
extern "C" const char* mssql_tls_last_error(const mssql_tls* tls) { return tls == nullptr ? "invalid TLS handle" : tls->error.c_str(); }
extern "C" const char* mssql_tls_openssl_version(void) { return OpenSSL_version(OPENSSL_VERSION); }
