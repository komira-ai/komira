# =============================================================================
# Tests for SIMD INT64 column builder fast path.
# =============================================================================
#
#
# Goal: verify the reshaped INT64 / FLOAT64 / DATE32 column builders
# in `int_column_simd.mojo` (which the parallel reader's
# `_build_int64/float64/date32_column` delegate to) produce
# byte-identical results to the prior `allocate_nullable` +
# `arr.set(r, val)` baseline on every applicable input AND correctly
# handle edge cases.
#
# Test taxonomy:
#   T1  single-row INT64 happy path — one row, one cell, ASCII digits.
#       Exercises the SIMD fast path's hot loop with the minimum-sized
#       fixture; validates that the all-valid post-loop branch ships
#       `validity = None` correctly.
#   T2  multi-row INT64 mix — 8 rows, alternating positive / negative /
#       multi-digit. Exercises sign handling, length variability, and
#       the all-valid fast path on a non-trivial column.
#   T3  null-mixed INT64 — 5 rows where 2 are the canonical "" null
#       token. Exercises the `null_positions` append path AND the
#       post-loop validity-bitmap-construction branch (the "any nulls"
#       case that the reshape only fires when necessary).
#   T4  overflow-boundary INT64 — 19-digit value (> 17 char SIMD ceiling)
#       falls through to scalar `_try_parse_int64`. Verifies the scalar
#       fallback still works under the new shape.
#
# All tests drive the production parallel-reader entry
# (`read_csv_bytes_to_batch_parallel` with `n_workers=2` + buffer
# padded to exceed `_MIN_PARALLEL_BYTES` = 1 MiB so the parallel
# dispatch fires). For test economy, the fixtures interleave a tiny
# data section with a 1 MiB pad of all-numeric rows; only the first
# few rows are asserted, the pad just keeps the parallel path active.
# Direct calls to `build_int64_column_simd` would skip the
# `read_csv_bytes_to_batch_parallel` orchestration which is the
# load-bearing call shape for the reshaped builders.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType

from komira_csv import (
    CsvReadOptions,
    Rfc4180,
    read_csv_bytes_to_batch_parallel,
)


# Buffer threshold (1 MiB) below which `read_csv_bytes_to_batch_parallel`
# falls back to single-thread. We pad fixtures to exceed this so the
# parallel path actually fires through `_build_int64_column` ->
# `build_int64_column_simd`.
comptime _PAD_TARGET_BYTES: Int = 1100 * 1024  # 1.1 MiB safety margin


