# =============================================================================
# column_stats.mojo, part 1: hashes, the sketch, ColumnStats, the accumulator
# =============================================================================
#
# Part 2, the scanners and the cardinality regimes, is
# test_column_stats_scan.mojo. What each group here proves, and its oracle:
#
#   1. Hashes. `_mix64` is the SplitMix64 finalizer: `_mix64(0)` is the
#      published first SplitMix64 output for seed 0, and the SIMD twin agrees
#      lane by lane. The string hash is FNV-1a 64: "abc" and "" hash to
#      the published FNV-1a values through the column scanner.
#   2. HyperLogLog. Register index and run length are checked bit by bit on
#      hand-built hashes; `add_bulk` equals the scalar `add`; `merge` of two
#      sketches equals the sketch of the union; `copy` is deep; `count` is
#      exact for 0, 1 and 10 values and within 5% (about three standard errors at p=12) for
#      larger sets. `_hll_sigma` / `_hll_tau` are held to their series
#      definitions, and are non-negative over their whole input domain (the
#      4097 fractions k/4096 `count` can pass), which is why `count`'s
#      `e < 0.0` arm cannot run. A saturated or nearly saturated sketch
#      counts `HLL_COUNT_CAP`, as does a forged one whose estimate is in
#      [2^63, 2^64); one whose estimate is just below 2^63 is not capped.
#   3. ColumnStats. `null_only` is all-Absent; `copy` shares the sketch and
#      bloom Arcs (refcount, no byte copy); `fingerprint` equals the FNV fold
#      of its summary fields, computed by hand.
#   4. Accumulator. The kind tag for every arrow type, the bloom sizing
#      clamp, the int and float scanners' count-only arms, a zero-row SIMD
#      scan, `_fixed_width_bytes`. The count-only arms are unreachable from
#      `compute_column_stats`; the test says so.
# =============================================================================

from std.memory import ArcPointer
from std.sys import simd_width_of
from std.testing import (
    TestSuite,
    assert_almost_equal,
    assert_equal,
    assert_false,
    assert_true,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_dynamic_filter.bloom_filter import BloomFilter
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.precision_scalar import PrecisionScalar
from komira_scan_source.column_stats import (
    COLSTATS_KIND_PRIMITIVE,
    ColumnStats,
    _finalize_accum,
    _fixed_width_bytes,
    compute_column_stats,
)
from komira_scan_source.column_stats_accum import (
    BLOOM_FPP,
    BLOOM_NDV_CAP,
    _ACC_KIND_BOOL,
    _ACC_KIND_FLOAT,
    _ACC_KIND_INT,
    _ACC_KIND_NONE,
    _ACC_KIND_STRING,
    _ColAccum,
    _scan_float_column,
    _scan_int_column,
    _scan_int_simd_no_validity,
)
from komira_scan_source.column_stats_hll import (
    HLL_COUNT_CAP,
    HyperLogLog,
    _hll_sigma,
    _hll_tau,
    _mix64,
    _mix64_simd,
)

comptime W = simd_width_of[DType.int64]()
comptime SPLITMIX_SEED0_FIRST: UInt64 = 0xE220A8397B1DCDAF
comptime FNV1A64_ABC: UInt64 = 0xE71FA2190541574B
comptime FNV1A64_EMPTY: UInt64 = 0xCBF29CE484222325


# =============================================================================
# Fixture helpers
# =============================================================================


def _int_col[dt: DType](vals: List[Int]) -> Column[HeapRegion]:
    var l = List[Scalar[dt]]()
    for i in range(len(vals)):
        l.append(Scalar[dt](vals[i]))
    return Column.from_primitive[dt](PrimitiveArray[dt].from_list(l^))


def _set_nulls(mut col: Column[HeapRegion], nulls: List[Int]):
    """Give `col` a validity bitmap with `nulls` cleared (physical indices)."""
    var bm = Bitmap.create_all_valid(col._offset + col._length)
    for i in range(len(nulls)):
        bm.clear(nulls[i])
    col._validity = Optional[Bitmap[HeapRegion]](bm^)
    col._null_count = len(nulls)


def _schema1(at: ArrowType) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("c", at, nullable=True))
    return sb.build()


