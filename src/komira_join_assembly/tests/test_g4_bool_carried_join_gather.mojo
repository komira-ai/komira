# =============================================================================
# BOOL through the join gather. `emit_gather_column_projected` needs a
# BIT-PACKED arm beside its STRING, BINARY and DICTIONARY arms.
# =============================================================================
#
# `compiler_join_assembly.emit_gather_column_projected` branches on
# STRING/BINARY (rebuild offsets) and on DICTIONARY (copy indices + share the
# dictionary), then falls to
#
#     var elem_size = element_size(at)
#     var data_buf  = OwnedAlignedBuffer(max(count * elem_size, 1))
#
# for everything else. BOOL's data buffer is `(n + 7) >> 3` bytes, so there
# is no per-row byte width to ask for: the oracle REFUSES, naming the type,
# and without a bit-packed arm every join that carries a bool column through
# the gather path raises
#
#     arrow_fixed_byte_width: ArrowType bool (type_id=1) has NO fixed
#     per-element byte width
#
# WHY THIS ONE IS LOAD-BEARING. It is the path the fused and chunked join
# assemblies fall back to: `compiler_join_fused` and `compiler_join_chunked`
# each compute `element_size(at)` per output column and stride raw bytes, and
# `_any_output_is_var_len` / `_any_schema_has_var_len` route a layout those
# paths cannot carry to `assemble_join_result`, i.e. to THIS function. So this
# arm has to exist, or routing BOOL here just moves the identical raise one
# frame deeper.
#
# THE `-1` SENTINEL IS PART OF THE CONTRACT, NOT AN EDGE CASE. On an outer
# join the unmatched side's index list holds `-1`, and every arm in this
# function must write a defined value at that row and clear the validity bit.
# A bit-packed arm that indexes the source at `-1` reads bit `src_off - 1`,
# which is a live bit of the PREVIOUS row on a windowed column.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_join_assembly.compiler_join_assembly import assemble_join_result


# -----------------------------------------------------------------------------
# Fixtures. `flag[i] = (i % 3 == 0)` — period 3 over 8-bit bytes, so the bit
# pattern differs in EVERY byte and a copy that lands one byte off, or that
# discards the sub-byte position of a non-aligned offset, cannot coincidentally
# agree.
# -----------------------------------------------------------------------------


def _expected_flag(i: Int) -> Bool:
    return i % 3 == 0


def _make_side(n: Int, id_name: String, flag_name: String) raises -> RecordBatch:
    """`{<id_name>: INT64 = i, <flag_name>: BOOL = i % 3 == 0}`."""
    var ids = List[Scalar[DType.int64]]()
    for i in range(n):
        ids.append(Scalar[DType.int64](i))
    var id_arr = PrimitiveArray[DType.int64].from_list(ids^)

    var flags = BooleanArray.allocate(n)
    for i in range(n):
        flags.set(i, _expected_flag(i))

    var sb = SchemaBuilder()
    sb.add_field(Field(id_name, ArrowType.INT64, False))
    sb.add_field(Field(flag_name, ArrowType.BOOL, False))

    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](id_arr^))
    rb.add_column(Column.from_boolean(flags))
    var schema = sb.build()
    return rb.build(schema^)


def _out_schema_4() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("lid", ArrowType.INT64, False))
    sb.add_field(Field("lflag", ArrowType.BOOL, False))
    sb.add_field(Field("rid", ArrowType.INT64, False))
    sb.add_field(Field("rflag", ArrowType.BOOL, True))
    var s = sb.build()
    return s^


def _read_flag(batch: RecordBatch, col: Int, row: Int) raises -> Bool:
    return batch.column_at(col).as_boolean().get(row)


def _read_id(batch: RecordBatch, col: Int, row: Int) raises -> Int:
    return Int(batch.column_at(col).as_primitive[DType.int64]().get(row))


# =============================================================================
# 1. The plain inner-join gather. BOTH sides carry a bool.
# =============================================================================


def test_join_gather_carries_bool_on_both_sides() raises:
    """37 source rows, 29 gathered in a NON-MONOTONE order.

    Order matters: a contiguous-run copy that happened to be right for an
    ascending index list is wrong here, so this leg cannot be satisfied by the
    `copy_bits_aligned_buffer` shape the contiguous sites use. The gather is
    indexed and needs `gather_bits_aligned_buffer`.
    """
    comptime N = 37
    var left = _make_side(N, "lid", "lflag")
    var right = _make_side(N, "rid", "rflag")

    var lidx = List[Int]()
    var ridx = List[Int]()
    for k in range(29):
        # Strided + wrapped, so the read order is not the write order.
        var src = (k * 11) % N
        lidx.append(src)
        ridx.append(src)

    var out = assemble_join_result(left, right, lidx, ridx, _out_schema_4())
    assert_equal(out.num_rows(), 29)
    assert_equal(out.num_columns(), 4)
    assert_equal(out.schema.field_arrow_type(1), ArrowType.BOOL)
    assert_equal(out.schema.field_arrow_type(3), ArrowType.BOOL)

    for r in range(29):
        var src = (r * 11) % N
        assert_equal(_read_id(out, 0, r), src)
        assert_equal(_read_id(out, 2, r), src)
        assert_equal(
            _read_flag(out, 1, r),
            _expected_flag(src),
            "left bool lost at out row " + String(r) + " (src " + String(src) + ")",
        )
        assert_equal(
            _read_flag(out, 3, r),
            _expected_flag(src),
            "right bool lost at out row " + String(r) + " (src " + String(src) + ")",
        )


