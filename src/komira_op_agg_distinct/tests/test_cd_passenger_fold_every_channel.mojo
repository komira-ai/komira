# =============================================================================
# MIXEDFUSE-FXCOL — the passenger fold, every input channel x every aggregate,
# against a linear-scan oracle, bit for bit
# =============================================================================
#
# WHAT THIS PINS. `WorkerCDState.consume_batch[has_fixed=True]` folds the
# non-distinct ("fixed") aggregates of a mixed COUNT(DISTINCT) node against the
# group id the COUNT(DISTINCT) lane resolves. FXCOL (2026-09-25) moved that fold
# out of the per-row loop into `_fx_fold_batch`, one aggregate at a time over
# the whole batch. That is a COST change and must be a VALUE no-op, so this file
# asserts the three fields of every (fixed aggregate, group) cell — `n`,
# `i_acc`, `f_acc` — against numbers recomputed from the RAW fixture lists by a
# linear scan, with EXACT equality (FLOAT64 included: the oracle adds each
# group's values in ascending row order, which is the order both the per-row
# fold and the column-major fold visit a cell's rows in).
#
# WHY A SECOND FILE. `komira_engine_dispatch`'s
# `test_agg_mixed_fuse_byte_equiv.mojo` drives the fuse end to end, but its
# fixture feeds only INT64 and FLOAT64 inputs and folds MIN/MAX over INT64
# only. The fold has FOUR input channels (`FXC_I64`, `FXC_I32`, `FXC_F64`,
# `FXC_F32`) and every one of them is a separate load at its own width; a
# channel no fixture reaches is a channel a refactor can break silently. This
# file reaches all four, with NULLs on the narrow ones, a bare COUNT(*) and a
# COUNT(col) over a nullable column, MIN/MAX over both families, and a group
# that first appears in the LAST batch (so its cells come from the per-batch
# `fx_cells` top-up plus `_append_group`'s lockstep growth, not from batch 1).
#
# DEFECTS THIS FILE IS BUILT TO CATCH:
#   * read an INT32 input at the 8-byte stride            -> SUM/MAX(c32)
#     (RUN 2026-09-25 against the column-major fold: RED at the i_acc
#     assertion; the same file is GREEN on the pre-FXCOL per-row fold, which
#     is what makes it a characterisation of the old answer, not of the new)
#   * seed MIN/MAX from 0 instead of the first value      -> MIN(c64)/MAX(c64),
#     whose values are all far from 0 in both directions
#   * skip the NULL check on a nullable FLOAT32 input     -> MIN/SUM(f32), n
#   * fold a FLOAT64 SUM in any order but ascending rows  -> AVG(f64) f_acc
#
# =============================================================================

from std.collections import List
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_plan_expr.agg_expr import (
    AGG_COUNT, AGG_MAX, AGG_MEAN, AGG_MIN, AGG_SUM,
)

from komira_op_agg_distinct.streaming_agg_count_distinct import (
    WorkerCDState,
)


comptime _N_BATCHES: Int = 3
comptime _ROWS: Int = 37


def _key(b: Int, r: Int) -> Int64:
    """Keys 0..4 in every batch; key 11 appears ONLY in the last batch."""
    if b == _N_BATCHES - 1 and r % 7 == 3:
        return Int64(11)
    return Int64((r * 3 + b) % 5)


def _c32(b: Int, r: Int) -> Int32:
    return Int32(((r * 37 + b * 11) % 53) - 26)


def _c32_null(b: Int, r: Int) -> Bool:
    return (r + b) % 6 == 0


def _c64(b: Int, r: Int) -> Int64:
    return Int64(((r * 7919 + b * 104729) % 100003) - 50001) * Int64(1000003)


def _f32(b: Int, r: Int) -> Float32:
    return Float32(((r * 13 + b * 5) % 29) - 14) * Float32(0.375)


def _f32_null(b: Int, r: Int) -> Bool:
    return (r * 5 + b) % 7 == 1


def _f64(b: Int, r: Int) -> Float64:
    # Deliberately NOT exactly representable in a short sum, so that a changed
    # ADDITION ORDER changes the bits.
    return (
        Float64(r) * Float64(0.1)
        + Float64(b) * Float64(0.37)
        - Float64(1.7) / Float64(r + 3)
    )


def _f64_null(b: Int, r: Int) -> Bool:
    return (r + 2 * b) % 9 == 4


