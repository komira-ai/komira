# =============================================================================
# `cd_grouped_fold`: the grouped and the 0-key COUNT(DISTINCT) folds, and the
# byte-equivalence ORACLE between the live native-hash fold and the legacy
# string-key fold the module keeps for exactly this test.
#
# What each part proves:
#
#   * THE ORACLE. Over null-bearing STRING, INT32 and INT64 keys, a composite
#     key, and a null-free key, `_fold_grouped_cd_nativehash` and
#     `_fold_grouped_cd_stringkey` emit the same groups in the same order with
#     the same counts, names, types and validity — and one fixture is also
#     checked against hand-computed values, so the two cannot agree on a
#     wrong answer.
#   * THE HASH TABLE. A key whose hash equals the NULL key's hash (splitmix64's
#     finalizer is a bijection, so the colliding value was computed by
#     inverting it) must still form its own group: the probe meets an equal
#     hash whose keys differ and walks on. 2,000 distinct keys force the table
#     to grow and rehash twice.
#   * EVERY DECLINE of both grouped folds and of the 0-key fold, each with
#     the reason named, including the row ceiling (a count-only batch carries
#     the row count without the memory).
#   * The pieces: the two shape predicates, the col-ref stripper, the key
#     type envelope, both key extractors (and their refusal of a FLOAT key),
#     and the native cell equality in each of its arms.
# =============================================================================

from std.collections import List, Optional
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT_DISTINCT, AGG_SUM
from komira_plan_expr.expr import BIN_ADD, Expr
from komira_plan_ir.logical_plan import (
    AggExprArray, ExprArray, LogicalPlan, SOURCE_PARQUET,
)
from komira_plan_ir.logical_plan_variants import AggregateData

from komira_dispatch_agg_folds.cd_grouped_fold import (
    _CD_FOLD_MAX_ROWS,
    _CD_NULL_KEY_HASH,
    _cd_col_idx,
    _cd_extract_key_col,
    _cd_extract_native_key_col,
    _cd_hash_combine,
    _cd_key_dtype_ok,
    _cd_strip_alias_col_ref,
    _fold_grouped_cd_nativehash,
    _fold_grouped_cd_stringkey,
    agg_all_count_distinct,
    agg_scalar_all_count_distinct,
    fold_grouped_count_distinct_over_batch,
    fold_scalar_count_distinct_over_batch,
)

# mix(_COLLIDES_WITH_NULL) == _CD_NULL_KEY_HASH: computed by inverting the
# splitmix64 finalizer `_cd_mix_u64`, which is a bijection on 64-bit words.
comptime _COLLIDES_WITH_NULL: Int64 = 8696546692802433211


# =============================================================================
# Columns, batches, plans
# =============================================================================


def _i64(imm v: List[Int64], imm ok: List[Bool]) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.int64].allocate_nullable(len(v))
    for i in range(len(v)):
        # The value is written even under a NULL, then the bit is cleared:
        # a NULL slot holding a real key's word is the case that matters.
        a.set(i, v[i])
        if not ok[i]:
            a._set_null(i)
    return Column.from_primitive[DType.int64](a^)


def _i32(imm v: List[Int32], imm ok: List[Bool]) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.int32].allocate_nullable(len(v))
    for i in range(len(v)):
        # The value is written even under a NULL, then the bit is cleared:
        # a NULL slot holding a real key's word is the case that matters.
        a.set(i, v[i])
        if not ok[i]:
            a._set_null(i)
    return Column.from_primitive[DType.int32](a^)


def _f64(imm v: List[Float64]) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.float64].allocate(len(v))
    for i in range(len(v)):
        a._typed_ptr_mut()[i] = v[i]
    return Column.from_primitive[DType.float64](a^)


def _str(imm v: List[String], imm ok: List[Bool]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings_with_validity(v, ok))


def _all(n: Int) -> List[Bool]:
    var o = List[Bool](capacity=n)
    for _ in range(n):
        o.append(True)
    return o^


struct _B(Movable):
    """A batch under construction: columns plus their fields."""

    var rbb: RecordBatchBuilder
    var sb: SchemaBuilder

    def __init__(out self):
        self.rbb = RecordBatchBuilder.with_capacity(4)
        self.sb = SchemaBuilder()

    def add(mut self, name: String, at: ArrowType, var col: Column[HeapRegion]) raises:
        self.rbb.add_column(col^)
        self.sb.add_field(Field(name, at, True))

    def build(mut self) raises -> RecordBatch:
        return self.rbb.build(self.sb.build())


