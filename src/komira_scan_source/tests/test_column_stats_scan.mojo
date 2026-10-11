# =============================================================================
# column_stats.mojo, part 2: every scanner arm and the cardinality regimes
# =============================================================================
#
# Part 1 (hashes, the sketch, ColumnStats, the accumulator) is
# test_column_stats.mojo. Every test here goes through
# `compute_column_stats`. Expected min/max/sum/NDV are computed in the test
# from the input values by definition, never by the code under test, and a
# null slot holds an extreme value, so reading it as a value moves min or max.
#
#   5. Scanners. Every integer arrow type in four layouts: no validity (the
#      SIMD kernel and its scalar tail), with nulls (the scalar path), a
#      zero-copy slice at offset 3 (the SIMD load honours the offset), and
#      that slice with nulls (the scalar path honours it too).
#      Unsigned types carry their maximum, so a sign-extending widen shows.
#      Floats in both widths, whole and sliced, with and without nulls.
#      Bools: bit addressing in the second byte through an offset view, with
#      and without a null, and nulls over a false bit.
#      Strings with Int32 and Int64 offsets: an offset view with a null,
#      nulls, an empty string (first value and new minimum), prefixes in
#      both directions, an all-null
#      column, and a field that says STRING over a column with no offsets.
#      The no-scanner arms (a DECIMAL128 field, DATE64), held only to what
#      is right whether or not komira-ai/komira#940 is fixed. An empty batch,
#      several batches whose SIMD blocks must fold into the running min/max,
#      and no batches at all.
#   6. Cardinality regimes, each on the SIMD path (no validity) and the
#      scalar path (a validity bitmap): exact NDV under 4096 distinct values
#      across the 8192-row sample point (fewer and more than 1024 distinct)
#      and the 65536-row bloom poll; 5000 distinct values (Inexact NDV, bloom
#      kept and holding every value); 140000 distinct values (Inexact NDV,
#      the bloom poll disables the bloom and finalize drops it). The poll
#      leaves no trace in the final stats, so it is checked on the
#      accumulator's `bloom_active`.
#
# Nothing here asserts a value believed wrong (komira-ai/komira#940).
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.large_string_array import LargeStringArray
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
from komira_scan_source.column_stats import (
    BLOOM_FPP,
    ColumnStats,
    _ColAccum,
    _mix64,
    _scan_int_simd_no_validity,
    compute_column_stats,
)


# =============================================================================
# Fixture helpers
# =============================================================================


def _int_col[dt: DType](vals: List[Int]) -> Column[HeapRegion]:
    var l = List[Scalar[dt]](capacity=len(vals))
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


def _batch(var col: Column[HeapRegion], schema: Schema) raises -> RecordBatch:
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(schema.copy())


def _stats1(var col: Column[HeapRegion], at: ArrowType) raises -> ColumnStats:
    """Stats of a one-column, one-batch relation whose field says `at`."""
    var schema = _schema1(at)
    var sl = Slab[RecordBatch].create(1)
    sl.append(_batch(col^, schema))
    var out = compute_column_stats(sl, schema)
    assert_equal(len(out), 1, "one ColumnStats per column")
    return out[0].copy()


def _ndv_of(vals: List[Int], skip: List[Int]) -> Int:
    var seen = Dict[Int, Bool]()
    for i in range(len(vals)):
        if i in skip:
            continue
        seen[vals[i]] = True
    return len(seen)


