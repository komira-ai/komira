# =============================================================================
# komira_webpush/tests/test_refusals.mojo
# =============================================================================
#
# Every malformed input is refused with its exact message.
#
#   aes128gcm_decrypt: a body shorter than the header, rs below 18, a keyid
#     running past the body, a header with no record, a record shorter than
#     17 bytes, a flipped ciphertext bit, the wrong IKM, a record of only
#     zero bytes, delimiter 1 in the last record (the RFC 8188 3.2 body cut
#     after its first record: a truncation), delimiter 2 before the last
#     record, and a delimiter of 3.
#   aes128gcm_encrypt: a 15-byte salt, a 256-byte keyid, rs 17 and 2^32,
#     a plaintext one byte over one record.
#   webpush_encrypt: 3994 bytes of plaintext, a 15-byte auth secret, a
#     64-byte and an off-curve user agent key, and a sender key source that
#     returns the group order n.
#   webpush_decrypt: a 64-byte keyid, two records, a public key that is not
#     the private key's, an off-curve keyid, the wrong auth secret.
#   p256_public_key: zero, n and a 31-byte key; n - 1 is accepted.
# =============================================================================

from std.testing import assert_equal

from komira_crypto import AesGcm128, hex_lower
from komira_encoding import base64_url_decode_nopad
from komira_webpush import (
    WebPushRandomness,
    aes128gcm_decrypt,
    aes128gcm_encrypt,
    aes128gcm_keys,
    p256_public_key,
    webpush_decrypt,
    webpush_encrypt,
    webpush_encrypt_with,
)


comptime _UA_PUBLIC = (
    "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcx"
    "aOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
)
comptime _UA_PRIVATE = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
comptime _AUTH_SECRET = "BTBZMqHH6r4Tts7J_aSIgg"
comptime _IKM_1 = "yqdlZ-tYemfogSmv7Ws5PQ"
comptime _BODY_1 = (
    "I1BsxtFttlv3u_Oo94xnmwAAEAAA-NAVub2qFgBEuQKRapoZu-IxkIva3MEB1PD-"
    "ly8Thjg"
)
comptime _IKM_2 = "BO3ZVPxUlnLORbVGMpbT1Q"
comptime _BODY_2 = (
    "uNCkWiNYzKTnBN9ji3-qWAAAABkCYTHOG8chz_gnvgOqdGYovxyjuqRyJFjEDyoF"
    "1Fvkj6hQPdPHI51OEUKEpgz3SsLWIqS_uA"
)
comptime _N_HEX = (
    "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"
)
comptime _N_MINUS_1_HEX = (
    "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550"
)


def _b(s: String) raises -> List[UInt8]:
    return base64_url_decode_nopad(s)


def _nibble(c: UInt8) raises -> UInt8:
    if c >= UInt8(0x30) and c <= UInt8(0x39):
        return c - UInt8(0x30)
    if c >= UInt8(0x61) and c <= UInt8(0x66):
        return c - UInt8(0x61) + UInt8(10)
    raise Error("bad hex digit in a test input")


