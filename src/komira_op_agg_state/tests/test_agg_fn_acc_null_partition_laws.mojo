# =============================================================================
# test_agg_fn_acc_null_partition_laws.mojo — NULL rows and worker cuts through
# the real AggFnAcc
# =============================================================================
#
# WHAT THIS PINS. `AggFnAcc[F]` is where a NULL input row is dropped (the
# PROPAGATE rule: `_update_arity1` skips `c0.is_null(i)` before it calls the
# cell) and where per-worker partial slabs are joined (`merge_aligned`). The
# cells themselves never see a NULL. Three laws, per group, on seeded batches
# of 0..96 rows over 1..4 groups:
#
#   N1 NULL is absence:   the answer over a batch with NULL rows equals the
#                         answer over the same batch with those rows deleted.
#   N2 worker cuts:       the batch cut into 1..5 contiguous slices, each
#                         folded by its own AggFnAcc and joined left to right
#                         with `merge_aligned`, equals the serial answer.
#   N3 all-NULL group:    a group whose every row is NULL answers exactly what
#                         a group with no rows answers (the cell's identity).
#
# N3 is N1 for the groups that end up empty; it is named because it is where a
# reader of a NULL slot would show first.
#
# THE NULL SLOTS HOLD POISON. Every NULL row's data slot is written with a
# value that would change the answer if it were read: NaN for Float64 (it
# would make SUM / AVG NaN and win MAX), Int64.MAX / Int64.MIN alternately for
# Int64 (they would win MAX / MIN and move SUM). A fold that read data under a
# NULL fails N1 on the first seed that has one.
#
# Values that are not NULL include NaN, -0.0 and +-inf for Float64, so N2 is
# also a NaN partition law at the accumulator level. Finite floats are
# multiples of 1/8 below 1000, so SUM and AVG are exact and compared exactly;
# STDDEV_SAMP is compared to 1e-9 relative on NaN-free, inf-free rows.
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, SchemaBuilder, RecordBatch, RecordBatchBuilder,
)
from komira_buffer.heap_region import HeapRegion
from komira_udf.agg_fn import AggFn
from komira_op_agg_state.agg_fn_acc import AggFnAcc

from komira_agg.builtin_agg_fns_sum import SumF64, SumI64
from komira_agg.builtin_agg_fns_count import CountF64, CountI64
from komira_agg.builtin_agg_fns_avg import AvgF64
from komira_agg.builtin_agg_fns_minmax import MinF64, MaxF64, MinI64, MaxI64
from komira_agg.builtin_agg_fns_stddev import StddevSampF64
from komira_agg.builtin_agg_fns_firstlast import FirstF64, LastF64


comptime N_CASES = 40
comptime N_CUTS = 4


# =============================================================================
# splitmix64
# =============================================================================