def _agg(imm keys: List[String], var aggs: AggExprArray, imm schema: Schema) raises -> AggregateData:
    var k = ExprArray()
    for i in range(len(keys)):
        k.append(Expr.col_ref(keys[i]))
    var child = LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, schema.copy())
    return AggregateData(k^, aggs^, child^)


def _cd(col: String, name: String) raises -> AggExpr:
    return AggExpr(AGG_COUNT_DISTINCT, Optional[Expr](Expr.col_ref(col)), Optional[String](name))


def _cd_unnamed(col: String) raises -> AggExpr:
    return AggExpr(AGG_COUNT_DISTINCT, Optional[Expr](Expr.col_ref(col)), Optional[String](None))


def _one_cd(col: String) raises -> AggExprArray:
    var a = AggExprArray()
    a.append(_cd(col, String("n")))
    return a^


# =============================================================================
# Fixtures
# =============================================================================


def _string_key_batch() raises -> RecordBatch:
    """k STRING (with NULL and ''), v INT64 (with NULL).

    row | k    | v
      0 | a    | 1
      1 | NULL | 2
      2 | ''   | 3
      3 | a    | 1
      4 | NULL | NULL
      5 | a    | 5
      6 | ''   | NULL
      7 | NULL | 2

    Hand oracle, first-occurrence order: a -> {1,5} = 2; NULL -> {2} = 1;
    '' -> {3} = 1. The NULL group and the '' group are DIFFERENT groups."""
    var k: List[String] = [String("a"), String(""), String(""), String("a"), String(""), String("a"), String(""), String("")]
    var kok: List[Bool] = [True, False, True, True, False, True, True, False]
    var v: List[Int64] = [1, 2, 3, 1, 0, 5, 0, 2]
    var vok: List[Bool] = [True, True, True, True, False, True, False, True]
    var b = _B()
    b.add(String("k"), ArrowType.STRING, _str(k, kok))
    b.add(String("v"), ArrowType.INT64, _i64(v, vok))
    return b.build()


def _int32_key_batch() raises -> RecordBatch:
    """k INT32 with two NULLs, one holding the word 7 (a real key) and one
    the word 3; v INT32."""
    var k: List[Int32] = [7, 7, 9, 7, 9, 3]
    var kok: List[Bool] = [True, False, True, True, True, False]
    var v: List[Int32] = [1, 1, 2, 3, 2, 4]
    var b = _B()
    b.add(String("k"), ArrowType.INT32, _i32(k, kok))
    b.add(String("v"), ArrowType.INT32, _i32(v, _all(6)))
    return b.build()


def _composite_batch() raises -> RecordBatch:
    """(s STRING, n INT64) composite key; (NULL,'x') and (NULL,'y') stay two
    groups; v INT64."""
    var s: List[String] = [String("x"), String("x"), String("y"), String("x"), String("y")]
    var sok: List[Bool] = [True, True, True, True, True]
    var n: List[Int64] = [1, 2, 1, 1, 0]
    var nok: List[Bool] = [False, True, False, False, True]
    var v: List[Int64] = [10, 20, 30, 40, 50]
    var b = _B()
    b.add(String("s"), ArrowType.STRING, _str(s, sok))
    b.add(String("n"), ArrowType.INT64, _i64(n, nok))
    b.add(String("v"), ArrowType.INT64, _i64(v, _all(5)))
    return b.build()


def _null_free_int64_batch() raises -> RecordBatch:
    var k: List[Int64] = [5, 6, 5, 6, 5]
    var v: List[Int64] = [1, 2, 3, 2, 1]
    var b = _B()
    b.add(String("k"), ArrowType.INT64, _i64(k, _all(5)))
    b.add(String("v"), ArrowType.INT64, _i64(v, _all(5)))
    return b.build()


# =============================================================================
# The oracle compare
# =============================================================================


