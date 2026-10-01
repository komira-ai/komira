# =============================================================================
# src/komira_http/tests/test_header_simd.mojo
#   Unit tests for hand-staged SIMD byte primitives.
# =============================================================================
#
#
#
# The SIMD kernel rule: "every SIMD kernel landing must satisfy
# a round-trip property test — the SIMD output is bit-identical to a
# scalar reference at edge sizes (0, 1, chunk-1, chunk, chunk+1) and at
# realistic sizes (header-name 10-30 bytes; value 5-100 bytes)."
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http.client.header_simd import (
    bulk_copy_span,
    case_fold_copy_span,
    ci_eq_span,
)


# =============================================================================
# §1 — bulk_copy_span tests.
# =============================================================================


def _bulk_copy_case(n: Int) raises:
    """Helper: construct src bytes 0..n-1, copy via SIMD, assert byte-identity."""
    var src = List[UInt8]()
    var i = 0
    while i < n:
        src.append(UInt8(i % 251))  # 251 prime: spread byte values
        i += 1
    var dst = List[UInt8]()
    while dst.__len__() < n:
        dst.append(UInt8(0xAA))  # poison value
    var src_span = Span[UInt8](src).as_imm()
    var dst_span = Span[UInt8](dst)
    bulk_copy_span(src_span, dst_span)
    var k = 0
    while k < n:
        if src[k] != dst[k]:
            print("bulk_copy mismatch at n=", n, " k=", k, " src=", Int(src[k]), " dst=", Int(dst[k]))
        assert_equal(Int(src[k]), Int(dst[k]))
        k += 1


def test_bulk_copy_edge_sizes() raises:
    _bulk_copy_case(0)
    _bulk_copy_case(1)
    _bulk_copy_case(7)
    _bulk_copy_case(15)
    _bulk_copy_case(16)
    _bulk_copy_case(17)
    _bulk_copy_case(31)
    _bulk_copy_case(32)
    _bulk_copy_case(33)


def test_bulk_copy_realistic_sizes() raises:
    _bulk_copy_case(11)   # "content-len"
    _bulk_copy_case(14)   # "content-length"
    _bulk_copy_case(17)   # "transfer-encoding"
    _bulk_copy_case(30)
    _bulk_copy_case(100)
    _bulk_copy_case(256)
    _bulk_copy_case(4095)


# =============================================================================
# §2 — case_fold_copy_span tests.
# =============================================================================


@always_inline
def _scalar_lower(b: UInt8) -> UInt8:
    var c = Int(b)
    if c >= Int(ord("A")) and c <= Int(ord("Z")):
        return UInt8(c + 32)
    return b


def _case_fold_case(imm src_bytes: List[UInt8]) raises:
    """Helper: case-fold via SIMD, assert byte-equal to scalar reference."""
    var n = src_bytes.__len__()
    var dst = List[UInt8]()
    while dst.__len__() < n:
        dst.append(UInt8(0xAA))
    var src_span = Span[UInt8](src_bytes).as_imm()
    var dst_span = Span[UInt8](dst)
    case_fold_copy_span(src_span, dst_span)
    var k = 0
    while k < n:
        var expect = _scalar_lower(src_bytes[k])
        if expect != dst[k]:
            print("case_fold mismatch at n=", n, " k=", k, " src=", Int(src_bytes[k]),
                  " expect=", Int(expect), " got=", Int(dst[k]))
        assert_equal(Int(expect), Int(dst[k]))
        k += 1


def _str_to_bytes(s: String) -> List[UInt8]:
    var b = List[UInt8]()
    var sb = s.as_bytes()
    var n = len(sb)
    var i = 0
    while i < n:
        b.append(sb[i])
        i += 1
    return b^


def test_case_fold_empty() raises:
    var src = List[UInt8]()
    _case_fold_case(src)


def test_case_fold_all_uppercase() raises:
    # "CONTENT-LENGTH" — 14 bytes, mixed shape (uppercase + hyphen).
    _case_fold_case(_str_to_bytes(String("CONTENT-LENGTH")))


def test_case_fold_all_lowercase() raises:
    _case_fold_case(_str_to_bytes(String("content-length")))


def test_case_fold_mixed() raises:
    _case_fold_case(_str_to_bytes(String("Content-Length")))
    _case_fold_case(_str_to_bytes(String("User-Agent")))
    _case_fold_case(_str_to_bytes(String("X-Custom-Header-Name")))


def test_case_fold_with_non_alpha() raises:
    # Bytes outside A-Z must pass through unchanged.
    _case_fold_case(_str_to_bytes(String("Application/JSON; charset=UTF-8")))
    _case_fold_case(_str_to_bytes(String("text/html,*/*;q=0.9")))


