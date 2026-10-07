# =============================================================================
# `agg_mixed_cd_fold`: what the mixed fold answers, over one batch and over a
# batch list.
#
# The oracle is hand arithmetic over the six-row fixture below; every expected
# value is written next to the rows it comes from. What each part proves:
#
#   * every accumulator kind in one node: COUNT(DISTINCT) over INT64 and
#     FLOAT64 (with -0.0 counted as +0.0), COUNT(*) and COUNT(col), SUM, MIN,
#     MAX and MEAN over INT64, INT32, FLOAT64 (with a NaN, ordered above every
#     number) and FLOAT32, and a STRING MIN and LARGE_STRING MAX (the shared
#     and the decoded string reader) — NULL inputs skipped, a group with no
#     contributing row emitting NULL (0 for the counts), and the empty string
#     a value;
#   * group keys emitted in their own type (STRING, INT32, INT64, composite);
#   * the 0-key node: one row, and one identity row over an empty input;
#   * the declines of both public entries (not a candidate, above the
#     ceiling, a missing column, a NULL-bearing key, nothing off-cell left,
#     an empty or disagreeing batch list, a count-only batch that is not a
#     schema source);
#   * the batch list: split across batches (with an empty first batch) it
#     answers exactly what the single batch answers; an all-empty list still
#     resolves its output schema;
#   * the group table: 2,000 groups grow and rehash it, and two composite keys
#     with the SAME hash (computed by inverting splitmix64) stay two groups;
#   * the NULL-key guard inside the fold skips a row whose key is NULL.
# =============================================================================

from std.collections import List, Optional
from std.math import isnan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_plan_expr.agg_expr import (
    AggExpr, AGG_COUNT, AGG_COUNT_DISTINCT, AGG_MAX, AGG_MEAN, AGG_MIN, AGG_SUM,
)
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    AggExprArray, ExprArray, LogicalPlan, SOURCE_PARQUET,
)
from komira_plan_ir.logical_plan_variants import AggregateData

from komira_dispatch_agg_folds.agg_mixed_cd_fold import (
    _MIX_FOLD_MAX_ROWS,
    _MixFoldInputs,
    _mix_extract_batch,
    _mix_fold_and_emit,
    fold_mixed_count_distinct_over_batch,
    fold_mixed_count_distinct_over_batches,
)

# (1, 2) and (3, _COLLIDING_B) give the same composite key hash: the second
# key was solved for by inverting `_cd_hash_combine` and the splitmix64
# finalizer, both bijections in the term being solved for.
comptime _COLLIDING_B: Int64 = -1472219984424839413


# =============================================================================
# The fixture
# =============================================================================
#
# row | ks | k32 | k64 | cd   | cdf  | i    | i32 | f    | f32 | s    | ls
#  0  | a  | 1   | 10  | 5    | 0.0  | 4    | 1   | 2.5  | 1.5 | 'p'  | 'p'
#  1  | b  | 2   | 20  | NULL | -0.0 | NULL | 2   | NULL | 2.5 | NULL | NULL
#  2  | a  | 1   | 10  | 5    | -0.0 | 9    | 3   | NaN  | 0.5 | 'c'  | 'x'
#  3  | c  | 3   | 30  | 7    | 1.0  | NULL | 4   | NULL | 3.5 | NULL | NULL
#  4  | a  | 1   | 10  | 6    | 2.0  | 2    | 5   | 1.0  | 4.5 | 'pq' | 'pa'
#  5  | b  | 2   | 20  | 8    | 2.0  | 3    | 6   | -4.0 | 5.5 | ''   | 'z'
#
# Groups a (rows 0,2,4), b (1,5), c (3), in that order.