def _assert_same(imm a: RecordBatch, imm b: RecordBatch) raises:
    """Same rows, same columns, and per column the same name, type,
    nullability and cells (value and validity)."""
    assert_equal(a.num_rows(), b.num_rows())
    assert_equal(a.num_columns(), b.num_columns())
    for c in range(a.num_columns()):
        ref fa = a.schema.field_at_unchecked(c)
        ref fb = b.schema.field_at_unchecked(c)
        assert_equal(fa.name, fb.name)
        assert_true(fa.arrow_type == fb.arrow_type)
        assert_equal(fa.nullable, fb.nullable)
        if fa.arrow_type == ArrowType.STRING:
            var sa = a.column_as_string(c)
            var sb = b.column_as_string(c)
            for r in range(a.num_rows()):
                assert_equal(sa.is_null(r), sb.is_null(r))
                assert_equal(sa.get(r), sb.get(r))
        else:
            var ia = a.column_as_primitive_int64(c)
            var ib = b.column_as_primitive_int64(c)
            for r in range(a.num_rows()):
                assert_equal(ia.is_null(r), ib.is_null(r))
                if not ia.is_null(r):
                    assert_equal(Int(ia.get(r)), Int(ib.get(r)))


def _both(imm ad: AggregateData, imm batch: RecordBatch) raises -> RecordBatch:
    var nh = _fold_grouped_cd_nativehash(ad, batch, batch.schema)
    var sk = _fold_grouped_cd_stringkey(ad, batch, batch.schema)
    assert_true(nh.__bool__(), "native-hash fold declined")
    assert_true(sk.__bool__(), "string-key fold declined")
    _assert_same(nh.value(), sk.value())
    return nh.take()


def test_oracle_string_key_with_null_and_empty_groups() raises:
    """Three groups — 'a', NULL, '' — with counts 2, 1, 1, in first-occurrence
    order, the NULL group read back NULL and the '' group read back as a
    value; both folds agree. Catches NULL and '' merged into one group (the
    null test after the length compare in `cell_eq`) and a NULL input value
    counted as a distinct value."""
    var batch = _string_key_batch()
    var keys: List[String] = [String("k")]
    var out = _both(_agg(keys, _one_cd(String("v")), batch.schema), batch)
    assert_equal(out.num_rows(), 3)
    var kc = out.column_as_string(0)
    var nc = out.column_as_primitive_int64(1)
    assert_equal(kc.get(0), "a")
    assert_true(kc.is_null(1))
    assert_false(kc.is_null(2))
    assert_equal(kc.get(2), "")
    assert_equal(Int(nc.get(0)), 2)
    assert_equal(Int(nc.get(1)), 1)
    assert_equal(Int(nc.get(2)), 1)
    assert_true(out.schema.field_at_unchecked(0).nullable)
    assert_equal(out.schema.field_name(1), "n")


def test_oracle_int32_key_null_is_its_own_group_and_widens() raises:
    """INT32 key with NULLs, one whose data word is 7: groups 7, NULL, 9 with
    counts 2, 2, 1; the key is emitted INT64 and nullable; an unaliased CD is
    named `count_distinct_0`. Catches the INT null mask read from the widened
    copy (it has no bitmap, so the NULL rows would join group 0 or 7)."""
    var batch = _int32_key_batch()
    var keys: List[String] = [String("k")]
    var aggs = AggExprArray()
    aggs.append(_cd_unnamed(String("v")))
    var out = _both(_agg(keys, aggs^, batch.schema), batch)
    assert_equal(out.num_rows(), 3)
    assert_true(out.column_arrow_type(0) == ArrowType.INT64)
    var kc = out.column_as_primitive_int64(0)
    assert_equal(Int(kc.get(0)), 7)
    assert_true(kc.is_null(1))
    assert_equal(Int(kc.get(2)), 9)
    var nc = out.column_as_primitive_int64(1)
    assert_equal(Int(nc.get(0)), 2)
    assert_equal(Int(nc.get(1)), 2)
    assert_equal(Int(nc.get(2)), 1)
    assert_equal(out.schema.field_name(1), "count_distinct_0")


def test_oracle_composite_key_keeps_null_parts_apart() raises:
    """Composite (s, n): ('x',NULL), ('x',2), ('y',NULL), ('y',0) — four
    groups, and two CDs over the same input. Catches a composite hash that
    ignores key order and NULL cells matched across different keys."""
    var batch = _composite_batch()
    var keys: List[String] = [String("s"), String("n")]
    var aggs = AggExprArray()
    aggs.append(_cd(String("v"), String("c1")))
    aggs.append(_cd(String("v"), String("c2")))
    var out = _both(_agg(keys, aggs^, batch.schema), batch)
    assert_equal(out.num_rows(), 4)
    assert_equal(out.num_columns(), 4)
    var c1 = out.column_as_primitive_int64(2)
    assert_equal(Int(c1.get(0)), 2)
    assert_equal(Int(c1.get(1)), 1)


