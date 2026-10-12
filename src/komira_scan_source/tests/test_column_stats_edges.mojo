# =============================================================================
# column_stats.mojo, part 3: values the stats must not misreport
# =============================================================================
#
# Parts 1 and 2 are test_column_stats.mojo and test_column_stats_scan.mojo.
# Every test here goes through `compute_column_stats` (or, for the saturated
# sketch, `_finalize_accum`) and holds a statistic to the values by
# definition. Each case reported a wrong statistic before komira-ai/komira#940
# was fixed:
#
#   7. Unscanned values. A column type with no scanner (DECIMAL128, FLOAT16),
#      a STRING field over a DICTIONARY batch next to a STRING batch, and a
#      STRING field over a column without offsets: the NDV was Exact 0 (or
#      the min/max Exact over the scanned batch only, or the nulls of the
#      offset-less column uncounted). Now: exact nulls, everything else
#      Absent, no sketch, no bloom; one unscanned value is enough. FLOAT16
#      and DATE64 widths are 2 and 8.
#   8. Floats. NaN (one or several): min over the other values, max and
#      sum Absent, one distinct NaN. All NaN: no min/max. All +inf / all
#      -inf: the infinity, not the largest finite value. -0.0 and +0.0:
#      one distinct value.
#   9. Integers. A sum that wraps Int64 (in one SIMD lane, in the lane fold,
#      on the scalar path, downwards) is Absent; one that ends in range
#      without wrapping is Exact. A UINT64 value above Int64.MAX: no
#      min/max/sum, NDV still exact.
#  10. A saturated sketch on an overflowed column: the Inexact NDV is the
#      non-null value count, not 0.
# =============================================================================

from std.math import inf
from std.sys import simd_width_of
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
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
from komira_scan_source.column_stats import (
    ColumnStats,
    _finalize_accum,
    compute_column_stats,
)
from komira_scan_source.column_stats_accum import _ColAccum

comptime W = simd_width_of[DType.int64]()


# =============================================================================
# Fixture helpers
# =============================================================================


def _int_col[dt: DType](vals: List[Scalar[dt]]) -> Column[HeapRegion]:
    return Column.from_primitive[dt](PrimitiveArray[dt].from_list(vals.copy()))


def _f64_col(vals: List[Float64]) -> Column[HeapRegion]:
    return Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(vals.copy())
    )


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
    return out[0].copy()


def _assert_only_nulls_known(s: ColumnStats, nulls: Int, label: String) raises:
    assert_equal(s.null_count, nulls, label + ": null_count")
    assert_true(s.min.is_absent() and s.max.is_absent(), label + ": no min/max")
    assert_true(s.sum.is_absent(), label + ": no sum")
    assert_true(s.distinct_count.is_absent(), label + ": NDV Absent, not Exact 0")
    assert_false(Bool(s.hll), label + ": no sketch")
    assert_false(Bool(s.bloom), label + ": no bloom")


def _nan() -> Float64:
    return Float64(0.0) / Float64(0.0)


def _ndv(s: ColumnStats) -> Int64:
    return s.distinct_count.value.value().int_val


# =============================================================================
# 7. Unscanned values
# =============================================================================


def test_types_without_a_scanner_report_only_nulls() raises:
    var vals = List[Int64]()
    for x in [7, 1, 7, 9]:
        vals.append(Int64(x))
    var nulls = List[Int]()
    nulls.append(1)
    var d = _int_col[DType.int64](vals)
    _set_nulls(d, nulls)
    var ds = _stats1(d^, ArrowType.DECIMAL128)
    _assert_only_nulls_known(ds, 1, "DECIMAL128")
    assert_equal(ds.avg_size_bytes, 16.0, "DECIMAL128 width")
    var h = List[Int16]()
    for x in [1, 2, 3]:
        h.append(Int16(x))
    var hc = _int_col[DType.int16](h)
    hc.arrow_type = ArrowType.FLOAT16
    var hs = _stats1(hc^, ArrowType.FLOAT16)
    _assert_only_nulls_known(hs, 0, "FLOAT16")
    assert_equal(hs.avg_size_bytes, 2.0, "FLOAT16 width")


