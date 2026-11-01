# =============================================================================
# test_binary_fn_kernel.mojo — EXECUTOR-KERNEL-COMPTIME Phase 1.a regression
# =============================================================================
#
# Exercises the Phase 1.a deliverables (synthesis memo
# an internal agent note):
#
#   - `AddI64.eval_chunk` correctness over {empty, 1-row, 2048-row,
#     4097-row} batches. The 2048 is the morsel chunk size; 4097 forces
#     a ragged tail at every SIMD width.
#   - PROPAGATE null handling at the operator boundary
#     (`BinaryFnOp[AddI64]` over a nullable input column).
#   - `BinaryFnOp[AddI64]` end-to-end through one Morsel.execute call.
#   - Byte-identical results between `BinaryFnOp[AddI64]` (the new
#     comptime fast path) and the existing `eval_add` SIMD primitive
#     (the established gold reference).
#   - Distinct monomorphizations: `BinaryFnOp[AddI64]` and
#     `BinaryFnOp[AddF64]` are different types AND
#     `KERNEL_ID(AddI64) != KERNEL_ID(AddF64)` — the comptime channel
#     specializes per `F`.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_almost_equal,
    assert_false,
)

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, Schema
from komira_morsel.morsel import Morsel
from komira_operator_api.binary_fn_op import BinaryFnOp
from komira_kernels.builtin_binary_fns import (
    AddI64,
    SubI64,
    MulI64,
    AddF64,
    SubF64,
    MulF64,
)
from komira_kernels.binary_fn import BinaryFn
from komira_column_kernels.arithmetic import eval_add


# =============================================================================
# Fixture helpers.
# =============================================================================


def _make_lr_i64_batch(n: Int) raises -> RecordBatch:
    """Build a 2-col Int64 batch with n rows.
    L[i] = i, R[i] = 10 * i (so L+R = 11 * i).
    """
    var L = PrimitiveArray[DType.int64].allocate(n)
    var R = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        L.set(i, Int64(i))
        R.set(i, Int64(10 * i))
    var schema = Schema.from_fields_2(
        Field("l", ArrowType.INT64, False),
        Field("r", ArrowType.INT64, False),
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_primitive[DType.int64](L^),
        Column.from_primitive[DType.int64](R^),
    )


def _make_lr_f64_batch(n: Int) raises -> RecordBatch:
    """Same shape, Float64 cells. L[i] = 0.5 * i, R[i] = 2.0 * i."""
    var L = PrimitiveArray[DType.float64].allocate(n)
    var R = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        L.set(i, Float64(0.5 * Float64(i)))
        R.set(i, Float64(2.0 * Float64(i)))
    var schema = Schema.from_fields_2(
        Field("lf", ArrowType.FLOAT64, False),
        Field("rf", ArrowType.FLOAT64, False),
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_primitive[DType.float64](L^),
        Column.from_primitive[DType.float64](R^),
    )


def _make_lr_i64_nullable(n: Int, null_lhs: Int, null_rhs: Int) raises -> RecordBatch:
    """2-col nullable Int64 batch. Rows `null_lhs` (lhs is null) and
    `null_rhs` (rhs is null) are nulled out; all others valid.
    """
    var L = PrimitiveArray[DType.int64].allocate_nullable(n)
    var R = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        L.set(i, Int64(i))
        R.set(i, Int64(10 * i))
    if 0 <= null_lhs < n:
        L._set_null(null_lhs)
        L.null_count = L.null_count + 1
    if 0 <= null_rhs < n:
        R._set_null(null_rhs)
        R.null_count = R.null_count + 1
    var schema = Schema.from_fields_2(
        Field("l", ArrowType.INT64, True),
        Field("r", ArrowType.INT64, True),
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_primitive[DType.int64](L^),
        Column.from_primitive[DType.int64](R^),
    )


# =============================================================================
# (a) AddI64.eval_chunk over varied chunk sizes — empty, 1, 2048, 4097.
# =============================================================================
#
# 2048 = a typical morsel chunk; 4097 forces ragged tail = 1 lane at width 4
# and width 8 alike. 1-row exercises the lane-by-lane tail path only.
# Empty exercises the "no work" path (must not crash).