def test_oracle_null_free_int_key_emits_no_validity() raises:
    """A null-free INT64 key: the key field is not nullable and carries no
    bitmap. Catches validity emitted unconditionally."""
    var batch = _null_free_int64_batch()
    var keys: List[String] = [String("k")]
    var out = _both(_agg(keys, _one_cd(String("v")), batch.schema), batch)
    assert_equal(out.num_rows(), 2)
    assert_false(out.schema.field_at_unchecked(0).nullable)
    assert_equal(Int(out.column_as_primitive_int64(1).get(0)), 2)
    var pub = fold_grouped_count_distinct_over_batch(
        _agg(keys, _one_cd(String("v")), batch.schema), batch, batch.schema
    )
    assert_true(pub.__bool__())
    _assert_same(pub.value(), out)


def test_a_key_hashing_like_null_is_a_different_group() raises:
    """Rows [NULL, X, NULL, X] where X hashes exactly as a NULL cell does: two
    groups, NULL and X, in both folds. The probe meets an equal hash whose
    keys differ and must walk on. Catches a probe that trusts the hash alone
    (X would join the NULL group)."""
    var k: List[Int64] = [0, _COLLIDES_WITH_NULL, 0, _COLLIDES_WITH_NULL]
    var kok: List[Bool] = [False, True, False, True]
    var v: List[Int64] = [1, 2, 3, 2]
    var b = _B()
    b.add(String("k"), ArrowType.INT64, _i64(k, kok))
    b.add(String("v"), ArrowType.INT64, _i64(v, _all(4)))
    var batch = b.build()
    var keys: List[String] = [String("k")]
    var out = _both(_agg(keys, _one_cd(String("v")), batch.schema), batch)
    assert_equal(out.num_rows(), 2)
    assert_true(out.column_as_primitive_int64(0).is_null(0))
    assert_equal(Int(out.column_as_primitive_int64(0).get(1)), Int(_COLLIDES_WITH_NULL))
    assert_equal(Int(out.column_as_primitive_int64(1).get(0)), 2)
    assert_equal(Int(out.column_as_primitive_int64(1).get(1)), 1)


def test_two_thousand_groups_grow_the_table_twice() raises:
    """2,000 distinct keys (each seen twice, with values g and g+1): the
    open-address table grows at 717 and 1,434 groups and rehashes; every
    group survives with count 2 and the first-occurrence order holds.
    Catches a rehash that drops slots or leaves `mask` stale."""
    comptime G = 2000
    var k = List[Int64](capacity=2 * G)
    var v = List[Int64](capacity=2 * G)
    for g in range(G):
        k.append(Int64(g * 7919))
        v.append(Int64(g))
    for g in range(G):
        k.append(Int64(g * 7919))
        v.append(Int64(g + 1))
    var b = _B()
    b.add(String("k"), ArrowType.INT64, _i64(k, _all(2 * G)))
    b.add(String("v"), ArrowType.INT64, _i64(v, _all(2 * G)))
    var batch = b.build()
    var keys: List[String] = [String("k")]
    var out = _both(_agg(keys, _one_cd(String("v")), batch.schema), batch)
    assert_equal(out.num_rows(), G)
    var kc = out.column_as_primitive_int64(0)
    var nc = out.column_as_primitive_int64(1)
    for g in range(G):
        assert_equal(Int(kc.get(g)), g * 7919)
        assert_equal(Int(nc.get(g)), 2)


# =============================================================================
# Declines — both grouped folds, each reason
# =============================================================================


def _declines_both(imm ad: AggregateData, imm batch: RecordBatch, why: String) raises:
    assert_false(_fold_grouped_cd_nativehash(ad, batch, batch.schema).__bool__(), "native: " + why)
    assert_false(_fold_grouped_cd_stringkey(ad, batch, batch.schema).__bool__(), "string-key: " + why)