def _rows(lo: Int, hi: Int) raises -> RecordBatch:
    """Rows [lo, hi) of the fixture, as one batch with the full schema."""
    var ks: List[String] = [String("a"), String("b"), String("a"), String("c"), String("a"), String("b")]
    var k32: List[Int32] = [1, 2, 1, 3, 1, 2]
    var k64: List[Int64] = [10, 20, 10, 30, 10, 20]
    var cd: List[Int64] = [5, 0, 5, 7, 6, 8]
    var cdok: List[Bool] = [True, False, True, True, True, True]
    var cdf: List[Float64] = [0.0, -0.0, -0.0, 1.0, 2.0, 2.0]
    var iv: List[Int64] = [4, 0, 9, 0, 2, 3]
    var iok: List[Bool] = [True, False, True, False, True, True]
    var i32: List[Int32] = [1, 2, 3, 4, 5, 6]
    var zero = Float64(0.0)
    var fv: List[Float64] = [2.5, 0.0, zero / zero, 0.0, 1.0, -4.0]
    var fok: List[Bool] = [True, False, True, False, True, True]
    var f32: List[Float32] = [1.5, 2.5, 0.5, 3.5, 4.5, 5.5]
    var sv: List[String] = [String("p"), String(""), String("c"), String(""), String("pq"), String("")]
    var sok: List[Bool] = [True, False, True, False, True, True]
    var lv: List[String] = [String("p"), String(""), String("x"), String(""), String("pa"), String("z")]
    var lok: List[Bool] = [True, False, True, False, True, True]
    var n = hi - lo
    var rbb = RecordBatchBuilder.with_capacity(12)
    var sb = SchemaBuilder()
    var a_ks = List[String]()
    var a_sv = List[String]()
    var a_sok = List[Bool]()
    var a_lv = List[String]()
    var a_lok = List[Bool]()
    var p32 = PrimitiveArray[DType.int32].allocate(n)
    var p64 = PrimitiveArray[DType.int64].allocate(n)
    var pcd = PrimitiveArray[DType.int64].allocate_nullable(n)
    var pcdf = PrimitiveArray[DType.float64].allocate(n)
    var pi = PrimitiveArray[DType.int64].allocate_nullable(n)
    var pi32 = PrimitiveArray[DType.int32].allocate(n)
    var pf = PrimitiveArray[DType.float64].allocate_nullable(n)
    var pf32 = PrimitiveArray[DType.float32].allocate(n)
    for r in range(lo, hi):
        var j = r - lo
        a_ks.append(ks[r])
        a_sv.append(sv[r])
        a_sok.append(sok[r])
        a_lv.append(lv[r])
        a_lok.append(lok[r])
        p32._typed_ptr_mut()[j] = k32[r]
        p64._typed_ptr_mut()[j] = k64[r]
        pcd.set(j, cd[r])
        if not cdok[r]:
            pcd._set_null(j)
        pcdf._typed_ptr_mut()[j] = cdf[r]
        pi.set(j, iv[r])
        if not iok[r]:
            pi._set_null(j)
        pi32._typed_ptr_mut()[j] = i32[r]
        pf.set(j, fv[r])
        if not fok[r]:
            pf._set_null(j)
        pf32._typed_ptr_mut()[j] = f32[r]
    rbb.add_column(Column.from_string(StringArray.from_strings(a_ks)))
    sb.add_field(Field(String("ks"), ArrowType.STRING, False))
    rbb.add_column(Column.from_primitive[DType.int32](p32^))
    sb.add_field(Field(String("k32"), ArrowType.INT32, False))
    rbb.add_column(Column.from_primitive[DType.int64](p64^))
    sb.add_field(Field(String("k64"), ArrowType.INT64, False))
    rbb.add_column(Column.from_primitive[DType.int64](pcd^))
    sb.add_field(Field(String("cd"), ArrowType.INT64, True))
    rbb.add_column(Column.from_primitive[DType.float64](pcdf^))
    sb.add_field(Field(String("cdf"), ArrowType.FLOAT64, False))
    rbb.add_column(Column.from_primitive[DType.int64](pi^))
    sb.add_field(Field(String("i"), ArrowType.INT64, True))
    rbb.add_column(Column.from_primitive[DType.int32](pi32^))
    sb.add_field(Field(String("i32"), ArrowType.INT32, False))
    rbb.add_column(Column.from_primitive[DType.float64](pf^))
    sb.add_field(Field(String("f"), ArrowType.FLOAT64, True))
    rbb.add_column(Column.from_primitive[DType.float32](pf32^))
    sb.add_field(Field(String("f32"), ArrowType.FLOAT32, False))
    rbb.add_column(Column.from_string(StringArray.from_strings_with_validity(a_sv, a_sok)))
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    rbb.add_column(Column.from_large_string(LargeStringArray.from_strings_with_validity(a_lv, a_lok)))
    sb.add_field(Field(String("ls"), ArrowType.LARGE_STRING, True))
    return rbb.build(sb.build())


