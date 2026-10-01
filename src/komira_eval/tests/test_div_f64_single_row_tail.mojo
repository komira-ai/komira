# =============================================================================
# Single-group AVG divide repro.
#
# A TPC-H Q1 single-group multi-agg query emitted a garbage denormal
# (~2.2e-314) instead of 20.0 for the AVG column when the hash-agg produced
# EXACTLY 1 group (a 1-row output batch). The AVG col is the
# `make_div_f64(__avg_sum, __avg_count)` BREAKER_NONE Project quotient.
#
# This test isolates the eval-layer F64 divide that the AVG-Project runs:
# drive `make_div_f64(col0, col1)` through ExpressionExecutor.
# `eval_to_list_f64_from_view` over an N-row F64 batch with an identity
# selection vector. N=1 is the pure-SIMD-tail / single-row case the triage
# hypothesis points at; N=2 covers the tail boundary; N=4 is the control
# (a clean full-vector multi-row case that must stay byte-identical).
#
# If the divide itself is the bug, N=1 reproduces the denormal here. If N=1
# divide returns the correct quotient, the bug is upstream in the HashAgg
# 1-group emit (the phys-agg column materialization), not the eval div, and
# the hypothesis must widen.
# =============================================================================

from std.testing import TestSuite, assert_equal
from std.collections.optional import Optional

from komira_core.arrow.schema import (
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
    Field,
)
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.arrow_types import ArrowType
from komira_core.io.heap_region import HeapRegion
from komira_core.collections.batch_view import BatchView, batch_view_over
from komira_eval.expression_executor import ExpressionExecutor
from komira_eval.runtime_expr import RuntimeExpr, make_col, make_div_f64
from komira_eval.selection_vector import RowSelectionVector


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _make_float64_col(values: List[Float64]) -> Column[HeapRegion]:
    """Create a float64 Column[HeapRegion] from a list of floats."""
    var n = len(values)
    var arr = PrimitiveArray[DType.float64].allocate(n)
    var ptr = arr._typed_ptr_mut()
    for i in range(n):
        ptr.store[width=1](i, Scalar[DType.float64](values[i]))
    return Column.from_primitive[DType.float64](arr)


def _build_two_f64_col_batch(
    numerators: List[Float64], denominators: List[Float64]
) raises -> RecordBatch:
    """Two-column F64 batch: col0='num', col1='den'."""
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()
    sb.add_field(Field("num", ArrowType.FLOAT64, False))
    sb.add_field(Field("den", ArrowType.FLOAT64, False))
    builder.add_column(_make_float64_col(numerators)^)
    builder.add_column(_make_float64_col(denominators)^)
    var schema = sb.build()
    return builder.build(schema^)


def _div_f64_quotients(
    numerators: List[Float64], denominators: List[Float64]
) raises -> List[Float64]:
    """Run `make_div_f64(col0, col1)` through the same column walker the
    AVG-Project's BREAKER_NONE segment uses (`eval_to_list_f64_from_view`
    over an identity selection vector) and return the quotients."""
    var batch = _build_two_f64_col_batch(numerators, denominators)
    var n = batch.num_rows()

    # Build the RuntimeExpr pool: div_f64(col0, col1).
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))  # slot 0 -> num
    pool.append(make_col(1))  # slot 1 -> den
    pool.append(make_div_f64(0, 1))  # slot 2 -> root
    var root_idx = 2

    var col_names = List[String]()
    col_names.append(String("num"))
    col_names.append(String("den"))

    var executor = ExpressionExecutor(pool^, root_idx, col_names^)

    # Identity selection vector [0, 1, ..., n-1] — exactly what the
    # BREAKER_NONE Project builds for an unfiltered input.
    var sel = RowSelectionVector(n if n > 0 else 1)
    var i = 0
    while i < n:
        sel.append(UInt32(i))
        i = i + 1

    var out = List[Scalar[DType.float64]](capacity=n)
    var bv = batch_view_over(batch)
    executor.eval_to_list_f64_from_view(bv, root_idx, sel, out)

    var quotients = List[Float64](capacity=len(out))
    for k in range(len(out)):
        quotients.append(Float64(out[k]))
    return quotients^


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_div_f64_single_row() raises:
    """1-row F64 divide: 60.0 / 3.0 == 20.0 (the failing AVG shape).

    This is the exact computation the AVG-Project performs for a 1-group
    HashAgg output. A pure-SIMD-tail (n_rows==1) batch must write the only
    output lane before it is read.
    """
    var nums: List[Float64] = [60.0]
    var dens: List[Float64] = [3.0]
    var q = _div_f64_quotients(nums, dens)
    assert_equal(len(q), 1)
    assert_equal(q[0], 20.0)


