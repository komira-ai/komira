# =============================================================================
# test_simd_row_boundary_scan.mojo — byte-identity
# =============================================================================
#
# Asserts
# that the SIMD-vectorized `find_first_newline_simd` primitive in
# `komira_csv/csv_scanner_phase1.mojo` returns BYTE-IDENTICAL offsets to a
# reference scalar memchr loop across:
#
#   1. Small files (<16 rows; tail-only path; <64-byte SIMD chunk).
#   2. Lineitem-SF1-shaped fixture (~3-4 MiB; exercises the 64-byte SIMD
#      fast loop across many chunks + cross-boundary continuity).
#   3. Edge cases:
#      - Empty buffer.
#      - 1-row file (single LF at end).
#      - File with NO trailing newline (last row ends at EOF).
#      - File with ONLY blank lines (just LFs).
#      - Start offset == len(bytes).
#      - LF exactly at a 64-byte chunk boundary (offset 0, 64, 128).
#
# The byte-identity verification is the load-bearing correctness gate for
# the SIMD scanner — the partition logic and the per-line newline find in
# the row-streaming CSV/JSONL readers MUST produce the same boundaries a
# scalar scan does. Any off-by-one / byte-misalignment in the SIMD scanner
# would corrupt row boundaries and silently misparse downstream.
#
# Test design: for each fixture shape, compute the FULL sequence of LF
# offsets via BOTH scanners, then compare List-equality. If they diverge
# at any byte, the test fails with the first-disagreeing offset for
# debugging.
#
# This test is the regression guard for the SIMD primitive: if its byte
# semantics change, this test fires.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_csv import find_first_newline_simd


# =============================================================================
# Reference scalar scanner: walks bytes one at a time looking for 0x0A.
# Returning len(bytes) on no-find
# mirrors the SIMD primitive's contract.
# =============================================================================


def _ref_find_first_newline_scalar(
    bytes: Span[UInt8, _], start: Int
) -> Int:
    var n = len(bytes)
    if start >= n:
        return n
    var p = start
    while p < n:
        if bytes[p] == UInt8(0x0A):
            return p
        p = p + 1
    return n


# =============================================================================
# Helper: collect ALL newline positions in a buffer via the given scanner.
# Returns offsets of every 0x0A byte (positions, not "byte after").
# =============================================================================


def _collect_all_newlines_simd(bytes: Span[UInt8, _]) -> List[Int]:
    var n = len(bytes)
    var out = List[Int]()
    var p = 0
    while p < n:
        var lf = find_first_newline_simd(bytes, p)
        if lf >= n:
            break
        out.append(lf)
        p = lf + 1
    return out^


def _collect_all_newlines_scalar(bytes: Span[UInt8, _]) -> List[Int]:
    var n = len(bytes)
    var out = List[Int]()
    var p = 0
    while p < n:
        var lf = _ref_find_first_newline_scalar(bytes, p)
        if lf >= n:
            break
        out.append(lf)
        p = lf + 1
    return out^


def _assert_lists_equal(
    a: List[Int], b: List[Int], context: String
) raises:
    assert_equal(
        len(a),
        len(b),
        String("byte-identity newline count mismatch: ") + context,
    )
    var i = 0
    while i < len(a):
        assert_equal(
            a[i],
            b[i],
            String("byte-identity offset mismatch at index ")
            + String(i)
            + String(" (")
            + context
            + String(")"),
        )
        i = i + 1


# =============================================================================
# Shape 1: small file (<16 rows, single chunk via scalar tail path).
# =============================================================================


def test_byte_identity_small_few_rows() raises:
    """Three short rows. Whole file fits below the 64-byte SIMD chunk,
    so the SIMD primitive exercises the scalar-tail path exclusively.
    """
    var s = String("a,b,c\n1,2,3\n4,5,6\n")
    var bytes = s.as_bytes()
    var simd_offsets = _collect_all_newlines_simd(bytes)
    var scalar_offsets = _collect_all_newlines_scalar(bytes)
    _assert_lists_equal(
        simd_offsets, scalar_offsets, String("small-3-rows")
    )
    # Sanity: expect exactly 3 newline offsets.
    assert_equal(
        len(simd_offsets), 3, "small-3-rows expected 3 LFs"
    )


def test_byte_identity_empty_buffer() raises:
    """Empty buffer: SIMD must return 0 (== len(bytes)) immediately."""
    var s = String("")
    var bytes = s.as_bytes()
    assert_equal(
        find_first_newline_simd(bytes, 0),
        0,
        "empty buffer: expected 0 (=len(bytes))",
    )
    # Start beyond end (degenerate).
    assert_equal(
        find_first_newline_simd(bytes, 100),
        0,
        "empty buffer + start past end: expected len(bytes)",
    )


