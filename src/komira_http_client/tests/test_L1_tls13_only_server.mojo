# =============================================================================
# test_L1_tls13_only_server.mojo -- the default client TLS configuration
# completes a handshake with a server that accepts TLS 1.3 only
# =============================================================================
#
# THE DEFECT. A fresh s2n config carries the `"default"` security policy,
# which in the pinned s2n-tls (v1.5.6) offers TLS 1.2 cipher suites only. A
# client built on it sends a TLS-1.2-only ClientHello, and a server that
# accepts TLS 1.3 only refuses it before ServerHello: the handshake fails and
# no request is ever sent. `default_client_tls_config` (the configuration both
# public-CA connectors build on) sets `"default_tls13"` so that the client
# offers TLS 1.3.
#
# THE PEER. An in-process s2n server holding the fixture leaf certificate,
# configured with `"AWS-CRT-SDK-TLSv1.3"`, an s2n policy whose minimum
# protocol version is TLS 1.3. Both ends run over a non-blocking socketpair,
# driven alternately until both are DONE or one fails. No third-party binary
# is involved.
#
# WHAT IT ASSERTS.
#   1. `default_client_tls_config()`, with its trust store swapped for the
#      fixture root, completes the handshake, and both ends report TLS 1.3
#      (`negotiated_tls_version() == TLS_VERSION_TLS13`).
#      `negotiated_tls_version()` is -1 until a handshake is DONE (asserted
#      on fresh connections), so this is a negotiated value, not s2n's
#      pre-handshake placeholder. Both ends also report the same cipher
#      suite (`negotiated_cipher()`), one of the three TLS 1.3 suites, and
#      the empty string before the handshake and on a refused client.
#   2. A client on a fresh config (the defect's shape: TLS 1.2 at most) is
#      refused by that server for its protocol version, and reports no
#      negotiated version. This is also what keeps (1) honest: it proves the
#      server really does refuse anything below TLS 1.3, so (1) passing means
#      the client offered 1.3.
#
# Defect it catches: `default_client_tls_config` capped at TLS 1.2 (its
# `set_cipher_preferences` call removed or given a TLS 1.2 policy);
# `negotiated_tls_version()` returning s2n's raw field before the handshake;
# `negotiated_cipher()` returning s2n's cipher field before the handshake
# (its `_handshake_done` guard dropped).
#
# It imports the TLS layer's connection type directly, on purpose, to drive
# the handshake without a reactor, as the other TLS tests here do.
# =============================================================================

from std.ffi import external_call
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from komira_http_client.tls_connector import default_client_tls_config
from komira_http_core.tls import (
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TLS_VERSION_TLS13,
    TlsConfig,
    TlsConnection,
    last_s2n_errno,
    s2n_strerror_message,
    tls_init,
)


comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1
comptime _TLS13_ONLY_POLICY = "AWS-CRT-SDK-TLSv1.3"


def _fixture(name: String) raises -> String:
    return Path("src/komira_http_core/tests/fixtures/tls/" + name).read_text()


def _socketpair() raises -> Tuple[Int32, Int32]:
    var sv = Array[Int32, 2](fill=Int32(-1))
    # SAFETY: the pointer's origin is `sv`, which outlives the synchronous
    # socketpair call; the call writes two Int32 into it and keeps no pointer.
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), sv.unsafe_ptr()
    )
    if rc != Int32(0):
        raise Error("socketpair() returned " + String(Int(rc)))
    return (sv[0], sv[1])


def _close_fd(fd: Int32):
    if fd >= 0:
        var _rc = external_call["close", Int32](fd)


def _set_nonblock(fd: Int32) raises:
    var rc = external_call["komira_fcntl_set_nonblock", Int32](fd)
    if rc < Int32(0):
        raise Error("komira_fcntl_set_nonblock returned " + String(Int(rc)))


def _tls13_only_server_config() raises -> TlsConfig:
    var config = TlsConfig()
    config.load_cert(_fixture("leaf_cert.pem"), _fixture("leaf_key.pem"))
    config.set_cipher_preferences(String(_TLS13_ONLY_POLICY))
    var alpn = List[String]()
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    return config^


def _pin_fixture_root(mut config: TlsConfig) raises:
    config.wipe_trust()
    config.add_trust_pem(_fixture("root_ca.pem"))


struct _Handshake(Copyable, Movable):
    """How a handshake ended: both outcomes, which side failed first, its
    s2n error, and each side's negotiated version."""

    var server: UInt8
    var client: UInt8
    var error: String
    var server_version: Int
    var client_version: Int
    var server_cipher: String
    var client_cipher: String

    def __init__(out self):
        self.server = UInt8(255)
        self.client = UInt8(255)
        self.error = String("")
        self.server_version = -1
        self.client_version = -1
        self.server_cipher = String("")
        self.client_cipher = String("")


