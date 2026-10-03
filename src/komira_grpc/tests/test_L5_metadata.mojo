# =============================================================================
# test_L5_metadata.mojo — RpcMetadata + base64 (standard) round-trip
# =============================================================================
#
# metadata.mojo coverage: metadata and standard base64.
#
# Coverage:
#   T1   RpcMetadata.set + drain → HeaderMap with grpc-metadata- prefix.
#   T2   RpcMetadata.set_bin → base64-encoded value with grpc-metadata- prefix.
#   T3   Empty RpcMetadata drain → empty dst.
#   T4   base64_encode_standard — empty input.
#   T5   base64_encode_standard — RFC 4648 §10 test vectors.
#   T6   base64_decode_standard — RFC 4648 §10 inverse test vectors.
#   T7   base64 round-trip arbitrary 0..255 bytes.
#   T8   base64 padding — 1 byte (== padding), 2 bytes (= padding), 3 bytes.
#   T9   base64_decode_standard — invalid character raises.
#   T10  base64_decode_standard — an UNPADDED value decodes; only a length
#        that cannot encode whole bytes (4k+1 symbols) raises — see the
#        docstring.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_grpc import (
    GRPC_METADATA_HEADER_PREFIX,
    RpcMetadata,
    base64_encode_standard,
    base64_decode_standard,
)
from komira_http_client.header_map import HeaderMap


def test_t1_metadata_set_drain_text() raises:
    """T1 — set + drain into HeaderMap with grpc-metadata- prefix."""
    var md = RpcMetadata.new()
    md.set(String("user-id"), String("42"))
    md.set(String("request-id"), String("abc-123"))
    assert_equal(md.count(), 2, "two entries stored")

    var dst = HeaderMap()
    md.drain_into_request_headers(dst)
    # Prefix is "grpc-metadata-" (lowercase per HeaderMap canon).
    var prefix = GRPC_METADATA_HEADER_PREFIX
    var got_user = dst.get(prefix + "user-id")
    assert_true(got_user.__bool__(), "prefixed user-id present")
    assert_equal(got_user.value(), String("42"), "value")
    var got_req = dst.get(prefix + "request-id")
    assert_true(got_req.__bool__(), "prefixed request-id present")
    assert_equal(got_req.value(), String("abc-123"), "value 2")


def test_t2_metadata_set_bin_drain() raises:
    """T2 — set_bin → base64-encoded value with grpc-metadata- prefix."""
    var md = RpcMetadata.new()
    var token = List[UInt8]()
    # "Hi" — 0x48 0x69 — base64 = "SGk="
    token.append(UInt8(0x48))
    token.append(UInt8(0x69))
    md.set_bin(String("auth-token-bin"), Span(token))

    var dst = HeaderMap()
    md.drain_into_request_headers(dst)
    var got = dst.get(GRPC_METADATA_HEADER_PREFIX + "auth-token-bin")
    assert_true(got.__bool__(), "prefixed bin key present")
    assert_equal(got.value(), String("SGk="), "base64 of 'Hi'")


def test_t3_empty_drain() raises:
    """T3 — empty RpcMetadata drain is a no-op."""
    var md = RpcMetadata.new()
    var dst = HeaderMap()
    md.drain_into_request_headers(dst)
    assert_equal(dst.len(), 0, "dst empty after empty drain")


def test_t4_b64_encode_empty() raises:
    """T4 — base64_encode_standard of empty input is empty string."""
    var empty = List[UInt8]()
    var s = base64_encode_standard(Span(empty))
    assert_equal(s, String(""), "empty in → empty out")


def test_t5_b64_encode_rfc4648_vectors() raises:
    """T5 — RFC 4648 §10 base64 test vectors (forward)."""
    # "f"     → "Zg=="
    var b1 = List[UInt8]()
    b1.append(UInt8(ord("f")))
    assert_equal(base64_encode_standard(Span(b1)), String("Zg=="), "f")

    # "fo"    → "Zm8="
    var b2 = List[UInt8]()
    b2.append(UInt8(ord("f")))
    b2.append(UInt8(ord("o")))
    assert_equal(base64_encode_standard(Span(b2)), String("Zm8="), "fo")

    # "foo"   → "Zm9v"
    var b3 = List[UInt8]()
    b3.append(UInt8(ord("f")))
    b3.append(UInt8(ord("o")))
    b3.append(UInt8(ord("o")))
    assert_equal(base64_encode_standard(Span(b3)), String("Zm9v"), "foo")

    # "foob"  → "Zm9vYg=="
    var b4 = List[UInt8]()
    b4.append(UInt8(ord("f")))
    b4.append(UInt8(ord("o")))
    b4.append(UInt8(ord("o")))
    b4.append(UInt8(ord("b")))
    assert_equal(base64_encode_standard(Span(b4)), String("Zm9vYg=="), "foob")

    # "fooba" → "Zm9vYmE="
    var b5 = List[UInt8]()
    b5.append(UInt8(ord("f")))
    b5.append(UInt8(ord("o")))
    b5.append(UInt8(ord("o")))
    b5.append(UInt8(ord("b")))
    b5.append(UInt8(ord("a")))
    assert_equal(base64_encode_standard(Span(b5)), String("Zm9vYmE="), "fooba")

    # "foobar" → "Zm9vYmFy"
    var b6 = List[UInt8]()
    b6.append(UInt8(ord("f")))
    b6.append(UInt8(ord("o")))
    b6.append(UInt8(ord("o")))
    b6.append(UInt8(ord("b")))
    b6.append(UInt8(ord("a")))
    b6.append(UInt8(ord("r")))
    assert_equal(base64_encode_standard(Span(b6)), String("Zm9vYmFy"), "foobar")


