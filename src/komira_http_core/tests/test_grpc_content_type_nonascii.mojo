# =============================================================================
# test_grpc_content_type_nonascii.mojo: a non-ASCII request content-type
# =============================================================================
#
# The h2 serve loop calls `is_grpc_content_type` on every request's
# `content-type` header to decide whether the request goes to the gRPC
# dispatcher. The header value is the peer's: any byte can be in it. Reading
# it with `ct[byte=i]` asserts on the first UTF-8 continuation byte ("does not
# lie on a codepoint boundary") and aborts the whole process. The old scan
# stopped at the first `;`, so a non-ASCII byte AFTER it was never read (T1
# passed on the old code: it pins the behaviour, not the abort); one BEFORE
# any `;` killed the test binary (and, in production, the server): T2 and the
# second half of T3 aborted on the old code.
#
# Spec: RFC 9110 8.3.1, `media-type = type "/" subtype parameters`; only the
# type/subtype decides the codec, a parameter (ASCII or not) is ignored. A
# non-ASCII byte inside the type/subtype simply does not name a gRPC type.
#
# Coverage:
#   T1  a non-ASCII parameter on each gRPC base type: still gRPC.
#   T2  a non-ASCII byte in the base type, with and without `;`: not gRPC.
#   T3  the value as the real HPACK decoder hands it to the serve loop (a
#       literal header field), for each wire suffix C3 A9 (valid `é`), a
#       lone 80, FF and a truncated C3 (invalid UTF-8):
#       `application/grpc; charset=caf` + suffix is gRPC;
#       `application/grpc` + suffix (no parameter) is not, and must not abort.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_core.codec.h2.hpack import HpackDecoder
from komira_http_core.transport.grpc_emit import is_grpc_content_type


def test_t1_nonascii_parameter_is_ignored() raises:
    print("  T1 non-ASCII parameter...")
    assert_true(is_grpc_content_type(String("application/grpc; charset=café")))
    assert_true(is_grpc_content_type(String("application/grpc+proto;café")))
    assert_true(is_grpc_content_type(String("application/grpc-web; x=✓")))
    assert_true(is_grpc_content_type(String("application/json; charset=utf-8; é")))
    print("    OK")


def test_t2_nonascii_base_is_not_grpc() raises:
    print("  T2 non-ASCII base type...")
    assert_false(is_grpc_content_type(String("application/grpcé")))
    assert_false(is_grpc_content_type(String("é")))
    assert_false(is_grpc_content_type(String("applicatioñ/grpc; charset=utf-8")))
    print("    OK")


def _hpack_content_type(prefix: String, suffix: List[UInt8]) raises -> String:
    """`prefix` + the `suffix` wire bytes as the HPACK decoder returns a
    literal `content-type` field carrying them (RFC 7541 6.2.2: literal
    without indexing, new name, no Huffman)."""
    var name = String("content-type")
    var value = List[UInt8]()
    for b in prefix.as_bytes():
        value.append(b)
    for i in range(len(suffix)):
        value.append(suffix[i])
    var block = List[UInt8]()
    block.append(UInt8(0x00))
    block.append(UInt8(name.byte_length()))
    for b in name.as_bytes():
        block.append(b)
    block.append(UInt8(len(value)))
    for i in range(len(value)):
        block.append(value[i])
    var dec = HpackDecoder()
    var headers = dec.decode_block(Span(block))
    assert_equal(len(headers), 1)
    assert_equal(String(headers[0].name), name)
    return String(headers[0].value)


def test_t3_hpack_decoded_value() raises:
    print("  T3 value from the HPACK decoder...")
    var suffixes = List[List[UInt8]]()
    suffixes.append([UInt8(0xC3), UInt8(0xA9)])
    suffixes.append([UInt8(0x80)])
    suffixes.append([UInt8(0xFF)])
    suffixes.append([UInt8(0xC3)])
    for i in range(len(suffixes)):
        assert_true(
            is_grpc_content_type(
                _hpack_content_type(String("application/grpc; charset=caf"), suffixes[i])
            )
        )
        assert_false(
            is_grpc_content_type(_hpack_content_type(String("application/grpc"), suffixes[i]))
        )
    print("    OK")


def main() raises:
    print("== non-ASCII content-type ==")
    test_t1_nonascii_parameter_is_ignored()
    test_t2_nonascii_base_is_not_grpc()
    test_t3_hpack_decoded_value()
    print("== PASSED (3 legs) ==")