def _agg(imm keys: List[String], var aggs: AggExprArray) raises -> AggregateData:
    var k = ExprArray()
    for i in range(len(keys)):
        k.append(Expr.col_ref(keys[i]))
    var child = LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, _rows(0, 0).schema.copy())
    return AggregateData(k^, aggs^, child^)


def _a(func: UInt8, col: String) raises -> AggExpr:
    return AggExpr(func, Optional[Expr](Expr.col_ref(col)), Optional[String](None))


def _star() raises -> AggExpr:
    return AggExpr(AGG_COUNT, Optional[Expr](None), Optional[String](None))


def _every_kind() raises -> AggExprArray:
    """Columns after the key: 1 CD(cd), 2 CD(cdf), 3 COUNT(*), 4 COUNT(i),
    5 SUM(i), 6 MIN(i), 7 MAX(i), 8 MEAN(i), 9 SUM(f), 10 MIN(f), 11 MAX(f),
    12 MEAN(f), 13 SUM(i32), 14 MIN(f32), 15 MIN(s), 16 MAX(ls), 17 MAX(ks)."""
    var a = AggExprArray()
    a.append(_a(AGG_COUNT_DISTINCT, String("cd")))
    a.append(_a(AGG_COUNT_DISTINCT, String("cdf")))
    a.append(_star())
    a.append(_a(AGG_COUNT, String("i")))
    a.append(_a(AGG_SUM, String("i")))
    a.append(_a(AGG_MIN, String("i")))
    a.append(_a(AGG_MAX, String("i")))
    a.append(_a(AGG_MEAN, String("i")))
    a.append(_a(AGG_SUM, String("f")))
    a.append(_a(AGG_MIN, String("f")))
    a.append(_a(AGG_MAX, String("f")))
    a.append(_a(AGG_MEAN, String("f")))
    a.append(_a(AGG_SUM, String("i32")))
    a.append(_a(AGG_MIN, String("f32")))
    a.append(_a(AGG_MIN, String("s")))
    a.append(_a(AGG_MAX, String("ls")))
    a.append(_a(AGG_MAX, String("ks")))
    return a^


def _keys(k: String) -> List[String]:
    var o = List[String]()
    o.append(k)
    return o^


def _serve(imm ad: AggregateData, imm batch: RecordBatch) raises -> RecordBatch:
    var o = fold_mixed_count_distinct_over_batch(ad, batch)
    assert_true(o.__bool__(), "the mixed fold declined a shape it serves")
    return o.take()


def _i(imm b: RecordBatch, c: Int, r: Int) raises -> Int:
    var col = b.column_as_primitive_int64(c)
    assert_false(col.is_null(r), "unexpected NULL at column " + String(c))
    return Int(col.get(r))


def _f(imm b: RecordBatch, c: Int, r: Int) raises -> Float64:
    var col = b.column_as_primitive_float64(c)
    assert_false(col.is_null(r), "unexpected NULL at column " + String(c))
    return col.get(r)


def _is_null(imm b: RecordBatch, c: Int, r: Int) raises -> Bool:
    return b.column_at(c).is_null_at(r)


def _s(imm b: RecordBatch, c: Int, r: Int) raises -> String:
    var col = b.column_as_string(c)
    if col.is_null(r):
        return String("<NULL>")
    return col.get(r)