def test_grouped_folds_decline_each_out_of_envelope_shape() raises:
    """No key; no aggregate; above the row ceiling; a computed key; a missing
    key column; a FLOAT key; a non-CD aggregate; a CD without an input; a
    computed CD input; a missing input column; a STRING input. Each is a
    `None`, never a raise. Catches any one guard removed (the fold would
    raise or count garbage instead)."""
    var batch = _string_key_batch()
    var s = batch.schema.copy()
    var k: List[String] = [String("k")]
    _declines_both(_agg(List[String](), _one_cd(String("v")), s), batch, "no key")
    _declines_both(_agg(k, AggExprArray(), s), batch, "no aggregate")
    var big = RecordBatch.count_only(_CD_FOLD_MAX_ROWS + 1)
    _declines_both(_agg(k, _one_cd(String("v")), s), big, "above the ceiling")
    var ck = ExprArray()
    ck.append(Expr.binary(BIN_ADD, Expr.col_ref(String("v")), Expr.col_ref(String("v"))))
    _declines_both(AggregateData(ck^, _one_cd(String("v")), LogicalPlan.scan(String("t"), SOURCE_PARQUET, s.copy())), batch, "computed key")
    var missing: List[String] = [String("nope")]
    _declines_both(_agg(missing, _one_cd(String("v")), s), batch, "missing key")
    var fb = _B()
    var fv: List[Float64] = [1.0, 2.0]
    var iv: List[Int64] = [1, 2]
    fb.add(String("f"), ArrowType.FLOAT64, _f64(fv))
    fb.add(String("v"), ArrowType.INT64, _i64(iv, _all(2)))
    var fbatch = fb.build()
    var fk: List[String] = [String("f")]
    _declines_both(_agg(fk, _one_cd(String("v")), fbatch.schema), fbatch, "float key")
    var sum_aggs = AggExprArray()
    sum_aggs.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref(String("v"))), Optional[String](None)))
    _declines_both(_agg(k, sum_aggs^, s), batch, "non-CD")
    var bare = AggExprArray()
    bare.append(AggExpr(AGG_COUNT_DISTINCT, Optional[Expr](None), Optional[String](None)))
    _declines_both(_agg(k, bare^, s), batch, "CD without input")
    var comp = AggExprArray()
    comp.append(AggExpr(AGG_COUNT_DISTINCT, Optional[Expr](Expr.binary(BIN_ADD, Expr.col_ref(String("v")), Expr.col_ref(String("v")))), Optional[String](None)))
    _declines_both(_agg(k, comp^, s), batch, "computed input")
    _declines_both(_agg(k, _one_cd(String("nope")), s), batch, "missing input")
    _declines_both(_agg(k, _one_cd(String("k")), s), batch, "string input")


# =============================================================================
# The 0-key fold
# =============================================================================


def test_scalar_fold_counts_distinct_non_null_values() raises:
    """0 keys, CDs over INT64 v (with NULLs: distinct {1,2,3,5} = 4) and over
    INT32 (aliased and not): one row, names from the alias or the default.
    Catches the NULL skip removed (5 instead of 4)."""
    var b = _B()
    var v: List[Int64] = [1, 2, 3, 1, 0, 5, 0, 2]
    var vok: List[Bool] = [True, True, True, True, False, True, False, True]
    var i32: List[Int32] = [4, 4, 4, 8, 8, 4, 0, 0]
    var ok: List[Bool] = [True, True, True, True, True, True, False, False]
    b.add(String("v"), ArrowType.INT64, _i64(v, vok))
    b.add(String("w"), ArrowType.INT32, _i32(i32, ok))
    var batch = b.build()
    var aggs = AggExprArray()
    aggs.append(_cd(String("v"), String("dv")))
    aggs.append(_cd_unnamed(String("w")))
    var out = fold_scalar_count_distinct_over_batch(_agg(List[String](), aggs^, batch.schema), batch)
    assert_true(out.__bool__())
    assert_equal(out.value().num_rows(), 1)
    assert_equal(Int(out.value().column_as_primitive_int64(0).get(0)), 4)
    assert_equal(Int(out.value().column_as_primitive_int64(1).get(0)), 2)
    assert_equal(out.value().schema.field_name(0), "dv")
    assert_equal(out.value().schema.field_name(1), "count_distinct_1")