def _assert_int_stats(
    s: ColumnStats, vals: List[Int], skip: List[Int], avg: Float64, label: String
) raises:
    """Hold `s` to min/max/sum/NDV of `vals` minus the indices in `skip`."""
    var mn = Int64.MAX
    var mx = Int64.MIN
    var sm = Int64(0)
    for i in range(len(vals)):
        if i in skip:
            continue
        var v = Int64(vals[i])
        mn = min(mn, v)
        mx = max(mx, v)
        sm += v
    assert_true(s.min.is_exact(), label + ": min is Exact")
    assert_equal(s.min.value.value().int_val, mn, label + ": min")
    assert_true(s.max.is_exact(), label + ": max is Exact")
    assert_equal(s.max.value.value().int_val, mx, label + ": max")
    assert_true(s.sum.is_exact(), label + ": sum is Exact")
    assert_equal(s.sum.value.value().int_val, sm, label + ": sum")
    assert_true(s.distinct_count.is_exact(), label + ": NDV is Exact")
    assert_equal(
        s.distinct_count.value.value().int_val,
        Int64(_ndv_of(vals, skip)),
        label + ": NDV",
    )
    assert_equal(s.null_count, len(skip), label + ": null_count")
    assert_equal(s.avg_size_bytes, avg, label + ": avg_size_bytes")
    assert_true(Bool(s.hll), label + ": sketch kept")
    assert_true(Bool(s.bloom), label + ": bloom kept")


def _within(est: Int64, n: Int, label: String) raises:
    """A HyperLogLog estimate within 5% (about three standard errors at
    p=12) of `n`."""
    var err = abs(Int(est) - n)
    assert_true(
        err * 100 <= n * 5,
        label + ": estimate " + String(est) + " vs true " + String(n),
    )


def _assert_unscanned(s: ColumnStats, nulls: Int, label: String) raises:
    """A column the docstring gives null_count only: exact nulls, no
    min/max/sum. NDV is not asserted: the code reports Exact 0 for a column
    holding values, the docstring says Absent (komira-ai/komira#940)."""
    assert_equal(s.null_count, nulls, label + ": null_count")
    assert_true(s.min.is_absent() and s.max.is_absent(), label + ": no min/max")
    assert_true(s.sum.is_absent(), label + ": no sum")


# =============================================================================
# 5. Scanners
# =============================================================================


def _check_int[dt: DType](at: ArrowType, vals: List[Int], width: Float64, label: String) raises:
    """Four layouts of the 11-row `vals`; index 2 holds the maximum and
    index 7 the minimum of the signed fixtures."""
    var none = List[Int]()
    var c1 = _int_col[dt](vals)
    c1.arrow_type = at
    _assert_int_stats(_stats1(c1^, at), vals, none, width, label + " plain")

    var c2 = _int_col[dt](vals)
    c2.arrow_type = at
    var nulls = List[Int]()
    nulls.append(2)
    nulls.append(7)
    _set_nulls(c2, nulls)
    _assert_int_stats(_stats1(c2^, at), vals, nulls, width, label + " nulls")

    var c3 = _int_col[dt](vals)
    c3.arrow_type = at
    var sub = List[Int]()
    for i in range(3, 11):
        sub.append(vals[i])
    _assert_int_stats(_stats1(c3.slice(3, 8), at), sub, none, width, label + " slice")

    # The slice with nulls at physical 4 and 7 (logical 1 and 4): the
    # scalar path must read value and validity at offset + i.
    var c4 = _int_col[dt](vals)
    c4.arrow_type = at
    var pnulls = List[Int]()
    pnulls.append(4)
    pnulls.append(7)
    _set_nulls(c4, pnulls)
    var lnulls = List[Int]()
    lnulls.append(1)
    lnulls.append(4)
    _assert_int_stats(_stats1(c4.slice(3, 8), at), sub, lnulls, width, label + " slice nulls")


def _signed() -> List[Int]:
    var v = List[Int]()
    for x in [5, -3, 100, -3, 7, 0, 42, -100, 9, 11, 2]:
        v.append(x)
    return v^


def _unsigned(top: Int) -> List[Int]:
    var v = List[Int]()
    for x in [5, 3, top, 3, 7, 0, 42, 1, 9, 11, 2]:
        v.append(x)
    return v^


