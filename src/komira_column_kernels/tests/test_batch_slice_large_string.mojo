# =============================================================================
# `batch_slice` CARRIES A PROMOTED (large_string) COLUMN — BOTH HELPERS
# =============================================================================
#
# TARGET: `komira_column_kernels/batch_slice.mojo`'s LARGE_STRING /
# LARGE_BINARY arms.
#
# ⛔ WHY THESE ARMS EXIST. Without them the `else` reaches
# `compiler_helpers.element_size(at)`, which REFUSES LARGE_STRING by design (a
# var-len layout has no fixed per-element byte width). So every consumer of
# either helper refused a promoted column outright:
#
#     _slice_batch_first_n  ...  LIMIT, TopN (`sort_topn_sink`,
#                                `partition_topn_sink`,
#                                `stage_streaming_collect_sink`)
#     _slice_batch_range    ...  the intra-row-group morsel split, the
#                                paginated SDK result, `sort_frame_resolver`,
#                                and the PER-ROW-GROUP encode of all three
#                                multi-row-group Parquet writers
#
# ★★ THE COVERAGE HOLE THIS FILE CLOSES. `_slice_batch_range`'s wide arm is
# exercised indirectly by the multi-row-group leg of
# `test_parquet_large_string_write_roundtrip`. `_slice_batch_first_n`'s wide
# arm is reached by `ORDER BY ... LIMIT`, not by a write, so no Parquet leg
# touches it. Its sibling's test does not cover it — the two functions share
# a shape and share NO code.
#
# ⚠ A SURVIVAL-ONLY TEST WOULD BE NEARLY WORTHLESS HERE, AND THAT IS THE
# SPECIFIC HAZARD OF THIS ARM. The wide arm is a hand-duplicated copy of the
# narrow one at 8-byte offset stride. Every plausible defect in it — reading
# offsets at Int32 stride, forgetting to rebase to zero, dropping the source
# `_offset` — produces a slice that BUILDS and has the RIGHT ROW COUNT and
# wrong bytes. So every leg below reads values back, and §0 asserts the fixture
# is physically wide first: over a narrow column every one of these would pass
# while proving nothing.
#
# ⚠ THE ZERO-ROW LEG IS NOT A CORNER CASE. `sort_topn_sink` calls
# `_slice_batch_first_n(batch, 0)` on its empty paths (twice), so a refusal
# here would make even an EMPTY TopN result unbuildable over a promoted column.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_column_kernels.batch_slice import (
    _slice_batch_first_n,
    _slice_batch_range,
)


# -----------------------------------------------------------------------------
# Fixture: `id` INT64 + `s` LARGE_STRING.
#
# ⚠ THE VALUES ARE VARIABLE-LENGTH AND ROW-STAMPED ON PURPOSE. A fixture of
# uniform-width strings is reproduced correctly by ANY constant stride, so it
# would pass over a slice that had dropped the offsets buffer entirely; and a
# fixture whose values do not name their own row passes when two rows swap.
# `id` rides alongside so a row misalignment shows up in two independent
# columns rather than one.
# -----------------------------------------------------------------------------


def _expected_value(i: Int) -> String:
    var w = i % 4
    if w == 0:
        return String("r") + String(i)
    elif w == 1:
        return String("row-") + String(i) + String("-padded-out")
    elif w == 2:
        return String("v") + String(i) + String("!")
    return String("wide-value-row-") + String(i) + String("-tail")


def _values(n: Int) -> List[String]:
    var out = List[String]()
    for i in range(n):
        out.append(_expected_value(i))
    return out^


def _make_id_wide_batch(n: Int) raises -> RecordBatch:
    var ids = List[Scalar[DType.int64]]()
    for i in range(n):
        ids.append(Scalar[DType.int64](i))
    var id_arr = PrimitiveArray[DType.int64].from_list(ids^)

    var arr = LargeStringArray.from_strings(_values(n))

    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.LARGE_STRING, False))

    var builder = RecordBatchBuilder()
    builder.add_column(Column.from_primitive[DType.int64](id_arr^))
    builder.add_column(Column.from_large_string(arr))
    var schema = sb.build()
    return builder.build(schema^)


def _make_nullable_id_wide_batch(n: Int) raises -> RecordBatch:
    """Same, but every 3rd row of `s` is NULL.

    Validity is a SEPARATE bitmap from the offsets, so a slice can get one
    right and the other wrong. The value bytes are still written where null, so
    an implementation that conflated the two shows up as a wrong value rather
    than as a crash.
    """
    var ids = List[Scalar[DType.int64]]()
    for i in range(n):
        ids.append(Scalar[DType.int64](i))
    var id_arr = PrimitiveArray[DType.int64].from_list(ids^)

    var vals = List[String]()
    var valid = List[Bool]()
    for i in range(n):
        vals.append(_expected_value(i))
        valid.append(i % 3 != 2)
    var arr = LargeStringArray.from_strings_with_validity(vals, valid)

    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.LARGE_STRING, True))

    var builder = RecordBatchBuilder()
    builder.add_column(Column.from_primitive[DType.int64](id_arr^))
    builder.add_column(Column.from_large_string(arr))
    var schema = sb.build()
    return builder.build(schema^)