def _check_add_i64(n: Int) raises:
    var lhs = PrimitiveArray[DType.int64].allocate(n)
    var rhs = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        lhs.set(i, Int64(i + 1))     # 1, 2, 3, ...
        rhs.set(i, Int64(2 * i + 3)) # 3, 5, 7, ...  (lhs + rhs = 3i + 4)
    var out = PrimitiveArray[DType.int64].allocate(n)
    var f = AddI64()
    f.eval_chunk(lhs, rhs, out)
    for i in range(n):
        var expected = Int64(3 * i + 4)
        assert_equal(out.get(i), expected, "AddI64 lane i (n=" + String(n) + ")")


def test_add_i64_empty() raises:
    _check_add_i64(0)


def test_add_i64_one_row() raises:
    _check_add_i64(1)


def test_add_i64_2048_rows() raises:
    _check_add_i64(2048)


def test_add_i64_4097_rows_ragged_tail() raises:
    _check_add_i64(4097)


# =============================================================================
# (b) Null propagation through BinaryFnOp[AddI64] — row null iff either side null.
# =============================================================================


def test_add_i64_op_null_propagate() raises:
    # 5 rows; row 1 lhs is null; row 3 rhs is null.
    # L = [0, NULL, 2, 3, 4]; R = [0, 10, 20, NULL, 40].
    # PROPAGATE result: [0, NULL, 22, NULL, 44].
    var rb = _make_lr_i64_nullable(5, 1, 3)
    var m = Morsel(rb^, 0, 0)
    var op = BinaryFnOp[AddI64](AddI64(), "l", "r", "sum")
    var _r = op.execute(m)
    assert_equal(m.batch.num_columns(), 3, "AddI64 appended one output column")
    assert_equal(m.batch.num_rows(), 5, "row count preserved")
    assert_equal(m.batch.schema.field_name(2), "sum", "output column name")
    var s = m.batch.column_at(2).as_primitive[DType.int64]()
    # Row-by-row validation.
    assert_false(s.is_null(0), "row 0 not null")
    assert_equal(s.get(0), Int64(0))
    assert_true(s.is_null(1), "row 1 null (lhs null)")
    assert_false(s.is_null(2), "row 2 not null")
    assert_equal(s.get(2), Int64(22))
    assert_true(s.is_null(3), "row 3 null (rhs null)")
    assert_false(s.is_null(4), "row 4 not null")
    assert_equal(s.get(4), Int64(44))


# =============================================================================
# (c) BinaryFnOp[AddI64] end-to-end through Morsel.execute (no nulls).
# =============================================================================


def test_add_i64_op_end_to_end() raises:
    var rb = _make_lr_i64_batch(64)
    var m = Morsel(rb^, 0, 0)
    var op = BinaryFnOp[AddI64](AddI64(), "l", "r", "sum")
    var _r = op.execute(m)
    assert_equal(m.batch.num_columns(), 3, "AddI64 appended one output column")
    assert_equal(m.batch.num_rows(), 64, "1:1 row count")
    assert_equal(m.batch.schema.field_name(2), "sum")
    var s = m.batch.column_at(2).as_primitive[DType.int64]()
    for i in range(64):
        assert_equal(s.get(i), Int64(11 * i), "lane i (n=64)")


# =============================================================================
# (d) Byte-identical to eval_add (the existing SIMD primitive).
#
# The motivating CORRECTNESS GATE: the comptime fast path must not change
# semantics vs the existing path. Compare every lane of AddI64.eval_chunk
# against eval_add on the same 4097-row input — if anything diverges, this
# fails loudly.
# =============================================================================


def test_add_i64_byte_identical_to_eval_add() raises:
    var n = 4097
    var lhs1 = PrimitiveArray[DType.int64].allocate(n)
    var rhs1 = PrimitiveArray[DType.int64].allocate(n)
    var lhs2 = PrimitiveArray[DType.int64].allocate(n)
    var rhs2 = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        # Mix of magnitudes incl. negatives.
        var l = Int64(i - 2000)
        var r = Int64((i * 7) % 1024 - 512)
        lhs1.set(i, l)
        rhs1.set(i, r)
        lhs2.set(i, l)
        rhs2.set(i, r)
    # Path A: comptime fast path (AddI64).
    var out_a = PrimitiveArray[DType.int64].allocate(n)
    var f = AddI64()
    f.eval_chunk(lhs1, rhs1, out_a)
    # Path B: existing eval_add primitive.
    var out_b = eval_add[DType.int64](lhs2, rhs2)
    for i in range(n):
        assert_equal(out_a.get(i), out_b.get(i), "lane i diverges (n=" + String(n) + ")")