def test_t6_b64_decode_rfc4648_vectors() raises:
    """T6 — RFC 4648 §10 inverse vectors."""
    # "Zm9vYmFy" → "foobar"
    var d6 = base64_decode_standard(String("Zm9vYmFy"))
    assert_equal(len(d6), 6, "6 bytes")
    assert_equal(d6[0], UInt8(ord("f")), "byte 0")
    assert_equal(d6[1], UInt8(ord("o")), "byte 1")
    assert_equal(d6[2], UInt8(ord("o")), "byte 2")
    assert_equal(d6[3], UInt8(ord("b")), "byte 3")
    assert_equal(d6[4], UInt8(ord("a")), "byte 4")
    assert_equal(d6[5], UInt8(ord("r")), "byte 5")

    # "Zg==" → "f"
    var d1 = base64_decode_standard(String("Zg=="))
    assert_equal(len(d1), 1, "1 byte")
    assert_equal(d1[0], UInt8(ord("f")), "byte")

    # "Zm8=" → "fo"
    var d2 = base64_decode_standard(String("Zm8="))
    assert_equal(len(d2), 2, "2 bytes")
    assert_equal(d2[0], UInt8(ord("f")), "byte 0")
    assert_equal(d2[1], UInt8(ord("o")), "byte 1")


def test_t7_b64_arbitrary_round_trip() raises:
    """T7 — round-trip arbitrary 0..255 byte payload."""
    var src = List[UInt8]()
    var i = 0
    while i < 256:
        src.append(UInt8(i))
        i = i + 1
    var enc = base64_encode_standard(Span(src))
    var dec = base64_decode_standard(enc)
    assert_equal(len(dec), 256, "256 bytes back")
    var j = 0
    while j < 256:
        assert_equal(dec[j], UInt8(j), "byte preserved")
        j = j + 1


def test_t8_b64_padding_variants() raises:
    """T8 — 1-byte (==), 2-byte (=), 3-byte (no pad) input."""
    # 1 byte
    var b1 = List[UInt8]()
    b1.append(UInt8(0xFF))
    var e1 = base64_encode_standard(Span(b1))
    var d1 = base64_decode_standard(e1)
    assert_equal(len(d1), 1, "1 byte back")
    assert_equal(d1[0], UInt8(0xFF), "0xFF preserved")

    # 2 bytes
    var b2 = List[UInt8]()
    b2.append(UInt8(0xDE))
    b2.append(UInt8(0xAD))
    var e2 = base64_encode_standard(Span(b2))
    var d2 = base64_decode_standard(e2)
    assert_equal(len(d2), 2, "2 bytes back")
    assert_equal(d2[0], UInt8(0xDE), "0xDE")
    assert_equal(d2[1], UInt8(0xAD), "0xAD")

    # 3 bytes
    var b3 = List[UInt8]()
    b3.append(UInt8(0xCA))
    b3.append(UInt8(0xFE))
    b3.append(UInt8(0xBE))
    var e3 = base64_encode_standard(Span(b3))
    var d3 = base64_decode_standard(e3)
    assert_equal(len(d3), 3, "3 bytes back")
    assert_equal(d3[0], UInt8(0xCA), "0xCA")
    assert_equal(d3[1], UInt8(0xFE), "0xFE")
    assert_equal(d3[2], UInt8(0xBE), "0xBE")


def test_t9_b64_decode_invalid_char() raises:
    """T9 — invalid character raises."""
    var raised = False
    try:
        var _ = base64_decode_standard(String("Zm9v!mFy"))  # '!' invalid
    except:
        raised = True
    assert_true(raised, "invalid char raised")


def test_t10_b64_decode_bad_length() raises:
    """T10 — the REAL malformed-length boundary is 4k+1, not "not a quad".

    ⚠ `"Zm9"` (3 chars) must NOT raise: a decoder that rejects every
    un-padded value is wrong. `grpc/doc/PROTOCOL-HTTP2.md`
    ("Custom-Metadata") says:

        "Implementations MUST accept padded and un-padded values and should
         emit un-padded values."

    and grpc-go / grpc-java EMIT un-padded, so such a decoder could not read
    any `-bin` header from a Go or Java peer whose payload length is not a
    multiple of 3 — grpc-go's own vector `Zm9vAGJhcg` (10 chars) included.

    The INTENT — a malformed length must raise — is asserted at
    the boundary that is actually malformed: 4k+1 symbols carry 6 bits, less
    than one byte, so no byte sequence encodes to them under any padding.
    """
    # The un-padded spelling of "fo" — 3 symbols, 2 bytes. Legal, and the
    # bytes must match the padded spelling exactly.
    var unpadded = base64_decode_standard(String("Zm9"))
    assert_equal(len(unpadded), 2, "3 unpadded symbols -> 2 bytes")
    assert_equal(unpadded[0], UInt8(ord("f")), "byte 0")
    assert_equal(unpadded[1], UInt8(ord("o")), "byte 1")

    # 4k+1 symbols cannot encode a whole number of bytes.
    var raised = False
    try:
        var _ = base64_decode_standard(String("Zm9vA"))  # 5 symbols
    except:
        raised = True
    assert_true(raised, "a 4k+1 symbol count raised")


def main() raises:
    test_t1_metadata_set_drain_text()
    test_t2_metadata_set_bin_drain()
    test_t3_empty_drain()
    test_t4_b64_encode_empty()
    test_t5_b64_encode_rfc4648_vectors()
    test_t6_b64_decode_rfc4648_vectors()
    test_t7_b64_arbitrary_round_trip()
    test_t8_b64_padding_variants()
    test_t9_b64_decode_invalid_char()
    test_t10_b64_decode_bad_length()
    print("test_L5_metadata: 10/10 PASS")