def test_byte_identity_no_trailing_newline() raises:
    """File ending without LF: last row terminates at EOF. Both scanners
    return `len(bytes)` for that final scan.
    """
    var s = String("alpha\nbeta\ngamma")  # no trailing LF
    var bytes = s.as_bytes()
    var simd_offsets = _collect_all_newlines_simd(bytes)
    var scalar_offsets = _collect_all_newlines_scalar(bytes)
    _assert_lists_equal(
        simd_offsets, scalar_offsets, String("no-trailing-newline")
    )
    # Sanity: 2 LFs (after alpha, after beta); none after gamma.
    assert_equal(
        len(simd_offsets), 2, "no-trailing-newline expected 2 LFs"
    )


def test_byte_identity_one_row() raises:
    """Single-row file with one trailing LF."""
    var s = String("hello\n")
    var bytes = s.as_bytes()
    var simd_offsets = _collect_all_newlines_simd(bytes)
    var scalar_offsets = _collect_all_newlines_scalar(bytes)
    _assert_lists_equal(
        simd_offsets, scalar_offsets, String("one-row")
    )
    assert_equal(len(simd_offsets), 1, "one-row expected 1 LF")


def test_byte_identity_all_blank_lines() raises:
    """Pathological: just LFs, no body bytes. Verifies the SIMD scan
    finds adjacent LFs correctly (no off-by-one from `+ 1` advance).
    """
    var s = String("\n\n\n\n\n")  # 5 consecutive LFs
    var bytes = s.as_bytes()
    var simd_offsets = _collect_all_newlines_simd(bytes)
    var scalar_offsets = _collect_all_newlines_scalar(bytes)
    _assert_lists_equal(
        simd_offsets, scalar_offsets, String("all-blank-lines")
    )
    assert_equal(
        len(simd_offsets), 5, "all-blank-lines expected 5 LFs"
    )


def test_byte_identity_start_at_eof() raises:
    """Start == len(bytes): must return len(bytes) without reading."""
    var s = String("a\nb\n")
    var bytes = s.as_bytes()
    var n = len(bytes)
    assert_equal(
        find_first_newline_simd(bytes, n),
        n,
        "start==len(bytes): expected len(bytes)",
    )


# =============================================================================
# Shape 2: lineitem-SF1-shaped fixture (~3-4 MiB; exercises the 64-byte
# SIMD fast loop across thousands of chunks).
# =============================================================================


def _build_lineitem_like_fixture(n_rows: Int) raises -> String:
    """Build a multi-row buffer with realistic CSV-row widths
    (~80 bytes/row), mirroring the row shape used in the existing
    `test_csv_roundtrip_row_typed_mmap_large` fixture.
    """
    var out = String("l_orderkey,l_partkey,l_quantity,l_shipinstruct\n")
    var i = 0
    while i < n_rows:
        var orderkey = i + 1000
        var partkey = i + 5000
        var row = (
            String(orderkey)
            + String(",")
            + String(partkey)
            + String(",17.50,DELIVER IN PERSON\n")
        )
        out += row
        i = i + 1
    return out^


def test_byte_identity_large_lineitem_shape() raises:
    """50K-row fixture (~4 MiB) exercises the 64-byte SIMD fast loop
    across thousands of chunks. Byte-identity at this scale validates
    cross-chunk continuity (no off-by-one at 64-byte boundaries).
    """
    var s = _build_lineitem_like_fixture(50_000)
    var bytes = s.as_bytes()
    var simd_offsets = _collect_all_newlines_simd(bytes)
    var scalar_offsets = _collect_all_newlines_scalar(bytes)
    _assert_lists_equal(
        simd_offsets,
        scalar_offsets,
        String("large-lineitem-50K"),
    )
    # 1 header row + 50000 data rows = 50001 LFs.
    assert_equal(
        len(simd_offsets),
        50_001,
        "large-lineitem-50K expected 50001 LFs",
    )


# =============================================================================
# Shape 3: LF at chunk-boundary positions (offset 0, 64, 128, 192).
# The SIMD chunk loader reads 64 bytes at a time; the byte at the START
# of a chunk has bit 0 in the movemask. The byte at the END (position 63
# within the chunk) has bit 63 — the highest bit. Both must be detected
# correctly via `count_trailing_zeros`.
# =============================================================================