def _bytes_of(s: String) -> List[UInt8]:
    """Convert a String to a List[UInt8] for test fixtures."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _build_padded_csv(header: String, leading_rows: String, pad_row: String) -> List[UInt8]:
    """Build a CSV fixture that exceeds `_PAD_TARGET_BYTES`.

    Layout: header + leading_rows (asserted by caller) + N copies of
    `pad_row` (any all-numeric row of the same column count). The pad
    is required to push past `_MIN_PARALLEL_BYTES` so the parallel
    reader doesn't fall back to single-thread (which would route
    through `reader._build_int64_column`, NOT the
    `parallel_reader._build_int64_column` under test).
    """
    var buf = List[UInt8]()
    # Header.
    var hdr = header.as_bytes()
    for i in range(len(hdr)):
        buf.append(hdr[i])
    # Leading rows (asserted by caller).
    var lead = leading_rows.as_bytes()
    for i in range(len(lead)):
        buf.append(lead[i])
    # Pad with copies of pad_row until we exceed the threshold.
    var pad = pad_row.as_bytes()
    var pad_n = len(pad)
    while len(buf) < _PAD_TARGET_BYTES:
        for i in range(pad_n):
            buf.append(pad[i])
    return buf^


# =============================================================================
# T1: single-row INT64 happy path.
# =============================================================================


def test_t1_single_row_int64_happy_path() raises:
    """T1: one INT64 cell, ASCII digits, no nulls.

    Verifies the all-valid post-loop fast path produces `validity =
    None` (the reshape's intended fast-path: zero bitmap traffic when
    no nulls are observed).
    """
    var buf = _build_padded_csv(
        header=String("k\n"),
        leading_rows=String("42\n"),
        # Pad rows are also single-cell INT64 to keep the schema stable.
        pad_row=String("100\n"),
    )
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), opts, n_workers=2
    )
    assert_true(rb.num_rows() >= 1, "at least one row")
    assert_equal(rb.num_columns(), 1, "single column")
    assert_true(
        rb.schema.field_at(0).arrow_type == ArrowType.INT64, "INT64 column"
    )
    var arr = rb.column_at(0).as_primitive[DType.int64]()
    # The leading row asserted by this test:
    assert_equal(arr.get(0), Int64(42), "row 0: 42")
    # all-valid fast path: validity bitmap is None when no nulls observed.
    assert_false(arr.validity, "validity = None on all-valid fast path")
    assert_equal(arr.null_count, 0, "null_count == 0")


# =============================================================================
# T2: multi-row INT64 mix (signs + length variability).
# =============================================================================


def test_t2_multi_row_int64_mix() raises:
    """T2: 5 leading rows alternating positive / negative / multi-digit.

    Exercises:
      - cell-length variability (1, 2, 3, 5, 6 digits)
      - sign byte at position 0 ('-')
      - all-valid fast path on a non-trivial column
    """
    var buf = _build_padded_csv(
        header=String("v\n"),
        leading_rows=String(
            "1\n"
            "-2\n"
            "100\n"
            "-999\n"
            "12345\n"
        ),
        pad_row=String("0\n"),
    )
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), opts, n_workers=2
    )
    assert_true(rb.num_rows() >= 5, "at least 5 rows")
    var arr = rb.column_at(0).as_primitive[DType.int64]()
    assert_equal(arr.get(0), Int64(1), "row 0: 1")
    assert_equal(arr.get(1), Int64(-2), "row 1: -2")
    assert_equal(arr.get(2), Int64(100), "row 2: 100")
    assert_equal(arr.get(3), Int64(-999), "row 3: -999")
    assert_equal(arr.get(4), Int64(12345), "row 4: 12345")
    # All non-null -> validity = None.
    assert_false(arr.validity, "validity = None on all-valid path")
    assert_equal(arr.null_count, 0, "null_count == 0")


# =============================================================================
# T3: null-mixed INT64 (canonical empty + 'NULL' tokens).
# =============================================================================


def test_t3_null_mixed_int64() raises:
    """T3: 5 leading rows with 2 nulls (1 empty cell, 1 'NULL' token).

    Exercises:
      - the `null_positions` append path
      - the post-loop validity-bitmap-construction branch (only fires
        when `len(null_positions) > 0`).
      - per-token null-cascade match: empty `""` AND `NULL` are both
        in the default `CsvReadOptions.null_strings` set.
    """
    var buf = _build_padded_csv(
        header=String("v\n"),
        leading_rows=String(
            "1\n"
            "\n"          # empty -> null (token 0 in default null_strings)
            "3\n"
            "NULL\n"     # NULL -> null (token 1)
            "5\n"
        ),
        pad_row=String("0\n"),
    )
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), opts, n_workers=2
    )
    assert_true(rb.num_rows() >= 5, "at least 5 rows")
    var arr = rb.column_at(0).as_primitive[DType.int64]()
    assert_equal(arr.get(0), Int64(1), "row 0: 1")
    assert_equal(arr.get(2), Int64(3), "row 2: 3")
    assert_equal(arr.get(4), Int64(5), "row 4: 5")
    # Validity bitmap MUST be present because nulls were observed.
    assert_true(arr.validity, "validity bitmap present when nulls observed")
    assert_true(arr.is_null(1), "row 1 is null (empty cell)")
    assert_true(arr.is_null(3), "row 3 is null ('NULL' token)")
    assert_false(arr.is_null(0), "row 0 is valid")
    assert_false(arr.is_null(2), "row 2 is valid")
    assert_false(arr.is_null(4), "row 4 is valid")
    # null_count reflects observed nulls in the leading rows + any pad
    # rows that match the null cascade. Pad row is "0" which is NOT a
    # null token, so null_count >= 2 (at least the two leading nulls).
    assert_true(arr.null_count >= 2, "null_count >= 2 (the two leading nulls)")


# =============================================================================
# T4: overflow-boundary INT64 — 17-char SIMD ceiling crossing.
# =============================================================================


def test_t4_overflow_boundary_int64() raises:
    """T4: 19-digit value at row 0 forces the scalar `_try_parse_int64`
    fallback (SIMD `fast_parse_int64_simple` caps at 17 chars including
    sign).

    Per the reshape comment in `int_column_simd.mojo`: when the SIMD
    applicability gate REJECTS (cell length > 16 OR cell length > 17
    after sign), the slow path consults `is_null_cell` (must not
    incorrectly null this cell) then `_try_parse_int64` (must succeed
    on the 19-digit input).

    Verifies the scalar fallback path under the reshape is still
    correctly wired AND the bitmap-build branch is bypassed for non-null
    cells in the slow path.
    """
    # 9223372036854775807 = Int64.max (19 digits). Stays in range; the
    # SIMD gate rejects it (>16 chars after sign) so the scalar parser
    # handles it.
    var buf = _build_padded_csv(
        header=String("v\n"),
        leading_rows=String(
            "9223372036854775807\n"   # row 0: Int64.max (19 digits, scalar)
            "1\n"                     # row 1: short SIMD cell
            "100\n"                   # row 2: short SIMD cell
        ),
        pad_row=String("0\n"),
    )
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), opts, n_workers=2
    )
    assert_true(rb.num_rows() >= 3, "at least 3 rows")
    var arr = rb.column_at(0).as_primitive[DType.int64]()
    # Scalar fallback path on row 0.
    assert_equal(
        arr.get(0), Int64(9223372036854775807),
        "row 0: Int64.max via scalar fallback (19 digits)"
    )
    # SIMD fast path on rows 1, 2.
    assert_equal(arr.get(1), Int64(1), "row 1: 1 via SIMD")
    assert_equal(arr.get(2), Int64(100), "row 2: 100 via SIMD")
    # All-valid path (no nulls in any row, leading or pad).
    assert_false(arr.validity, "validity = None on all-valid path")
    assert_equal(arr.null_count, 0, "null_count == 0")


# =============================================================================
# Driver.
# =============================================================================


def main() raises:
    test_t1_single_row_int64_happy_path()
    test_t2_multi_row_int64_mix()
    test_t3_null_mixed_int64()
    test_t4_overflow_boundary_int64()
    print("test_csv_simd_int_column: 4/4 PASS")