def test_scalar_fold_declines_each_out_of_envelope_shape() raises:
    """A group key; no aggregate; above the ceiling; a non-CD; a CD without
    input; a computed input; a missing column; a STRING input. Catches any
    one guard removed."""
    var batch = _string_key_batch()
    var s = batch.schema.copy()
    var k: List[String] = [String("k")]
    var nk = List[String]()
    assert_false(fold_scalar_count_distinct_over_batch(_agg(k, _one_cd(String("v")), s), batch).__bool__())
    assert_false(fold_scalar_count_distinct_over_batch(_agg(nk, AggExprArray(), s), batch).__bool__())
    assert_false(fold_scalar_count_distinct_over_batch(_agg(nk, _one_cd(String("v")), s), RecordBatch.count_only(_CD_FOLD_MAX_ROWS + 1)).__bool__())
    var sum_aggs = AggExprArray()
    sum_aggs.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref(String("v"))), Optional[String](None)))
    assert_false(fold_scalar_count_distinct_over_batch(_agg(nk, sum_aggs^, s), batch).__bool__())
    var bare = AggExprArray()
    bare.append(AggExpr(AGG_COUNT_DISTINCT, Optional[Expr](None), Optional[String](None)))
    assert_false(fold_scalar_count_distinct_over_batch(_agg(nk, bare^, s), batch).__bool__())
    var comp = AggExprArray()
    comp.append(AggExpr(AGG_COUNT_DISTINCT, Optional[Expr](Expr.binary(BIN_ADD, Expr.col_ref(String("v")), Expr.col_ref(String("v")))), Optional[String](None)))
    assert_false(fold_scalar_count_distinct_over_batch(_agg(nk, comp^, s), batch).__bool__())
    assert_false(fold_scalar_count_distinct_over_batch(_agg(nk, _one_cd(String("nope")), s), batch).__bool__())
    assert_false(fold_scalar_count_distinct_over_batch(_agg(nk, _one_cd(String("k")), s), batch).__bool__())


# =============================================================================
# The predicates and helpers
# =============================================================================


def _cd_then_sum() raises -> AggExprArray:
    var a = AggExprArray()
    a.append(_cd(String("v"), String("a")))
    a.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref(String("v"))), Optional[String](None)))
    return a^


def test_shape_predicates() raises:
    """`agg_all_count_distinct` needs >= 1 key, >= 1 aggregate, all CD;
    `agg_scalar_all_count_distinct` needs 0 keys, >= 1 aggregate, all CD.
    Each refusal on its own. Catches `< 1` written `< 0` and the all-CD loop
    reduced to the first aggregate."""
    var s = _string_key_batch().schema.copy()
    var k: List[String] = [String("k")]
    var nk = List[String]()
    assert_true(agg_all_count_distinct(_agg(k, _one_cd(String("v")), s)))
    assert_false(agg_all_count_distinct(_agg(nk, _one_cd(String("v")), s)))
    assert_false(agg_all_count_distinct(_agg(k, AggExprArray(), s)))
    assert_false(agg_all_count_distinct(_agg(k, _cd_then_sum(), s)))
    assert_true(agg_scalar_all_count_distinct(_agg(nk, _one_cd(String("v")), s)))
    assert_false(agg_scalar_all_count_distinct(_agg(k, _one_cd(String("v")), s)))
    assert_false(agg_scalar_all_count_distinct(_agg(nk, AggExprArray(), s)))
    assert_false(agg_scalar_all_count_distinct(_agg(nk, _cd_then_sum(), s)))


def test_strip_col_idx_and_key_envelope() raises:
    """A col-ref and an alias of one strip to the column; an alias of a
    computed expression and a bare computed expression do not; `_cd_col_idx`
    finds a column or answers -1; the key envelope is exactly STRING, INT32,
    INT64. Catches the alias arm removed and an operand dropped from the
    envelope."""
    assert_equal(_cd_strip_alias_col_ref(Expr.col_ref(String("a"))).value(), "a")
    assert_equal(_cd_strip_alias_col_ref(Expr.alias(Expr.col_ref(String("b")), String("x"))).value(), "b")
    var sum = Expr.binary(BIN_ADD, Expr.col_ref(String("a")), Expr.col_ref(String("b")))
    assert_false(_cd_strip_alias_col_ref(Expr.alias(sum.copy(), String("y"))).__bool__())
    assert_false(_cd_strip_alias_col_ref(sum).__bool__())
    var s = _string_key_batch().schema.copy()
    assert_equal(_cd_col_idx(s, String("v")), 1)
    assert_equal(_cd_col_idx(s, String("zz")), -1)
    assert_true(_cd_key_dtype_ok(ArrowType.STRING))
    assert_true(_cd_key_dtype_ok(ArrowType.INT32))
    assert_true(_cd_key_dtype_ok(ArrowType.INT64))
    assert_false(_cd_key_dtype_ok(ArrowType.FLOAT64))
    assert_false(_cd_key_dtype_ok(ArrowType.LARGE_STRING))


