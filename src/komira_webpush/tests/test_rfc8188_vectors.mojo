# =============================================================================
# komira_webpush/tests/test_rfc8188_vectors.mojo
# =============================================================================
#
# The two examples of RFC 8188 section 3:
#
#   * 3.1 (one record, rs 4096, empty keyid): CEK and NONCE equal the RFC's
#     intermediate values, `aes128gcm_encrypt` writes the 53-byte body byte
#     for byte, and `aes128gcm_decrypt` reads it back;
#   * 3.2 (two records of rs 25, keyid "a1", one 0x00 padding byte in the
#     first record): the header parses and the body decrypts. The second
#     record only opens when its nonce is XORed with sequence number 1, and
#     the first only when delimiter 0x01 is accepted before the last record
#     and its padding is stripped.
# =============================================================================

from std.testing import assert_equal

from komira_crypto import hex_lower
from komira_encoding import base64_url_decode_nopad
from komira_webpush import (
    aes128gcm_decrypt,
    aes128gcm_encrypt,
    aes128gcm_keys,
    aes128gcm_parse_header,
)


comptime _IKM_1 = "yqdlZ-tYemfogSmv7Ws5PQ"
comptime _SALT_1 = "I1BsxtFttlv3u_Oo94xnmw"
comptime _CEK_1 = "_wniytB-ofscZDh4tbSjHw"
comptime _NONCE_1 = "Bcs8gkIRKLI8GeI8"
comptime _BODY_1 = (
    "I1BsxtFttlv3u_Oo94xnmwAAEAAA-NAVub2qFgBEuQKRapoZu-IxkIva3MEB1PD-"
    "ly8Thjg"
)
comptime _IKM_2 = "BO3ZVPxUlnLORbVGMpbT1Q"
comptime _BODY_2 = (
    "uNCkWiNYzKTnBN9ji3-qWAAAABkCYTHOG8chz_gnvgOqdGYovxyjuqRyJFjEDyoF"
    "1Fvkj6hQPdPHI51OEUKEpgz3SsLWIqS_uA"
)


def _b(s: String) raises -> List[UInt8]:
    return base64_url_decode_nopad(s)


def _hex(s: String) raises -> String:
    var bs = _b(s)
    return hex_lower(Span[UInt8](bs))


def _text(bs: List[UInt8]) raises -> String:
    return String(StringSlice(from_utf8=Span[UInt8](bs)))


def test_section_3_1_keys() raises:
    var ikm = _b(_IKM_1)
    var salt = _b(_SALT_1)
    var keys = aes128gcm_keys(Span[UInt8](ikm), Span[UInt8](salt))
    assert_equal(hex_lower(Span[UInt8](keys.cek)), _hex(_CEK_1), "CEK")
    assert_equal(hex_lower(Span[UInt8](keys.nonce)), _hex(_NONCE_1), "NONCE")


def test_section_3_1_encrypt_byte_exact() raises:
    var ikm = _b(_IKM_1)
    var salt = _b(_SALT_1)
    var keyid = List[UInt8]()
    var plaintext = List[UInt8](String("I am the walrus").as_bytes())
    var body = aes128gcm_encrypt(
        Span[UInt8](ikm),
        Span[UInt8](salt),
        Span[UInt8](keyid),
        4096,
        Span[UInt8](plaintext),
    )
    # The example body decodes to 53 bytes (header 21, record 32); the
    # Content-Length line printed above it in the RFC says 54.
    assert_equal(len(body), 53, "length of the example body")
    assert_equal(hex_lower(Span[UInt8](body)), _hex(_BODY_1), "body")


def test_section_3_1_decrypt() raises:
    var ikm = _b(_IKM_1)
    var body = _b(_BODY_1)
    var out = aes128gcm_decrypt(Span[UInt8](ikm), Span[UInt8](body))
    assert_equal(_text(out), "I am the walrus")


def test_section_3_2_header() raises:
    var body = _b(_BODY_2)
    assert_equal(len(body), 73)
    var header = aes128gcm_parse_header(Span[UInt8](body))
    assert_equal(header.rs, 25)
    assert_equal(_text(header.keyid), "a1")
    assert_equal(header.records_offset, 23)


def test_section_3_2_decrypt_two_records() raises:
    var ikm = _b(_IKM_2)
    var body = _b(_BODY_2)
    var out = aes128gcm_decrypt(Span[UInt8](ikm), Span[UInt8](body))
    assert_equal(_text(out), "I am the walrus")


def main() raises:
    test_section_3_1_keys()
    print("PASS RFC 8188 3.1 CEK and NONCE")
    test_section_3_1_encrypt_byte_exact()
    print("PASS RFC 8188 3.1 body byte for byte")
    test_section_3_1_decrypt()
    print("PASS RFC 8188 3.1 decrypts")
    test_section_3_2_header()
    print("PASS RFC 8188 3.2 header")
    test_section_3_2_decrypt_two_records()
    print("PASS RFC 8188 3.2 two records decrypt")