def _read_id(batch: RecordBatch, col: Int, row: Int) raises -> Int:
    var arr = batch.column_at(col).as_primitive[DType.int64]()
    return Int(arr.get(row))


def _assert_still_wide(batch: RecordBatch, col: Int, n: Int, site: String) raises:
    """The slice must PRESERVE the offset width, not narrow it.

    A slice that silently produced a `string` column would read back with the
    right values at test scale (a kilobyte of payload fits Int32 offsets
    trivially) and then wrap at 2 GiB — reintroducing exactly the defect the
    promotion exists to abolish. So the TAG and the offsets buffer STRIDE are
    asserted, not just the values.
    """
    assert_equal(
        batch.column_at(col).arrow_type,
        ArrowType.LARGE_STRING,
        site + ": the slice narrowed the column's tag",
    )
    ref off = batch.column_at(col)._offsets
    assert_true(off.__bool__(), site + ": sliced column has no offsets buffer")
    assert_equal(
        Int(off.value().len()),
        (n + 1) * 8,
        site + ": the sliced offsets buffer is not (n+1)*8 bytes — the arm"
        " wrote Int32 offsets under a LARGE_STRING tag, which is a buffer the"
        " tag lies about",
    )
    if n > 0:
        assert_equal(
            Int(off.value().get_typed[Int64](0)),
            0,
            site + ": offsets[0] is not 0 — the slice did not REBASE, so every"
            " value in it is read from the wrong start",
        )


# =============================================================================
# §0 — THE PRECONDITION. Assert the SUBJECT before asserting anything through
#      it, or every leg below exercises the narrow arm and passes vacuously.
# =============================================================================


def test_the_fixture_is_physically_wide() raises:
    comptime N = 24
    var b = _make_id_wide_batch(N)
    _assert_still_wide(b, 1, N, "fixture")
    assert_equal(
        b.schema.field_arrow_type(1),
        ArrowType.LARGE_STRING,
        "the fixture's Schema disagrees with its Column",
    )


# =============================================================================
# §1 — `_slice_batch_first_n` — the arm no write path reaches.
#      `ORDER BY ... LIMIT k` over a promoted column.
# =============================================================================


def test_slice_batch_first_n_carries_a_large_string_column() raises:
    """`LIMIT 21` over a table carrying a promoted string column."""
    comptime N = 40
    comptime K = 21
    var batch = _make_id_wide_batch(N)

    var out = _slice_batch_first_n(batch, K)
    assert_equal(out.num_rows(), K)
    assert_equal(out.num_columns(), 2)
    _assert_still_wide(out, 1, K, "_slice_batch_first_n")

    var arr = out.column_as_large_string(1)
    for r in range(K):
        assert_equal(_read_id(out, 0, r), r)
        assert_equal(
            arr.get(r),
            _expected_value(r),
            "_slice_batch_first_n lost a carried large_string value at row "
            + String(r),
        )


def test_slice_batch_first_n_zero_rows_with_large_string_column() raises:
    """`_slice_batch_first_n(batch, 0)` — the EMPTY TopN path.

    `sort_topn_sink` calls exactly this on two of its empty legs, so a refusal
    here would make even a zero-row TopN result unbuildable over a promoted column.
    """
    var batch = _make_id_wide_batch(16)
    var out = _slice_batch_first_n(batch, 0)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), 2)
    _assert_still_wide(out, 1, 0, "_slice_batch_first_n(0)")


def test_slice_batch_first_n_whole_batch_with_large_string_column() raises:
    """`n == length`: the offsets walk reads `offsets[n]`, the LAST entry.

    An arm that sized its offsets buffer at `n * 8` instead of `(n + 1) * 8`
    passes every k < n leg and overruns here.
    """
    comptime N = 17
    var batch = _make_id_wide_batch(N)
    var out = _slice_batch_first_n(batch, N)
    assert_equal(out.num_rows(), N)
    _assert_still_wide(out, 1, N, "_slice_batch_first_n(all)")
    var arr = out.column_as_large_string(1)
    for r in range(N):
        assert_equal(arr.get(r), _expected_value(r))