def test_date64_width_is_8() raises:
    var vals = List[Int64]()
    vals.append(Int64(86400000))
    var c = _int_col[DType.int64](vals)
    c.arrow_type = ArrowType.DATE64
    var s = _stats1(c^, ArrowType.DATE64)
    assert_equal(s.avg_size_bytes, 8.0)
    assert_equal(s.min.value.value().int_val, Int64(86400000), "DATE64 is scanned")


def test_string_field_over_a_dictionary_batch_claims_nothing() raises:
    """Batch 1 is a STRING column, batch 2 a DICTIONARY column under the
    same STRING field. Min/max/NDV over batch 1 alone would be wrong for
    the relation ("a" is not the minimum: batch 2 holds "0")."""
    var schema = _schema1(ArrowType.STRING)
    var sv = List[String]()
    sv.append(String("b"))
    sv.append(String("a"))
    var dv = List[String]()
    dv.append(String("0"))
    dv.append(String("zz"))
    var idx = List[Int32]()
    idx.append(Int32(0))
    idx.append(Int32(1))
    var dict_col = Column.from_dictionary(
        StringDictionaryArray.from_parts(
            PrimitiveArray[DType.int32].from_list(idx^), StringArray.from_strings(dv)
        )
    )
    var sl = Slab[RecordBatch].create(2)
    sl.append(_batch(Column.from_string(StringArray.from_strings(sv)), schema))
    sl.append(_batch(dict_col^, schema))
    var s = compute_column_stats(sl, schema)[0].copy()
    _assert_only_nulls_known(s, 0, "string + dictionary batches")
    assert_equal(s.avg_size_bytes, 0.0, "no width known")


def test_string_field_over_a_column_without_offsets_counts_nulls() raises:
    var vals = List[Int32]()
    for x in [1, 2, 3, 4]:
        vals.append(Int32(x))
    var c = _int_col[DType.int32](vals)
    var nulls = List[Int]()
    nulls.append(0)
    nulls.append(2)
    _set_nulls(c, nulls)
    var s = _stats1(c^, ArrowType.STRING)
    _assert_only_nulls_known(s, 2, "no offsets")
    assert_equal(s.avg_size_bytes, 0.0, "no width known")


# Exactly one non-null value goes unscanned in each of the next three
# tests, so a check that needed two (`n_unscanned > 1`) would report NDV
# Exact 0 for the DECIMAL128 columns and Exact min/max over the STRING batch.


def test_one_row_decimal_column_reports_only_nulls() raises:
    var one = List[Int64]()
    one.append(Int64(42))
    _assert_only_nulls_known(
        _stats1(_int_col[DType.int64](one), ArrowType.DECIMAL128), 0, "one DECIMAL128 row"
    )


def test_one_decimal_value_among_nulls_reports_only_nulls() raises:
    var three = List[Int64]()
    for x in [5, 6, 7]:
        three.append(Int64(x))
    var dn = _int_col[DType.int64](three)
    var nulls = List[Int]()
    nulls.append(0)
    nulls.append(2)
    _set_nulls(dn, nulls)
    _assert_only_nulls_known(_stats1(dn^, ArrowType.DECIMAL128), 2, "one DECIMAL128 value, two nulls")


def test_string_batch_beside_a_one_index_dictionary_batch_claims_nothing() raises:
    var schema = _schema1(ArrowType.STRING)
    var sv = List[String]()
    sv.append(String("b"))
    sv.append(String("a"))
    var dv = List[String]()
    dv.append(String("0"))
    var idx = List[Int32]()
    idx.append(Int32(0))
    var dict_col = Column.from_dictionary(
        StringDictionaryArray.from_parts(
            PrimitiveArray[DType.int32].from_list(idx^), StringArray.from_strings(dv)
        )
    )
    var sl = Slab[RecordBatch].create(2)
    sl.append(_batch(Column.from_string(StringArray.from_strings(sv)), schema))
    sl.append(_batch(dict_col^, schema))
    var s = compute_column_stats(sl, schema)[0].copy()
    _assert_only_nulls_known(s, 0, "string batch + one-index dictionary batch")