def _stats1(var col: Column[HeapRegion], at: ArrowType) raises -> ColumnStats:
    """Stats of a one-column, one-batch relation whose field says `at`."""
    var schema = _schema1(at)
    var b = RecordBatchBuilder()
    b.add_column(col^)
    var sl = Slab[RecordBatch].create(1)
    sl.append(b.build(schema.copy())^)
    var out = compute_column_stats(sl, schema)
    assert_equal(len(out), 1, "one ColumnStats per column")
    return out[0].copy()


def _within(est: Int64, n: Int, label: String) raises:
    """A HyperLogLog estimate within 5% (about three standard errors at
    p=12) of `n`."""
    var err = abs(Int(est) - n)
    assert_true(
        err * 100 <= n * 5,
        label + ": estimate " + String(est) + " vs true " + String(n),
    )


# =============================================================================
# 1. Hashes
# =============================================================================


def test_mix64_is_splitmix64_and_simd_twin_agrees() raises:
    assert_equal(_mix64(UInt64(0)), SPLITMIX_SEED0_FIRST)
    var x = SIMD[DType.uint64, W](0)
    for j in range(W):
        x[j] = UInt64(j) * UInt64(0x9E3779B97F4A7C15) + UInt64(j * 7)
    x[0] = UInt64(0)
    var h = _mix64_simd[W](x)
    assert_equal(h[0], SPLITMIX_SEED0_FIRST, "lane 0 is the published value")
    for j in range(W):
        assert_equal(h[j], _mix64(x[j]), "lane " + String(j))


def test_string_hash_is_fnv1a_in_the_scanner() raises:
    var vals = List[String]()
    vals.append(String("abc"))
    var s = _stats1(Column.from_string(StringArray.from_strings(vals)), ArrowType.STRING)
    assert_true(s.bloom.value()[].check_hash(FNV1A64_ABC), "bloom holds FNV-1a(abc)")
    var want = HyperLogLog()
    want.add(FNV1A64_ABC)
    for i in range(4096):
        assert_equal(s.hll.value()[].registers[i], want.registers[i], "register " + String(i))
    var empty = List[String]()
    empty.append(String(""))
    var e = _stats1(Column.from_string(StringArray.from_strings(empty)), ArrowType.STRING)
    var want_e = HyperLogLog()
    want_e.add(FNV1A64_EMPTY)
    for i in range(4096):
        assert_equal(
            e.hll.value()[].registers[i], want_e.registers[i], "the empty string hashes to the offset basis"
        )


# =============================================================================
# 2. HyperLogLog
# =============================================================================


def test_hll_add_index_and_run_length() raises:
    var h = HyperLogLog()
    for i in range(4096):
        assert_equal(h.registers[i], UInt8(0), "a new sketch is all zero")
    h.add(UInt64(7))  # no bit above the index: run is Q + 1 = 53
    assert_equal(h.registers[7], UInt8(53))
    h.add((UInt64(1) << 15) | UInt64(9))  # first 1 at bit 3 of rest: run 4
    assert_equal(h.registers[9], UInt8(4))
    h.add((UInt64(1) << 12) | UInt64(9))  # run 1 < 4: register kept
    assert_equal(h.registers[9], UInt8(4))
    h.add(UInt64(0xFFFFFFFFFFFFF000) | UInt64(4095))  # run 1 at the top index
    assert_equal(h.registers[4095], UInt8(1))
    var touched = 0
    for i in range(4096):
        if h.registers[i] != 0:
            touched += 1
    assert_equal(touched, 3, "only the three addressed registers moved")


def test_hll_add_value_mixes_first() raises:
    var a = HyperLogLog()
    a.add_value(UInt64(0))
    var idx = Int(SPLITMIX_SEED0_FIRST & UInt64(4095))
    var b = HyperLogLog()
    b.add(SPLITMIX_SEED0_FIRST)
    assert_true(a.registers[idx] > 0, "the mixed hash's register moved")
    for i in range(4096):
        assert_equal(a.registers[i], b.registers[i], "register " + String(i))


def test_hll_add_bulk_equals_scalar_add() raises:
    var hashes = SIMD[DType.uint64, W](0)
    for j in range(W):
        # lane j: index j + 1, first 1 of rest at bit j, so run j + 1
        hashes[j] = (UInt64(1) << UInt64(12 + j)) | UInt64(j + 1)
    var bulk = HyperLogLog()
    bulk.add_bulk[W](hashes)
    for j in range(W):
        assert_equal(bulk.registers[j + 1], UInt8(j + 1), "lane " + String(j))
    # Every lane again, now not above the register: nothing changes.
    var low = SIMD[DType.uint64, W](0)
    for j in range(W):
        low[j] = (UInt64(1) << UInt64(12)) | UInt64(j + 1)
    bulk.add_bulk[W](low)
    var scalar = HyperLogLog()
    for j in range(W):
        scalar.add(hashes[j])
        scalar.add(low[j])
    for i in range(4096):
        assert_equal(bulk.registers[i], scalar.registers[i], "register " + String(i))