# =============================================================================
# (e) Distinct monomorphizations: AddI64 vs AddF64 — comptime channel
#     specializes per kernel type.
# =============================================================================


def _assert_kernel_ids_differ[F: BinaryFn, G: BinaryFn]() raises:
    # KERNEL_ID is a comptime UInt32 — read off the type, not an instance.
    assert_true(
        F.KERNEL_ID != G.KERNEL_ID,
        "F and G have distinct KERNEL_IDs",
    )


def test_add_i64_vs_add_f64_distinct_monomorphizations() raises:
    # Compile-time check: AddI64.TA != AddF64.TA — Mojo refuses the type
    # mismatch if these collapsed. The kernel-ID assertion is the
    # one we can actually evaluate at test time.
    _assert_kernel_ids_differ[AddI64, AddF64]()
    _assert_kernel_ids_differ[AddI64, SubI64]()
    _assert_kernel_ids_differ[AddI64, MulI64]()
    _assert_kernel_ids_differ[AddF64, SubF64]()
    _assert_kernel_ids_differ[AddF64, MulF64]()
    # And just for completeness — KERNEL_ID is a comptime field, so
    # the dispatcher cannot confuse two cells.
    assert_equal(Int(AddI64.OP_TAG), 0, "AddI64 OP_TAG = BIN_ADD = 0")
    assert_equal(Int(SubI64.OP_TAG), 1, "SubI64 OP_TAG = BIN_SUB = 1")
    assert_equal(Int(MulI64.OP_TAG), 2, "MulI64 OP_TAG = BIN_MUL = 2")


# =============================================================================
# Float64 sanity — Sub / Mul kernels also reach the right answer.
# =============================================================================


def test_sub_i64_basic() raises:
    var n = 32
    var lhs = PrimitiveArray[DType.int64].allocate(n)
    var rhs = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        lhs.set(i, Int64(100 + i))
        rhs.set(i, Int64(i))
    var out = PrimitiveArray[DType.int64].allocate(n)
    var f = SubI64()
    f.eval_chunk(lhs, rhs, out)
    for i in range(n):
        assert_equal(out.get(i), Int64(100), "SubI64 lane " + String(i))


def test_mul_f64_basic() raises:
    var n = 33
    var lhs = PrimitiveArray[DType.float64].allocate(n)
    var rhs = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        lhs.set(i, Float64(0.5 * Float64(i)))
        rhs.set(i, Float64(4.0))
    var out = PrimitiveArray[DType.float64].allocate(n)
    var f = MulF64()
    f.eval_chunk(lhs, rhs, out)
    for i in range(n):
        assert_almost_equal(out.get(i), Float64(2.0 * Float64(i)), atol=1e-12)


def test_add_f64_op_end_to_end() raises:
    var rb = _make_lr_f64_batch(128)
    var m = Morsel(rb^, 0, 0)
    var op = BinaryFnOp[AddF64](AddF64(), "lf", "rf", "fsum")
    var _r = op.execute(m)
    assert_equal(m.batch.num_columns(), 3)
    assert_equal(m.batch.num_rows(), 128)
    var s = m.batch.column_at(2).as_primitive[DType.float64]()
    for i in range(128):
        assert_almost_equal(s.get(i), Float64(2.5 * Float64(i)), atol=1e-12)


def main() raises:
    var suite = TestSuite()
    suite.test[test_add_i64_empty]()
    suite.test[test_add_i64_one_row]()
    suite.test[test_add_i64_2048_rows]()
    suite.test[test_add_i64_4097_rows_ragged_tail]()
    suite.test[test_add_i64_op_null_propagate]()
    suite.test[test_add_i64_op_end_to_end]()
    suite.test[test_add_i64_byte_identical_to_eval_add]()
    suite.test[test_add_i64_vs_add_f64_distinct_monomorphizations]()
    suite.test[test_sub_i64_basic]()
    suite.test[test_mul_f64_basic]()
    suite.test[test_add_f64_op_end_to_end]()
    suite^.run()
