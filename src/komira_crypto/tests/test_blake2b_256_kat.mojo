# =============================================================================
# src/komira_crypto/tests/test_blake2b_256_kat.mojo — the known-answer
#   gate for the AWS-LC-backed one-shot `blake2b_256` (`hash.mojo`).
# =============================================================================
#
# WHAT BLAKE2b-256 IS FOR HERE: the Python package index's legacy upload form
# carries `blake2_256_digest` beside `sha256_digest`, and the index verifies
# every digest it is given against the uploaded file. A wrong value is a 400
# ("The digest supplied does not match…") on every upload, so this gate holds
# that the digest is BLAKE2b's with a 32-byte output, bit for bit, at package
# scale.
#
# THE ROWS
#   (1) the empty message, "abc", and the classic 43-byte pangram;
#   (2) the bytes 0x00..0xff (256 bytes = two full 128-byte blocks);
#   (3) 127 / 128 / 129 bytes — the last-block boundary, where a BLAKE2b
#       implementation that finalises a full final block wrongly diverges;
#   (4) a MULTI-MB input (5 MiB + 7 bytes, not block-aligned);
#   (5) the output is 32 bytes and differs from the 64-byte BLAKE2b-512 of the
#       same input (the parameter block, not a truncation, selects the length:
#       BLAKE2b-256 is NOT the first half of BLAKE2b-512).
#
# PROVENANCE OF EVERY EXPECTED VALUE: each agrees with CPython's
# `hashlib.blake2b(data, digest_size=32)` AND coreutils `b2sum -l 256` — two
# implementations independent of AWS-LC. Row (5)'s BLAKE2b-512("abc") is RFC
# 7693 Appendix A.
#
# Hermetic: no file, no network, no clock.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import blake2b_256, hex_lower


def _hex(d: Array[UInt8, 32]) -> String:
    return hex_lower(Span(d))


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _repeat(c: UInt8, n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(c)
    return out^


def _digest_hex(data: List[UInt8]) -> String:
    return _hex(blake2b_256(Span(data)))


def test_short_messages() raises:
    assert_equal(
        _digest_hex(List[UInt8]()),
        String("0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8"),
    )
    assert_equal(
        _digest_hex(_bytes_of(String("abc"))),
        String("bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319"),
    )
    assert_equal(
        _digest_hex(
            _bytes_of(String("The quick brown fox jumps over the lazy dog"))
        ),
        String("01718cec35cd3d796dd00020e0bfecb473ad23457d063b75eff29c0ffa2e58a9"),
    )
    print("  test_short_messages: PASS")


def test_two_full_blocks() raises:
    var data = List[UInt8]()
    for i in range(256):
        data.append(UInt8(i))
    assert_equal(
        _digest_hex(data),
        String("39a7eb9fedc19aabc83425c6755dd90e6f9d0c804964a1f4aaeea3b9fb599835"),
    )
    print("  test_two_full_blocks: PASS")


def test_last_block_boundary() raises:
    var a = UInt8(ord("a"))
    assert_equal(
        _digest_hex(_repeat(a, 127)),
        String("59e2f1aba240f20aa591016f5ef429990bc9c2131dcd0d30f0ffd75ed18f317d"),
    )
    assert_equal(
        _digest_hex(_repeat(a, 128)),
        String("ae2aa48507885c4c950fb809b2076f959cde9f8ea6da260d9a3587df33dac450"),
    )
    assert_equal(
        _digest_hex(_repeat(a, 129)),
        String("2f64744a6de0d2c0b56e64cf6e29a5aaa255010d415d51c75ccc82f73dccd865"),
    )
    print("  test_last_block_boundary: PASS")


def test_multi_mb_input() raises:
    var n = 5 * 1024 * 1024 + 7
    var data = List[UInt8](capacity=n)
    for i in range(n):
        data.append(UInt8((i * 31 + 7) & 0xFF))
    assert_equal(
        _digest_hex(data),
        String("98cddea148f159fa9d3c5e16a27d14da1f219d75b0facd6ae3dfd1a81a2ee965"),
    )
    print("  test_multi_mb_input: PASS")


def test_is_not_a_truncated_blake2b_512() raises:
    # RFC 7693 Appendix A: BLAKE2b-512("abc") begins BA 80 A5 3F 98 1C 4D 0D.
    # BLAKE2b-256 encodes the output length in its parameter block, so its
    # digest is NOT a prefix of the 512-bit one. A wrapper that truncated a
    # 512-bit digest would pass a length check and fail this row.
    var got = _digest_hex(_bytes_of(String("abc")))
    assert_equal(got.byte_length(), 64)
    assert_true(not got.startswith(String("ba80a53f981c4d0d")))
    print("  test_is_not_a_truncated_blake2b_512: PASS")


def main() raises:
    test_short_messages()
    test_two_full_blocks()
    test_last_block_boundary()
    test_multi_mb_input()
    test_is_not_a_truncated_blake2b_512()
    print("test_blake2b_256_kat: ALL PASS")
