# =============================================================================
# komira_webpush/tests/test_rfc8291_vector.mojo
# =============================================================================
#
# The RFC 8291 section 5 example with its appendix A intermediate values,
# byte for byte. The fixed salt and sender key of the example go in through
# a `WebPushRandomness` conformer defined here.
#
#   * both public keys derive from their private keys;
#   * ecdh_secret, IKM (which covers key_info: a missing 0x00 after
#     "WebPush: info" or swapped public keys change it), CEK and NONCE;
#   * the encrypted body equals the 144-byte body of section 5 (covers the
#     header layout, rs 4096, keyid = as_public and the 0x02 delimiter);
#   * the user agent's side decrypts that body to the plaintext.
# =============================================================================

from std.testing import assert_equal

from komira_crypto import hex_lower, p256_ecdh
from komira_encoding import base64_url_decode_nopad
from komira_webpush import (
    WebPushRandomness,
    aes128gcm_keys,
    p256_public_key,
    webpush_decrypt,
    webpush_encrypt_with,
    webpush_ikm,
)


comptime _PLAINTEXT = "V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24"
comptime _AS_PUBLIC = (
    "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIg"
    "Dll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
)
comptime _AS_PRIVATE = "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
comptime _UA_PUBLIC = (
    "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcx"
    "aOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
)
comptime _UA_PRIVATE = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
comptime _SALT = "DGv6ra1nlYgDCS1FRnbzlw"
comptime _AUTH_SECRET = "BTBZMqHH6r4Tts7J_aSIgg"
comptime _ECDH_SECRET = "kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs"
comptime _IKM = "S4lYMb_L0FxCeq0WhDx813KgSYqU26kOyzWUdsXYyrg"
comptime _CEK = "oIhVW04MRdy2XN9CiKLxTg"
comptime _NONCE = "4h_95klXJ5E_qnoN"
comptime _BODY = (
    "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml"
    "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT"
    "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
)


def _b(s: String) raises -> List[UInt8]:
    return base64_url_decode_nopad(s)


def _hex(s: String) raises -> String:
    var bs = _b(s)
    return hex_lower(Span[UInt8](bs))


struct _FixedRandomness(WebPushRandomness):
    """The example's salt and sender key, for every call."""

    var _salt: List[UInt8]
    var _key: List[UInt8]

    def __init__(out self, salt: String, key: String) raises:
        self._salt = _b(salt)
        self._key = _b(key)

    def salt(mut self) raises -> Array[UInt8, 16]:
        var out = Array[UInt8, 16](fill=UInt8(0))
        for i in range(16):
            out[i] = self._salt[i]
        return out^

    def sender_private_key(mut self) raises -> Array[UInt8, 32]:
        var out = Array[UInt8, 32](fill=UInt8(0))
        for i in range(32):
            out[i] = self._key[i]
        return out^


def test_public_keys_derive() raises:
    var as_private = _b(_AS_PRIVATE)
    var ua_private = _b(_UA_PRIVATE)
    var as_public = p256_public_key(Span[UInt8](as_private))
    var ua_public = p256_public_key(Span[UInt8](ua_private))
    assert_equal(hex_lower(Span[UInt8](as_public)), _hex(_AS_PUBLIC))
    assert_equal(hex_lower(Span[UInt8](ua_public)), _hex(_UA_PUBLIC))


def test_intermediate_values() raises:
    var as_private = _b(_AS_PRIVATE)
    var ua_public = _b(_UA_PUBLIC)
    var as_public = _b(_AS_PUBLIC)
    var auth = _b(_AUTH_SECRET)
    var salt = _b(_SALT)
    var ecdh = p256_ecdh(Span[UInt8](as_private), Span[UInt8](ua_public))
    assert_equal(hex_lower(Span[UInt8](ecdh)), _hex(_ECDH_SECRET), "ecdh_secret")
    var ikm = webpush_ikm(
        Span[UInt8](ecdh),
        Span[UInt8](auth),
        Span[UInt8](ua_public),
        Span[UInt8](as_public),
    )
    assert_equal(hex_lower(Span[UInt8](ikm)), _hex(_IKM), "IKM")
    var keys = aes128gcm_keys(Span[UInt8](ikm), Span[UInt8](salt))
    assert_equal(hex_lower(Span[UInt8](keys.cek)), _hex(_CEK), "CEK")
    assert_equal(hex_lower(Span[UInt8](keys.nonce)), _hex(_NONCE), "NONCE")


def test_encrypt_byte_exact() raises:
    var randomness = _FixedRandomness(_SALT, _AS_PRIVATE)
    var ua_public = _b(_UA_PUBLIC)
    var auth = _b(_AUTH_SECRET)
    var plaintext = _b(_PLAINTEXT)
    var body = webpush_encrypt_with(
        randomness,
        Span[UInt8](ua_public),
        Span[UInt8](auth),
        Span[UInt8](plaintext),
    )
    # The example body decodes to 144 bytes (header 86, record 41 + 1 + 16);
    # the Content-Length line printed above it in the RFC says 145.
    assert_equal(len(body), 144, "length of the example body")
    assert_equal(hex_lower(Span[UInt8](body)), _hex(_BODY), "body")


def test_user_agent_decrypts() raises:
    var ua_private = _b(_UA_PRIVATE)
    var ua_public = _b(_UA_PUBLIC)
    var auth = _b(_AUTH_SECRET)
    var body = _b(_BODY)
    var plaintext = webpush_decrypt(
        Span[UInt8](ua_private),
        Span[UInt8](ua_public),
        Span[UInt8](auth),
        Span[UInt8](body),
    )
    assert_equal(
        String(StringSlice(from_utf8=Span[UInt8](plaintext))),
        "When I grow up, I want to be a watermelon",
    )


def main() raises:
    test_public_keys_derive()
    print("PASS RFC 8291 section 5 public keys")
    test_intermediate_values()
    print("PASS RFC 8291 appendix A intermediate values")
    test_encrypt_byte_exact()
    print("PASS RFC 8291 section 5 body byte for byte")
    test_user_agent_decrypts()
    print("PASS RFC 8291 section 5 body decrypts")