def _batch(b: Int) raises -> RecordBatch:
    var karr = PrimitiveArray[DType.int64].allocate(_ROWS)
    var varr = PrimitiveArray[DType.int64].allocate(_ROWS)
    var a32 = PrimitiveArray[DType.int32].allocate_nullable(_ROWS)
    var a64 = PrimitiveArray[DType.int64].allocate(_ROWS)
    var af32 = PrimitiveArray[DType.float32].allocate_nullable(_ROWS)
    var af64 = PrimitiveArray[DType.float64].allocate_nullable(_ROWS)
    for r in range(_ROWS):
        karr.store[1](r, Scalar[DType.int64](_key(b, r)))
        varr.store[1](r, Scalar[DType.int64](Int64(r % 4)))
        a32.store[1](r, Scalar[DType.int32](_c32(b, r)))
        a64.store[1](r, Scalar[DType.int64](_c64(b, r)))
        af32.store[1](r, Scalar[DType.float32](_f32(b, r)))
        af64.store[1](r, Scalar[DType.float64](_f64(b, r)))
    # Values FIRST, then the nulls: a store marks its index VALID.
    for r in range(_ROWS):
        if _c32_null(b, r):
            a32._set_null(r)
        if _f32_null(b, r):
            af32._set_null(r)
        if _f64_null(b, r):
            af64._set_null(r)
    var rbb = RecordBatchBuilder.with_capacity(6)
    rbb.add_column(Column.from_primitive[DType.int64](karr^))
    rbb.add_column(Column.from_primitive[DType.int64](varr^))
    rbb.add_column(Column.from_primitive[DType.int32](a32^))
    rbb.add_column(Column.from_primitive[DType.int64](a64^))
    rbb.add_column(Column.from_primitive[DType.float32](af32^))
    rbb.add_column(Column.from_primitive[DType.float64](af64^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    sb.add_field(Field("c32", ArrowType.INT32, True))
    sb.add_field(Field("c64", ArrowType.INT64, False))
    sb.add_field(Field("f32", ArrowType.FLOAT32, True))
    sb.add_field(Field("f64", ArrowType.FLOAT64, True))
    return rbb.build(sb.build())


# The fixed slots: (function, input column index or -1, int family?).
def _funcs() -> List[UInt8]:
    return [
        AGG_COUNT,  # 0: COUNT(*)
        AGG_COUNT,  # 1: COUNT(c32)          nullable
        AGG_SUM,    # 2: SUM(c32)            I32, nullable
        AGG_MIN,    # 3: MIN(c64)            I64
        AGG_MAX,    # 4: MAX(c32)            I32, nullable
        AGG_MEAN,   # 5: AVG(f64)            F64, nullable
        AGG_MIN,    # 6: MIN(f32)            F32, nullable
        AGG_MAX,    # 7: MAX(f64)            F64, nullable
        AGG_SUM,    # 8: SUM(f32)            F32, nullable
        AGG_MAX,    # 9: MAX(c64)            I64
    ]


def _cols() -> List[Int]:
    return [-1, 2, 2, 3, 2, 5, 4, 5, 4, 3]


def _is_int() -> List[Bool]:
    return [True, True, True, True, True, False, False, False, False, True]


def _input_null(col: Int, b: Int, r: Int) -> Bool:
    if col == 2:
        return _c32_null(b, r)
    if col == 4:
        return _f32_null(b, r)
    if col == 5:
        return _f64_null(b, r)
    return False


def _input_int(col: Int, b: Int, r: Int) -> Int64:
    if col == 2:
        return Int64(_c32(b, r))
    return _c64(b, r)


def _input_float(col: Int, b: Int, r: Int) -> Float64:
    if col == 4:
        return Float64(_f32(b, r))
    return _f64(b, r)


struct _Cell(Copyable, Movable):
    var i_acc: Int64
    var f_acc: Float64
    var n: Int64

    def __init__(out self):
        self.i_acc = Int64(0)
        self.f_acc = Float64(0.0)
        self.n = Int64(0)


def _oracle(f: Int, key: Int64) -> _Cell:
    """LINEAR SCAN over the raw fixture, rows in (batch, row) order — the
    serial fold's semantics, restated with no kernel and no hash table."""
    var funcs = _funcs()
    var cols = _cols()
    var is_int = _is_int()
    var c = _Cell()
    var afn = funcs[f]
    var col = cols[f]
    for b in range(_N_BATCHES):
        for r in range(_ROWS):
            if _key(b, r) != key:
                continue
            if col < 0:
                c.n += 1
                continue
            if _input_null(col, b, r):
                continue
            c.n += 1
            if afn == AGG_COUNT:
                continue
            if is_int[f]:
                var iv = _input_int(col, b, r)
                if afn == AGG_SUM or afn == AGG_MEAN:
                    c.i_acc += iv
                elif afn == AGG_MIN:
                    if c.n == 1 or iv < c.i_acc:
                        c.i_acc = iv
                else:
                    if c.n == 1 or iv > c.i_acc:
                        c.i_acc = iv
            else:
                var fv = _input_float(col, b, r)
                if afn == AGG_SUM or afn == AGG_MEAN:
                    c.f_acc += fv
                elif afn == AGG_MIN:
                    if c.n == 1 or fv < c.f_acc:
                        c.f_acc = fv
                else:
                    if c.n == 1 or fv > c.f_acc:
                        c.f_acc = fv
    return c^


def _assert_cells_match_oracle(imm st: WorkerCDState, imm arm: String) raises:
    var nf = len(_funcs())
    for g in range(len(st.group_keys)):
        var key = Int64(st.group_keys[g])
        for f in range(nf):
            var want = _oracle(f, key)
            ref got = st.fx_cells[f][g]
            var where = (
                arm + " slot " + String(f) + " key " + String(key) + ": "
            )
            assert_equal(got.n, want.n, where + "n")
            assert_equal(got.i_acc, want.i_acc, where + "i_acc")
            assert_true(
                got.f_acc == want.f_acc,
                where + "f_acc " + String(got.f_acc) + " != oracle "
                + String(want.f_acc),
            )


def _consume_all(fxcol_on: Bool = True) raises -> WorkerCDState:
    var st = WorkerCDState(1)
    st.fxcol_on = fxcol_on
    st.configure_fixed(_funcs(), _is_int())
    var val_idx = List[Int]()
    val_idx.append(1)
    for b in range(_N_BATCHES):
        var batch = _batch(b)
        st.consume_batch[has_fixed=True](batch, 0, val_idx, _cols())
        _ = batch^
    return st^


def test_the_passenger_lane_ran_on_every_batch() raises:
    """Vacuity guard: every assertion below is about the passenger fold, so it
    must actually have run, once per batch."""
    var st = _consume_all()
    assert_equal(st.stat_fx_batches, _N_BATCHES)
    assert_equal(st.num_fixed, len(_funcs()))


def test_the_late_group_exists_and_every_cell_space_covers_it() raises:
    """Key 11 first appears in the LAST batch. Its cells are created by the
    lockstep growth after batches 1-2 have already sized `fx_cells`."""
    var st = _consume_all()
    var found = False
    for g in range(len(st.group_keys)):
        if st.group_keys[g] == 11:
            found = True
    assert_true(found, "the late key 11 never became a group")
    for f in range(len(_funcs())):
        assert_equal(len(st.fx_cells[f]), len(st.group_keys))


def test_every_cell_matches_the_linear_scan_oracle_bit_for_bit() raises:
    """THE VALUE CLAIM, on the shipped (column-major) arm: n, i_acc and f_acc
    of every (fixed slot, group) cell, EXACT equality — FLOAT64 sums
    included."""
    var st = _consume_all()
    _assert_cells_match_oracle(st, "FXCOL")


def test_the_per_row_arm_matches_the_same_oracle() raises:
    """`fxcol_on = False` runs the per-row fold. It must answer the SAME
    oracle — which is also what makes the two arms bit-identical to each
    other."""
    var st = _consume_all(False)
    assert_equal(st.stat_fx_batches, _N_BATCHES)
    _assert_cells_match_oracle(st, "per-row")


def test_the_fixture_reaches_every_channel_and_has_nulls() raises:
    """Refuse a fixture that stopped testing the hard cases: each nullable
    input must actually carry a NULL, and every group must have at least one
    contributing row on every slot (else MIN/MAX seeding is never taken)."""
    var nulls32 = 0
    var nullsf32 = 0
    var nullsf64 = 0
    for b in range(_N_BATCHES):
        for r in range(_ROWS):
            if _c32_null(b, r):
                nulls32 += 1
            if _f32_null(b, r):
                nullsf32 += 1
            if _f64_null(b, r):
                nullsf64 += 1
    assert_true(nulls32 > 0 and nullsf32 > 0 and nullsf64 > 0)
    var st = _consume_all()
    for g in range(len(st.group_keys)):
        for f in range(len(_funcs())):
            assert_true(
                _oracle(f, Int64(st.group_keys[g])).n > 0,
                "slot " + String(f) + " has a group with no contributing row",
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