# =============================================================================
# 8. Floats
# =============================================================================


def test_nan_leaves_min_and_drops_max_and_sum() raises:
    var vals = List[Float64]()
    vals.append(1.0)
    vals.append(_nan())
    vals.append(-2.0)
    vals.append(-_nan())  # a NaN with the sign bit set: another bit pattern
    var s = _stats1(_f64_col(vals), ArrowType.FLOAT64)
    assert_true(s.min.is_exact(), "min over the non-NaN values")
    assert_equal(s.min.value.value().float_val, -2.0)
    assert_true(s.max.is_absent(), "NaN orders above 1.0: no max")
    assert_true(s.sum.is_absent(), "a NaN sum is not reported")
    assert_true(s.distinct_count.is_exact())
    assert_equal(_ndv(s), Int64(3), "1.0, -2.0 and one NaN")


def test_one_nan_drops_max() raises:
    # Exactly one NaN: a max over the other values would let `x > c` prune
    # the NaN row.
    var vals = List[Float64]()
    vals.append(1.0)
    vals.append(_nan())
    vals.append(-2.0)
    var s = _stats1(_f64_col(vals), ArrowType.FLOAT64)
    assert_true(s.max.is_absent(), "one NaN orders above 1.0: no max")
    assert_true(s.min.is_exact(), "min over the non-NaN values")
    assert_equal(s.min.value.value().float_val, -2.0)
    assert_true(s.sum.is_absent(), "a NaN sum is not reported")
    assert_equal(_ndv(s), Int64(3), "1.0, -2.0 and one NaN")


def test_one_value_beside_nans_is_the_min() raises:
    var vals = List[Float64]()
    vals.append(_nan())
    vals.append(5.0)
    vals.append(_nan())
    var s = _stats1(_f64_col(vals), ArrowType.FLOAT64)
    assert_true(s.min.is_exact(), "the one non-NaN value is the min")
    assert_equal(s.min.value.value().float_val, 5.0)
    assert_true(s.max.is_absent(), "NaN orders above 5.0: no max")
    assert_equal(_ndv(s), Int64(2), "5.0 and one NaN")


def test_all_nan_has_no_min_or_max() raises:
    var vals = List[Float64]()
    vals.append(_nan())
    vals.append(_nan())
    var s = _stats1(_f64_col(vals), ArrowType.FLOAT64)
    assert_true(s.min.is_absent() and s.max.is_absent(), "no orderable value")
    assert_true(s.sum.is_absent())
    assert_equal(_ndv(s), Int64(1))


def test_infinities_are_their_own_extremes() raises:
    var pos = List[Float64]()
    pos.append(inf[DType.float64]())
    pos.append(inf[DType.float64]())
    var p = _stats1(_f64_col(pos), ArrowType.FLOAT64)
    assert_equal(p.min.value.value().float_val, inf[DType.float64](), "all +inf: min")
    assert_equal(p.max.value.value().float_val, inf[DType.float64](), "all +inf: max")
    assert_true(p.sum.is_absent(), "an infinite sum is not reported")
    var neg = List[Float64]()
    neg.append(-inf[DType.float64]())
    neg.append(1.0)
    var n = _stats1(_f64_col(neg), ArrowType.FLOAT64)
    assert_equal(n.min.value.value().float_val, -inf[DType.float64](), "-inf min")
    assert_equal(n.max.value.value().float_val, 1.0)
    var negonly = List[Float64]()
    negonly.append(-inf[DType.float64]())
    var no = _stats1(_f64_col(negonly), ArrowType.FLOAT64)
    assert_equal(no.max.value.value().float_val, -inf[DType.float64](), "all -inf: max")