def _check_every_kind(imm out: RecordBatch) raises:
    """The hand oracle for `_every_kind` grouped by a key whose groups are a,
    b, c in that order."""
    assert_equal(out.num_rows(), 3)
    # CD(cd): a {5,6}; b {8} (NULL skipped); c {7}.
    assert_equal(_i(out, 1, 0), 2)
    assert_equal(_i(out, 1, 1), 1)
    assert_equal(_i(out, 1, 2), 1)
    # CD(cdf): a {0.0, -0.0, 2.0} = {0, 2}; b {-0.0, 2.0} = 2; c 1.
    assert_equal(_i(out, 2, 0), 2)
    assert_equal(_i(out, 2, 1), 2)
    assert_equal(_i(out, 2, 2), 1)
    # COUNT(*) 3, 2, 1; COUNT(i) 3, 1, 0 (0, not NULL).
    assert_equal(_i(out, 3, 0), 3)
    assert_equal(_i(out, 3, 2), 1)
    assert_equal(_i(out, 4, 1), 1)
    assert_equal(_i(out, 4, 2), 0)
    # SUM(i) 15, 3, NULL; MIN(i) 2, 3, NULL; MAX(i) 9, 3, NULL.
    assert_equal(_i(out, 5, 0), 15)
    assert_true(_is_null(out, 5, 2))
    assert_equal(_i(out, 6, 0), 2)
    assert_equal(_i(out, 6, 1), 3)
    assert_true(_is_null(out, 6, 2))
    assert_equal(_i(out, 7, 0), 9)
    assert_true(_is_null(out, 7, 2))
    # MEAN(i) 5.0, 3.0, NULL.
    assert_equal(_f(out, 8, 0), 5.0)
    assert_equal(_f(out, 8, 1), 3.0)
    assert_true(_is_null(out, 8, 2))
    # SUM(f): a holds a NaN; b -4.0; c NULL.
    assert_true(isnan(_f(out, 9, 0)))
    assert_equal(_f(out, 9, 1), -4.0)
    assert_true(_is_null(out, 9, 2))
    # MIN(f): NaN sorts above every number, so a's MIN is 1.0; MAX(f) is NaN.
    assert_equal(_f(out, 10, 0), 1.0)
    assert_equal(_f(out, 10, 1), -4.0)
    assert_true(_is_null(out, 10, 2))
    assert_true(isnan(_f(out, 11, 0)))
    assert_equal(_f(out, 11, 1), -4.0)
    # MEAN(f): a NaN, b -4.0, c NULL.
    assert_true(isnan(_f(out, 12, 0)))
    assert_equal(_f(out, 12, 1), -4.0)
    assert_true(_is_null(out, 12, 2))
    # SUM(i32) 9, 8, 4 — no NULL, so the field is not nullable.
    assert_equal(_i(out, 13, 0), 9)
    assert_equal(_i(out, 13, 1), 8)
    assert_equal(_i(out, 13, 2), 4)
    assert_false(out.schema.field_at_unchecked(13).nullable)
    # MIN(f32) 0.5, 2.5, 3.5.
    assert_equal(_f(out, 14, 0), 0.5)
    assert_equal(_f(out, 14, 2), 3.5)
    assert_false(out.schema.field_at_unchecked(14).nullable)
    # MIN(s): a 'c'; b '' (a value); c NULL.  MAX(ls): a 'x'; b 'z'; c NULL.
    assert_equal(_s(out, 15, 0), "c")
    assert_equal(_s(out, 15, 1), "")
    assert_equal(_s(out, 15, 2), "<NULL>")
    assert_true(out.schema.field_at_unchecked(15).nullable)
    assert_equal(_s(out, 16, 0), "x")
    assert_equal(_s(out, 16, 1), "z")
    assert_equal(_s(out, 16, 2), "<NULL>")
    # MAX(ks): every group saw a value, so no validity.
    assert_equal(_s(out, 17, 1), "b")
    assert_false(out.schema.field_at_unchecked(17).nullable)
    assert_true(out.schema.field_at_unchecked(5).nullable)
    assert_true(out.column_arrow_type(1) == ArrowType.INT64)
    assert_true(out.column_arrow_type(14) == ArrowType.FLOAT64)