def _hex(s: String) raises -> List[UInt8]:
    var bs = s.as_bytes()
    var out = List[UInt8](capacity=len(bs) // 2)
    for i in range(len(bs) // 2):
        out.append((_nibble(bs[2 * i]) << UInt8(4)) | _nibble(bs[2 * i + 1]))
    return out^


def _filled(n: Int, v: UInt8) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(v)
    return out^


def _header(salt_byte: UInt8, rs: Int, keyid: List[UInt8]) -> List[UInt8]:
    var out = _filled(16, salt_byte)
    out.append(UInt8((rs >> 24) & 0xFF))
    out.append(UInt8((rs >> 16) & 0xFF))
    out.append(UInt8((rs >> 8) & 0xFF))
    out.append(UInt8(rs & 0xFF))
    out.append(UInt8(len(keyid)))
    for i in range(len(keyid)):
        out.append(keyid[i])
    return out^


def _sealed(ikm: List[UInt8], var body: List[UInt8], seq: Int, record: List[UInt8]) raises -> List[UInt8]:
    """Appends `record` (data, delimiter and padding, as given) to `body`
    sealed as record `seq`, with the key and nonce of `body`'s salt."""
    var salt = List[UInt8](capacity=16)
    for i in range(16):
        salt.append(body[i])
    var keys = aes128gcm_keys(Span[UInt8](ikm), Span[UInt8](salt))
    var nonce = keys.nonce.copy()
    nonce[11] = nonce[11] ^ UInt8(seq)
    var buf = record.copy()
    for _ in range(16):
        buf.append(UInt8(0))
    var cipher = AesGcm128(keys.cek.copy())
    var empty = List[UInt8]()
    cipher.seal_in_place(nonce, Span[UInt8](empty), Span[UInt8](buf))
    for i in range(len(buf)):
        body.append(buf[i])
    return body^


def _decrypt_outcome(ikm: List[UInt8], body: List[UInt8]) -> String:
    try:
        var out = aes128gcm_decrypt(Span[UInt8](ikm), Span[UInt8](body))
        return String("OK ") + hex_lower(Span[UInt8](out))
    except e:
        return String(e)


def test_content_coding_decrypt_refusals() raises:
    var ikm = _b(_IKM_1)
    var none = List[UInt8]()
    assert_equal(
        _decrypt_outcome(ikm, _filled(20, 0)),
        "aes128gcm: body of 20 bytes is shorter than the 21-byte header",
    )
    assert_equal(
        _decrypt_outcome(ikm, _header(1, 17, none)),
        "aes128gcm: rs must be at least 18, got 17",
    )
    var five_id = _header(1, 4096, _filled(5, 0x61))
    var cut_id = List[UInt8]()
    for i in range(23):
        cut_id.append(five_id[i])
    assert_equal(
        _decrypt_outcome(ikm, cut_id),
        "aes128gcm: body of 23 bytes is shorter than its header with a"
        " 5-byte keyid",
    )
    assert_equal(
        _decrypt_outcome(ikm, _header(1, 4096, none)),
        "aes128gcm: body holds no record",
    )
    var short = _header(1, 4096, none)
    for _ in range(16):
        short.append(UInt8(0))
    assert_equal(
        _decrypt_outcome(ikm, short),
        "aes128gcm: record 0 is 16 bytes, shorter than 17",
    )
    var flipped = _b(_BODY_1)
    flipped[30] = flipped[30] ^ UInt8(0x01)
    assert_equal(
        _decrypt_outcome(ikm, flipped),
        "aes128gcm: record 0 failed authentication",
    )
    assert_equal(
        _decrypt_outcome(_b(_IKM_2), _b(_BODY_1)),
        "aes128gcm: record 0 failed authentication",
    )


def test_content_coding_delimiter_refusals() raises:
    var ikm = _b(_IKM_1)
    var none = List[UInt8]()
    var zeros = _sealed(ikm, _header(7, 4096, none), 0, _filled(5, 0))
    assert_equal(
        _decrypt_outcome(ikm, zeros),
        "aes128gcm: record 0 has no padding delimiter",
    )
    var three = _filled(4, 0x41)
    three.append(UInt8(3))
    var bad = _sealed(ikm, _header(7, 4096, none), 0, three)
    assert_equal(
        _decrypt_outcome(ikm, bad),
        "aes128gcm: last record 0 has delimiter 3, want 2",
    )
    # The RFC 8188 3.2 body cut after its first record (23 + 25 bytes).
    var full = _b(_BODY_2)
    var cut = List[UInt8]()
    for i in range(48):
        cut.append(full[i])
    assert_equal(
        _decrypt_outcome(_b(_IKM_2), cut),
        "aes128gcm: last record 0 has delimiter 1, want 2",
    )
    # rs 20: each record holds 4 bytes of data, delimiter and padding.
    var first = _filled(3, 0x41)
    first.append(UInt8(2))
    var second = _filled(3, 0x42)
    second.append(UInt8(2))
    var early = _sealed(ikm, _header(7, 20, none), 0, first)
    early = _sealed(ikm, early^, 1, second)
    assert_equal(
        _decrypt_outcome(ikm, early),
        "aes128gcm: record 0 has delimiter 2, want 1 (not the last record)",
    )
    first[3] = UInt8(1)
    var good = _sealed(ikm, _header(7, 20, none), 0, first)
    good = _sealed(ikm, good^, 1, second)
    assert_equal(_decrypt_outcome(ikm, good), "OK 414141424242")


def _encrypt_outcome(
    salt: List[UInt8], keyid: List[UInt8], rs: Int, plaintext: List[UInt8]
) -> String:
    try:
        var ikm = _b(_IKM_1)
        var out = aes128gcm_encrypt(
            Span[UInt8](ikm),
            Span[UInt8](salt),
            Span[UInt8](keyid),
            rs,
            Span[UInt8](plaintext),
        )
        return String("OK ") + String(len(out))
    except e:
        return String(e)


def test_content_coding_encrypt_refusals() raises:
    var salt = _filled(16, 9)
    var none = List[UInt8]()
    var one = _filled(1, 0x41)
    assert_equal(
        _encrypt_outcome(_filled(15, 9), none, 4096, one),
        "aes128gcm: salt must be 16 bytes, got 15",
    )
    assert_equal(
        _encrypt_outcome(salt, _filled(256, 0x61), 4096, one),
        "aes128gcm: keyid must be at most 255 bytes, got 256",
    )
    assert_equal(
        _encrypt_outcome(salt, none, 17, one),
        "aes128gcm: rs must be at least 18, got 17",
    )
    assert_equal(
        _encrypt_outcome(salt, none, 4294967296, one),
        "aes128gcm: rs must fit 32 bits, got 4294967296",
    )
    assert_equal(
        _encrypt_outcome(salt, none, 18, _filled(2, 0x41)),
        "aes128gcm: plaintext of 2 bytes does not fit one record of rs 18"
        " (at most 1)",
    )
    assert_equal(_encrypt_outcome(salt, none, 18, one), "OK 39")


def _webpush_outcome(
    ua_public: List[UInt8], auth: List[UInt8], plaintext: List[UInt8]
) -> String:
    try:
        var out = webpush_encrypt(
            Span[UInt8](ua_public), Span[UInt8](auth), Span[UInt8](plaintext)
        )
        return String("OK ") + String(len(out))
    except e:
        return String(e)


struct _OrderKey(WebPushRandomness):
    """Returns the group order n as the sender key."""

    def __init__(out self):
        pass

    def salt(mut self) raises -> Array[UInt8, 16]:
        return Array[UInt8, 16](fill=UInt8(5))

    def sender_private_key(mut self) raises -> Array[UInt8, 32]:
        var n = _hex(_N_HEX)
        var out = Array[UInt8, 32](fill=UInt8(0))
        for i in range(32):
            out[i] = n[i]
        return out^


def test_webpush_encrypt_refusals() raises:
    var ua = _b(_UA_PUBLIC)
    var auth = _b(_AUTH_SECRET)
    var one = _filled(1, 0x41)
    assert_equal(
        _webpush_outcome(ua, auth, _filled(3994, 0x41)),
        "webpush: plaintext is 3994 bytes, more than the 3993 a push message"
        " holds",
    )
    assert_equal(
        _webpush_outcome(ua, _filled(15, 1), one),
        "webpush: auth secret must be 16 bytes, got 15",
    )
    var bare = List[UInt8]()
    for i in range(1, 65):
        bare.append(ua[i])
    assert_equal(
        _webpush_outcome(bare, auth, one),
        "p256_ecdh: peer public key must be 65 bytes, got 64",
    )
    var off_curve = ua.copy()
    off_curve[64] = off_curve[64] ^ UInt8(0x01)
    assert_equal(
        _webpush_outcome(off_curve, auth, one),
        "p256_ecdh: peer public key is not a point on P-256",
    )
    var order = _OrderKey()
    var outcome: String
    try:
        _ = webpush_encrypt_with(
            order, Span[UInt8](ua), Span[UInt8](auth), Span[UInt8](one)
        )
        outcome = "OK"
    except e:
        outcome = String(e)
    assert_equal(outcome, "webpush: private key is not in [1, n-1]")


def _ua_outcome(
    ua_public: List[UInt8], auth: List[UInt8], body: List[UInt8]
) -> String:
    try:
        var ua_private = _b(_UA_PRIVATE)
        var out = webpush_decrypt(
            Span[UInt8](ua_private),
            Span[UInt8](ua_public),
            Span[UInt8](auth),
            Span[UInt8](body),
        )
        return String("OK ") + hex_lower(Span[UInt8](out))
    except e:
        return String(e)


def test_webpush_decrypt_refusals() raises:
    var ua = _b(_UA_PUBLIC)
    var auth = _b(_AUTH_SECRET)
    var one = _filled(1, 0x41)
    var body = webpush_encrypt(Span[UInt8](ua), Span[UInt8](auth), Span[UInt8](one))
    assert_equal(_ua_outcome(ua, auth, body), "OK 41")

    var ikm = _b(_IKM_1)
    var record = _filled(1, 0x41)
    record.append(UInt8(2))
    var short_id = _sealed(ikm, _header(3, 4096, _filled(64, 4)), 0, record)
    assert_equal(
        _ua_outcome(ua, auth, short_id),
        "webpush: keyid must be the 65-byte sender public key, got 64 bytes",
    )
    var keyid = List[UInt8]()
    for i in range(21, 86):
        keyid.append(body[i])
    var two = _sealed(ikm, _header(3, 18, keyid), 0, record)
    two = _sealed(ikm, two^, 1, record)
    assert_equal(_ua_outcome(ua, auth, two), "webpush: body holds more than one record")

    var n_minus_1 = _hex(_N_MINUS_1_HEX)
    var other = p256_public_key(Span[UInt8](n_minus_1))
    var other_list = List[UInt8]()
    for i in range(65):
        other_list.append(other[i])
    assert_equal(
        _ua_outcome(other_list, auth, body),
        "webpush: user agent public key is not the key of the private key",
    )
    var bad_point = body.copy()
    bad_point[85] = bad_point[85] ^ UInt8(0x01)
    assert_equal(
        _ua_outcome(ua, auth, bad_point),
        "p256_ecdh: peer public key is not a point on P-256",
    )
    var wrong_auth = auth.copy()
    wrong_auth[0] = wrong_auth[0] ^ UInt8(0x01)
    assert_equal(
        _ua_outcome(ua, wrong_auth, body),
        "aes128gcm: record 0 failed authentication",
    )


def _pub_outcome(key: List[UInt8]) -> String:
    try:
        var p = p256_public_key(Span[UInt8](key))
        return String("OK ") + hex_lower(Span[UInt8](p))
    except e:
        return String(e)


def test_p256_public_key_refusals() raises:
    assert_equal(
        _pub_outcome(_filled(32, 0)), "webpush: private key is not in [1, n-1]"
    )
    assert_equal(
        _pub_outcome(_hex(_N_HEX)), "webpush: private key is not in [1, n-1]"
    )
    assert_equal(
        _pub_outcome(_filled(31, 1)),
        "webpush: private key must be 32 bytes, got 31",
    )
    # n - 1 is -1: its point is -G = (Gx, p - Gy).
    assert_equal(
        _pub_outcome(_hex(_N_MINUS_1_HEX)),
        "OK 04"
        + "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
        + "b01cbd1c01e58065711814b583f061e9d431cca994cea1313449bf97c840ae0a",
    )


def main() raises:
    test_content_coding_decrypt_refusals()
    print("PASS aes128gcm_decrypt refusals")
    test_content_coding_delimiter_refusals()
    print("PASS aes128gcm_decrypt delimiter refusals")
    test_content_coding_encrypt_refusals()
    print("PASS aes128gcm_encrypt refusals")
    test_webpush_encrypt_refusals()
    print("PASS webpush_encrypt refusals")
    test_webpush_decrypt_refusals()
    print("PASS webpush_decrypt refusals")
    test_p256_public_key_refusals()
    print("PASS p256_public_key refusals")