def test_div_f64_two_rows_tail() raises:
    """2-row F64 divide — covers the SIMD tail boundary (1 full lane + tail
    or pure tail depending on native width)."""
    var nums: List[Float64] = [60.0, 90.0]
    var dens: List[Float64] = [3.0, 2.0]
    var q = _div_f64_quotients(nums, dens)
    assert_equal(len(q), 2)
    assert_equal(q[0], 20.0)
    assert_equal(q[1], 45.0)


def test_div_f64_four_rows_control() raises:
    """4-row control — a clean multi-row case (mirrors the multi-group
    twin `test_multi_agg_sum_count_mean` that already PASSES)."""
    var nums: List[Float64] = [60.0, 90.0, 100.0, 12.0]
    var dens: List[Float64] = [3.0, 2.0, 4.0, 6.0]
    var q = _div_f64_quotients(nums, dens)
    assert_equal(len(q), 4)
    assert_equal(q[0], 20.0)
    assert_equal(q[1], 45.0)
    assert_equal(q[2], 25.0)
    assert_equal(q[3], 2.0)


# -----------------------------------------------------------------------------
# Agg-emit isolation: mirror finalize_hash_agg_single_byte_key_f64_val's
# 2-col (StringArray key, F64 agg) emit for exactly ONE group + read via
# `as_primitive[float64].get(0)` (the path the failing integration test
# uses). If the n_groups==1 denormal reproduces HERE, the bug is in the
# 1-element F64 column build / read, not in the live agg kernel.
# -----------------------------------------------------------------------------


def _emit_2col_and_read_f64(
    keys: List[String], agg_vals: List[Float64]
) raises -> List[Float64]:
    """Build (StringArray key, F64 agg) via from_typed_columns_2 — the exact
    finalize_hash_agg_single_byte_key_f64_val emit shape — then read the F64
    column back via `as_primitive[float64].get(i)`."""
    var key_arr = StringArray.from_strings(keys)
    var key_col = Column.from_string(key_arr^)

    var f64_scalars = List[Scalar[DType.float64]](capacity=len(agg_vals))
    for k in range(len(agg_vals)):
        f64_scalars.append(Scalar[DType.float64](agg_vals[k]))
    var agg_arr = PrimitiveArray[DType.float64].from_list(f64_scalars)
    var agg_col = Column.from_primitive[DType.float64](agg_arr^)

    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.STRING, False))
    sb.add_field(Field("agg", ArrowType.FLOAT64, False))
    var schema = sb.build()
    var batch = RecordBatch.from_typed_columns_2(schema^, key_col^, agg_col^)

    var out = List[Float64](capacity=batch.num_rows())
    var read_col = (batch._columns._unsafe_ptr() + 1)[].as_primitive[
        DType.float64
    ]()
    for i in range(batch.num_rows()):
        out.append(Float64(read_col.get(i)))
    return out^


def test_emit_2col_single_group_f64() raises:
    """ONE group: (StringArray ['X'], F64 [60.0]) round-trips to 60.0."""
    var keys: List[String] = ["X"]
    var vals: List[Float64] = [60.0]
    var got = _emit_2col_and_read_f64(keys, vals)
    assert_equal(len(got), 1)
    assert_equal(got[0], 60.0)


def test_emit_2col_three_groups_f64() raises:
    """THREE groups control (mirrors the PASSING multi-group emit)."""
    var keys: List[String] = ["a", "b", "c"]
    var vals: List[Float64] = [4.0, 6.0, 5.0]
    var got = _emit_2col_and_read_f64(keys, vals)
    assert_equal(len(got), 3)
    assert_equal(got[0], 4.0)
    assert_equal(got[1], 6.0)
    assert_equal(got[2], 5.0)


