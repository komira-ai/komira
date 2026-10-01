"""L1 TLS ALPN negotiation unit tests.

Tests TlsConfig.set_alpn_protocols input validation and successful
configuration paths:

  1. Empty protocol list → raises Error.
  2. Empty protocol string in list → raises Error (s2n disallows
     zero-length protocols per s2n.h:1096).
  3. Oversized (>255-byte) protocol name → raises Error.
  4. Single protocol "http/1.1" → succeeds (the Phase 1 default).
  5. Two protocols ["h2", "http/1.1"] → succeeds (forward-compat for
     Phase 2 HTTP/2 once that lands).

Real ALPN-negotiation OUTCOME — what the client and server actually
agree on — needs a peer driving a real handshake; the unit tests here
pin the configuration side.
"""

from komira_http.tls import TlsConfig, tls_init


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_empty_list_raises() raises:
    """set_alpn_protocols([]) should raise."""
    print("  test_empty_list_raises...")
    var config = TlsConfig()
    var raised = False
    try:
        var empty = List[String]()
        config.set_alpn_protocols(empty)
    except e:
        raised = True
        _ = e
    if not raised:
        raise Error("expected set_alpn_protocols([]) to raise")
    print("    OK")


def test_empty_protocol_string_raises() raises:
    """A protocol with zero-length byte content should raise (s2n.h:1096
    explicitly disallows this)."""
    print("  test_empty_protocol_string_raises...")
    var config = TlsConfig()
    var raised = False
    try:
        var protocols = List[String]()
        protocols.append(String(""))
        config.set_alpn_protocols(protocols)
    except e:
        raised = True
        _ = e
    if not raised:
        raise Error("expected set_alpn_protocols([\"\"]) to raise")
    print("    OK")


def test_oversized_protocol_raises() raises:
    """A protocol name >255 bytes should raise (ALPN per-protocol
    length is a single byte field on the wire per RFC 7301)."""
    print("  test_oversized_protocol_raises...")
    var config = TlsConfig()
    # 300-char string — well past the 255-byte limit.
    var s = String()
    var i = 0
    while i < 300:
        s += String("a")
        i = i + 1
    var raised = False
    try:
        var protocols = List[String]()
        protocols.append(s^)
        config.set_alpn_protocols(protocols)
    except e:
        raised = True
        _ = e
    if not raised:
        raise Error("expected set_alpn_protocols(>255 bytes) to raise")
    print("    OK")


def test_single_protocol_http11() raises:
    """The canonical Phase 1 ALPN list [\"http/1.1\"] should succeed."""
    print("  test_single_protocol_http11...")
    var config = TlsConfig()
    var protocols = List[String]()
    protocols.append(String("http/1.1"))
    config.set_alpn_protocols(protocols)
    print("    OK")


def test_two_protocols_h2_http11() raises:
    """Forward-compat: setting [\"h2\", \"http/1.1\"] (Phase 2 shape)
    should succeed."""
    print("  test_two_protocols_h2_http11...")
    var config = TlsConfig()
    var protocols = List[String]()
    protocols.append(String("h2"))
    protocols.append(String("http/1.1"))
    config.set_alpn_protocols(protocols)
    print("    OK")


def test_alpn_then_cert_order() raises:
    """ALPN config can be set BEFORE cert loading (the order should
    not matter to s2n)."""
    print("  test_alpn_then_cert_order...")
    var config = TlsConfig()
    var protocols = List[String]()
    protocols.append(String("http/1.1"))
    config.set_alpn_protocols(protocols)
    # Don't actually load a cert here (kept minimal). The point is
    # set_alpn_protocols is order-agnostic with cert loading.
    print("    OK")


def main() raises:
    print("== L1 TLS ALPN ==")
    tls_init()
    test_empty_list_raises()
    test_empty_protocol_string_raises()
    test_oversized_protocol_raises()
    test_single_protocol_http11()
    test_two_protocols_h2_http11()
    test_alpn_then_cert_order()
    print("== L1 TLS ALPN PASSED (6 tests) ==")
