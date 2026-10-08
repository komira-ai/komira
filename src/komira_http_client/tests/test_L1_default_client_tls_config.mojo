# =============================================================================
# test_L1_default_client_tls_config.mojo -- the default client TLS
# configuration offers exactly the ALPN list it documents and verifies the
# server's certificate
# =============================================================================
#
# `default_client_tls_config` is what both public-CA connectors build on, so
# every HTTPS dial a komira client makes carries its ALPN list and its
# verification setting. Before this file, two mutants of it left this
# package's tests green: offering `h3` where it offers `h2`, and turning
# certificate verification off.
#
# THE PEER. An in-process s2n server holding the fixture leaf certificate
# (signed by the fixture root, SANs `localhost` and `127.0.0.1`), over a
# non-blocking socketpair, both ends driven alternately until both are DONE or
# one fails. No third-party binary is involved.
#
# HOW THE ALPN LIST IS READ. s2n keeps no readable copy of a config's ALPN
# list, so the test reads what the client actually SENT: the server side's
# parsed ClientHello (`s2n_connection_get_client_hello` +
# `s2n_client_hello_get_extension_by_id`, extension 16, RFC 7301 section 3.1).
# The extension body is the wire `ProtocolNameList`: a 2-byte length, then
# each name as a 1-byte length and its bytes. Comparing those bytes pins the
# names, their order and that nothing else is offered.
#
# WHAT IT ASSERTS.
#   1. `default_client_tls_config()` sends exactly `[http/1.1]`; against a
#      server preferring `[h3, h2, http/1.1]` it negotiates `http/1.1`.
#   2. `default_client_tls_config(alpn_h2=True)` sends exactly
#      `[h2, http/1.1]`; against the same server it negotiates `h2`.
#   3. `default_client_tls_config()` WITHOUT the fixture root in its trust
#      store is refused by the client with s2n's "Certificate is untrusted".
#      (1) and (2) are its control: the same configuration with the root
#      pinned completes against the same server and name, so (3) is refused
#      for trust and nothing else.
#
# Defects it catches (each planted and seen red):
#   * `h2` replaced by `h3` in the default ALPN list (1 still passes; 2 fails
#     on the wire bytes and on the negotiated `h3`);
#   * `config.disable_verify()` in `default_client_tls_config` (3 completes
#     the handshake instead of refusing it).
#
# Cost: (3) is the file's only refused handshake. s2n blinds a failed
# handshake with a 10-30 s delay (komira#765), so it is kept to one.
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
    TlsConfig,
    TlsConnection,
    last_s2n_errno,
    s2n_strerror_message,
    tls_init,
)
from komira_http_core.tls.ffi import S2nOpaquePtr


comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1
# s2n.h `s2n_tls_extension_type`: S2N_EXTENSION_ALPN = 16 (RFC 7301).
comptime _S2N_EXTENSION_ALPN: Int32 = 16


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


def _server_config() raises -> TlsConfig:
    """The fixture leaf, TLS 1.3 offered, and an ALPN preference that puts
    `h3` and `h2` ahead of `http/1.1`: the server picks the first of its own
    list that the client offered, so the negotiated name says which of them
    the client sent."""
    var config = TlsConfig()
    config.load_cert(_fixture("leaf_cert.pem"), _fixture("leaf_key.pem"))
    config.set_cipher_preferences(String("default_tls13"))
    var alpn = List[String]()
    alpn.append(String("h3"))
    alpn.append(String("h2"))
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    return config^


def _pin_fixture_root(mut config: TlsConfig) raises:
    config.wipe_trust()
    config.add_trust_pem(_fixture("root_ca.pem"))


def _hex(bytes: Span[UInt8, _]) -> String:
    comptime digits = "0123456789abcdef"
    var out = String()
    for b in bytes:
        if out.byte_length() > 0:
            out += " "
        out += String(digits[byte=Int(b >> 4)])
        out += String(digits[byte=Int(b & 15)])
    return out^


def _alpn_wire(protocols: List[String]) -> String:
    """The RFC 7301 `ProtocolNameList` encoding of `protocols`, as hex."""
    var body = List[UInt8]()
    for p in protocols:
        body.append(UInt8(p.byte_length()))
        for b in p.as_bytes():
            body.append(b)
    var wire = List[UInt8]()
    wire.append(UInt8(len(body) >> 8))
    wire.append(UInt8(len(body) & 0xFF))
    for b in body:
        wire.append(b)
    return _hex(wire)


