# =============================================================================
# komira_crypto/tests/test_rsa_pss_verify.mojo
# =============================================================================
#
# End-to-end RSA-PSS-SHA-256 verify tests (the body delegates to AWS-LC
# RSA_verify_pss_mgf1 via `komira_crypto.internal.asm.rsa_ffi`).
#
# Sub-tests (4):
#   1. Valid RSA-PSS-SHA-256 signature over fixed message -> True.
#   2. Modified message -> False.
#   3. Modified signature byte -> False.
#   4. Truncated signature (length mismatch) -> False.
#
# MGF1 and the bignum arithmetic run inside AWS-LC's RSA_verify_pss_mgf1,
# so the 4 PSS-KAT sub-tests below cover the public API end-to-end via the
# FFI delegation path.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.hash import Sha256
from komira_crypto.rsa_pss import (
    RsaPublicKey,
    rsa_public_key_from_bytes,
    rsa_pss_verify,
)


# -----------------------------------------------------------------------------
# Hex helpers
# -----------------------------------------------------------------------------


def _hex_nibble(c: UInt8) -> UInt8:
    if c >= UInt8(0x30) and c <= UInt8(0x39):
        return c - UInt8(0x30)
    if c >= UInt8(0x61) and c <= UInt8(0x66):
        return c - UInt8(0x61) + UInt8(10)
    if c >= UInt8(0x41) and c <= UInt8(0x46):
        return c - UInt8(0x41) + UInt8(10)
    return UInt8(0xFF)


def _hex_decode_inline256(s: String) -> Array[UInt8, 256]:
    """Decode a 512-char hex string to 256 bytes."""
    var bs = s.as_bytes()
    var out = Array[UInt8, 256](fill=UInt8(0))
    for i in range(256):
        var hi = _hex_nibble(bs[2 * i])
        var lo = _hex_nibble(bs[2 * i + 1])
        out[i] = (hi << UInt8(4)) | lo
    return out^


# -----------------------------------------------------------------------------
# RSA-PSS-SHA-256 KAT — 2048-bit modulus
#
# The (n, e, message, signature, salt_length=32) tuple below was generated
# once with Python's `cryptography` library, which produced the signature;
# the test below verifies that our FFI-backed `rsa_pss_verify` accepts it.
# The message is part of the signed vector and cannot change without a
# re-signing key.
# -----------------------------------------------------------------------------


def _kat_modulus_n_hex() -> String:
    return String(
        "bfe23c2961dd4fd42c853b002f79a23e6784799715091107ddd537fa9bc66938"
        + "cdcd85dac0b109196e916ae8da4e412eea0f1f48518e50dc0f62664110d77c69"
        + "e3d56c30d514a45f6855b4ca48a65532e8975412b9f751d1a520c114bc6496ec"
        + "a95d3f08103ae5962b08f4136b81953b73c31acea2f6191991793428327dfc6a"
        + "12b17375dba312a9f15055ad2b692540624df655e0a29b7b070bad51c2e22cb4"
        + "739111ee7ad586e8382b8d2b904671e2653e80b9d6af69298451d802db289dc8"
        + "886982f2676daa10de66dcdf99fe4ee28808da69b0459a7d35c93424dcb25772"
        + "f62ce460fafd2e8aad24ce79cfe99181e08123ebd069ddf39ee98abc3df2af5d"
    )


def _kat_message_str() -> String:
    return String("Hello, RSA-PSS verify -- 2048-bit SHA-256 test vector.")


def _kat_sig_hex() -> String:
    return String(
        "a1f1217deaf6b8e91aa2446aac33d057c63c36a28123d101731bc48f691c67dd"
        + "56e404662597eee7ce460ef0bb63343cb8e446231edf37358f994e338351bf1d"
        + "b0ba8b1fe64385613e426a365b5a251553a1b95261d13d34e312b8c6960012e5"
        + "c0e9c477904410fd4807813af8c70220cf539cad8b2a5b8b2684a0cedbc94070"
        + "d83c8856abf9d132459584a4a72f56652bc511732dbd7ee22f61930b99110881"
        + "6805313e2f6d23a02b3ca313b1adaff2ddc0f6e547f77b676fcb9269a06d80cd"
        + "5019c0bab38a77abdf2ed14cc2f6e73bdc2c6db8348b4ee59b3914ce1d9a2fb1"
        + "3d8f4f3e1d5a4ddc94c629ae34b5c974f04903bfd7e9fad0065d1cb9f0f897dc"
    )