def test_every_integer_type_in_four_layouts() raises:
    _check_int[DType.int8](ArrowType.INT8, _signed(), 1.0, "INT8")
    _check_int[DType.int16](ArrowType.INT16, _signed(), 2.0, "INT16")
    _check_int[DType.int32](ArrowType.INT32, _signed(), 4.0, "INT32")
    _check_int[DType.int32](ArrowType.DATE32, _signed(), 4.0, "DATE32")
    _check_int[DType.int64](ArrowType.INT64, _signed(), 8.0, "INT64")
    _check_int[DType.int64](ArrowType.TIMESTAMP, _signed(), 8.0, "TIMESTAMP")
    _check_int[DType.int64](ArrowType.TIMESTAMP_S, _signed(), 8.0, "TIMESTAMP_S")
    _check_int[DType.int64](ArrowType.TIMESTAMP_MS, _signed(), 8.0, "TIMESTAMP_MS")
    _check_int[DType.int64](ArrowType.TIMESTAMP_US, _signed(), 8.0, "TIMESTAMP_US")
    _check_int[DType.int64](ArrowType.TIMESTAMP_NS, _signed(), 8.0, "TIMESTAMP_NS")
    _check_int[DType.uint8](ArrowType.UINT8, _unsigned(255), 1.0, "UINT8")
    _check_int[DType.uint16](ArrowType.UINT16, _unsigned(65535), 2.0, "UINT16")
    _check_int[DType.uint32](ArrowType.UINT32, _unsigned(4294967295), 4.0, "UINT32")
    _check_int[DType.uint64](ArrowType.UINT64, _unsigned(1 << 40), 8.0, "UINT64")


def _float_col(vals: List[Float64], f32: Bool) -> Column[HeapRegion]:
    if f32:
        var l = List[Float32]()
        for i in range(len(vals)):
            l.append(Float32(vals[i]))
        return Column.from_primitive[DType.float32](PrimitiveArray[DType.float32].from_list(l^))
    return Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(vals.copy()))


def test_floats_both_widths_four_layouts() raises:
    """Whole column and a slice at offset 2, each with and without nulls at
    physical 2 and 5. Expected values are folded here from the values in
    row order (all dyadic, so float32 and the sums are exact)."""
    var vals = List[Float64]()
    for x in [1.5, -2.25, 1048576.0, 1.5, 0.5, -1048576.0, 8.0]:
        vals.append(x)
    var pnulls = List[Int]()
    pnulls.append(2)
    pnulls.append(5)
    for width in range(2):
        var at = ArrowType.FLOAT32 if width == 0 else ArrowType.FLOAT64
        var w = 4.0 if width == 0 else 8.0
        for layout in range(4):
            var off = 2 if layout >= 2 else 0
            var n = 7 - off
            var with_nulls = layout % 2 == 1
            var col = _float_col(vals, width == 0)
            if with_nulls:
                _set_nulls(col, pnulls)
            if off > 0:
                col = col.slice(off, n)
            var mn = Float64.MAX_FINITE
            var mx = -Float64.MAX_FINITE
            var sm = 0.0
            var seen = List[Float64]()
            var nnull = 0
            for p in range(off, 7):
                if with_nulls and p in pnulls:
                    nnull += 1
                    continue
                var v = vals[p]
                mn = min(mn, v)
                mx = max(mx, v)
                sm += v
                if not (v in seen):
                    seen.append(v)
            var s = _stats1(col^, at)
            var label = String("width ") + String(w) + " layout " + String(layout)
            assert_true(s.min.is_exact() and s.max.is_exact() and s.sum.is_exact(), label)
            assert_equal(s.min.value.value().float_val, mn, label + " min")
            assert_equal(s.max.value.value().float_val, mx, label + " max")
            assert_equal(s.sum.value.value().float_val, sm, label + " sum")
            assert_equal(s.distinct_count.value.value().int_val, Int64(len(seen)), label + " NDV")
            assert_equal(s.null_count, nnull, label + " nulls")
            assert_equal(s.avg_size_bytes, w, label + " avg")


def _bools(pattern: String) -> Column[HeapRegion]:
    var bm = Bitmap.create(pattern.byte_length())
    var bs = pattern.as_bytes()
    for i in range(len(bs)):
        if bs[i] == UInt8(ord("T")):
            bm.set(i)
    return Column.from_boolean(BooleanArray.from_bitmap(bm^))