def _offered_alpn(ref server: TlsConnection) -> Optional[String]:
    """The ALPN extension body of the ClientHello the server has parsed, as
    hex; None until the server has parsed one. An absent extension reads as
    the empty string."""
    var raw = server._raw_conn_ptr_for_test()
    # SAFETY (FFI-BOUNDARY): `raw` is the live s2n_connection_t the caller's
    # `server` owns for this call. The returned client-hello pointer is
    # s2n-owned, lives inside that connection, is NULL until a ClientHello
    # has been parsed, and is used only within this function.
    var ch = external_call["s2n_connection_get_client_hello", S2nOpaquePtr](raw)
    if Int(ch) == 0:
        return None
    # SAFETY (FFI-BOUNDARY): `ch` is non-NULL and owned by the live
    # connection; the call only reads a length.
    var n = external_call["s2n_client_hello_get_extension_length", Int](
        ch, _S2N_EXTENSION_ALPN
    )
    var buf = List[UInt8]()
    for _ in range(n if n > 0 else 1):
        buf.append(UInt8(0))
    # SAFETY (FFI-BOUNDARY): `buf` is alive across this synchronous call and
    # holds `len(buf)` bytes, the bound passed; s2n copies at most that many
    # into it and keeps no pointer. `ch` is as above.
    var got = external_call["s2n_client_hello_get_extension_by_id", Int](
        ch, _S2N_EXTENSION_ALPN, buf.unsafe_ptr(), UInt32(len(buf))
    )
    if got <= 0:
        return String("")
    return _hex(Span(buf)[:got])


struct _Handshake(Copyable, Movable):
    """How a handshake ended: both outcomes, the first side's s2n error, the
    ALPN list the client offered (hex) and the protocol the client
    negotiated."""

    var server: UInt8
    var client: UInt8
    var error: String
    var offered_alpn: String
    var negotiated: String

    def __init__(out self):
        self.server = UInt8(255)
        self.client = UInt8(255)
        self.error = String("")
        self.offered_alpn = String("<no ClientHello parsed>")
        self.negotiated = String("<none>")


def _handshake(ref server_config: TlsConfig, ref client_config: TlsConfig) raises -> _Handshake:
    """Drive both ends over a socketpair until both are DONE or one fails
    (64 rounds at most; a TLS 1.3 handshake needs a handful). The offered
    ALPN list is read right after the server step that parses the
    ClientHello."""
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
        var captured = False
        for _ in range(64):
            if not server_done:
                r.server = server.handshake()
                if not captured:
                    var offered = _offered_alpn(server)
                    if offered:
                        r.offered_alpn = offered.value()
                        captured = True
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
        var negotiated = client.negotiated_protocol()
        if negotiated:
            r.negotiated = negotiated.value()
        _ = server^
        _ = client^
    finally:
        _close_fd(fds[0])
        _close_fd(fds[1])
    return r^


def _report(label: String, r: _Handshake):
    print(
        label + ": server=" + String(Int(r.server)) + " client="
        + String(Int(r.client)) + " offered=[" + r.offered_alpn
        + "] negotiated=" + r.negotiated + " error='" + r.error + "'"
    )


def test_default_config_offers_exactly_http11() raises:
    tls_init()
    var server_config = _server_config()
    var client_config = default_client_tls_config()
    _pin_fixture_root(client_config)
    var r = _handshake(server_config, client_config)
    _report("default ALPN", r)
    var expected = List[String]()
    expected.append(String("http/1.1"))
    assert_equal(
        r.offered_alpn, _alpn_wire(expected),
        "the default client config did not offer exactly [http/1.1]",
    )
    assert_true(
        r.server == TLS_OUTCOME_DONE and r.client == TLS_OUTCOME_DONE,
        "the default config with the fixture root pinned did not complete: "
        + r.error,
    )
    assert_equal(r.negotiated, String("http/1.1"))


def test_h2_config_offers_exactly_h2_then_http11() raises:
    tls_init()
    var server_config = _server_config()
    var client_config = default_client_tls_config(alpn_h2=True)
    _pin_fixture_root(client_config)
    var r = _handshake(server_config, client_config)
    _report("alpn_h2 ALPN", r)
    var expected = List[String]()
    expected.append(String("h2"))
    expected.append(String("http/1.1"))
    assert_equal(
        r.offered_alpn, _alpn_wire(expected),
        "default_client_tls_config(alpn_h2=True) did not offer exactly"
        + " [h2, http/1.1]",
    )
    assert_true(
        r.server == TLS_OUTCOME_DONE and r.client == TLS_OUTCOME_DONE,
        "the h2 config with the fixture root pinned did not complete: "
        + r.error,
    )
    assert_equal(r.negotiated, String("h2"))


def test_default_config_refuses_an_untrusted_server() raises:
    """The one refused handshake in this file (s2n's blinding delay)."""
    tls_init()
    var server_config = _server_config()
    var client_config = default_client_tls_config()  # fixture root NOT trusted
    var r = _handshake(server_config, client_config)
    _report("default config vs untrusted server", r)
    assert_true(
        r.client == TLS_OUTCOME_ERROR,
        "the default client config completed a handshake with a server whose"
        + " certificate it does not trust: verification is off",
    )
    assert_equal(r.error, String("client: Certificate is untrusted"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