# =============================================================================
# One batch
# =============================================================================


def test_every_accumulator_kind_by_a_string_key() raises:
    """The full oracle by the STRING key, which is emitted STRING and not
    nullable. Catches, among others: the MIN arm comparing with IEEE `<`
    (a NaN seed would stick), MEAN divided by COUNT(*) instead of the
    contributing count, and '' read as 'no value'."""
    var batch = _rows(0, 6)
    var out = _serve(_agg(_keys(String("ks")), _every_kind()), batch)
    _check_every_kind(out)
    assert_equal(_s(out, 0, 0), "a")
    assert_equal(_s(out, 0, 2), "c")
    assert_false(out.schema.field_at_unchecked(0).nullable)


def test_int32_and_int64_keys_keep_their_own_type() raises:
    """By the INT32 key the key column is INT32 (not widened); by the INT64
    key it is INT64; a composite (ks, k64) key gives the same three groups.
    Catches the INT32 key emitted INT64."""
    var batch = _rows(0, 6)
    var o32 = _serve(_agg(_keys(String("k32")), _every_kind()), batch)
    assert_true(o32.column_arrow_type(0) == ArrowType.INT32)
    assert_equal(Int(o32.column_as_primitive[DType.int32](0).get(2)), 3)
    _check_every_kind(o32)
    var o64 = _serve(_agg(_keys(String("k64")), _every_kind()), batch)
    assert_true(o64.column_arrow_type(0) == ArrowType.INT64)
    assert_equal(_i(o64, 0, 1), 20)
    var both: List[String] = [String("ks"), String("k64")]
    var oc = _serve(_agg(both, _two(_a(AGG_COUNT_DISTINCT, String("cd")), _star())), batch)
    assert_equal(oc.num_rows(), 3)
    assert_equal(_i(oc, 1, 2), 30)
    assert_equal(_i(oc, 3, 0), 3)


def _two(var x: AggExpr, var y: AggExpr) -> AggExprArray:
    var a = AggExprArray()
    a.append(x^)
    a.append(y^)
    return a^


def test_zero_key_node_is_one_row_and_an_empty_input_is_the_identity() raises:
    """0 keys: CD(cd) = |{5,6,7,8}| = 4 and COUNT(*) = 6 in one row. Over a
    0-row batch: still one row, CD 0, COUNT 0, SUM NULL, MIN(s) NULL. Catches
    the up-front implicit group removed (an empty input would emit no row)."""
    var aggs = AggExprArray()
    aggs.append(_a(AGG_COUNT_DISTINCT, String("cd")))
    aggs.append(_star())
    aggs.append(_a(AGG_SUM, String("i")))
    aggs.append(_a(AGG_MIN, String("s")))
    var ad = _agg(List[String](), aggs^)
    var out = _serve(ad, _rows(0, 6))
    assert_equal(out.num_rows(), 1)
    assert_equal(_i(out, 0, 0), 4)
    assert_equal(_i(out, 1, 0), 6)
    assert_equal(_i(out, 2, 0), 18)
    assert_equal(_s(out, 3, 0), "")
    var empty = _serve(ad, _rows(0, 0))
    assert_equal(empty.num_rows(), 1)
    assert_equal(_i(empty, 0, 0), 0)
    assert_equal(_i(empty, 1, 0), 0)
    assert_true(_is_null(empty, 2, 0))
    assert_equal(_s(empty, 3, 0), "<NULL>")