def _assert_bool(s: ColumnStats, mn: Int, mx: Int, ndv: Int, nulls: Int, label: String) raises:
    assert_equal(s.min.value.value().int_val, Int64(mn), label + " min")
    assert_equal(s.max.value.value().int_val, Int64(mx), label + " max")
    assert_true(s.sum.is_absent(), label + " no sum over booleans")
    assert_equal(s.distinct_count.value.value().int_val, Int64(ndv), label + " NDV")
    assert_equal(s.null_count, nulls, label + " nulls")
    assert_equal(s.avg_size_bytes, 1.0, label + " avg")


def test_bools_bits_slice_and_nulls() raises:
    _assert_bool(_stats1(_bools("TFTTFFTFTT"), ArrowType.BOOL), 0, 1, 2, 0, "mixed")
    # Bits 9 and 10 are the only true ones: a view from offset 9 is in the
    # second byte, so a wrong byte or bit index reads a false. (`slice`
    # refuses BOOL, so the view is set by hand.)
    var tail = _bools("FFFFFFFFFTT")
    tail._offset = 9
    tail._length = 2
    _assert_bool(_stats1(tail^, ArrowType.BOOL), 1, 1, 1, 0, "offset 9")
    var c = _bools("FTTT")
    var nulls = List[Int]()
    nulls.append(0)
    _set_nulls(c, nulls)
    _assert_bool(_stats1(c^, ArrowType.BOOL), 1, 1, 1, 1, "null over a false bit")
    # Offset 9 with a null at physical 11 (a false bit): logical rows are
    # true, true, null. Validity must be read at offset + i too.
    var v = _bools("FFFFFFFFFTTF")
    v._offset = 9
    v._length = 3
    var vnull = List[Int]()
    vnull.append(11)
    _set_nulls(v, vnull)
    _assert_bool(_stats1(v^, ArrowType.BOOL), 1, 1, 1, 1, "offset 9 with a null")


def _strs(vals: List[String], valid: List[Bool], large: Bool) raises -> Column[HeapRegion]:
    if large:
        return Column.from_large_string(LargeStringArray.from_strings_with_validity(vals, valid))
    return Column.from_string(StringArray.from_strings_with_validity(vals, valid))


def _assert_str(
    s: ColumnStats, mn: String, mx: String, ndv: Int, nulls: Int, avg: Float64, label: String
) raises:
    assert_true(s.min.is_exact() and s.max.is_exact(), label + " exact")
    assert_equal(s.min.value.value().string_val, mn, label + " min")
    assert_equal(s.max.value.value().string_val, mx, label + " max")
    assert_true(s.sum.is_absent(), label + " no sum")
    assert_equal(s.distinct_count.value.value().int_val, Int64(ndv), label + " NDV")
    assert_equal(s.null_count, nulls, label + " nulls")
    assert_equal(s.avg_size_bytes, avg, label + " avg")


