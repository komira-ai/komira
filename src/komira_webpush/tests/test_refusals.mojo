# =============================================================================
# komira_webpush/tests/test_refusals.mojo
# =============================================================================
#
# Each malformed input listed below is refused with its exact message, and
# the accepting side of each numeric limit listed is pinned.
#
#   aes128gcm_decrypt: a body shorter than the header, rs below 18, a keyid
#     running past the body, a header with no record, a record shorter than
#     17 bytes, a flipped ciphertext bit, the wrong IKM, a record of only
#     zero bytes, delimiter 1 in the last record (the RFC 8188 3.2 body cut
#     after its first record: a truncation), delimiter 2 before the last
#     record, and a delimiter of 3; accepted: 257 records at rs 18 (record
#     256 needs the second sequence-number byte in its nonce).
#   aes128gcm_encrypt: a 15-byte salt, a 256-byte keyid, rs 17 and 2^32,
#     a plaintext one byte over one record; accepted: rs 18, and rs
#     2^32 - 1, a 255-byte keyid and rs 0x01020304 with a 200-byte keyid,
#     each checked on the header bytes written, the header read back by
#     aes128gcm_parse_header and the decryption.
#   aes128gcm_parse_header: rs 2^32 - 1 and rs 0x01020304 with a 130-byte
#     keyid (idlen above 127) in bodies the test writes itself.
#   webpush_encrypt: 3994 bytes of plaintext, a 15-byte auth secret, a
#     64-byte and an off-curve user agent key, and a sender key source that
#     returns the group order n.
#   webpush_decrypt: a 64-byte keyid, two records, public keys that are
#     not the private key's (-G; -P, the same x with y negated; the RFC
#     key with one byte flipped at each of the 65 positions, the 0x04
#     prefix included), an off-curve keyid, the wrong auth secret, a
#     64-byte user agent key, a 15-byte auth secret.
#   webpush_ikm: a 15-byte auth secret, a 64-byte user agent key, a 64-byte
#     application server key.
#   p256_public_key: zero, n and a 31-byte key; 1 (point G) and n - 1
#     (point -G) are accepted.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import AesGcm128, hex_lower
from komira_encoding import base64_url_decode_nopad
from komira_webpush import (
    WebPushRandomness,
    aes128gcm_decrypt,
    aes128gcm_encrypt,
    aes128gcm_keys,
    aes128gcm_parse_header,
    p256_public_key,
    webpush_decrypt,
    webpush_encrypt,
    webpush_encrypt_with,
    webpush_ikm,
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


def _n_minus(k: List[UInt8]) raises -> List[UInt8]:
    """Returns n - k for a 32-byte big-endian k in [1, n - 1].

    n is the P-256 group order; byte-wise subtraction with borrow.
    """
    var n = _hex(_N_MINUS_1_HEX)
    n[31] = n[31] + UInt8(1)  # n - 1 ends in 0x50: no carry
    var out = List[UInt8](length=32, fill=0)
    var borrow = 0
    for i in range(31, -1, -1):
        var d = Int(n[i]) - Int(k[i]) - borrow
        borrow = 0
        if d < 0:
            d += 256
            borrow = 1
        out[i] = UInt8(d)
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
    # RFC 8188 2.3: the 96-bit nonce is the base nonce XOR the sequence
    # number as a 96-bit big-endian integer (its top 4 bytes are zero here).
    for i in range(8):
        var shift = 8 * (7 - i)
        nonce[4 + i] = nonce[4 + i] ^ UInt8((seq >> shift) & 0xFF)
    var buf = record.copy()
    for _ in range(16):
        buf.append(UInt8(0))
    var cipher = AesGcm128(keys.cek)
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


def test_content_coding_257_records() raises:
    """rs 18: 257 records of one data byte and a delimiter each. Record 256
    is the first whose sequence number has a bit above the low byte, so a
    nonce that XORs only the low byte reuses record 0's nonce there and
    fails authentication."""
    var ikm = _b(_IKM_1)
    var none = List[UInt8]()
    var body = _header(7, 18, none)
    var data = List[UInt8]()
    for seq in range(257):
        var v = UInt8(seq & 0xFF)
        var record = List[UInt8]()
        record.append(v)
        record.append(UInt8(1) if seq < 256 else UInt8(2))
        body = _sealed(ikm, body^, seq, record)
        data.append(v)
    assert_equal(len(body), 21 + 257 * 18)
    assert_equal(
        _decrypt_outcome(ikm, body),
        String("OK ") + hex_lower(Span[UInt8](data)),
    )


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


def _distinct(n: Int) -> List[UInt8]:
    """n bytes counting up from 0x80 (0xff is followed by 0x00)."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8((0x80 + i) & 0xFF))
    return out^


def _encrypt_round_trip(
    keyid: List[UInt8], rs: Int, plaintext: List[UInt8]
) -> String:
    """Encrypts, then reports the header bytes rs and idlen as written, the
    rs and keyid `aes128gcm_parse_header` reads back, and the decryption."""
    try:
        var ikm = _b(_IKM_1)
        var salt = _filled(16, 9)
        var out = aes128gcm_encrypt(
            Span[UInt8](ikm),
            Span[UInt8](salt),
            Span[UInt8](keyid),
            rs,
            Span[UInt8](plaintext),
        )
        var raw = List[UInt8]()
        for i in range(16, 21):
            raw.append(out[i])
        var h = aes128gcm_parse_header(Span[UInt8](out))
        var same = len(h.keyid) == len(keyid)
        if same:
            for i in range(len(keyid)):
                if h.keyid[i] != keyid[i]:
                    same = False
        var data = aes128gcm_decrypt(Span[UInt8](ikm), Span[UInt8](out))
        return (
            String("OK len ")
            + String(len(out))
            + " rs|idlen "
            + hex_lower(Span[UInt8](raw))
            + " rs "
            + String(h.rs)
            + " keyid "
            + String(len(h.keyid))
            + (" same" if same else " differs")
            + " data "
            + hex_lower(Span[UInt8](data))
        )
    except e:
        return String(e)


def test_content_coding_encrypt_limits_accepted() raises:
    """The accepting side of each encrypt limit, checked on the header bytes
    written, on the header read back and on the decryption (not only on
    the output length). 21-byte header + keyid + 1 data byte + delimiter +
    16-byte tag."""
    var none = List[UInt8]()
    var one = _filled(1, 0x41)
    # rs 2^32 - 1: all four rs bytes are 0xff.
    assert_equal(
        _encrypt_round_trip(none, 4294967295, one),
        "OK len 39 rs|idlen ffffffff00 rs 4294967295 keyid 0 same data 41",
    )
    # A 255-byte keyid: idlen 0xff, the top bit set.
    assert_equal(
        _encrypt_round_trip(_distinct(255), 4096, one),
        "OK len 294 rs|idlen 00001000ff rs 4096 keyid 255 same data 41",
    )
    # rs 0x01020304: each rs byte differs, so a swapped or dropped shift
    # changes the header; a 200-byte keyid (idlen 0xc8).
    assert_equal(
        _encrypt_round_trip(_distinct(200), 0x01020304, one),
        "OK len 239 rs|idlen 01020304c8 rs 16909060 keyid 200 same data 41",
    )


def _parsed(body: List[UInt8]) -> String:
    """`aes128gcm_parse_header`'s rs, keyid and records offset, then the
    decryption with _IKM_1."""
    try:
        var h = aes128gcm_parse_header(Span[UInt8](body))
        var ikm = _b(_IKM_1)
        var data = aes128gcm_decrypt(Span[UInt8](ikm), Span[UInt8](body))
        return (
            String("rs ")
            + String(h.rs)
            + " keyid "
            + hex_lower(Span[UInt8](h.keyid))
            + " offset "
            + String(h.records_offset)
            + " data "
            + hex_lower(Span[UInt8](data))
        )
    except e:
        return String(e)


def test_content_coding_parse_wide_fields() raises:
    """Bodies the test writes itself (`_header`, `_sealed`) with an rs above
    2^24 and an idlen above 127: the parser reads all four rs bytes and
    the whole idlen byte."""
    var ikm = _b(_IKM_1)
    var record = _filled(1, 0x41)
    record.append(UInt8(2))
    var none = List[UInt8]()
    var top = _sealed(ikm, _header(7, 4294967295, none), 0, record)
    assert_equal(_parsed(top), "rs 4294967295 keyid  offset 21 data 41")
    var wide = _sealed(ikm, _header(7, 0x01020304, _distinct(130)), 0, record)
    assert_equal(
        _parsed(wide),
        "rs 16909060 keyid "
        + hex_lower(Span[UInt8](_distinct(130)))
        + " offset 151 data 41",
    )


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


struct _FailingSalt(WebPushRandomness):
    """A valid sender key (1) and a salt source that raises: the error
    must reach the caller of `webpush_encrypt_with` unchanged."""

    def __init__(out self):
        pass

    def salt(mut self) raises -> Array[UInt8, 16]:
        raise Error("test: salt source failed")

    def sender_private_key(mut self) raises -> Array[UInt8, 32]:
        var out = Array[UInt8, 32](fill=UInt8(0))
        out[31] = UInt8(1)
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
    # A salt-source error is raised after the IKM is derived, through the
    # arm that wipes the IKM; it must not turn into an empty body.
    var failing = _FailingSalt()
    var salt_outcome: String
    try:
        var body = webpush_encrypt_with(
            failing, Span[UInt8](ua), Span[UInt8](auth), Span[UInt8](one)
        )
        salt_outcome = "OK " + String(len(body))
    except e:
        salt_outcome = String(e)
    assert_equal(salt_outcome, "test: salt source failed")


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
    # -P: the RFC private key k negated (n - k) gives the same x with y
    # negated, the key a y-sign or decompression mix-up would hand over.
    var neg_k = _n_minus(_b(_UA_PRIVATE))
    var neg = p256_public_key(Span[UInt8](neg_k))
    var neg_list = List[UInt8]()
    for i in range(65):
        neg_list.append(neg[i])
    for i in range(33):
        assert_equal(neg_list[i], ua[i])
    assert_true(neg_list[64] != ua[64])
    assert_equal(
        _ua_outcome(neg_list, auth, body),
        "webpush: user agent public key is not the key of the private key",
    )
    # One byte flipped at every position 0..64, the 0x04 prefix included:
    # the comparison covers all 65 bytes and runs before any curve check.
    for i in range(65):
        var ua_flip = ua.copy()
        ua_flip[i] = ua_flip[i] ^ UInt8(0x01)
        assert_equal(
            _ua_outcome(ua_flip, auth, body),
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
    var ua_64 = List[UInt8]()
    for i in range(64):
        ua_64.append(ua[i])
    assert_equal(
        _ua_outcome(ua_64, auth, body),
        "webpush: user agent public key must be 65 bytes, got 64",
    )
    var auth_15 = List[UInt8]()
    for i in range(15):
        auth_15.append(auth[i])
    assert_equal(
        _ua_outcome(ua, auth_15, body),
        "webpush: auth secret must be 16 bytes, got 15",
    )


def _ikm_outcome(
    auth: List[UInt8], ua_public: List[UInt8], as_public: List[UInt8]
) -> String:
    try:
        var secret = _filled(32, 0x33)
        var ikm = webpush_ikm(
            Span[UInt8](secret),
            Span[UInt8](auth),
            Span[UInt8](ua_public),
            Span[UInt8](as_public),
        )
        return String("OK ") + String(len(ikm))
    except e:
        return String(e)


def test_webpush_ikm_refusals() raises:
    """`webpush_ikm` is public: its own size checks, reached directly."""
    var ua = _b(_UA_PUBLIC)
    var auth = _b(_AUTH_SECRET)
    var ua_64 = List[UInt8]()
    for i in range(64):
        ua_64.append(ua[i])
    assert_equal(_ikm_outcome(auth, ua, ua), "OK 32")
    assert_equal(
        _ikm_outcome(_filled(15, 1), ua, ua),
        "webpush: auth secret must be 16 bytes, got 15",
    )
    assert_equal(
        _ikm_outcome(auth, ua_64, ua),
        "webpush: user agent public key must be 65 bytes, got 64",
    )
    assert_equal(
        _ikm_outcome(auth, ua, ua_64),
        "webpush: application server public key must be 65 bytes, got 64",
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
    # 1 is the lower bound and has a zero top byte, as 1 in 256 valid keys
    # do: its point is the generator G (FIPS 186-4 D.1.2.3).
    var k_one = _filled(32, 0)
    k_one[31] = UInt8(1)
    assert_equal(
        _pub_outcome(k_one),
        "OK 04"
        + "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
        + "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
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
    test_content_coding_257_records()
    print("PASS aes128gcm_decrypt 257 records")
    test_content_coding_encrypt_refusals()
    print("PASS aes128gcm_encrypt refusals")
    test_content_coding_encrypt_limits_accepted()
    print("PASS aes128gcm_encrypt limits accepted")
    test_content_coding_parse_wide_fields()
    print("PASS aes128gcm_parse_header wide rs and idlen")
    test_webpush_encrypt_refusals()
    print("PASS webpush_encrypt refusals")
    test_webpush_decrypt_refusals()
    print("PASS webpush_decrypt refusals")
    test_webpush_ikm_refusals()
    print("PASS webpush_ikm refusals")
    test_p256_public_key_refusals()
    print("PASS p256_public_key refusals")
