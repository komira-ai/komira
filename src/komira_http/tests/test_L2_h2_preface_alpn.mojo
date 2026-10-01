# =============================================================================
# tests/test_L2_h2_preface_alpn.mojo — RFC 9113 §3.4 preface + ALPN
# =============================================================================
#
# L2 unit tests. Covers:
#   * 24-byte client preface validation (RFC 9113 §3.4)
#   * NEED_MORE on short input + ERROR on mismatch
#   * ALPN identifier strings
#   * is_h2_negotiated helper
#
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http.codec.h2 import (
    ALPN_PROTOCOL_H2,
    ALPN_PROTOCOL_HTTP11,
    H2_CLIENT_PREFACE,
    H2_CLIENT_PREFACE_LEN,
    PREFACE_ERROR,
    PREFACE_NEED_MORE,
    PREFACE_OK,
    check_client_preface,
    is_h2_negotiated,
)


# =============================================================================
# §1 — Client preface validation.
# =============================================================================


def test_preface_valid_24_bytes() raises:
    var preface = H2_CLIENT_PREFACE()
    assert_equal(len(preface), 24)
    var result = check_client_preface(Span(preface))
    assert_equal(Int(result.status), Int(PREFACE_OK))
    assert_equal(result.consumed, 24)


def test_preface_short_input_need_more() raises:
    var short = List[UInt8]()
    short.append(UInt8(ord("P")))
    short.append(UInt8(ord("R")))
    short.append(UInt8(ord("I")))
    var result = check_client_preface(Span(short))
    assert_equal(Int(result.status), Int(PREFACE_NEED_MORE))


def test_preface_mismatch_error() raises:
    """24 bytes that don't match the H2 magic → PREFACE_ERROR."""
    var bad = List[UInt8]()
    bad.append(UInt8(ord("G")))
    bad.append(UInt8(ord("E")))
    bad.append(UInt8(ord("T")))
    bad.append(UInt8(0x20))
    var i = 0
    while i < 20:
        bad.append(UInt8(ord(" ")))
        i = i + 1
    assert_equal(len(bad), 24)
    var result = check_client_preface(Span(bad))
    assert_equal(Int(result.status), Int(PREFACE_ERROR))


def test_preface_one_byte_mismatch_error() raises:
    """All-correct except one byte → ERROR."""
    var preface = H2_CLIENT_PREFACE()
    preface[5] = UInt8(0xff)  # corrupt one byte
    var result = check_client_preface(Span(preface))
    assert_equal(Int(result.status), Int(PREFACE_ERROR))


# =============================================================================
# §2 — ALPN identifiers + negotiation check.
# =============================================================================


def test_alpn_h2_identifier() raises:
    assert_equal(ALPN_PROTOCOL_H2(), String("h2"))


def test_alpn_http11_identifier() raises:
    assert_equal(ALPN_PROTOCOL_HTTP11(), String("http/1.1"))


def test_is_h2_negotiated_true() raises:
    assert_true(is_h2_negotiated(String("h2")))


def test_is_h2_negotiated_false_for_http11() raises:
    assert_false(is_h2_negotiated(String("http/1.1")))


def test_is_h2_negotiated_false_for_empty() raises:
    assert_false(is_h2_negotiated(String("")))


def test_is_h2_negotiated_false_for_random() raises:
    """Case-sensitive: "H2" must NOT match."""
    assert_false(is_h2_negotiated(String("H2")))


# =============================================================================
# §3 — main.
# =============================================================================


def main() raises:
    print("test_L2_h2_preface_alpn: start")
    test_preface_valid_24_bytes()
    print(" preface_valid_24_bytes PASS")
    test_preface_short_input_need_more()
    print(" preface_short_input_need_more PASS")
    test_preface_mismatch_error()
    print(" preface_mismatch_error PASS")
    test_preface_one_byte_mismatch_error()
    print(" preface_one_byte_mismatch_error PASS")
    test_alpn_h2_identifier()
    print(" alpn_h2_identifier PASS")
    test_alpn_http11_identifier()
    print(" alpn_http11_identifier PASS")
    test_is_h2_negotiated_true()
    print(" is_h2_negotiated_true PASS")
    test_is_h2_negotiated_false_for_http11()
    print(" is_h2_negotiated_false_http11 PASS")
    test_is_h2_negotiated_false_for_empty()
    print(" is_h2_negotiated_false_empty PASS")
    test_is_h2_negotiated_false_for_random()
    print(" is_h2_negotiated_false_random PASS")
    print("test_L2_h2_preface_alpn: ALL 10 TESTS PASS")