struct Rng(Movable, Deinitable):
    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next_u64(mut self) -> UInt64:
        self.state += UInt64(0x9E3779B97F4A7C15)
        var z = self.state
        z = (z ^ (z >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B9)
        z = (z ^ (z >> UInt64(27))) * UInt64(0x94D049BB133111EB)
        return z ^ (z >> UInt64(31))

    def next_int(mut self, n: Int) -> Int:
        if n <= 1:
            return 0
        return Int(self.next_u64() % UInt64(n))


def _nan() -> Float64:
    return Float64(0.0) / Float64(0.0)


def _inf() -> Float64:
    return Float64(1.0) / Float64(0.0)


# =============================================================================
# One seeded case: rows, group ids, NULL flags
# =============================================================================


struct Case(Movable):
    var f64: List[Float64]
    var i64: List[Int64]
    var gids: List[Int]
    var nulls: List[Bool]
    var groups: Int

    def __init__(out self):
        self.f64 = List[Float64]()
        self.i64 = List[Int64]()
        self.gids = List[Int]()
        self.nulls = List[Bool]()
        self.groups = 1


def _gen_case(mut rng: Rng, specials: Bool) -> Case:
    """0..96 rows over 1..4 groups. The NULL density is one of 0, ~1/3 or all,
    picked per case, and each group of the last kind is all-NULL (N3)."""
    var c = Case()
    var n = rng.next_int(97)
    c.groups = 1 + rng.next_int(4)
    var density = rng.next_int(3)  # 0: none, 1: about a third, 2: all
    for i in range(n):
        c.gids.append(rng.next_int(c.groups))
        var is_null = False
        if density == 1:
            is_null = rng.next_int(3) == 0
        elif density == 2:
            is_null = True
        c.nulls.append(is_null)
        if is_null:
            # Poison: these must never be read.
            c.f64.append(_nan())
            c.i64.append(Int64.MAX if i % 2 == 0 else Int64.MIN)
        else:
            var k = rng.next_int(10)
            if specials and k == 0:
                var s = rng.next_int(5)
                if s == 0:
                    c.f64.append(_nan())
                elif s == 1:
                    c.f64.append(Float64(0.0) * Float64(-1.0))
                elif s == 2:
                    c.f64.append(_inf())
                elif s == 3:
                    c.f64.append(-_inf())
                else:
                    c.f64.append(-_nan())
            else:
                c.f64.append(Float64(rng.next_int(16001) - 8000) / Float64(8.0))
            var mag = (rng.next_u64() >> UInt64(24)).cast[DType.int64]()
            c.i64.append(mag if rng.next_int(2) == 0 else -mag)
    return c^


# =============================================================================
# Batch builders: one nullable column named "v" (the cells' InRow field)
# =============================================================================


def _batch[
    dt: DType
](imm vals: List[Scalar[dt]], imm nulls: List[Bool], lo: Int, hi: Int, keep_nulls: Bool) raises -> RecordBatch:
    """Rows [lo, hi) as a one-column batch. With `keep_nulls` False the NULL
    rows are left out entirely (the N1 reference)."""
    var idx = List[Int]()
    for i in range(lo, hi):
        if keep_nulls or not nulls[i]:
            idx.append(i)
    var n = len(idx)
    var arr = PrimitiveArray[dt].allocate_nullable(n)
    for r in range(n):
        arr.set(r, vals[idx[r]])
    for r in range(n):
        if nulls[idx[r]]:
            arr._set_null(r)
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.from_dtype(dt), True))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[dt](arr^))
    return b.build(sb.build())


def _gids(
    imm gids: List[Int], imm nulls: List[Bool], lo: Int, hi: Int, keep_nulls: Bool
) -> List[Int]:
    var out = List[Int]()
    for i in range(lo, hi):
        if keep_nulls or not nulls[i]:
            out.append(gids[i])
    return out^


def _cuts(mut rng: Rng, n: Int) -> List[Int]:
    var k = 1 + rng.next_int(5)
    var inner = List[Int]()
    for _ in range(k - 1):
        inner.append(rng.next_int(n + 1))
    for i in range(1, len(inner)):
        var j = i
        while j > 0 and inner[j - 1] > inner[j]:
            var t = inner[j]
            inner[j] = inner[j - 1]
            inner[j - 1] = t
            j -= 1
    var out = List[Int]()
    out.append(0)
    for i in range(len(inner)):
        out.append(inner[i])
    out.append(n)
    return out^


def _same[dt: DType](a: Scalar[dt], b: Scalar[dt], rel_tol: Float64) -> Bool:
    comptime if dt.is_floating_point():
        var x = a.cast[DType.float64]()
        var y = b.cast[DType.float64]()
        if x != x:
            return y != y
        if y != y:
            return False
        if x == y:
            return True
        if rel_tol == 0.0:
            return False
        var scale = max(max(abs(x), abs(y)), Float64(1.0))
        return abs(x - y) <= rel_tol * scale
    else:
        return a == b


# =============================================================================
# The law driver
# =============================================================================


def _run[
    dt: DType, F: AggFn
](
    f: F,
    imm vals: List[Scalar[dt]],
    imm gids: List[Int],
    imm nulls: List[Bool],
    groups: Int,
    lo: Int,
    hi: Int,
    keep_nulls: Bool,
) raises -> AggFnAcc[F]:
    var acc = AggFnAcc[F](f.copy())
    acc.ensure_capacity(groups)
    acc.update_record_batch(
        _gids(gids, nulls, lo, hi, keep_nulls),
        _batch[dt](vals, nulls, lo, hi, keep_nulls),
    )
    return acc^