def test_byte_identity_lf_at_chunk_boundaries() raises:
    """Construct a 256-byte buffer with LFs at exact chunk-boundary
    positions: 0, 63, 64, 127, 128, 191, 192, 255.
    """
    var buf = List[UInt8]()
    var i = 0
    while i < 256:
        buf.append(UInt8(ord("X")))  # filler byte
        i = i + 1
    # Place LFs at the boundary positions.
    var lf_positions = List[Int]()
    lf_positions.append(0)
    lf_positions.append(63)
    lf_positions.append(64)
    lf_positions.append(127)
    lf_positions.append(128)
    lf_positions.append(191)
    lf_positions.append(192)
    lf_positions.append(255)
    for j in range(len(lf_positions)):
        buf[lf_positions[j]] = UInt8(0x0A)
    var bytes = Span(buf)
    var simd_offsets = _collect_all_newlines_simd(bytes)
    var scalar_offsets = _collect_all_newlines_scalar(bytes)
    _assert_lists_equal(
        simd_offsets,
        scalar_offsets,
        String("lf-at-chunk-boundaries"),
    )
    assert_equal(
        len(simd_offsets), 8, "lf-at-chunk-boundaries expected 8 LFs"
    )


# =============================================================================
# Shape 4: Random / arbitrary buffer (~10K bytes) for fuzz-like coverage.
# Uses a deterministic seed-style pattern to keep the test reproducible
# while spreading LFs at non-aligned positions.
# =============================================================================


def test_byte_identity_arbitrary_buffer() raises:
    """Pseudo-random 10000-byte buffer: every 7th byte is LF, others
    are filler. Exercises non-aligned LF positions across 156 chunks.
    """
    var buf = List[UInt8]()
    var i = 0
    while i < 10_000:
        # Deterministic: LF every 7 bytes; filler otherwise.
        if i % 7 == 0:
            buf.append(UInt8(0x0A))
        else:
            buf.append(UInt8(ord("a") + (i % 26)))
        i = i + 1
    var bytes = Span(buf)
    var simd_offsets = _collect_all_newlines_simd(bytes)
    var scalar_offsets = _collect_all_newlines_scalar(bytes)
    _assert_lists_equal(
        simd_offsets, scalar_offsets, String("arbitrary-10K")
    )
    # 10000 / 7 ≈ 1429 LFs (positions 0, 7, 14, ..., 9996).
    var expected_n_lfs = (9_999 // 7) + 1
    assert_equal(
        len(simd_offsets),
        expected_n_lfs,
        "arbitrary-10K LF count mismatch",
    )


# =============================================================================
# Shape 5: start parameter validation (mid-buffer scan).
# Calling find_first_newline_simd with start > 0 must skip earlier LFs
# and find the first LF at or after `start`.
# =============================================================================


def test_byte_identity_mid_buffer_start() raises:
    """Start in the middle of a buffer that has LFs both before AND
    after the start position. SIMD must skip earlier LFs and return
    the first one >= start.
    """
    var s = String(
        "AAAA\nBBBB\nCCCC\nDDDD\nEEEE\nFFFF\nGGGG\nHHHH\n"
        + "IIII\nJJJJ\nKKKK\nLLLL\nMMMM\nNNNN\nOOOO\nPPPP\n"
    )  # 16 lines × ~5 bytes = ~80 bytes
    var bytes = s.as_bytes()
    # Find the first LF at or after offset 30 (mid-buffer).
    var simd_lf = find_first_newline_simd(bytes, 30)
    var scalar_lf = _ref_find_first_newline_scalar(bytes, 30)
    assert_equal(
        simd_lf,
        scalar_lf,
        "mid-buffer-start: SIMD vs scalar disagree",
    )
    # Sanity: the LF MUST be at or after position 30 (we asked for >= 30).
    assert_true(
        simd_lf >= 30,
        "mid-buffer-start: returned offset earlier than start",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_byte_identity_small_few_rows]()
    suite.test[test_byte_identity_empty_buffer]()
    suite.test[test_byte_identity_no_trailing_newline]()
    suite.test[test_byte_identity_one_row]()
    suite.test[test_byte_identity_all_blank_lines]()
    suite.test[test_byte_identity_start_at_eof]()
    suite.test[test_byte_identity_large_lineitem_shape]()
    suite.test[test_byte_identity_lf_at_chunk_boundaries]()
    suite.test[test_byte_identity_arbitrary_buffer]()
    suite.test[test_byte_identity_mid_buffer_start]()
    suite^.run()