def _handshake(ref server_config: TlsConfig, ref client_config: TlsConfig) raises -> _Handshake:
    """Drive both ends over a socketpair until both are DONE or one fails
    (64 rounds at most; a TLS 1.3 handshake needs a handful)."""
    var r = _Handshake()
    var fds = _socketpair()
    try:
        _set_nonblock(fds[0])
        _set_nonblock(fds[1])
        var server = TlsConnection(server_config)
        server.bind_fd(fds[0])
        var client = TlsConnection.new_client(client_config)
        client.bind_fd(fds[1])
        client.set_server_name(String("localhost"))
        var server_done = False
        var client_done = False
        for _ in range(64):
            if not server_done:
                r.server = server.handshake()
                if r.server == TLS_OUTCOME_ERROR:
                    r.error = "server: " + s2n_strerror_message(last_s2n_errno())
                    break
                server_done = r.server == TLS_OUTCOME_DONE
            if not client_done:
                r.client = client.handshake()
                if r.client == TLS_OUTCOME_ERROR:
                    r.error = "client: " + s2n_strerror_message(last_s2n_errno())
                    break
                client_done = r.client == TLS_OUTCOME_DONE
            if server_done and client_done:
                break
        r.server_version = server.negotiated_tls_version()
        r.client_version = client.negotiated_tls_version()
        r.server_cipher = server.negotiated_cipher()
        r.client_cipher = client.negotiated_cipher()
        _ = server^
        _ = client^
    finally:
        _close_fd(fds[0])
        _close_fd(fds[1])
    return r^


def test_default_client_negotiates_tls13_with_a_tls13_only_server() raises:
    tls_init()
    var server_config = _tls13_only_server_config()
    var client_config = default_client_tls_config()
    _pin_fixture_root(client_config)
    var r = _handshake(server_config, client_config)
    print(
        "default client vs TLS1.3-only server: server=" + String(Int(r.server))
        + " client=" + String(Int(r.client)) + " versions="
        + String(r.server_version) + "/" + String(r.client_version)
        + " error='" + r.error + "'"
    )
    assert_true(
        r.server == TLS_OUTCOME_DONE and r.client == TLS_OUTCOME_DONE,
        "the default client did not complete a handshake with a TLS 1.3-only"
        + " server: " + r.error,
    )
    assert_equal(r.client_version, TLS_VERSION_TLS13)
    assert_equal(r.server_version, TLS_VERSION_TLS13)
    assert_equal(r.client_cipher, r.server_cipher, "both ends' cipher suite")
    assert_true(
        r.client_cipher == "TLS_AES_128_GCM_SHA256"
        or r.client_cipher == "TLS_AES_256_GCM_SHA384"
        or r.client_cipher == "TLS_CHACHA20_POLY1305_SHA256",
        "not a TLS 1.3 suite: '" + r.client_cipher + "'",
    )


def test_tls12_capped_client_is_refused_by_a_tls13_only_server() raises:
    tls_init()
    var server_config = _tls13_only_server_config()
    var client_config = TlsConfig()  # s2n's "default": TLS 1.2 at most
    _pin_fixture_root(client_config)
    var alpn = List[String]()
    alpn.append(String("http/1.1"))
    client_config.set_alpn_protocols(alpn)
    var r = _handshake(server_config, client_config)
    print(
        "TLS1.2 client vs TLS1.3-only server: server=" + String(Int(r.server))
        + " client=" + String(Int(r.client)) + " error='" + r.error + "'"
    )
    assert_true(
        r.server == TLS_OUTCOME_ERROR or r.client == TLS_OUTCOME_ERROR,
        "a TLS 1.2-only client was not refused: the server is not TLS 1.3-only",
    )
    assert_true(
        r.error.find("protocol version") >= 0,
        "refused, but not for its protocol version: '" + r.error + "'",
    )
    assert_equal(r.client_version, -1, "a refused client reports a version")
    assert_equal(r.client_cipher, String(""), "a refused client reports a cipher suite")


def test_no_version_is_reported_before_the_handshake() raises:
    """Before the handshake s2n's version field holds a placeholder (TLS 1.3
    on a client, 0 on a server); the wrapper must report -1 instead, or the
    TLS 1.3 assertion above could pass with no handshake at all."""
    tls_init()
    var server_config = _tls13_only_server_config()
    var client_config = default_client_tls_config()
    var server = TlsConnection(server_config)
    var client = TlsConnection.new_client(client_config)
    assert_equal(client.negotiated_tls_version(), -1, "fresh client")
    assert_equal(server.negotiated_tls_version(), -1, "fresh server")
    assert_equal(client.negotiated_cipher(), String(""), "fresh client's cipher suite")
    assert_equal(server.negotiated_cipher(), String(""), "fresh server's cipher suite")
    _ = server^
    _ = client^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