def test_single_batch_declines() raises:
    """Not a candidate (all CD); above the ceiling (a count-only batch); a
    missing column; a NULL-bearing key; nothing off-cell left (a numeric MIN
    beside COUNT(*)). Each is None. Catches the off-cell survivor check
    removed (a numeric node would be served serially)."""
    var batch = _rows(0, 6)
    var k = _keys(String("ks"))
    assert_false(fold_mixed_count_distinct_over_batch(_agg(k, _two(_a(AGG_COUNT_DISTINCT, String("cd")), _a(AGG_COUNT_DISTINCT, String("i")))), batch).__bool__())
    assert_false(fold_mixed_count_distinct_over_batch(_agg(List[String](), _two(_a(AGG_COUNT_DISTINCT, String("cd")), _star())), RecordBatch.count_only(_MIX_FOLD_MAX_ROWS + 1)).__bool__())
    assert_false(fold_mixed_count_distinct_over_batch(_agg(k, _two(_a(AGG_COUNT_DISTINCT, String("nope")), _star())), batch).__bool__())
    assert_false(fold_mixed_count_distinct_over_batch(_agg(_keys(String("cd")), _two(_a(AGG_COUNT_DISTINCT, String("i")), _star())), batch).__bool__())
    assert_false(fold_mixed_count_distinct_over_batch(_agg(k, _two(_a(AGG_MIN, String("i")), _star())), batch).__bool__())


# =============================================================================
# The batch list
# =============================================================================


def _slab3(var a: RecordBatch, var b: RecordBatch, var c: RecordBatch) -> Slab[RecordBatch]:
    var s = Slab[RecordBatch]()
    s.append(a^)
    s.append(b^)
    s.append(c^)
    return s^


def test_a_split_batch_list_answers_what_one_batch_answers() raises:
    """[empty, rows 0-2, rows 3-5]: the same answer as the single batch,
    because a group's retained key and string best can sit in a different
    batch from the row compared against them; and a node whose only off-cell
    aggregate is a string MIN is served over the list too. Catches the empty
    first batch used as the schema source, a cross-batch compare that reads
    the wrong batch, and the off-cell survivor check written with `or`."""
    var bs = _slab3(_rows(0, 0), _rows(0, 3), _rows(3, 6))
    var o = fold_mixed_count_distinct_over_batches(_agg(_keys(String("ks")), _every_kind()), bs)
    assert_true(o.__bool__())
    _check_every_kind(o.value())
    # A string MIN is the only off-cell aggregate: still served.
    var smin = _agg(_keys(String("ks")), _two(_a(AGG_MIN, String("s")), _star()))
    var so = fold_mixed_count_distinct_over_batches(smin, _slab3(_rows(0, 0), _rows(0, 3), _rows(3, 6)))
    assert_true(so.__bool__())
    assert_equal(_s(so.value(), 1, 0), "c")
    assert_equal(_i(so.value(), 2, 0), 3)


def test_an_all_empty_list_still_resolves_its_schema() raises:
    """Three empty batches: zero groups and every output column present;
    with a missing input column the same list declines. Catches the
    schema-source fallback removed."""
    var ad = _agg(_keys(String("ks")), _two(_a(AGG_COUNT_DISTINCT, String("cd")), _star()))
    var o = fold_mixed_count_distinct_over_batches(ad, _slab3(_rows(0, 0), _rows(0, 0), _rows(0, 0)))
    assert_true(o.__bool__())
    assert_equal(o.value().num_rows(), 0)
    assert_equal(o.value().num_columns(), 3)
    var bad = _agg(_keys(String("ks")), _two(_a(AGG_COUNT_DISTINCT, String("nope")), _star()))
    assert_false(fold_mixed_count_distinct_over_batches(bad, _slab3(_rows(0, 0), _rows(0, 0), _rows(0, 0))).__bool__())