def test_rsa_pss_2048_sha256_valid() raises:
    """Valid RSA-PSS-SHA-256 signature -> verify True."""
    var n_bytes = _hex_decode_inline256(_kat_modulus_n_hex())
    var pk = rsa_public_key_from_bytes[32](
        Span[UInt8, origin_of(n_bytes)](n_bytes), UInt64(65537)
    )
    assert_equal(pk.bit_len, 2048)

    var sig_bytes = _hex_decode_inline256(_kat_sig_hex())
    var msg_str = _kat_message_str()
    var msg = msg_str.as_bytes()

    var ok = rsa_pss_verify[32, Sha256](
        pk,
        msg,
        Span[UInt8, origin_of(sig_bytes)](sig_bytes),
        32,  # salt_length
    )
    assert_true(ok, "valid PSS-SHA-256 signature should verify")


def test_rsa_pss_2048_sha256_modified_message() raises:
    """Modified message -> verify False."""
    var n_bytes = _hex_decode_inline256(_kat_modulus_n_hex())
    var pk = rsa_public_key_from_bytes[32](
        Span[UInt8, origin_of(n_bytes)](n_bytes), UInt64(65537)
    )
    var sig_bytes = _hex_decode_inline256(_kat_sig_hex())
    var bad_msg = String("DIFFERENT MESSAGE")
    var ok = rsa_pss_verify[32, Sha256](
        pk,
        bad_msg.as_bytes(),
        Span[UInt8, origin_of(sig_bytes)](sig_bytes),
        32,
    )
    assert_false(ok, "modified message MUST NOT verify")


def test_rsa_pss_2048_sha256_modified_signature() raises:
    """Single-bit signature modification -> verify False."""
    var n_bytes = _hex_decode_inline256(_kat_modulus_n_hex())
    var pk = rsa_public_key_from_bytes[32](
        Span[UInt8, origin_of(n_bytes)](n_bytes), UInt64(65537)
    )
    var sig_bytes = _hex_decode_inline256(_kat_sig_hex())
    # Flip one bit of the signature.
    sig_bytes[100] = sig_bytes[100] ^ UInt8(0x01)
    var msg_str = _kat_message_str()
    var ok = rsa_pss_verify[32, Sha256](
        pk,
        msg_str.as_bytes(),
        Span[UInt8, origin_of(sig_bytes)](sig_bytes),
        32,
    )
    assert_false(ok, "modified signature MUST NOT verify")


def test_rsa_pss_2048_sha256_wrong_length_sig() raises:
    """Signature with wrong length (255 instead of 256) -> verify False."""
    var n_bytes = _hex_decode_inline256(_kat_modulus_n_hex())
    var pk = rsa_public_key_from_bytes[32](
        Span[UInt8, origin_of(n_bytes)](n_bytes), UInt64(65537)
    )
    var sig_bytes = _hex_decode_inline256(_kat_sig_hex())
    var truncated = Span[UInt8, origin_of(sig_bytes)](sig_bytes)[0:255]
    var msg_str = _kat_message_str()
    var ok = rsa_pss_verify[32, Sha256](pk, msg_str.as_bytes(), truncated, 32)
    assert_false(ok, "wrong-length signature MUST NOT verify")


def main() raises:
    test_rsa_pss_2048_sha256_valid()
    test_rsa_pss_2048_sha256_modified_message()
    test_rsa_pss_2048_sha256_modified_signature()
    test_rsa_pss_2048_sha256_wrong_length_sig()
    print("OK")