def test_hll_merge_is_the_sketch_of_the_union() raises:
    var a = HyperLogLog()
    var b = HyperLogLog()
    var u = HyperLogLog()
    for v in range(1000):
        a.add_value(UInt64(v))
        u.add_value(UInt64(v))
    for v in range(500, 1500):
        b.add_value(UInt64(v))
        u.add_value(UInt64(v))
    var a_wins = 0
    var b_wins = 0
    for i in range(4096):
        if a.registers[i] > b.registers[i]:
            a_wins += 1
        elif b.registers[i] > a.registers[i]:
            b_wins += 1
    assert_true(a_wins > 0 and b_wins > 0, "both sides win some registers")
    a.merge(b)
    for i in range(4096):
        assert_equal(a.registers[i], u.registers[i], "register " + String(i))
    _within(Int64(a.count()), 1500, "merged count")


def test_hll_copy_is_deep() raises:
    var a = HyperLogLog()
    a.add_value(UInt64(1))
    var c = a.copy()
    c.add(UInt64(7))
    assert_equal(c.registers[7], UInt8(53))
    assert_equal(a.registers[7], UInt8(0), "the original is untouched")
    for i in range(4096):
        if i != 7:
            assert_equal(a.registers[i], c.registers[i], "register " + String(i))


def test_hll_count_small_and_large() raises:
    assert_equal(HyperLogLog().count(), UInt64(0), "empty sketch")
    var h = HyperLogLog()
    h.add_value(UInt64(0))
    assert_equal(h.count(), UInt64(1), "one value")
    for v in range(10):
        h.add_value(UInt64(v))
    assert_equal(h.count(), UInt64(10), "ten values")
    for v in range(5000):
        h.add_value(UInt64(v))
    _within(Int64(h.count()), 5000, "5000 values")
    assert_almost_equal(HyperLogLog.relative_std_error(), 1.04 / 64.0)


def test_hll_count_clamps_a_forged_register() raises:
    """`registers` is a public field: a value above Q + 1 counts as Q + 1,
    so a sketch of forged registers counts exactly as one holding Q + 1.

    In `count` the Q + 1 bucket and the Q bucket differ only by a 2^-52
    weight in z, which shows only when no register is lower: so every
    register is forged. Both are saturated: `HLL_COUNT_CAP`."""
    var forged = HyperLogLog()
    var honest = HyperLogLog()
    for i in range(4096):
        forged.registers[i] = UInt8(255)
        honest.registers[i] = UInt8(53)
    assert_equal(forged.count(), honest.count(), "255 counts as Q + 1")
    assert_equal(honest.count(), HLL_COUNT_CAP, "saturated")


def test_hll_saturating_hashes_and_count_returns() raises:
    """Hashes below 4096 put Q + 1 in every register, which makes the Ertl
    sum z exactly 0: the estimate is unbounded, and `count` returns
    `HLL_COUNT_CAP`, not 0."""
    var h = HyperLogLog()
    for i in range(4096):
        h.add(UInt64(i))
    for i in range(4096):
        assert_equal(h.registers[i], UInt8(53))
    assert_equal(h.count(), HLL_COUNT_CAP)


def test_hll_nearly_saturated_count_is_capped() raises:
    """One register at Q, the rest at Q + 1: z is 2^-52 and the estimate
    about 5e22, past what a UInt64 holds; `count` returns `HLL_COUNT_CAP`."""
    var h = HyperLogLog()
    for i in range(4096):
        h.registers[i] = UInt8(53)
    h.registers[0] = UInt8(52)
    assert_equal(h.count(), HLL_COUNT_CAP)
    assert_equal(Int(h.count()), Int(Int64.MAX), "converts to Int without wrapping")