def test_strings_both_offset_widths() raises:
    for large in range(2):
        var at = ArrowType.LARGE_STRING if large == 1 else ArrowType.STRING
        var tag = String(" large") if large == 1 else String(" small")
        # "ab" < "abc" and "abc" > "ab" are decided by length (a prefix);
        # "" becomes the new minimum after "m".
        var v1 = List[String]()
        var ok1 = List[Bool]()
        for x in ["m", "ab", "", "abc", "zz", "ab", "a"]:
            v1.append(String(x))
            ok1.append(True)
        _assert_str(_stats1(_strs(v1, ok1, large == 1), at), "", "zz", 6, 0, 11.0 / 7.0, "plain" + tag)
        # An empty first value; nulls are zero-length slots; "zzz" null.
        var v2 = List[String]()
        var ok2 = List[Bool]()
        for x in ["", "q", "zzz", "b", "qq", "zzz"]:
            v2.append(String(x))
        for x in [True, True, False, True, True, False]:
            ok2.append(x)
        _assert_str(_stats1(_strs(v2, ok2, large == 1), at), "", "qq", 4, 2, 4.0 / 4.0, "nulls" + tag)
        # All null: no values, average length 0.
        var v3 = List[String]()
        var ok3 = List[Bool]()
        for _ in range(3):
            v3.append(String("x"))
            ok3.append(False)
        var s3 = _stats1(_strs(v3, ok3, large == 1), at)
        assert_equal(s3.null_count, 3, "all null" + tag)
        assert_true(s3.min.is_absent() and s3.max.is_absent(), "all null" + tag)
        assert_equal(s3.distinct_count.value.value().int_val, Int64(0), "all null" + tag)
        assert_equal(s3.avg_size_bytes, 0.0, "all null" + tag)
        # A view at offset 1, length 5, with a null at physical 3: logical
        # rows "a", "m", null, "b", "zz". "zzz" (physical 0) and "aaa"
        # (physical 6) lie outside, so offsets or validity read at i
        # instead of offset + i move min, max or the counts. (`slice`
        # refuses strings, so the view is set by hand.)
        var v4 = List[String]()
        var ok4 = List[Bool]()
        for x in ["zzz", "a", "m", "q", "b", "zz", "aaa"]:
            v4.append(String(x))
        for x in [True, True, True, False, True, True, True]:
            ok4.append(x)
        var c4 = _strs(v4, ok4, large == 1)
        c4._offset = 1
        c4._length = 5
        c4._null_count = 1
        _assert_str(_stats1(c4^, at), "a", "zz", 4, 1, 5.0 / 4.0, "offset view" + tag)


def test_string_field_over_a_column_without_offsets() raises:
    """A field that says STRING over an INT32 column: no offsets buffer, so
    the string scanner returns early. Exact nulls and no min/max are right
    either way; NDV and average size are komira-ai/komira#940."""
    var vals = List[Int]()
    vals.append(1)
    vals.append(2)
    _assert_unscanned(_stats1(_int_col[DType.int32](vals), ArrowType.STRING), 0, "no offsets")


def test_no_scanner_arms() raises:
    var vals = List[Int]()
    for x in [7, 1, 7, 9]:
        vals.append(x)
    var nulls = List[Int]()
    nulls.append(1)
    nulls.append(3)
    # A DECIMAL128 field: NONE kind, the dispatcher's own count-only arm.
    var d = _int_col[DType.int64](vals)
    _set_nulls(d, nulls)
    var ds = _stats1(d^, ArrowType.DECIMAL128)
    _assert_unscanned(ds, 2, "DECIMAL128")
    assert_equal(ds.avg_size_bytes, 16.0, "DECIMAL128 is 16 bytes")
    # DATE64 is INT kind, but `_scan_int_column` has no DATE64 arm, so its
    # min/max/NDV and width are wrong today (komira-ai/komira#940). Only the
    # null count, right either way, is asserted.
    var t = _int_col[DType.int64](vals)
    t.arrow_type = ArrowType.DATE64
    _set_nulls(t, nulls)
    assert_equal(_stats1(t^, ArrowType.DATE64).null_count, 2, "DATE64 nulls")


def test_empty_and_multiple_batches_fold() raises:
    """Batch 1 holds the extremes; batch 2's SIMD blocks must fold into them,
    not replace them. An empty batch in front is skipped; the bloom is sized
    from all batches' rows."""
    var schema = _schema1(ArrowType.INT64)
    var b1 = List[Int]()
    for x in [-5, 300, 12, 12, 13, 14, 15, 16, 17]:
        b1.append(x)
    var b2 = List[Int]()
    for x in [10, 20, 11, 19, 12, 18, 13, 17, 14]:
        b2.append(x)
    var sl = Slab[RecordBatch].create(3)
    sl.append(_batch(_int_col[DType.int64](List[Int]()), schema))
    sl.append(_batch(_int_col[DType.int64](b1), schema))
    sl.append(_batch(_int_col[DType.int64](b2), schema))
    var out = compute_column_stats(sl, schema)
    var all = b1.copy()
    for i in range(len(b2)):
        all.append(b2[i])
    _assert_int_stats(out[0], all, List[Int](), 8.0, "three batches")
    assert_equal(
        out[0].bloom.value()[].num_bytes,
        BloomFilter.with_ndv_fpp(18, BLOOM_FPP).num_bytes,
        "bloom sized for 18 rows",
    )
    var none = Slab[RecordBatch].create(1)
    var empty = compute_column_stats(none, schema)
    # No rows at all: NDV Exact 0 is right here.
    ref e = empty[0]
    _assert_unscanned(e, 0, "no batches")
    assert_true(e.distinct_count.is_exact(), "no batches: NDV Exact")
    assert_equal(e.distinct_count.value.value().int_val, Int64(0), "no batches: NDV 0")
    assert_equal(e.avg_size_bytes, 8.0, "no batches: INT64 width")