def test_slice_batch_first_n_carries_a_nullable_large_string_column() raises:
    """Nullable: validity and offsets are two independent buffers."""
    comptime N = 30
    comptime K = 19
    var batch = _make_nullable_id_wide_batch(N)

    var out = _slice_batch_first_n(batch, K)
    assert_equal(out.num_rows(), K)
    _assert_still_wide(out, 1, K, "_slice_batch_first_n(nullable)")

    var arr = out.column_as_large_string(1)
    for r in range(K):
        assert_equal(_read_id(out, 0, r), r)
        assert_equal(
            arr.is_null(r),
            r % 3 == 2,
            "_slice_batch_first_n mis-copied large_string validity at row "
            + String(r),
        )
        if r % 3 != 2:
            assert_equal(
                arr.get(r),
                _expected_value(r),
                "_slice_batch_first_n mis-copied a large_string value at row "
                + String(r),
            )


# =============================================================================
# §2 — `_slice_batch_range`. Otherwise covered only INDIRECTLY (by the
#      multi-row-group Parquet write leg). A direct test states what that leg
#      only implies.
# =============================================================================


def test_slice_batch_range_carries_a_large_string_column() raises:
    """A range starting at a NON-ZERO row.

    `start = 5` is the whole point: the arm reads
    `offsets[_offset + r]` and must REBASE by `offsets[_offset]`. An arm that
    copied the data buffer from byte 0, or that forgot the rebase, returns
    row 0's bytes for row 0 of the slice and drifts from there — right row
    count, wrong values.
    """
    comptime N = 40
    var batch = _make_id_wide_batch(N)

    var out = _slice_batch_range(batch, 5, 27)
    assert_equal(out.num_rows(), 27)
    assert_equal(out.num_columns(), 2)
    _assert_still_wide(out, 1, 27, "_slice_batch_range")

    var arr = out.column_as_large_string(1)
    for r in range(27):
        var src = r + 5
        assert_equal(_read_id(out, 0, r), src)
        assert_equal(
            arr.get(r),
            _expected_value(src),
            "_slice_batch_range mis-rebased a large_string value at row "
            + String(r),
        )


def test_slice_batch_range_zero_length_with_large_string_column() raises:
    """`_slice_batch_range(batch, 0, 0)` — `paginated_result`'s empty page."""
    var batch = _make_id_wide_batch(16)
    var out = _slice_batch_range(batch, 0, 0)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), 2)
    _assert_still_wide(out, 1, 0, "_slice_batch_range(0,0)")


def test_slice_batch_range_carries_a_nullable_large_string_column() raises:
    comptime N = 30
    var batch = _make_nullable_id_wide_batch(N)

    var out = _slice_batch_range(batch, 7, 14)
    assert_equal(out.num_rows(), 14)
    _assert_still_wide(out, 1, 14, "_slice_batch_range(nullable)")

    var arr = out.column_as_large_string(1)
    for r in range(14):
        var src = r + 7
        assert_equal(_read_id(out, 0, r), src)
        assert_equal(
            arr.is_null(r),
            src % 3 == 2,
            "_slice_batch_range mis-copied large_string validity at row "
            + String(r),
        )
        if src % 3 != 2:
            assert_equal(arr.get(r), _expected_value(src))


# =============================================================================
# §3 — THE COMPOSITION. Range-slice, then first-n over the RESULT.
#
# This is the real shape of `ORDER BY ... LIMIT` over a spilled / chunked
# input: the second slice reads offsets the FIRST slice rebased. A rebase that
# is wrong by a constant survives §1 and §2 individually (each measures against
# its own source) and diverges here.
# =============================================================================


def test_range_then_first_n_composes_over_a_large_string_column() raises:
    comptime N = 40
    var batch = _make_id_wide_batch(N)

    var mid = _slice_batch_range(batch, 11, 20)
    var out = _slice_batch_first_n(mid, 9)
    assert_equal(out.num_rows(), 9)
    _assert_still_wide(out, 1, 9, "range->first_n")

    var arr = out.column_as_large_string(1)
    for r in range(9):
        var src = r + 11
        assert_equal(_read_id(out, 0, r), src)
        assert_equal(
            arr.get(r),
            _expected_value(src),
            "range->first_n lost a large_string value at row " + String(r),
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_fixture_is_physically_wide]()
    suite.test[test_slice_batch_first_n_carries_a_large_string_column]()
    suite.test[test_slice_batch_first_n_zero_rows_with_large_string_column]()
    suite.test[test_slice_batch_first_n_whole_batch_with_large_string_column]()
    suite.test[
        test_slice_batch_first_n_carries_a_nullable_large_string_column
    ]()
    suite.test[test_slice_batch_range_carries_a_large_string_column]()
    suite.test[test_slice_batch_range_zero_length_with_large_string_column]()
    suite.test[test_slice_batch_range_carries_a_nullable_large_string_column]()
    suite.test[test_range_then_first_n_composes_over_a_large_string_column]()
    suite^.run()