def _laws[
    dt: DType, F: AggFn
](
    f: F,
    name: String,
    imm vals: List[Scalar[dt]],
    imm c: Case,
    mut rng: Rng,
    seed: UInt64,
    rel_tol: Float64,
) raises:
    var n = len(c.gids)
    var ctx = name + " seed=" + String(seed) + " n=" + String(n) + " groups=" + String(c.groups)

    var serial = _run[dt, F](f, vals, c.gids, c.nulls, c.groups, 0, n, True)
    var want_col = serial.finalize_to_column().as_primitive[F.OutType]()

    # N1 (and N3 for every group that holds only NULL rows).
    var absent = _run[dt, F](f, vals, c.gids, c.nulls, c.groups, 0, n, False)
    var absent_col = absent.finalize_to_column().as_primitive[F.OutType]()
    for g in range(c.groups):
        assert_true(
            _same[F.OutType](want_col.get(g), absent_col.get(g), rel_tol),
            ctx + " group " + String(g) + ": with NULL rows=" + String(want_col.get(g))
            + " but with those rows deleted=" + String(absent_col.get(g))
            + " (a NULL slot was read)",
        )

    # N2 — worker cuts joined with merge_aligned, left to right.
    for _ in range(N_CUTS):
        var b = _cuts(rng, n)
        var joined = _run[dt, F](f, vals, c.gids, c.nulls, c.groups, b[0], b[1], True)
        for j in range(1, len(b) - 1):
            var part = _run[dt, F](f, vals, c.gids, c.nulls, c.groups, b[j], b[j + 1], True)
            joined.merge_aligned(part)
        var got_col = joined.finalize_to_column().as_primitive[F.OutType]()
        var cuts = String("[")
        for j in range(len(b)):
            if j > 0:
                cuts += ","
            cuts += String(b[j])
        cuts += "]"
        for g in range(c.groups):
            assert_true(
                _same[F.OutType](got_col.get(g), want_col.get(g), rel_tol),
                ctx + " cuts=" + cuts + " group " + String(g) + ": merged="
                + String(got_col.get(g)) + " but serial=" + String(want_col.get(g)),
            )


def _laws_f64[F: AggFn](f: F, name: String, base_seed: UInt64, specials: Bool, rel_tol: Float64) raises:
    for k in range(N_CASES):
        var seed = base_seed + UInt64(k)
        var rng = Rng(seed)
        var c = _gen_case(rng, specials)
        _laws[DType.float64, F](f, name, c.f64, c, rng, seed, rel_tol)


def _laws_i64[F: AggFn](f: F, name: String, base_seed: UInt64) raises:
    for k in range(N_CASES):
        var seed = base_seed + UInt64(k)
        var rng = Rng(seed)
        var c = _gen_case(rng, False)
        _laws[DType.int64, F](f, name, c.i64, c, rng, seed, 0.0)


# =============================================================================
# Tests
# =============================================================================


def test_sum_f64_null_and_cut_laws() raises:
    _laws_f64[SumF64](SumF64(), "SumF64", 100, True, 0.0)


def test_count_f64_null_and_cut_laws() raises:
    _laws_f64[CountF64](CountF64(), "CountF64", 200, True, 0.0)


def test_avg_f64_null_and_cut_laws() raises:
    _laws_f64[AvgF64](AvgF64(), "AvgF64", 300, True, 0.0)


def test_min_max_f64_null_and_cut_laws() raises:
    _laws_f64[MinF64](MinF64(), "MinF64", 400, True, 0.0)
    _laws_f64[MaxF64](MaxF64(), "MaxF64", 500, True, 0.0)


def test_first_last_f64_null_and_cut_laws() raises:
    """FIRST / LAST are order-dependent, but the cuts keep row order and the
    merge is left to right, so they obey N1-N3 like the others."""
    _laws_f64[FirstF64](FirstF64(), "FirstF64", 600, True, 0.0)
    _laws_f64[LastF64](LastF64(), "LastF64", 700, True, 0.0)


def test_stddev_f64_null_and_cut_laws() raises:
    _laws_f64[StddevSampF64](StddevSampF64(), "StddevSampF64", 800, False, 1e-9)


def test_i64_null_and_cut_laws() raises:
    _laws_i64[SumI64](SumI64(), "SumI64", 900)
    _laws_i64[CountI64](CountI64(), "CountI64", 1000)
    _laws_i64[MinI64](MinI64(), "MinI64", 1100)
    _laws_i64[MaxI64](MaxI64(), "MaxI64", 1200)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
