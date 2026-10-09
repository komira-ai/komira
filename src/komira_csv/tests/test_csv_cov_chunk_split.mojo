# =============================================================================
# compute_csv_quote_safe_row_ranges: the scalar tail and the edge returns.
# =============================================================================
#
# test_csv_quote_safe_chunk_split drives the splitter with bodies long enough
# that every boundary is settled inside the 64-byte SIMD loop. The scalar tail
# (the last < 64 bytes, and whole small inputs) is the readable reference
# semantics and had no test of its own. Each fixture below is small enough to
# run in the tail (or crosses into it from one SIMD chunk), and each expected
# range list is worked out by hand in the test's docstring; every boundary is
# a true row start of the fixture.
# =============================================================================

from std.testing import assert_equal

from komira_csv import Rfc4180, compute_csv_quote_safe_row_ranges


comptime _COMMA = UInt8(44)
comptime _QUOTE = UInt8(34)


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^


def _ranges(text: String, data_start: Int, k: Int) -> String:
    """`lo-hi,lo-hi,...` for the ranges the splitter returns."""
    var b = _b(text)
    var los = List[Int]()
    var his = List[Int]()
    compute_csv_quote_safe_row_ranges[Rfc4180](
        Span(b), data_start, k, _COMMA, _QUOTE, los, his
    )
    var out = String("")
    for i in range(len(los)):
        if i > 0:
            out += ","
        out += String(los[i]) + "-" + String(his[i])
    return out^


def test_tail_quoted_newline_and_doubled_quote() raises:
    """`a,"x""y<LF>z",b<LF>c,d<LF>e,f<LF>` (21 bytes), k = 3: candidates at 7
    and 14. The LF at 7 is inside the quoted field and the `""` at 4-5 is an
    escape, so the first boundary is after the LF at 12 (13), the second
    after the LF at 16 (17). Mutant: step one byte over `""` (red: the
    pair's second quote reads as the close, so the quoted LF at 7 becomes
    a boundary at 8)."""
    assert_equal(
        _ranges('a,"x""y\nz",b\nc,d\ne,f\n', 0, 3), "0-13,13-17,17-21"
    )


def test_tail_skips_newlines_before_the_candidate() raises:
    """`a<LF>b<LF>c<LF>d<LF>`, k = 2: the candidate is 4, so the LFs at 1
    and 3 are passed over and the boundary is after the LF at 5. Mutant:
    take any LF (`pos >= cand` -> True; red: boundary 2)."""
    assert_equal(_ranges("a\nb\nc\nd\n", 0, 2), "0-6,6-8")


def test_tail_stray_quote_stops_splitting() raises:
    """`ab"c<LF>d"<LF>e<LF>`: the quote at 2 is content to the FSA (not at a
    cell start), so parity cannot be trusted past it and the splitter keeps
    one range. Mutant: treat it as an opener (red: a second range at 8)."""
    assert_equal(_ranges('ab"c\nd"\ne\n', 0, 2), "0-10")


def test_tail_quote_after_bare_cr_opens() raises:
    """`a<CR>"b"<LF>c<LF>d<LF>` (10 bytes), k = 2: the candidate is 5. A bare
    CR ends a record, so the quote at 2 is at a cell start and opens a
    field; the LF at 5 after the closing quote is the boundary (6). Mutant:
    drop the bare-CR half of `at_cell_start` (red: the quote reads as stray
    and the splitter keeps one range, 0-10)."""
    assert_equal(_ranges('a\r"b"\nc\nd\n', 0, 2), "0-6,6-10")


def test_doubled_quote_straddling_the_simd_chunk_end() raises:
    """A quoted field opens at byte 0; bytes 63-64 are a `""` escape that
    straddles the first 64-byte chunk, so the tail must step over its high
    half (byte 64) before resuming in the quoted state. The field closes at
    70, its LF is at 71, and `x,y` / `z` follow: ranges 0-72, 72-78. Mutant:
    drop the straddle step (red: byte 64 reads as the close, the quote at 70
    as stray, one range)."""
    var text = String('"')
    for _ in range(62):
        text += "a"
    text += '""bbbbb"\nx,y\nz\n'
    assert_equal(text.byte_length(), 78)
    assert_equal(_ranges(text, 0, 2), "0-72,72-78")


def test_edge_returns() raises:
    """Empty input and a data start at or past the end give no range, even
    for k = 1; an LF that ends the input settles every candidate without
    opening an empty range (64 bytes, LF at 63). Mutant: drop the
    `data_start_byte >= n` refusal (red: k = 1 returns the inverted range
    10-5)."""
    assert_equal(_ranges("", 0, 4), "")
    assert_equal(_ranges("abcde", 10, 1), "")
    assert_equal(_ranges("abcde", 5, 2), "")
    var text = String("")
    for _ in range(63):
        text += "a"
    text += "\n"
    assert_equal(_ranges(text, 0, 2), "0-64")
    assert_equal(_ranges("h\nabc\n", 2, 1), "2-6")


def main() raises:
    test_tail_quoted_newline_and_doubled_quote()
    test_tail_skips_newlines_before_the_candidate()
    test_tail_stray_quote_stops_splitting()
    test_tail_quote_after_bare_cr_opens()
    test_doubled_quote_straddling_the_simd_chunk_end()
    test_edge_returns()
    print("test_csv_cov_chunk_split: 6 tests PASS")