def test_batch_list_declines() raises:
    """Not a candidate; an empty list; batches whose schemas disagree (a
    count-only batch has rows but no columns, so it is no schema source and
    disagrees); a total above the ceiling; a missing column; nothing off-cell
    left. Each is None."""
    var ad = _agg(_keys(String("ks")), _two(_a(AGG_COUNT_DISTINCT, String("cd")), _star()))
    var not_cand = _agg(_keys(String("ks")), _two(_a(AGG_SUM, String("i")), _star()))
    assert_false(fold_mixed_count_distinct_over_batches(not_cand, _slab3(_rows(0, 1), _rows(1, 2), _rows(2, 3))).__bool__())
    assert_false(fold_mixed_count_distinct_over_batches(ad, Slab[RecordBatch]()).__bool__())
    assert_false(fold_mixed_count_distinct_over_batches(ad, _slab3(RecordBatch.count_only(3), _rows(0, 3), _rows(3, 6))).__bool__())
    var big = _slab3(RecordBatch.count_only(_MIX_FOLD_MAX_ROWS), RecordBatch.count_only(1), RecordBatch.count_only(0))
    var zk = _agg(List[String](), _two(_a(AGG_COUNT_DISTINCT, String("cd")), _star()))
    assert_false(fold_mixed_count_distinct_over_batches(zk, big).__bool__())
    var miss = _agg(_keys(String("ks")), _two(_a(AGG_COUNT_DISTINCT, String("nope")), _star()))
    assert_false(fold_mixed_count_distinct_over_batches(miss, _slab3(_rows(0, 0), _rows(0, 3), _rows(3, 6))).__bool__())
    var numeric = _agg(_keys(String("ks")), _two(_a(AGG_MAX, String("i")), _star()))
    assert_false(fold_mixed_count_distinct_over_batches(numeric, _slab3(_rows(0, 0), _rows(0, 3), _rows(3, 6))).__bool__())


# =============================================================================
# The group table
# =============================================================================


def _int_key_batch(imm a: List[Int64], imm b: List[Int64]) raises -> RecordBatch:
    var rbb = RecordBatchBuilder.with_capacity(3)
    var sb = SchemaBuilder()
    var pa = PrimitiveArray[DType.int64].allocate(len(a))
    var pb = PrimitiveArray[DType.int64].allocate(len(a))
    var pv = PrimitiveArray[DType.int64].allocate(len(a))
    for i in range(len(a)):
        pa._typed_ptr_mut()[i] = a[i]
        pb._typed_ptr_mut()[i] = b[i]
        pv._typed_ptr_mut()[i] = Int64(i % 3)
    rbb.add_column(Column.from_primitive[DType.int64](pa^))
    sb.add_field(Field(String("ka"), ArrowType.INT64, False))
    rbb.add_column(Column.from_primitive[DType.int64](pb^))
    sb.add_field(Field(String("kb"), ArrowType.INT64, False))
    rbb.add_column(Column.from_primitive[DType.int64](pv^))
    sb.add_field(Field(String("v"), ArrowType.INT64, False))
    return rbb.build(sb.build())


def _int_agg(imm keys: List[String], imm schema: Schema) raises -> AggregateData:
    var k = ExprArray()
    for i in range(len(keys)):
        k.append(Expr.col_ref(keys[i]))
    var child = LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, schema.copy())
    return AggregateData(k^, _two(_a(AGG_COUNT_DISTINCT, String("v")), _star()), child^)


def test_two_keys_with_one_hash_stay_two_groups() raises:
    """Rows (1,2), (3,B), (1,2), (3,B) where B makes the composite hash of
    (3,B) equal that of (1,2): two groups of COUNT(*) 2 each. Catches a
    probe that matches on the hash alone (one group of 4)."""
    var a: List[Int64] = [1, 3, 1, 3]
    var b: List[Int64] = [2, _COLLIDING_B, 2, _COLLIDING_B]
    var batch = _int_key_batch(a, b)
    var keys: List[String] = [String("ka"), String("kb")]
    var out = _serve(_int_agg(keys, batch.schema), batch)
    assert_equal(out.num_rows(), 2)
    assert_equal(_i(out, 1, 1), Int(_COLLIDING_B))
    assert_equal(_i(out, 3, 0), 2)
    assert_equal(_i(out, 3, 1), 2)