def test_hash_combine_is_order_sensitive() raises:
    """combine(combine(s, x), y) != combine(combine(s, y), x): the composite
    key [brand, type] must not equal [type, brand]."""
    var s = UInt64(1469598103934665603)
    var xy = _cd_hash_combine(_cd_hash_combine(s, UInt64(11)), UInt64(22))
    var yx = _cd_hash_combine(_cd_hash_combine(s, UInt64(22)), UInt64(11))
    assert_true(xy != yx)


def test_native_key_extraction_and_cell_equality() raises:
    """The native extractor over STRING, INT64 and INT32 marks NULL rows and
    hashes them to the one NULL constant, keeps strings as an array and ints
    as values, and refuses a FLOAT column. Cell equality: NULL vs value is
    false, NULL vs NULL is true, two strings of different length are false,
    two '' are true, equal bytes are true, same-length different bytes are
    false, ints compare by value. Catches the validity test moved after the
    byte compare (NULL would equal '')."""
    var sb = _string_key_batch()
    var sk_o = _cd_extract_native_key_col(sb, 0)
    var sk = sk_o.take()
    assert_true(sk.is_string)
    assert_true(sk.nulls[1])
    assert_equal(sk.hashes[1], _CD_NULL_KEY_HASH)
    assert_false(sk.row_eq(1, 2))
    assert_true(sk.row_eq(1, 4))
    assert_false(sk.row_eq(0, 2))
    assert_true(sk.row_eq(2, 6))
    assert_true(sk.row_eq(0, 3))
    var ab: List[String] = [String("ab"), String("ac"), String("ab")]
    var abb = _B()
    abb.add(String("k"), ArrowType.STRING, _str(ab, _all(3)))
    var abk_o = _cd_extract_native_key_col(abb.build(), 0)
    var abk = abk_o.take()
    assert_false(abk.row_eq(0, 1))
    assert_true(abk.cell_eq(0, abk, 2))
    var ib = _int32_key_batch()
    var ik_o = _cd_extract_native_key_col(ib, 0)
    var ik = ik_o.take()
    assert_false(ik.is_string)
    assert_true(ik.nulls[1])
    assert_true(ik.row_eq(0, 3))
    assert_false(ik.row_eq(0, 2))
    var lk_o = _cd_extract_native_key_col(_composite_batch(), 1)
    var lk = lk_o.take()
    assert_true(lk.nulls[0])
    assert_equal(lk.hashes[0], _CD_NULL_KEY_HASH)
    var fb = _B()
    var fv: List[Float64] = [1.0]
    fb.add(String("f"), ArrowType.FLOAT64, _f64(fv))
    var fbatch = fb.build()
    assert_false(_cd_extract_native_key_col(fbatch, 0).__bool__())
    assert_false(_cd_extract_key_col(fbatch, 0).__bool__())


def test_string_key_renderings_cannot_alias() raises:
    """The legacy extractor renders a STRING cell `<len>:<bytes>`, an INT cell
    `#<v>`, and a NULL `~NULL~`, so NULL, '' and a value never render alike;
    the INT32 arm reads its NULL mask from the source column. Catches the
    length prefix removed (`"a"+"bc"` would alias `"ab"+"c"`)."""
    var sk_o = _cd_extract_key_col(_string_key_batch(), 0)
    var sk = sk_o.take()
    assert_equal(sk.rendered[0], "1:a")
    assert_equal(sk.rendered[1], "~NULL~")
    assert_equal(sk.rendered[2], "0:")
    assert_true(sk.nulls[1])
    var ik_o = _cd_extract_key_col(_int32_key_batch(), 0)
    var ik = ik_o.take()
    assert_equal(ik.rendered[0], "#7")
    assert_equal(ik.rendered[1], "~NULL~")
    assert_true(ik.nulls[1])
    assert_false(ik.nulls[0])
    var lk_o = _cd_extract_key_col(_composite_batch(), 1)
    var lk = lk_o.take()
    assert_equal(lk.rendered[1], "#2")
    assert_true(lk.nulls[0])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