# =============================================================================
# 6. Cardinality regimes
# =============================================================================


def _regime(n: Int, modulo: Int, scalar: Bool) raises -> ColumnStats:
    """Stats of `v[i] = i % modulo` for i < n. `scalar` adds a validity
    bitmap (the per-row path) with one null slot appended holding 10^12."""
    var vals = List[Int](capacity=n + 1)
    for i in range(n):
        vals.append(i % modulo)
    if scalar:
        vals.append(1000000000000)
    var col = _int_col[DType.int64](vals)
    if scalar:
        var nulls = List[Int]()
        nulls.append(n)
        _set_nulls(col, nulls)
    return _stats1(col^, ArrowType.INT64)


def _assert_regime(s: ColumnStats, n: Int, modulo: Int, scalar: Bool, label: String) raises:
    var ndv = min(n, modulo)
    assert_equal(s.null_count, 1 if scalar else 0, label + " nulls")
    assert_equal(s.min.value.value().int_val, Int64(0), label + " min")
    assert_equal(s.max.value.value().int_val, Int64(ndv - 1), label + " max")
    var sm = Int64(0)
    for i in range(n):
        sm += Int64(i % modulo)
    assert_equal(s.sum.value.value().int_val, sm, label + " sum")


def test_exact_ndv_across_the_sample_and_poll_points() raises:
    """10 distinct values over 8200 rows (sample at 8192 with < 1024
    distinct) and 2000 distinct over 70000 rows (sample with >= 1024, poll
    at 65536 with a small estimate): NDV stays Exact, the bloom holds every
    value."""
    for path in range(2):
        var scalar = path == 1
        var tag = String(" scalar") if scalar else String(" simd")
        var cases = List[Int]()
        cases.append(8200)
        cases.append(10)
        cases.append(70000)
        cases.append(2000)
        for c in range(2):
            var n = cases[2 * c]
            var m = cases[2 * c + 1]
            var label = String(n) + "%" + String(m) + tag
            var s = _regime(n, m, scalar)
            _assert_regime(s, n, m, scalar, label)
            assert_true(s.distinct_count.is_exact(), label + " Exact")
            assert_equal(s.distinct_count.value.value().int_val, Int64(m), label + " NDV")
            ref bloom = s.bloom.value()[]
            for v in range(m):
                assert_true(bloom.check_hash(_mix64(UInt64(v))), label + " bloom " + String(v))


def test_overflow_keeps_bloom_below_the_cap() raises:
    """5000 distinct values: past the exact set, NDV is the Inexact
    estimate; the estimate is under 64 Ki, so the bloom is kept and holds
    every value."""
    for path in range(2):
        var scalar = path == 1
        var label = String("5000") + (" scalar" if scalar else " simd")
        var s = _regime(5000, 5000, scalar)
        _assert_regime(s, 5000, 5000, scalar, label)
        assert_true(s.distinct_count.is_inexact(), label + " Inexact")
        _within(s.distinct_count.value.value().int_val, 5000, label)
        assert_true(Bool(s.bloom), label + " bloom kept")
        ref bloom = s.bloom.value()[]
        for v in range(5000):
            assert_true(bloom.check_hash(_mix64(UInt64(v))), label + " bloom " + String(v))


