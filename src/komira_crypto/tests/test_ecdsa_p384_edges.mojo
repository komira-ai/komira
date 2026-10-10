# =============================================================================
# komira_crypto/tests/test_ecdsa_p384_edges.mojo
#
# P-384 paths the KAT and RFC 6979 tests do not reach:
#   * RFC 6979 bits2octets (section 2.3.4) for a digest at or above the
#     curve order n (one whose subtraction borrows through the low bytes):
#     2^384-1 reduces to 2^384-1-n, n reduces to 0, n-1 and a
#     digest below n are unchanged (values computed with Python integers);
#   * the big-endian compare and the [1, n-1] nonce range check at their
#     edges (equal, first/last byte decides, 0, 1, n-1, n);
#   * the public API's size refusals (random-k nonce, verify key and
#     signature lengths) and generate_pubkey returning all-zero bytes for a
#     private key AWS-LC cannot turn into a point (0, or a short buffer);
#   * the FFI layer's own refusals: each argument's length, a zero nonce
#     ("signing failed"), the zero scalar's point at infinity.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.ecdsa_p384 import (
    _bits2octets_p384_bytes,
    _be48_lt,
    _is_in_range_1_to_n_minus_1_384,
    ecdsa_p384_sign_random,
    ecdsa_p384_verify,
    ecdsa_p384_generate_pubkey,
)
from komira_crypto.internal.asm.p384_ffi import (
    p384_sign_with_nonce,
    p384_verify,
    p384_pubkey_from_priv,
)


comptime W = 48


def _hex(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(0, len(b), 2):
        var hi = Int(b[i])
        var lo = Int(b[i + 1])
        hi = hi - 48 if hi < 58 else hi - 87
        lo = lo - 48 if lo < 58 else lo - 87
        out.append(UInt8(hi * 16 + lo))
    return out^


def _arr(s: String) -> Array[UInt8, W]:
    var v = _hex(s)
    var a = Array[UInt8, W](fill=UInt8(0))
    for i in range(W):
        a[i] = v[i]
    return a^


def _fill(v: Int) -> Array[UInt8, W]:
    return Array[UInt8, W](fill=UInt8(v))


def _n() -> String:
    return "ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973"


def _n_minus_1() -> Array[UInt8, W]:
    var a = _arr(_n())
    a[W - 1] = a[W - 1] - 1
    return a^


def _same(a: Array[UInt8, W], b: Array[UInt8, W], what: String) raises:
    for i in range(W):
        assert_equal(Int(a[i]), Int(b[i]), what + ": byte " + String(i))


def _is_zero(a: Array[UInt8, 2 * W]) -> Bool:
    for i in range(2 * W):
        if a[i] != 0:
            return False
    return True


def _err(msg: String) -> String:
    return msg


# -----------------------------------------------------------------------------
# bits2octets and the range checks
# -----------------------------------------------------------------------------


def test_bits2octets_reduces_at_and_above_n() raises:
    var ff = _fill(0xFF)
    _same(
        _bits2octets_p384_bytes(Span[UInt8, origin_of(ff)](ff)),
        _arr("000000000000000000000000000000000000000000000000389cb27e0bc8d220a7e5f24db74f58851313e695333ad68c"),
        "2^384-1 mod n",
    )
    # Above n with low bytes of zero: every lower byte borrows.
    var borrow = _arr("ffffffffffffffffffffffffffffffffffffffffffffffffc80000000000000000000000000000000000000000000000")
    _same(
        _bits2octets_p384_bytes(Span[UInt8, origin_of(borrow)](borrow)),
        _arr("000000000000000000000000000000000000000000000000009cb27e0bc8d220a7e5f24db74f58851313e695333ad68d"),
        "borrowing subtraction",
    )
    var n = _arr(_n())
    _same(_bits2octets_p384_bytes(Span[UInt8, origin_of(n)](n)), _fill(0), "n mod n")
    var nm1 = _n_minus_1()
    _same(_bits2octets_p384_bytes(Span[UInt8, origin_of(nm1)](nm1)), _n_minus_1(), "n-1 unchanged")
    var low = _fill(0x11)
    _same(_bits2octets_p384_bytes(Span[UInt8, origin_of(low)](low)), _fill(0x11), "below n unchanged")


def test_big_endian_compare_edges() raises:
    var a = _fill(0x40)
    var b = _fill(0x40)
    assert_false(_be48_lt(a, b), "equal is not less")
    b[W - 1] = 0x41
    assert_true(_be48_lt(a, b), "last byte smaller")
    assert_false(_be48_lt(b, a), "last byte larger")
    var c = _fill(0x00)
    c[0] = 0x41
    assert_false(_be48_lt(c, a), "first byte larger decides")
    assert_true(_be48_lt(a, c), "first byte smaller decides")


def test_nonce_range() raises:
    var one = _fill(0)
    one[W - 1] = 1
    assert_false(_is_in_range_1_to_n_minus_1_384(_fill(0)), "0")
    assert_true(_is_in_range_1_to_n_minus_1_384(one), "1")
    assert_true(_is_in_range_1_to_n_minus_1_384(_n_minus_1()), "n-1")
    assert_false(_is_in_range_1_to_n_minus_1_384(_arr(_n())), "n")


# -----------------------------------------------------------------------------
# Public API size refusals
# -----------------------------------------------------------------------------


def test_public_api_sizes() raises:
    var priv = _fill(0x22)
    var msg = String("m").as_bytes()
    var short_k = List[UInt8]()
    for _ in range(W - 1):
        short_k.append(0x33)
    var e = String("no error")
    try:
        _ = ecdsa_p384_sign_random(Span[UInt8, origin_of(priv)](priv), msg, Span(short_k))
    except err:
        e = String(err)
    assert_true(e.find("k_bytes must be 48 bytes") >= 0, "short k: " + e)
    var long_k = short_k.copy()
    long_k.append(0x33)
    long_k.append(0x33)
    e = String("no error")
    try:
        _ = ecdsa_p384_sign_random(Span[UInt8, origin_of(priv)](priv), msg, Span(long_k))
    except err:
        e = String(err)
    assert_true(e.find("k_bytes must be 48 bytes") >= 0, "long k: " + e)

    var k = _fill(0x33)
    var sig = ecdsa_p384_sign_random(Span[UInt8, origin_of(priv)](priv), msg, Span[UInt8, origin_of(k)](k))
    var pub = ecdsa_p384_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    assert_true(ecdsa_p384_verify(Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig)), "baseline verifies")
    var pub_short = List[UInt8]()
    for i in range(2 * W - 1):
        pub_short.append(pub[i])
    assert_false(ecdsa_p384_verify(Span(pub_short), msg, Span[UInt8, origin_of(sig)](sig)), "short key")
    var sig_short = List[UInt8]()
    for i in range(2 * W - 1):
        sig_short.append(sig[i])
    assert_false(ecdsa_p384_verify(Span[UInt8, origin_of(pub)](pub), msg, Span(sig_short)), "short signature")


