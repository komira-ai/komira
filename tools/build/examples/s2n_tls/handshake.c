// A TLS 1.3 handshake between an s2n-tls client and an s2n-tls server in
// one process, over a socketpair, with a certificate made for the occasion
// by aws-lc. Called from handshake_test.mojo, after it has called s2n_init.

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <openssl/bio.h>
#include <openssl/ec.h>
#include <openssl/evp.h>
#include <openssl/nid.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <s2n.h>

#define FAIL(what) do { \
    fprintf(stderr, "s2n handshake: %s: %s (%s)\n", what, s2n_strerror(s2n_errno, "EN"), s2n_strerror_debug(s2n_errno, "EN")); \
    return 1; \
} while (0)

static char *bio_string(BIO *b) {
    const uint8_t *data;
    size_t len;
    if (!BIO_mem_contents(b, &data, &len)) return NULL;
    char *s = malloc(len + 1);
    memcpy(s, data, len);
    s[len] = 0;
    return s;
}

// A P-256 key and a self-signed certificate for "localhost", as PEM.
static int make_cert(char **cert_pem, char **key_pem) {
    EVP_PKEY *pkey = NULL;
    EVP_PKEY_CTX *kctx = EVP_PKEY_CTX_new_id(EVP_PKEY_EC, NULL);
    if (!kctx || EVP_PKEY_keygen_init(kctx) != 1 ||
        EVP_PKEY_CTX_set_ec_paramgen_curve_nid(kctx, NID_X9_62_prime256v1) != 1 ||
        EVP_PKEY_keygen(kctx, &pkey) != 1) {
        fprintf(stderr, "s2n handshake: EC key generation failed\n");
        return 1;
    }
    X509 *x = X509_new();
    X509_set_version(x, X509_VERSION_3);
    ASN1_INTEGER_set(X509_get_serialNumber(x), 1);
    X509_gmtime_adj(X509_getm_notBefore(x), -3600);
    X509_gmtime_adj(X509_getm_notAfter(x), 86400);
    X509_set_pubkey(x, pkey);
    X509_NAME *name = X509_get_subject_name(x);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const unsigned char *)"localhost", -1, -1, 0);
    X509_set_issuer_name(x, name);
    X509_EXTENSION *san = X509V3_EXT_conf_nid(NULL, NULL, NID_subject_alt_name, "DNS:localhost");
    if (!san || X509_add_ext(x, san, -1) != 1 || X509_sign(x, pkey, EVP_sha256()) == 0) {
        fprintf(stderr, "s2n handshake: certificate creation failed\n");
        return 1;
    }
    X509_EXTENSION_free(san);
    BIO *cb = BIO_new(BIO_s_mem());
    BIO *kb = BIO_new(BIO_s_mem());
    if (PEM_write_bio_X509(cb, x) != 1 || PEM_write_bio_PrivateKey(kb, pkey, NULL, NULL, 0, NULL, NULL) != 1) {
        fprintf(stderr, "s2n handshake: PEM encoding failed\n");
        return 1;
    }
    *cert_pem = bio_string(cb);
    *key_pem = bio_string(kb);
    BIO_free(cb);
    BIO_free(kb);
    X509_free(x);
    EVP_PKEY_free(pkey);
    EVP_PKEY_CTX_free(kctx);
    return (*cert_pem && *key_pem) ? 0 : 1;
}

static int step(struct s2n_connection *conn, int *done, const char *who) {
    s2n_blocked_status blocked;
    if (*done) return 0;
    if (s2n_negotiate(conn, &blocked) == S2N_SUCCESS) {
        *done = 1;
        return 0;
    }
    if (s2n_error_get_type(s2n_errno) == S2N_ERR_T_BLOCKED) return 0;
    FAIL(who);
}

// 0 when the handshake completes with TLS 1.3, the client verifies the
// server's certificate for "localhost", and a message crosses in each
// direction. Writes the negotiated protocol version to *version.
int komira_s2n_handshake(int *version) {
    char *cert_pem, *key_pem;
    if (make_cert(&cert_pem, &key_pem)) return 1;

    struct s2n_cert_chain_and_key *chain = s2n_cert_chain_and_key_new();
    if (!chain || s2n_cert_chain_and_key_load_pem(chain, cert_pem, key_pem) != S2N_SUCCESS) FAIL("load certificate");

    struct s2n_config *server_config = s2n_config_new();
    if (!server_config || s2n_config_set_cipher_preferences(server_config, "default_tls13") != S2N_SUCCESS ||
        s2n_config_add_cert_chain_and_key_to_store(server_config, chain) != S2N_SUCCESS) FAIL("server config");

    struct s2n_config *client_config = s2n_config_new();
    if (!client_config || s2n_config_set_cipher_preferences(client_config, "default_tls13") != S2N_SUCCESS ||
        s2n_config_wipe_trust_store(client_config) != S2N_SUCCESS ||
        s2n_config_add_pem_to_trust_store(client_config, cert_pem) != S2N_SUCCESS) FAIL("client config");

    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
        fprintf(stderr, "s2n handshake: socketpair: %s\n", strerror(errno));
        return 1;
    }
    for (int i = 0; i < 2; i++) fcntl(fds[i], F_SETFL, fcntl(fds[i], F_GETFL) | O_NONBLOCK);

    struct s2n_connection *client = s2n_connection_new(S2N_CLIENT);
    struct s2n_connection *server = s2n_connection_new(S2N_SERVER);
    if (!client || s2n_connection_set_config(client, client_config) != S2N_SUCCESS ||
        s2n_set_server_name(client, "localhost") != S2N_SUCCESS || s2n_connection_set_fd(client, fds[0]) != S2N_SUCCESS)
        FAIL("client connection");
    if (!server || s2n_connection_set_config(server, server_config) != S2N_SUCCESS ||
        s2n_connection_set_fd(server, fds[1]) != S2N_SUCCESS)
        FAIL("server connection");

    int client_done = 0, server_done = 0;
    for (int i = 0; i < 1000 && !(client_done && server_done); i++) {
        if (step(client, &client_done, "client negotiate") || step(server, &server_done, "server negotiate")) return 1;
    }
    if (!(client_done && server_done)) {
        fprintf(stderr, "s2n handshake: did not complete in 1000 rounds\n");
        return 1;
    }
    *version = s2n_connection_get_actual_protocol_version(client);

    // One message each way.
    const char *msgs[2] = {"ping", "pong"};
    struct s2n_connection *from[2] = {client, server}, *to[2] = {server, client};
    for (int m = 0; m < 2; m++) {
        s2n_blocked_status blocked;
        char buf[16] = {0};
        ssize_t got = -1;
        if (s2n_send(from[m], msgs[m], 4, &blocked) != 4) FAIL("send");
        for (int i = 0; i < 1000 && got < 0; i++) {
            got = s2n_recv(to[m], buf, sizeof(buf), &blocked);
            if (got < 0 && s2n_error_get_type(s2n_errno) != S2N_ERR_T_BLOCKED) FAIL("recv");
        }
        if (got != 4 || memcmp(buf, msgs[m], 4) != 0) {
            fprintf(stderr, "s2n handshake: %s arrived as '%s'\n", msgs[m], buf);
            return 1;
        }
    }

    s2n_connection_free(client);
    s2n_connection_free(server);
    s2n_config_free(client_config);
    s2n_config_free(server_config);
    s2n_cert_chain_and_key_free(chain);
    close(fds[0]);
    close(fds[1]);
    free(cert_pem);
    free(key_pem);
    return 0;
}