# -----------------------------------------------------------------------------
# Finalize-order isolation: mimic finalize_hash_agg_single_byte_key_f64_val's
# EXACT shape — List built from EMPTY (no capacity), value into a Scalar,
# from_list, from_typed_columns_2, RETURNED THROUGH Optional[RecordBatch],
# then the producer scope exits before the read. The denormal in the live
# path is ordering-dependent (reading the F64 col without first touching
# col0 surfaces it). This reproduces the producer-returns-then-reads shape.
# -----------------------------------------------------------------------------


def _finalize_like_emit(
    keys: List[String], agg_vals: List[Float64]
) raises -> Optional[RecordBatch]:
    """Mirror finalize_hash_agg_single_byte_key_f64_val: build keys_str +
    agg_vals lists from EMPTY (no capacity reserve, append-grow), emit the
    2-col batch, return through Optional[RecordBatch]."""
    var keys_str = List[String]()
    var f64_scalars = List[Scalar[DType.float64]]()
    for k in range(len(keys)):
        keys_str.append(keys[k])
        f64_scalars.append(Scalar[DType.float64](agg_vals[k]))

    var key_arr = StringArray.from_strings(keys_str)
    var key_col = Column.from_string(key_arr^)
    var agg_arr = PrimitiveArray[DType.float64].from_list(f64_scalars)
    var agg_col = Column.from_primitive[DType.float64](agg_arr^)

    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.STRING, False))
    sb.add_field(Field("agg", ArrowType.FLOAT64, False))
    var schema = sb.build()
    var batch = RecordBatch.from_typed_columns_2(schema^, key_col^, agg_col^)
    return Optional[RecordBatch](batch^)


def test_finalize_order_single_group_f64() raises:
    """ONE group through the finalize-order producer (Optional return) — read
    ONLY the F64 col (no col0 touch first), mirroring the failing assert."""
    var keys: List[String] = ["X"]
    var vals: List[Float64] = [60.0]
    var fin = _finalize_like_emit(keys, vals)
    var rb = fin.take()
    var agg_col = (rb._columns._unsafe_ptr() + 1)[].as_primitive[
        DType.float64
    ]()
    assert_equal(Float64(agg_col.get(0)), 60.0)


def _emit_direct_return(
    keys: List[String], agg_vals: List[Float64]
) raises -> RecordBatch:
    """Same emit but return RecordBatch DIRECTLY (no Optional wrap)."""
    var keys_str = List[String]()
    var f64_scalars = List[Scalar[DType.float64]]()
    for k in range(len(keys)):
        keys_str.append(keys[k])
        f64_scalars.append(Scalar[DType.float64](agg_vals[k]))
    var key_arr = StringArray.from_strings(keys_str)
    var key_col = Column.from_string(key_arr^)
    var agg_arr = PrimitiveArray[DType.float64].from_list(f64_scalars)
    var agg_col = Column.from_primitive[DType.float64](agg_arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.STRING, False))
    sb.add_field(Field("agg", ArrowType.FLOAT64, False))
    var schema = sb.build()
    return RecordBatch.from_typed_columns_2(schema^, key_col^, agg_col^)


def test_finalize_direct_return_single_group_f64() raises:
    """ONE group, DIRECT RecordBatch return (no Optional) — isolates whether
    the Optional wrap/take is required to surface the dangling buffer."""
    var keys: List[String] = ["X"]
    var vals: List[Float64] = [60.0]
    var rb = _emit_direct_return(keys, vals)
    var agg_col = (rb._columns._unsafe_ptr() + 1)[].as_primitive[
        DType.float64
    ]()
    assert_equal(Float64(agg_col.get(0)), 60.0)


def test_finalize_order_single_group_read_key_first() raises:
    """ONE group through the Optional producer — but read col0 (STRING key)
    BEFORE the F64 col. In the live SRP repro this ORDERING masked the
    denormal, confirming a premature-destruction / drop-reorder root cause."""
    var keys: List[String] = ["X"]
    var vals: List[Float64] = [60.0]
    var fin = _finalize_like_emit(keys, vals)
    var rb = fin.take()
    var key_arr = rb.column_as_string(0)
    _ = key_arr.get(0)
    var agg_col = (rb._columns._unsafe_ptr() + 1)[].as_primitive[
        DType.float64
    ]()
    assert_equal(Float64(agg_col.get(0)), 60.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