def test_hll_estimate_between_2_63_and_2_64_is_capped() raises:
    """One register at 40, the rest at Q + 1: z is about 2^-40 and the
    estimate about 1.22e19, inside [2^63, 2^64). A UInt64 holds it but an
    Int would wrap it negative, so `count` must return `HLL_COUNT_CAP`.
    With that register at 39 the estimate is about 6.38e18, below the cap,
    and is returned as is."""
    var h = HyperLogLog()
    for i in range(4096):
        h.registers[i] = UInt8(53)
    h.registers[0] = UInt8(40)
    assert_equal(h.count(), HLL_COUNT_CAP)
    assert_true(Int(h.count()) > 0, "converts to a positive Int")
    h.registers[0] = UInt8(39)
    var below = h.count()
    assert_true(below < HLL_COUNT_CAP, "not capped below 2^63")
    assert_true(below > UInt64(6_300_000_000_000_000_000), "about 6.38e18")


def test_hll_sigma_tau_series_and_domain() raises:
    # Ertl: sigma(x) = x + sum_k x^(2^k) 2^(k-1); tau(x) = (1 - x -
    # sum_k (1 - x^(2^-k))^2 2^-k) / 3. Values from those series.
    assert_almost_equal(_hll_sigma(0.5), 0.8907470740377903, atol=1e-12)
    assert_almost_equal(_hll_sigma(0.25), 0.32037353701889515, atol=1e-12)
    assert_equal(_hll_sigma(0.0), 0.0)
    assert_equal(_hll_sigma(1.0), 1e50, "the +inf sentinel")
    assert_almost_equal(_hll_tau(0.5), 0.14992949586408807, atol=1e-12)
    assert_equal(_hll_tau(0.0), 0.0)
    assert_equal(_hll_tau(1.0), 0.0)
    # count() passes sigma reghisto[0]/m and tau (m - reghisto[Q+1])/m: both
    # are k/4096 for k in [0, 4096]. Over that whole domain both are
    # non-negative, so z >= 0, and `e = alpha*m*m/z` is positive whenever
    # z != 0: the `e < 0.0` arm of count() cannot run.
    for k in range(4097):
        var x = Float64(k) / 4096.0
        assert_true(_hll_sigma(x) >= 0.0, "sigma(" + String(k) + "/4096)")
        assert_true(_hll_tau(x) >= 0.0, "tau(" + String(k) + "/4096)")


# =============================================================================
# 3. ColumnStats
# =============================================================================


def _summary(ndv: PrecisionScalar) -> ColumnStats:
    var none_hll: Optional[ArcPointer[HyperLogLog]] = None
    var none_bloom: Optional[ArcPointer[BloomFilter]] = None
    return ColumnStats(
        COLSTATS_KIND_PRIMITIVE,
        PrecisionScalar.exact(ScalarValue.from_int(1)),
        PrecisionScalar.exact(ScalarValue.from_int(2)),
        0,
        ndv.copy(),
        PrecisionScalar.exact(ScalarValue.from_int(3)),
        8.0,
        none_hll^,
        none_bloom^,
    )


def test_null_only_and_fingerprint() raises:
    var s = ColumnStats.null_only(3, 2.5)
    assert_equal(s.kind, COLSTATS_KIND_PRIMITIVE)
    assert_true(s.min.is_absent() and s.max.is_absent())
    assert_true(s.distinct_count.is_absent() and s.sum.is_absent())
    assert_equal(s.null_count, 3)
    assert_equal(s.avg_size_bytes, 2.5)
    assert_false(Bool(s.hll) or Bool(s.bloom))
    # FNV-1a 64 over kind, null_count, the four tags, [NDV], avg*1000.
    assert_equal(s.fingerprint(), UInt64(0xCC84C1C044BDA898), "null_only(3, 2.5)")
    var e7 = _summary(PrecisionScalar.exact(ScalarValue.from_int(7)))
    var e8 = _summary(PrecisionScalar.exact(ScalarValue.from_int(8)))
    var i7 = _summary(PrecisionScalar.inexact(ScalarValue.from_int(7)))
    assert_equal(e7.fingerprint(), UInt64(0xA8D306322835AC0A), "Exact NDV 7")
    assert_equal(e8.fingerprint(), UInt64(0xA892083227D5AC3D), "Exact NDV 8")
    assert_equal(i7.fingerprint(), UInt64(0x08D4A629D1F3DE4B), "Inexact NDV 7")