def test_two_thousand_groups_grow_the_table() raises:
    """2,000 distinct keys, each twice: 2,000 groups of COUNT(*) 2, in
    first-occurrence order, through two grows and rehashes. Catches a rehash
    that loses a slot."""
    comptime G = 2000
    var a = List[Int64](capacity=2 * G)
    var b = List[Int64](capacity=2 * G)
    for r in range(2 * G):
        a.append(Int64((r % G) * 104729))
        b.append(Int64(0))
    var batch = _int_key_batch(a, b)
    var out = _serve(_int_agg(_keys(String("ka")), batch.schema), batch)
    assert_equal(out.num_rows(), G)
    for g in range(G):
        assert_equal(_i(out, 0, g), g * 104729)
        assert_equal(_i(out, 2, g), 2)


def test_the_fold_skips_a_row_whose_key_is_null() raises:
    """The extraction refuses a NULL-bearing key, so the fold's own guard is
    reached only by marking a key cell NULL after extraction: that row joins
    no group (group a counts 2 rows, not 3). Catches the guard removed."""
    var ad = _agg(_keys(String("ks")), _two(_a(AGG_COUNT_DISTINCT, String("cd")), _star()))
    var st = _MixFoldInputs()
    assert_true(_mix_extract_batch(ad, _rows(0, 6), st, True))
    st.key_cols[0][0].nulls[2] = True
    var o = _mix_fold_and_emit(ad, st)
    assert_true(o.__bool__())
    var out = o.take()
    assert_equal(out.num_rows(), 3)
    assert_equal(_i(out, 2, 0), 2)


def test_null_inputs_in_the_narrow_widths_are_skipped() raises:
    """A nullable INT32 and a nullable FLOAT32 fixed-cell input: by key x
    over rows [x, x, y], SUM(i32 = [7, NULL, NULL]) is 7 and NULL, MAX(f32 =
    [NULL, 1.5, NULL]) is 1.5 and NULL, beside a CD. Catches a NULL in the
    narrow readers read as its data word (SUM would be 7 + 99)."""
    var rbb = RecordBatchBuilder.with_capacity(4)
    var sb = SchemaBuilder()
    var kv: List[String] = [String("x"), String("x"), String("y")]
    rbb.add_column(Column.from_string(StringArray.from_strings(kv)))
    sb.add_field(Field(String("k"), ArrowType.STRING, False))
    var cd = PrimitiveArray[DType.int64].allocate(3)
    for r in range(3):
        cd._typed_ptr_mut()[r] = Int64(r)
    rbb.add_column(Column.from_primitive[DType.int64](cd^))
    sb.add_field(Field(String("cd"), ArrowType.INT64, False))
    var i32 = PrimitiveArray[DType.int32].allocate_nullable(3)
    i32.set(0, 7)
    i32.set(1, 99)
    i32._set_null(1)
    i32.set(2, 99)
    i32._set_null(2)
    rbb.add_column(Column.from_primitive[DType.int32](i32^))
    sb.add_field(Field(String("n32"), ArrowType.INT32, True))
    var f32 = PrimitiveArray[DType.float32].allocate_nullable(3)
    f32.set(0, 99.0)
    f32._set_null(0)
    f32.set(1, 1.5)
    f32.set(2, 99.0)
    f32._set_null(2)
    rbb.add_column(Column.from_primitive[DType.float32](f32^))
    sb.add_field(Field(String("nf32"), ArrowType.FLOAT32, True))
    var batch = rbb.build(sb.build())
    var aggs = AggExprArray()
    aggs.append(_a(AGG_COUNT_DISTINCT, String("cd")))
    aggs.append(_a(AGG_SUM, String("n32")))
    aggs.append(_a(AGG_MAX, String("nf32")))
    var k = ExprArray()
    k.append(Expr.col_ref(String("k")))
    var ad = AggregateData(k^, aggs^, LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, batch.schema.copy()))
    var out = _serve(ad, batch)
    assert_equal(out.num_rows(), 2)
    assert_equal(_i(out, 2, 0), 7)
    assert_true(_is_null(out, 2, 1))
    assert_equal(_f(out, 3, 0), 1.5)
    assert_true(_is_null(out, 3, 1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