def test_case_fold_edge_alpha_bytes() raises:
    # Boundaries: 0x40 ('@', just below 'A'), 0x41 ('A'), 0x5A ('Z'),
    # 0x5B ('[', just above 'Z'), 0x60 ('`', just below 'a'), 0x61 ('a').
    var src = List[UInt8]()
    src.append(UInt8(0x40))  # '@' - keep
    src.append(UInt8(0x41))  # 'A' - fold
    src.append(UInt8(0x5A))  # 'Z' - fold
    src.append(UInt8(0x5B))  # '[' - keep
    src.append(UInt8(0x60))  # '`' - keep
    src.append(UInt8(0x61))  # 'a' - keep (already lower)
    src.append(UInt8(0x7A))  # 'z' - keep
    src.append(UInt8(0x7B))  # '{' - keep
    src.append(UInt8(0xFF))  # high byte - keep
    src.append(UInt8(0x00))  # null - keep
    src.append(UInt8(0x80))  # high bit - keep
    src.append(UInt8(0x7F))  # del - keep
    src.append(UInt8(0x30))  # '0' - keep
    src.append(UInt8(0x39))  # '9' - keep
    src.append(UInt8(0x20))  # space - keep
    src.append(UInt8(0x2D))  # '-' - keep
    src.append(UInt8(0x4A))  # 'J' - fold (mid-alphabet, second 16-chunk start)
    _case_fold_case(src)


def test_case_fold_long_mixed() raises:
    # 100-byte mixed: full SIMD chunks + tail.
    var src = List[UInt8]()
    var i = 0
    while i < 100:
        src.append(UInt8((i * 7) % 128))  # ASCII range, varied
        i += 1
    _case_fold_case(src)


# =============================================================================
# §3 — ci_eq_span tests.
# =============================================================================


def _ci_eq(imm a: List[UInt8], imm b: List[UInt8]) -> Bool:
    """Test helper: wrap ci_eq_span over List[UInt8] pairs."""
    var sa = Span[UInt8](a).as_imm()
    var sb = Span[UInt8](b).as_imm()
    return ci_eq_span(sa, sb)


def test_ci_eq_match_mixed_case() raises:
    var a = _str_to_bytes(String("Content-Length"))
    var b = _str_to_bytes(String("content-length"))
    assert_true(_ci_eq(a, b))


def test_ci_eq_match_all_upper_vs_lower() raises:
    var a = _str_to_bytes(String("CONTENT-LENGTH"))
    var b = _str_to_bytes(String("content-length"))
    assert_true(_ci_eq(a, b))


def test_ci_eq_match_all_lower() raises:
    var a = _str_to_bytes(String("content-length"))
    var b = _str_to_bytes(String("content-length"))
    assert_true(_ci_eq(a, b))


def test_ci_eq_mismatch_different_string() raises:
    var a = _str_to_bytes(String("content-length"))
    var b = _str_to_bytes(String("content-typenn"))  # same len, diff content
    assert_false(_ci_eq(a, b))


def test_ci_eq_length_diff_returns_false() raises:
    var a = _str_to_bytes(String("content-length"))
    var b = _str_to_bytes(String("content"))
    assert_false(_ci_eq(a, b))


def test_ci_eq_empty() raises:
    var a = List[UInt8]()
    var b = List[UInt8]()
    assert_true(_ci_eq(a, b))


def test_ci_eq_short_below_chunk_size() raises:
    # < 16 bytes — entirely scalar-tail path.
    var a = _str_to_bytes(String("Cookie"))
    var b = _str_to_bytes(String("cookie"))
    assert_true(_ci_eq(a, b))


def test_ci_eq_exact_chunk_size() raises:
    # Exactly 16 bytes — single SIMD chunk, no tail.
    var a = _str_to_bytes(String("ABCDEFGHIJKLMNOP"))
    var b = _str_to_bytes(String("abcdefghijklmnop"))
    assert_true(_ci_eq(a, b))


def test_ci_eq_chunk_plus_tail() raises:
    # 17 bytes — full SIMD chunk + 1 scalar tail byte.
    var a = _str_to_bytes(String("ABCDEFGHIJKLMNOPQ"))
    var b = _str_to_bytes(String("abcdefghijklmnopq"))
    assert_true(_ci_eq(a, b))


def test_ci_eq_mismatch_in_second_chunk() raises:
    # First 16 bytes match CI; 17th differs — early exit must still
    # detect difference in the scalar tail.
    var a = _str_to_bytes(String("ABCDEFGHIJKLMNOPQ"))
    var b = _str_to_bytes(String("abcdefghijklmnopX"))  # last byte != 'q' folded
    assert_false(_ci_eq(a, b))


def test_ci_eq_mismatch_in_first_chunk() raises:
    var a = _str_to_bytes(String("ABCXEFGHIJKLMNOPQ"))  # X at pos 3
    var b = _str_to_bytes(String("abcdefghijklmnopq"))
    assert_false(_ci_eq(a, b))


def main() raises:
    # bulk_copy
    test_bulk_copy_edge_sizes()
    test_bulk_copy_realistic_sizes()

    # case_fold_copy
    test_case_fold_empty()
    test_case_fold_all_uppercase()
    test_case_fold_all_lowercase()
    test_case_fold_mixed()
    test_case_fold_with_non_alpha()
    test_case_fold_edge_alpha_bytes()
    test_case_fold_long_mixed()

    # ci_eq
    test_ci_eq_match_mixed_case()
    test_ci_eq_match_all_upper_vs_lower()
    test_ci_eq_match_all_lower()
    test_ci_eq_mismatch_different_string()
    test_ci_eq_length_diff_returns_false()
    test_ci_eq_empty()
    test_ci_eq_short_below_chunk_size()
    test_ci_eq_exact_chunk_size()
    test_ci_eq_chunk_plus_tail()
    test_ci_eq_mismatch_in_second_chunk()
    test_ci_eq_mismatch_in_first_chunk()

    print("OK: test_header_simd")