def test_column_stats_copy_shares_the_arcs() raises:
    var vals = List[Int]()
    vals.append(4)
    vals.append(-2)
    var s = _stats1(_int_col[DType.int64](vals), ArrowType.INT64)
    var c = s.copy()
    assert_equal(s.hll.value().count(), UInt64(2), "sketch Arc shared")
    assert_equal(s.bloom.value().count(), UInt64(2), "bloom Arc shared")
    assert_equal(c.min.value.value().int_val, Int64(-2))
    assert_equal(c.max.value.value().int_val, Int64(4))
    assert_equal(c.sum.value.value().int_val, Int64(2))
    assert_equal(c.distinct_count.value.value().int_val, Int64(2))
    assert_equal(c.null_count, s.null_count)
    assert_equal(c.avg_size_bytes, 8.0)
    assert_equal(c.kind, s.kind)
    assert_equal(c.fingerprint(), s.fingerprint())


# =============================================================================
# 4. Accumulator
# =============================================================================


def test_acc_kind_for_every_arrow_type() raises:
    assert_equal(_ColAccum(ArrowType.BOOL, 1).acc_kind, _ACC_KIND_BOOL)
    assert_equal(_ColAccum(ArrowType.STRING, 1).acc_kind, _ACC_KIND_STRING)
    assert_equal(_ColAccum(ArrowType.LARGE_STRING, 1).acc_kind, _ACC_KIND_STRING)
    assert_equal(_ColAccum(ArrowType.FLOAT32, 1).acc_kind, _ACC_KIND_FLOAT)
    assert_equal(_ColAccum(ArrowType.FLOAT64, 1).acc_kind, _ACC_KIND_FLOAT)
    var ints = List[ArrowType]()
    ints.append(ArrowType.INT8)
    ints.append(ArrowType.INT16)
    ints.append(ArrowType.INT32)
    ints.append(ArrowType.INT64)
    ints.append(ArrowType.UINT8)
    ints.append(ArrowType.UINT16)
    ints.append(ArrowType.UINT32)
    ints.append(ArrowType.UINT64)
    ints.append(ArrowType.DATE32)
    ints.append(ArrowType.DATE64)
    ints.append(ArrowType.TIMESTAMP)
    ints.append(ArrowType.TIMESTAMP_S)
    ints.append(ArrowType.TIMESTAMP_MS)
    ints.append(ArrowType.TIMESTAMP_US)
    ints.append(ArrowType.TIMESTAMP_NS)
    for i in range(len(ints)):
        assert_equal(_ColAccum(ints[i], 1).acc_kind, _ACC_KIND_INT, "int kind " + String(i))
    var none = List[ArrowType]()
    none.append(ArrowType.FLOAT16)
    none.append(ArrowType.BINARY)
    none.append(ArrowType.DECIMAL128)
    none.append(ArrowType.DICTIONARY)
    none.append(ArrowType.TIME64_US)
    for i in range(len(none)):
        assert_equal(_ColAccum(none[i], 1).acc_kind, _ACC_KIND_NONE, "no kind " + String(i))


def test_bloom_sized_from_rows_clamped_to_1_and_cap() raises:
    assert_equal(
        _ColAccum(ArrowType.INT64, 0).bloom.num_bytes,
        BloomFilter.with_ndv_fpp(1, BLOOM_FPP).num_bytes,
        "0 rows sizes for 1",
    )
    assert_equal(
        _ColAccum(ArrowType.INT64, 200000).bloom.num_bytes,
        BloomFilter.with_ndv_fpp(BLOOM_NDV_CAP, BLOOM_FPP).num_bytes,
        "rows above the cap size for the cap",
    )
    assert_equal(
        _ColAccum(ArrowType.INT64, 20000).bloom.num_bytes,
        BloomFilter.with_ndv_fpp(20000, BLOOM_FPP).num_bytes,
        "rows below the cap size for the rows",
    )
    assert_true(
        BloomFilter.with_ndv_fpp(20000, BLOOM_FPP).num_bytes
        < BloomFilter.with_ndv_fpp(BLOOM_NDV_CAP, BLOOM_FPP).num_bytes
        and BloomFilter.with_ndv_fpp(1, BLOOM_FPP).num_bytes
        < BloomFilter.with_ndv_fpp(20000, BLOOM_FPP).num_bytes,
        "the three sizes are distinct, so each clamp is observable",
    )


