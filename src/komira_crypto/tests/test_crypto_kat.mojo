# =============================================================================
# komira_crypto/tests/test_crypto_kat.mojo — NIST/RFC Known-Answer Tests
# =============================================================================
#
# Validates `komira_crypto`'s request-signing primitives against
# checked-in published vectors:
# checked-in published vectors:
#   * SHA-256:   FIPS 180-4 / RFC 6234 KATs (empty string, "abc", "abcdbcde..."
#                + one large input).
#   * HMAC-SHA256: RFC 4231 §4.1-§4.5 test cases 1-5.
#   * base64:    RFC 4648 §10 test cases (standard + URL-safe).
#   * hex:       round-trip stability + the lowercase/uppercase contract.
#   * constant_time_eq_32: equality + inequality (no timing assertions —
#                we just confirm the bit-correctness of the OR-accumulator).
#   * RSA-SHA256: STUB raise — confirms the stub announces NotImplemented.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_crypto import (
    sha256,
    sha256_string,
    hmac_sha256,
    constant_time_eq_32,
    hex_lower,
    hex_lower_array_32,
    hex_upper,
    rsa_sha256_sign,
)
from komira_encoding import (
    base64_encode,
    base64_decode,
    base64_url_encode,
    base64_url_encode_nopad,
    base64_url_decode,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _rep(c: UInt8, n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(c)
    return out^


# -----------------------------------------------------------------------------
# SHA-256 KATs — FIPS 180-4 + RFC 6234
# -----------------------------------------------------------------------------


def test_sha256_empty() raises:
    """SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    — the well-known empty-input digest, used as SigV4's empty-payload hash."""
    var data = List[UInt8]()
    var digest = sha256(data)
    var got = hex_lower_array_32(digest)
    assert_equal(
        got,
        String(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        ),
    )


def test_sha256_abc() raises:
    """SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    — FIPS 180-4 Appendix A example."""
    var got = hex_lower_array_32(sha256_string(String("abc")))
    assert_equal(
        got,
        String(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        ),
    )


def test_sha256_long_message() raises:
    """SHA-256 over 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq' —
    FIPS 180-4 Appendix B example (multi-block, 56 bytes spanning block boundary)."""
    var got = hex_lower_array_32(
        sha256_string(
            String("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
        )
    )
    assert_equal(
        got,
        String(
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        ),
    )


def test_sha256_one_million_a() raises:
    """SHA-256 of one million repetitions of "a" — FIPS 180-4 NIST.
    Stresses the streaming-block padding under heavy input."""
    var data = _rep(UInt8(0x61), 1_000_000)
    var got = hex_lower_array_32(sha256(data))
    assert_equal(
        got,
        String(
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        ),
    )


# -----------------------------------------------------------------------------
# HMAC-SHA256 KATs — RFC 4231
# -----------------------------------------------------------------------------


def test_hmac_sha256_rfc4231_case1() raises:
    """RFC 4231 §4.2: key = 20 bytes of 0x0b, data = "Hi There".
    Expected: b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7."""
    var key = _rep(UInt8(0x0b), 20)
    var data = _bytes_of(String("Hi There"))
    var mac = hmac_sha256(key, data)
    assert_equal(
        hex_lower_array_32(mac),
        String(
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        ),
    )


def test_hmac_sha256_rfc4231_case2() raises:
    """RFC 4231 §4.3: key = "Jefe", data = "what do ya want for nothing?"."""
    var key = _bytes_of(String("Jefe"))
    var data = _bytes_of(String("what do ya want for nothing?"))
    var mac = hmac_sha256(key, data)
    assert_equal(
        hex_lower_array_32(mac),
        String(
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        ),
    )


def test_hmac_sha256_rfc4231_case3() raises:
    """RFC 4231 §4.4: key = 20 bytes 0xaa, data = 50 bytes 0xdd."""
    var key = _rep(UInt8(0xaa), 20)
    var data = _rep(UInt8(0xdd), 50)
    var mac = hmac_sha256(key, data)
    assert_equal(
        hex_lower_array_32(mac),
        String(
            "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"
        ),
    )


def test_hmac_sha256_rfc4231_case4() raises:
    """RFC 4231 §4.5: key = 0x0102030405...19 (25 bytes), data = 50 bytes 0xcd."""
    var key = List[UInt8]()
    for i in range(25):
        key.append(UInt8(i + 1))
    var data = _rep(UInt8(0xcd), 50)
    var mac = hmac_sha256(key, data)
    assert_equal(
        hex_lower_array_32(mac),
        String(
            "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"
        ),
    )


def test_hmac_sha256_rfc4231_case6_long_key() raises:
    """RFC 4231 §4.7: key = 131 bytes 0xaa (LONGER than block size, triggers
    the key-hash branch), data = "Test Using Larger Than Block-Size Key - Hash Key First"."""
    var key = _rep(UInt8(0xaa), 131)
    var data = _bytes_of(
        String("Test Using Larger Than Block-Size Key - Hash Key First")
    )
    var mac = hmac_sha256(key, data)
    assert_equal(
        hex_lower_array_32(mac),
        String(
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
        ),
    )


# -----------------------------------------------------------------------------
# constant_time_eq_32
# -----------------------------------------------------------------------------


def test_constant_time_eq_equal() raises:
    var a = Array[UInt8, 32](fill=0)
    var b = Array[UInt8, 32](fill=0)
    for i in range(32):
        a[i] = UInt8(i)
        b[i] = UInt8(i)
    assert_true(constant_time_eq_32(a, b))


def test_constant_time_eq_differ_first_byte() raises:
    var a = Array[UInt8, 32](fill=0)
    var b = Array[UInt8, 32](fill=0)
    for i in range(32):
        a[i] = UInt8(i)
        b[i] = UInt8(i)
    b[0] = UInt8(0xFF)
    assert_false(constant_time_eq_32(a, b))


def test_constant_time_eq_differ_last_byte() raises:
    var a = Array[UInt8, 32](fill=0)
    var b = Array[UInt8, 32](fill=0)
    for i in range(32):
        a[i] = UInt8(i)
        b[i] = UInt8(i)
    b[31] = UInt8(0xFF)
    assert_false(constant_time_eq_32(a, b))


# -----------------------------------------------------------------------------
# hex
# -----------------------------------------------------------------------------


def test_hex_lower_round() raises:
    var data = List[UInt8]()
    data.append(UInt8(0xDE))
    data.append(UInt8(0xAD))
    data.append(UInt8(0xBE))
    data.append(UInt8(0xEF))
    assert_equal(hex_lower(data), String("deadbeef"))


def test_hex_upper_round() raises:
    var data = List[UInt8]()
    data.append(UInt8(0xDE))
    data.append(UInt8(0xAD))
    data.append(UInt8(0xBE))
    data.append(UInt8(0xEF))
    assert_equal(hex_upper(data), String("DEADBEEF"))


def test_hex_lower_zero_byte() raises:
    var data = List[UInt8]()
    data.append(UInt8(0))
    data.append(UInt8(0x0F))
    data.append(UInt8(0xF0))
    assert_equal(hex_lower(data), String("000ff0"))


# -----------------------------------------------------------------------------
# base64 — RFC 4648 §10 test vectors
# -----------------------------------------------------------------------------


def test_base64_rfc4648_empty() raises:
    var data = List[UInt8]()
    assert_equal(base64_encode(data), String(""))


def test_base64_rfc4648_f() raises:
    var data = _bytes_of(String("f"))
    assert_equal(base64_encode(data), String("Zg=="))


def test_base64_rfc4648_fo() raises:
    assert_equal(base64_encode(_bytes_of(String("fo"))), String("Zm8="))


def test_base64_rfc4648_foo() raises:
    assert_equal(base64_encode(_bytes_of(String("foo"))), String("Zm9v"))


def test_base64_rfc4648_foob() raises:
    assert_equal(base64_encode(_bytes_of(String("foob"))), String("Zm9vYg=="))


def test_base64_rfc4648_fooba() raises:
    assert_equal(base64_encode(_bytes_of(String("fooba"))), String("Zm9vYmE="))


def test_base64_rfc4648_foobar() raises:
    assert_equal(
        base64_encode(_bytes_of(String("foobar"))), String("Zm9vYmFy")
    )


def test_base64_decode_round_trip() raises:
    var s = String("Hello, World!")
    var enc = base64_encode(_bytes_of(s))
    var dec = base64_decode(enc)
    var dec_str = String("")
    for i in range(len(dec)):
        dec_str += chr(Int(dec[i]))
    assert_equal(dec_str, s)


def test_base64_decode_padded() raises:
    var dec = base64_decode(String("Zm9vYmFy"))
    assert_equal(len(dec), 6)
    assert_equal(Int(dec[0]), 0x66)  # 'f'
    assert_equal(Int(dec[5]), 0x72)  # 'r'


def test_base64_decode_rejects_bad_char() raises:
    with assert_raises():
        var _r = base64_decode(String("Zm9*"))


def test_base64_decode_rejects_bad_length() raises:
    with assert_raises():
        var _r = base64_decode(String("Zm="))    # mod 4 == 3, only 1 pad — invalid


def test_base64_url_encode_uses_dash_underscore() raises:
    # Bytes that would produce '+' and '/' under standard alphabet:
    # 0xFB,0xFF -> "+/8="; under URL-safe alphabet -> "-_8=".
    var data = List[UInt8]()
    data.append(UInt8(0xFB))
    data.append(UInt8(0xFF))
    var std_enc = base64_encode(data)
    var url_enc = base64_url_encode(data)
    # Difference at the index where '+' / '/' would appear.
    var ok_std = std_enc.find("+") >= 0 or std_enc.find("/") >= 0
    var ok_url = url_enc.find("-") >= 0 or url_enc.find("_") >= 0
    assert_true(ok_std)
    assert_true(ok_url)


def test_base64url_nopad_jwt_shape() raises:
    """RFC 7515 §2: base64url-WITHOUT-padding is the canonical JWT shape."""
    var data = _bytes_of(String("foob"))
    var enc = base64_url_encode_nopad(data)
    # The padded form is "Zm9vYg==" -> nopad: "Zm9vYg"
    assert_equal(enc, String("Zm9vYg"))
    # Round-trip via the tolerant decoder.
    var dec = base64_url_decode(enc)
    assert_equal(len(dec), 4)


def test_base64_encode_no_heap_overflow_stress() raises:
    """REGRESSION: base64_encode must NOT overflow its
    output List[UInt8] by the AWS-LC EVP_EncodeBlock trailing-NUL byte.

    EVP_EncodeBlock writes `4*ceil(n/3)` base64 chars PLUS a trailing NUL
    (AWS-LC base64.h: "writes the result to |dst| with a trailing NUL").
    If the Mojo dst List is sized to the base64 length WITHOUT the +1 NUL
    slot, every encode overwrites 1 byte past the allocation — clobbering
    the adjacent allocator freelist node in that size class. The corruption
    is latent until a later same-size-class allocation pops the poisoned
    node, then crashes in `List[UInt8]::_realloc`.

    A SCRAM handshake is the canonical trigger: it base64-encodes the
    24-byte client nonce (-> 32 chars, the ~32B size class) and the 32-byte
    ClientProof (-> 44 chars), poisoning the small-String size classes that
    the next String builds then draw from.

    The test encodes many small buffers (filling the small size classes
    with would-be-clobbered nodes) and then allocates + grows many
    same-size-class buffers. Under the bug this corrupts the freelist and
    crashes; after the +1 NUL-slot fix it is clean. Output correctness is
    also asserted (the encoded length must NOT include the NUL).
    """
    # Encode many small buffers across the size classes the SCRAM handshake
    # touches (3..48 raw bytes -> 4..64 base64 chars). Each encode that
    # overflows poisons one freelist node in its size class.
    for _round in range(64):
        for n in range(3, 49):
            var raw = List[UInt8]()
            for i in range(n):
                raw.append(UInt8((i * 7 + n) & 0xFF))
            var enc = base64_encode(raw)
            # The encoded length is 4*ceil(n/3) — NO trailing NUL in the
            # String (the NUL slot is internal scratch, never surfaced).
            assert_equal(len(enc.as_bytes()), 4 * ((n + 2) // 3))

    # Now hammer the same small size classes with fresh allocations + grows.
    # If a freelist node was clobbered above, one of these pops it -> SIGBUS.
    for _round in range(256):
        var probe = List[UInt8]()
        for k in range(48):
            probe.append(UInt8(k))
        var s = String("")
        for k in range(40):
            s += chr(ord("a") + (k % 26))
        # Touch both so neither is optimized away.
        assert_true(len(probe) == 48 and len(s.as_bytes()) == 40)


# -----------------------------------------------------------------------------
# rsa_sha256_sign — STUB raise contract
# -----------------------------------------------------------------------------


def test_rsa_sha256_sign_stub_raises() raises:
    """rsa_sha256_sign MUST raise on an empty (unparseable) PKCS#8 key."""
    var key = List[UInt8]()
    var msg = List[UInt8]()
    with assert_raises():
        var _r = rsa_sha256_sign(key, msg)


# -----------------------------------------------------------------------------
# main — invoke every test
# -----------------------------------------------------------------------------


def main() raises:
    # SHA-256 KATs
    test_sha256_empty()
    test_sha256_abc()
    test_sha256_long_message()
    test_sha256_one_million_a()
    # HMAC-SHA256 KATs
    test_hmac_sha256_rfc4231_case1()
    test_hmac_sha256_rfc4231_case2()
    test_hmac_sha256_rfc4231_case3()
    test_hmac_sha256_rfc4231_case4()
    test_hmac_sha256_rfc4231_case6_long_key()
    # constant_time_eq
    test_constant_time_eq_equal()
    test_constant_time_eq_differ_first_byte()
    test_constant_time_eq_differ_last_byte()
    # hex
    test_hex_lower_round()
    test_hex_upper_round()
    test_hex_lower_zero_byte()
    # base64
    test_base64_rfc4648_empty()
    test_base64_rfc4648_f()
    test_base64_rfc4648_fo()
    test_base64_rfc4648_foo()
    test_base64_rfc4648_foob()
    test_base64_rfc4648_fooba()
    test_base64_rfc4648_foobar()
    test_base64_decode_round_trip()
    test_base64_decode_padded()
    test_base64_decode_rejects_bad_char()
    test_base64_decode_rejects_bad_length()
    test_base64_url_encode_uses_dash_underscore()
    test_base64url_nopad_jwt_shape()
    test_base64_encode_no_heap_overflow_stress()
    # RSA stub
    test_rsa_sha256_sign_stub_raises()
    print("OK")