def test_generate_pubkey_failure_is_all_zero() raises:
    var zero = _fill(0)
    assert_true(_is_zero(ecdsa_p384_generate_pubkey(Span[UInt8, origin_of(zero)](zero))), "zero scalar")
    var short = List[UInt8]()
    for _ in range(W - 1):
        short.append(0x22)
    assert_true(_is_zero(ecdsa_p384_generate_pubkey(Span(short))), "short scalar")
    var good = _fill(0x22)
    assert_false(_is_zero(ecdsa_p384_generate_pubkey(Span[UInt8, origin_of(good)](good))), "valid scalar")


# -----------------------------------------------------------------------------
# FFI refusals
# -----------------------------------------------------------------------------


def _sign_err(priv: List[UInt8], digest: List[UInt8], nonce: List[UInt8]) -> String:
    var r = Array[UInt8, W](fill=UInt8(0))
    var s = Array[UInt8, W](fill=UInt8(0))
    try:
        p384_sign_with_nonce(Span[UInt8, origin_of(priv)](priv), Span(digest), Span(nonce), r, s)
    except e:
        return String(e)
    return String("no error")


def _l(n: Int, v: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(UInt8(v))
    return out^


def test_ffi_sign_refusals() raises:
    assert_equal(_sign_err(_l(W, 0x22), _l(W, 5), _l(W, 0x33)), String("no error"), "baseline")
    var e = _sign_err(_l(W - 1, 0x22), _l(W, 5), _l(W, 0x33))
    assert_true(e.find("priv_be must be 48 bytes") >= 0, e)
    e = _sign_err(_l(W, 0x22), _l(W - 1, 5), _l(W, 0x33))
    assert_true(e.find("digest must be 48 bytes") >= 0, e)
    e = _sign_err(_l(W, 0x22), _l(W, 5), _l(W + 1, 0x33))
    assert_true(e.find("nonce_be must be 48 bytes") >= 0, e)
    e = _sign_err(_l(W, 0x22), _l(W, 5), _l(W, 0))
    assert_true(e.find("ECDSA signing failed") >= 0, "zero nonce: " + e)


def test_ffi_verify_refusals() raises:
    var priv = _fill(0x22)
    var k = _fill(0x33)
    var msg = String("m").as_bytes()
    var sig = ecdsa_p384_sign_random(Span[UInt8, origin_of(priv)](priv), msg, Span[UInt8, origin_of(k)](k))
    var pub = ecdsa_p384_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var digest = _l(W, 5)
    var sig_l = List[UInt8]()
    for i in range(2 * W):
        sig_l.append(sig[i])
    var pub_l = List[UInt8]()
    for i in range(2 * W):
        pub_l.append(pub[i])
    assert_false(p384_verify(Span(pub_l), Span(digest), Span(sig_l)), "wrong digest is not valid")
    var key_short = _l(2 * W - 1, 1)
    var digest_short = _l(W - 1, 5)
    var sig_short = _l(2 * W - 1, 1)
    assert_false(p384_verify(Span(key_short), Span(digest), Span(sig_l)), "short key")
    assert_false(p384_verify(Span(pub_l), Span(digest_short), Span(sig_l)), "short digest")
    assert_false(p384_verify(Span(pub_l), Span(digest), Span(sig_short)), "short signature")


def test_ffi_pubkey_refusals() raises:
    var out = Array[UInt8, 2 * W](fill=UInt8(0))
    var e = String("no error")
    try:
        var long_priv = _l(W + 1, 0x22)
        p384_pubkey_from_priv(Span(long_priv), out)
    except err:
        e = String(err)
    assert_true(e.find("priv_be must be 48 bytes") >= 0, e)
    e = String("no error")
    try:
        var zero_priv = _l(W, 0)
        p384_pubkey_from_priv(Span(zero_priv), out)
    except err:
        e = String(err)
    assert_true(e.find("EC_POINT_point2oct failed") >= 0, "zero scalar: " + e)


def main() raises:
    test_bits2octets_reduces_at_and_above_n()
    test_big_endian_compare_edges()
    test_nonce_range()
    test_public_api_sizes()
    test_generate_pubkey_failure_is_all_zero()
    test_ffi_sign_refusals()
    test_ffi_verify_refusals()
    test_ffi_pubkey_refusals()
    print("test_ecdsa_p384_edges: 8 tests PASS")