def test_note_bool_and_note_float_extremes() raises:
    var b = _ColAccum(ArrowType.BOOL, 3)
    b.note_bool(True)
    assert_equal(b.min_i, Int64(1))
    assert_equal(b.max_i, Int64(1))
    b.note_bool(False)
    assert_equal(b.min_i, Int64(0))
    assert_equal(b.max_i, Int64(1))
    var f = _ColAccum(ArrowType.FLOAT64, 3)
    f.note_float(2.5)
    f.note_float(-1.0)
    f.note_float(4.0)
    assert_equal(f.min_f, -1.0)
    assert_equal(f.max_f, 4.0)
    assert_equal(f.sum_f, 5.5)


def test_scanners_count_only_arms() raises:
    """`_scan_float_column` given FLOAT16 and `_scan_int_column` given
    DECIMAL128 (both unreachable from `compute_column_stats`, which tags
    those types NONE kind) count nulls exactly and read no value: after a
    scanned value, finalize reports the nulls and nothing else, since a
    statistic over the scanned values alone would be wrong."""
    var vals = List[Int]()
    vals.append(1)
    vals.append(2)
    vals.append(3)
    var nulls = List[Int]()
    nulls.append(1)
    for arm in range(2):
        var col = _int_col[DType.int32](vals)
        _set_nulls(col, nulls)
        var acc = _ColAccum(ArrowType.FLOAT64 if arm == 0 else ArrowType.INT64, 3)
        if arm == 0:
            acc.note_float(5.0)
            _scan_float_column(acc, col, ArrowType.FLOAT16, 3)
        else:
            acc.note_int(Int64(5))
            _scan_int_column(acc, col, ArrowType.DECIMAL128, 3)
        assert_equal(acc.null_count, 1, "arm " + String(arm))
        assert_equal(acc.n_values, 1, "arm " + String(arm) + ": only the noted value read")
        var s = _finalize_accum(acc)
        assert_equal(s.null_count, 1)
        assert_true(s.min.is_absent() and s.max.is_absent() and s.sum.is_absent())
        assert_true(s.distinct_count.is_absent(), "arm " + String(arm) + ": NDV Absent")
        assert_false(Bool(s.hll) or Bool(s.bloom))


def test_simd_scan_of_zero_rows_sees_nothing() raises:
    var acc = _ColAccum(ArrowType.INT64, 1)
    _scan_int_simd_no_validity[DType.int64](acc, _int_col[DType.int64](List[Int]()), 0)
    assert_false(acc.seen_value, "zero rows set no value")
    assert_equal(acc.min_i, Int64.MAX)
    assert_equal(acc.max_i, Int64.MIN)


def test_fixed_width_bytes_table() raises:
    var w1 = List[ArrowType]()
    w1.append(ArrowType.INT8)
    w1.append(ArrowType.UINT8)
    w1.append(ArrowType.BOOL)
    var w2 = List[ArrowType]()
    w2.append(ArrowType.INT16)
    w2.append(ArrowType.UINT16)
    w2.append(ArrowType.FLOAT16)
    var w4 = List[ArrowType]()
    w4.append(ArrowType.INT32)
    w4.append(ArrowType.UINT32)
    w4.append(ArrowType.FLOAT32)
    w4.append(ArrowType.DATE32)
    var w8 = List[ArrowType]()
    w8.append(ArrowType.INT64)
    w8.append(ArrowType.UINT64)
    w8.append(ArrowType.FLOAT64)
    w8.append(ArrowType.DATE64)
    w8.append(ArrowType.TIMESTAMP)
    w8.append(ArrowType.TIMESTAMP_S)
    w8.append(ArrowType.TIMESTAMP_MS)
    w8.append(ArrowType.TIMESTAMP_US)
    w8.append(ArrowType.TIMESTAMP_NS)
    for i in range(len(w1)):
        assert_equal(_fixed_width_bytes(w1[i]), 1, "1-byte " + String(i))
    for i in range(len(w2)):
        assert_equal(_fixed_width_bytes(w2[i]), 2, "2-byte " + String(i))
    for i in range(len(w4)):
        assert_equal(_fixed_width_bytes(w4[i]), 4, "4-byte " + String(i))
    for i in range(len(w8)):
        assert_equal(_fixed_width_bytes(w8[i]), 8, "8-byte " + String(i))
    assert_equal(_fixed_width_bytes(ArrowType.DECIMAL128), 16)
    assert_equal(_fixed_width_bytes(ArrowType.STRING), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