def test_high_cardinality_drops_the_bloom() raises:
    """140000 distinct values: the estimate is above 64 Ki, so finalize
    drops the bloom (the poll that stops feeding it earlier is checked in
    `test_bloom_poll_stops_feeding_the_bloom`). The sketch stays."""
    for path in range(2):
        var scalar = path == 1
        var label = String("140000") + (" scalar" if scalar else " simd")
        var s = _regime(140000, 140000, scalar)
        _assert_regime(s, 140000, 140000, scalar, label)
        assert_true(s.distinct_count.is_inexact(), label + " Inexact")
        _within(s.distinct_count.value.value().int_val, 140000, label)
        assert_false(Bool(s.bloom), label + " bloom dropped")
        assert_true(Bool(s.hll), label + " sketch kept")
        assert_equal(Int64(s.hll.value()[].count()), s.distinct_count.value.value().int_val, label)


def test_bloom_poll_stops_feeding_the_bloom() raises:
    """The 65536-row poll is invisible in the final stats (finalize drops a
    high-cardinality bloom either way), so it is checked on the
    accumulator: after 140000 distinct values the bloom is no longer fed;
    after 70000 rows of 2000 distinct values it still is."""
    var hi = _ColAccum(ArrowType.INT64, 140000)
    for v in range(140000):
        hi.note_int(Int64(v))
    assert_true(hi.exact_overflowed, "scalar: exact set abandoned")
    assert_false(hi.bloom_active, "scalar: poll stopped the bloom")
    var lo = _ColAccum(ArrowType.INT64, 70000)
    for v in range(70000):
        lo.note_int(Int64(v % 2000))
    assert_false(lo.exact_overflowed, "scalar: 2000 distinct stay exact")
    assert_true(lo.bloom_active, "scalar: small estimate keeps the bloom")

    var vals = List[Int](capacity=140000)
    for v in range(140000):
        vals.append(v)
    var col = _int_col[DType.int64](vals)
    var hs = _ColAccum(ArrowType.INT64, 140000)
    _scan_int_simd_no_validity[DType.int64](hs, col, 140000)
    assert_true(hs.exact_overflowed, "simd: exact set abandoned")
    assert_false(hs.bloom_active, "simd: poll stopped the bloom")
    var lvals = List[Int](capacity=70000)
    for v in range(70000):
        lvals.append(v % 2000)
    var lcol = _int_col[DType.int64](lvals)
    var ls = _ColAccum(ArrowType.INT64, 70000)
    _scan_int_simd_no_validity[DType.int64](ls, lcol, 70000)
    assert_false(ls.exact_overflowed, "simd: 2000 distinct stay exact")
    assert_true(ls.bloom_active, "simd: small estimate keeps the bloom")


def test_bloom_is_polled_only_every_65536_rows() raises:
    """60000 distinct values in the first 65536 rows (the poll there sees an
    estimate under 64 Ki), then 65535 new values: the estimate passes 64 Ki
    long before row 131071, but the next poll is at 131072, so the bloom is
    still fed. (Estimates for these hashes: 60363 at the poll, 127622 at
    the end.)"""
    var vals = List[Int](capacity=131071)
    for i in range(65536):
        vals.append(i % 60000)
    for i in range(65536, 131071):
        vals.append(1000000 + i)
    var sc = _ColAccum(ArrowType.INT64, 131071)
    for i in range(len(vals)):
        sc.note_int(Int64(vals[i]))
    assert_true(Int(sc.hll.count()) > 65536, "scalar: estimate above the cap")
    assert_true(sc.bloom_active, "scalar: no poll between 65536 and 131072")
    var col = _int_col[DType.int64](vals)
    var sv = _ColAccum(ArrowType.INT64, 131071)
    _scan_int_simd_no_validity[DType.int64](sv, col, 131071)
    assert_true(Int(sv.hll.count()) > 65536, "simd: estimate above the cap")
    assert_true(sv.bloom_active, "simd: no poll between 65536 and 131072")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
