# =============================================================================
# komira_webpush/tests/test_webpush_round_trip.mojo
# =============================================================================
#
# `webpush_encrypt` over the system CSPRNG, decrypted with the RFC 8291
# example's user agent key:
#
#   * two encryptions of the same plaintext differ in salt, in sender key
#     (the keyid) and in ciphertext, and both decrypt (a constant salt or a
#     reused sender key goes red here);
#   * the header is rs 4096 with a 65-byte keyid that is an uncompressed
#     point, and the body is 86 + plaintext + 17 bytes (one record, no
#     padding);
#   * the largest plaintext, 3993 bytes, makes a 4096-byte body; an empty
#     plaintext round-trips.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import hex_lower
from komira_encoding import base64_url_decode_nopad
from komira_webpush import (
    MAX_PLAINTEXT_SIZE,
    aes128gcm_parse_header,
    webpush_decrypt,
    webpush_encrypt,
)


comptime _UA_PUBLIC = (
    "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcx"
    "aOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
)
comptime _UA_PRIVATE = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
comptime _AUTH_SECRET = "BTBZMqHH6r4Tts7J_aSIgg"


def _b(s: String) raises -> List[UInt8]:
    return base64_url_decode_nopad(s)


def _encrypt(plaintext: List[UInt8]) raises -> List[UInt8]:
    var ua_public = _b(_UA_PUBLIC)
    var auth = _b(_AUTH_SECRET)
    return webpush_encrypt(
        Span[UInt8](ua_public), Span[UInt8](auth), Span[UInt8](plaintext)
    )


def _decrypt(body: List[UInt8]) raises -> List[UInt8]:
    var ua_private = _b(_UA_PRIVATE)
    var ua_public = _b(_UA_PUBLIC)
    var auth = _b(_AUTH_SECRET)
    return webpush_decrypt(
        Span[UInt8](ua_private),
        Span[UInt8](ua_public),
        Span[UInt8](auth),
        Span[UInt8](body),
    )


def _hex_of(bs: List[UInt8]) -> String:
    return hex_lower(Span[UInt8](bs))


def _slice_hex(bs: List[UInt8], start: Int, end: Int) -> String:
    var part = List[UInt8](capacity=end - start)
    for i in range(start, end):
        part.append(bs[i])
    return hex_lower(Span[UInt8](part))


def test_two_encryptions_differ() raises:
    var plaintext = List[UInt8](String("wake").as_bytes())
    var a = _encrypt(plaintext)
    var b = _encrypt(plaintext)
    assert_true(_slice_hex(a, 0, 16) != _slice_hex(b, 0, 16), "salt reused")
    assert_true(
        _slice_hex(a, 21, 86) != _slice_hex(b, 21, 86), "sender key reused"
    )
    assert_true(
        _slice_hex(a, 86, len(a)) != _slice_hex(b, 86, len(b)),
        "ciphertext repeated",
    )
    assert_equal(_hex_of(_decrypt(a)), _hex_of(plaintext))
    assert_equal(_hex_of(_decrypt(b)), _hex_of(plaintext))


def test_header_shape() raises:
    var plaintext = List[UInt8](String("0123456789").as_bytes())
    var body = _encrypt(plaintext)
    assert_equal(len(body), 86 + 10 + 17)
    var header = aes128gcm_parse_header(Span[UInt8](body))
    assert_equal(header.rs, 4096)
    assert_equal(len(header.keyid), 65)
    assert_equal(Int(header.keyid[0]), 0x04)
    assert_equal(header.records_offset, 86)


def test_largest_and_empty_plaintext() raises:
    assert_equal(MAX_PLAINTEXT_SIZE, 3993)
    var big = List[UInt8](capacity=3993)
    for i in range(3993):
        big.append(UInt8(i % 251))
    var body = _encrypt(big)
    assert_equal(len(body), 4096)
    assert_equal(_hex_of(_decrypt(body)), _hex_of(big))
    var empty = List[UInt8]()
    var body_empty = _encrypt(empty)
    assert_equal(len(body_empty), 86 + 17)
    assert_equal(len(_decrypt(body_empty)), 0)


def main() raises:
    test_two_encryptions_differ()
    print("PASS two encryptions differ in salt, key and ciphertext")
    test_header_shape()
    print("PASS header rs 4096, 65-byte keyid, one record")
    test_largest_and_empty_plaintext()
    print("PASS 3993-byte and empty plaintexts round-trip")