# =============================================================================
# 2. The `-1` null sentinel — the outer-join shape.
# =============================================================================


def test_join_gather_bool_honours_the_null_sentinel() raises:
    """`right_nullable=True` with `-1` at every third output row.

    The value written at a `-1` row is unconstrained; the VALIDITY BIT is not.
    A bit-packed arm that feeds `-1` to the bit gather reads `src_off - 1` —
    a live bit of the row before the window — and, worse, still reports the
    row as valid.
    """
    comptime N = 24
    var left = _make_side(N, "lid", "lflag")
    var right = _make_side(N, "rid", "rflag")

    var lidx = List[Int]()
    var ridx = List[Int]()
    for r in range(N):
        lidx.append(r)
        ridx.append(-1 if r % 3 == 2 else r)

    var out = assemble_join_result(
        left, right, lidx, ridx, _out_schema_4(), False, True
    )
    assert_equal(out.num_rows(), N)

    ref rflag_col = out.column_at(3)
    assert_true(
        rflag_col._validity.__bool__(),
        "a -1 sentinel must produce a validity bitmap on the output column",
    )
    var rflag = rflag_col.as_boolean()
    for r in range(N):
        assert_equal(_read_flag(out, 1, r), _expected_flag(r))
        var valid = rflag_col._validity.value().test(r)
        if r % 3 == 2:
            assert_true(
                not valid,
                "row " + String(r) + " came from index -1 and must be NULL",
            )
        else:
            assert_true(valid, "row " + String(r) + " is not null")
            assert_equal(
                rflag.get(r),
                _expected_flag(r),
                "right bool lost at non-sentinel row " + String(r),
            )


# =============================================================================
# 3. COMPOSITION: the source column already carries `_offset > 0`.
# =============================================================================


def test_join_gather_over_an_already_offset_bool_column() raises:
    """`col._offset` and the gathered index are BOTH bit indices for BOOL.

    A fix that treats the index as bits but `_offset` as a byte address passes
    test 1 (whose `_offset` is 0) and fails here. The same leg is repeated at
    every site that carries BOOL on purpose — the composition is where these
    regressions live.
    """
    comptime N = 40
    var base = _make_side(N, "rid", "rflag")

    # BOOL is deliberately NOT on `supports_zero_copy_slice`'s whitelist, so
    # `Column.slice` refuses it; the window is built directly, which is exactly
    # the shape an offset-honoring consumer has to cope with.
    var sb = SchemaBuilder()
    sb.add_field(Field("rid", ArrowType.INT64, False))
    sb.add_field(Field("rflag", ArrowType.BOOL, False))
    var rb = RecordBatchBuilder()
    var id_win = base.column_at(0).share()
    id_win._offset = 3
    id_win._length = N - 3
    var flag_win = base.column_at(1).share()
    flag_win._offset = 3
    flag_win._length = N - 3
    rb.add_column(id_win^)
    rb.add_column(flag_win^)
    var schema = sb.build()
    var windowed = rb.build(schema^)
    assert_equal(windowed.num_rows(), N - 3)

    var left = _make_side(N - 3, "lid", "lflag")
    var lidx = List[Int]()
    var ridx = List[Int]()
    for r in range(N - 3):
        lidx.append(r)
        ridx.append(r)

    var out = assemble_join_result(left, windowed, lidx, ridx, _out_schema_4())
    assert_equal(out.num_rows(), N - 3)
    for r in range(N - 3):
        assert_equal(_read_id(out, 2, r), r + 3)
        assert_equal(
            _read_flag(out, 3, r),
            _expected_flag(r + 3),
            "windowed bool lost at out row " + String(r),
        )


# =============================================================================
# 4. ZERO ROWS. `element_size(at)` is evaluated BEFORE the `count *` multiply,
#    so an empty join over a bool column would be unbuildable too.
# =============================================================================


def test_join_gather_bool_with_zero_matched_rows() raises:
    comptime N = 16
    var left = _make_side(N, "lid", "lflag")
    var right = _make_side(N, "rid", "rflag")
    var lidx = List[Int]()
    var ridx = List[Int]()

    var out = assemble_join_result(left, right, lidx, ridx, _out_schema_4())
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), 4)
    assert_equal(out.schema.field_arrow_type(1), ArrowType.BOOL)
    assert_equal(out.schema.field_arrow_type(3), ArrowType.BOOL)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