def test_signed_zeros_are_one_value() raises:
    var vals = List[Float64]()
    vals.append(0.0)
    vals.append(-0.0)
    vals.append(0.0)
    var s = _stats1(_f64_col(vals), ArrowType.FLOAT64)
    assert_equal(_ndv(s), Int64(1), "-0.0 == +0.0")
    assert_equal(s.min.value.value().float_val, 0.0)
    assert_equal(s.max.value.value().float_val, 0.0)


# =============================================================================
# 9. Integers
# =============================================================================


def _sum_absent(var c: Column[HeapRegion], label: String) raises:
    var s = _stats1(c^, ArrowType.INT64)
    assert_true(s.sum.is_absent(), label + ": a wrapped sum is not reported")
    assert_true(s.min.is_exact() and s.max.is_exact(), label + ": min/max kept")


def test_int64_sum_that_wraps_is_absent() raises:
    var mx = Int64.MAX
    # W rows of MAX: one per SIMD lane, so only the lane fold wraps.
    var fold = List[Int64]()
    for _ in range(W):
        fold.append(mx)
    _sum_absent(_int_col[DType.int64](fold), "lane fold")
    # 2W rows of MAX: every lane wraps inside the SIMD loop (MAX + MAX is
    # -2 wrapped); the fold of W lanes of -2 does not wrap, so only the
    # in-loop check sees it.
    var lane = List[Int64]()
    for _ in range(2 * W):
        lane.append(mx)
    _sum_absent(_int_col[DType.int64](lane), "SIMD lane")
    # The scalar path (a validity bitmap), upwards and downwards.
    var up = List[Int64]()
    up.append(mx)
    up.append(Int64(1))
    up.append(Int64(5))
    var cu = _int_col[DType.int64](up)
    var nulls = List[Int]()
    nulls.append(2)
    _set_nulls(cu, nulls)
    _sum_absent(cu^, "scalar up")
    var down = List[Int64]()
    down.append(Int64.MIN)
    down.append(Int64(-1))
    _sum_absent(_int_col[DType.int64](down), "downwards")


def test_int64_sum_in_range_stays_exact() raises:
    var vals = List[Int64]()
    vals.append(Int64.MAX)
    vals.append(Int64(-1))
    vals.append(Int64(1))
    vals.append(Int64.MIN)
    var s = _stats1(_int_col[DType.int64](vals), ArrowType.INT64)
    assert_true(s.sum.is_exact())
    assert_equal(s.sum.value.value().int_val, Int64(-1))


def test_uint64_above_int64_max_has_no_min_max_sum() raises:
    for path in range(2):
        var vals = List[UInt64]()
        vals.append(UInt64.MAX)
        vals.append(UInt64(1))
        vals.append(UInt64(1) << 63)
        for _ in range(W):
            vals.append(UInt64(7))
        var c = _int_col[DType.uint64](vals)
        c.arrow_type = ArrowType.UINT64
        if path == 1:
            var nulls = List[Int]()
            nulls.append(3)
            _set_nulls(c, nulls)
        var s = _stats1(c^, ArrowType.UINT64)
        var label = String("path ") + String(path)
        assert_true(s.min.is_absent() and s.max.is_absent(), label + ": no min/max")
        assert_true(s.sum.is_absent(), label + ": no sum")
        assert_true(s.distinct_count.is_exact(), label)
        assert_equal(_ndv(s), Int64(4), label + ": NDV is over the bits")


# =============================================================================
# 10. Saturated sketch
# =============================================================================


def test_saturated_sketch_ndv_is_capped_at_the_value_count() raises:
    """5000 distinct values overflow the exact set; then every register is
    forced to Q + 1, the state 4096 hashes below 4096 produce. The estimate
    is unbounded, so the NDV is the non-null value count."""
    var acc = _ColAccum(ArrowType.INT64, 5000)
    for v in range(5000):
        acc.note_int(Int64(v))
    assert_true(acc.exact_overflowed)
    for i in range(4096):
        acc.hll.registers[i] = UInt8(53)
    var s = _finalize_accum(acc)
    assert_true(s.distinct_count.is_inexact())
    assert_equal(_ndv(s), Int64(5000))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
