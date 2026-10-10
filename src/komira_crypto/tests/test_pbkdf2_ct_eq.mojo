# =============================================================================
# komira_crypto/tests/test_pbkdf2_ct_eq.mojo
#
# Two modules no other welded test compiled:
#   * pbkdf2.mojo: PBKDF2-HMAC-SHA256 against values from Python's
#     hashlib.pbkdf2_hmac (an independent implementation), across one and two
#     iterations, one block, two full blocks, a partial second block, the
#     31/32/33-byte edges and a non-positive length.
#   * aead.mojo: constant_time_eq_n on equal, unequal at the first or last
#     byte, prefix-equal spans of different lengths, and two empty spans.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.pbkdf2 import pbkdf2_hmac_sha256, pbkdf2_hmac_sha256_32
from komira_crypto.aead import constant_time_eq_n


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


def _eq_list(got: List[UInt8], want_hex: String, what: String) raises:
    var want = _hex(want_hex)
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), what + ": byte " + String(i))


# -----------------------------------------------------------------------------
# PBKDF2-HMAC-SHA256
# -----------------------------------------------------------------------------


def _kdf(p: String, s: String, c: Int, dk: Int) -> List[UInt8]:
    return pbkdf2_hmac_sha256(p.as_bytes(), s.as_bytes(), c, dk)


def test_pbkdf2_one_iteration_one_block() raises:
    _eq_list(
        _kdf("password", "salt", 1, 32),
        "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b",
        "c=1 dkLen=32",
    )


def test_pbkdf2_two_iterations_xor_u2() raises:
    # c=2 differs from c=1 only by U_2, so a loop that skips U_2..U_c fails.
    _eq_list(
        _kdf("password", "salt", 2, 32),
        "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43",
        "c=2 dkLen=32",
    )


def test_pbkdf2_partial_second_block() raises:
    # dkLen 40: one full block, then 8 bytes of T_2 (block index 2).
    _eq_list(
        _kdf(
            "passwordPASSWORDpassword",
            "saltSALTsaltSALTsaltSALTsaltSALTsalt",
            4096,
            40,
        ),
        "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9",
        "c=4096 dkLen=40",
    )


def test_pbkdf2_two_full_blocks() raises:
    # RFC 7914 section 11's PBKDF2-HMAC-SHA256 vector: dkLen 64 = T_1 || T_2.
    _eq_list(
        _kdf("passwd", "salt", 1, 64),
        "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc"
        + "49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783",
        "c=1 dkLen=64",
    )


def test_pbkdf2_block_edges() raises:
    _eq_list(
        _kdf("password", "salt", 1, 31),
        "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be1",
        "dkLen=31",
    )
    _eq_list(
        _kdf("password", "salt", 1, 33),
        "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b4d",
        "dkLen=33",
    )


def test_pbkdf2_non_positive_length_is_empty() raises:
    assert_equal(len(_kdf("password", "salt", 1, 0)), 0, "dkLen=0")
    assert_equal(len(_kdf("password", "salt", 1, -5)), 0, "dkLen<0")


def test_pbkdf2_32_matches_the_general_form() raises:
    var a = pbkdf2_hmac_sha256_32(
        String("password").as_bytes(), String("salt").as_bytes(), 2
    )
    var want = _hex(
        "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"
    )
    for i in range(32):
        assert_equal(Int(a[i]), Int(want[i]), "Hi byte " + String(i))


# -----------------------------------------------------------------------------
# constant_time_eq_n
# -----------------------------------------------------------------------------


def test_ct_eq_n() raises:
    var a = _hex("00112233445566778899aabbccddeeff")
    var b = _hex("00112233445566778899aabbccddeeff")
    var last = _hex("00112233445566778899aabbccddeefe")
    var first = _hex("80112233445566778899aabbccddeeff")
    var longer = _hex("00112233445566778899aabbccddeeff00")
    var empty = List[UInt8]()
    var empty2 = List[UInt8]()
    assert_true(constant_time_eq_n(Span(a), Span(b)), "equal tags")
    assert_false(constant_time_eq_n(Span(a), Span(last)), "last byte differs")
    assert_false(constant_time_eq_n(Span(a), Span(first)), "first byte differs")
    # A prefix-equal longer span must not compare equal.
    assert_false(constant_time_eq_n(Span(a), Span(longer)), "a shorter than b")
    assert_false(constant_time_eq_n(Span(longer), Span(a)), "a longer than b")
    assert_true(constant_time_eq_n(Span(empty), Span(empty2)), "two empty spans")


def main() raises:
    test_pbkdf2_one_iteration_one_block()
    test_pbkdf2_two_iterations_xor_u2()
    test_pbkdf2_partial_second_block()
    test_pbkdf2_two_full_blocks()
    test_pbkdf2_block_edges()
    test_pbkdf2_non_positive_length_is_empty()
    test_pbkdf2_32_matches_the_general_form()
    test_ct_eq_n()
    print("test_pbkdf2_ct_eq_compress: 8 tests PASS")
