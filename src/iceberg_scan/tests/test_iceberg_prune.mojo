# =============================================================================
# The pruning evaluator: which files a filter can skip
# =============================================================================
#
# Every test builds file entries and manifests by hand and asks whether a filter
# can skip them; "kept" means the evaluator may not skip (a file that might hold
# a matching row), "skipped" means it provably holds none.
#
# What each test proves:
#   * test_integer_bounds_skip_by_each_comparison: =, <, <=, >, >= against a
#     file of longs in [10, 20], `<>` never, a literal on the left (mirrored),
#     two conjuncts, and an int bound (4 bytes) under a long column.
#   * test_a_missing_or_malformed_metric_keeps_the_file: no bounds, one bound,
#     and a bound of a length the type does not have.
#   * test_null_counts_skip_is_null_is_not_null_and_all_null_files: IS NULL on
#     a file with no nulls, IS NOT NULL and every comparison on an all-null
#     file (`<>` excepted), a missing count.
#   * test_nan_is_never_a_bound_and_greater_than_needs_a_nan_count_of_zero:
#     `>` and `>=` skip by the upper bound only when the NaN count is 0, `<`,
#     `<=` and `=` skip regardless, a NaN literal and a NaN bound never skip, an
#     int literal on a double column, a float column's 4-byte bounds, and -0.0.
#   * test_string_bounds_compare_as_unsigned_bytes_and_may_be_truncated: strings
#     of the bounds' prefix are kept, a literal past a truncated upper bound is
#     skipped only when the bound is not its prefix, and a multi-byte character
#     sorts above ASCII.
#   * test_other_types_date_timestamp_int_and_boolean: the other column types.
#   * test_conjuncts_the_evaluator_does_not_understand_are_ignored: a
#     literal of another kind, an unknown or decimal column, a NULL literal, OR,
#     arithmetic, NOT, a side-qualified column and column-to-column comparisons
#     give no predicate; understood conjuncts of an AND still apply.
#   * test_identity_partition_values_skip_entries: the entry's tuple of an
#     identity field is compared (equality, ranges, IS NULL, IS NOT NULL, a null
#     value, an int value under a long column, a NaN value), another transform
#     and a short tuple keep the file, and metrics still apply.
#   * test_partition_summaries_skip_manifests: the manifest list's summary of an
#     identity field (bounds, contains_null, contains_nan), and a summary count
#     that is not the spec's, no bounds and another transform, keep the manifest.

from std.math import nan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from plan_expr.expr import (
    BIN_ADD,
    BIN_AND,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
    BIN_OR,
    Expr,
    UN_IS_NOT_NULL,
    UN_IS_NULL,
    UN_NOT,
)
from plan_expr.scalar_value import ScalarValue
from iceberg_scan.manifests import (
    IcebergFileEntry,
    IcebergManifestFile,
    IcebergPartitionSummary,
)
from iceberg_scan.prune import (
    IcebergPrunePredicate,
    entry_may_match,
    manifest_may_match,
    prune_predicates_of,
)
from iceberg_scan.table_fixture import (
    fixture_double_bytes,
    fixture_float_bytes,
    fixture_int_bytes,
    fixture_long_bytes,
    fixture_text_bytes,
)
from iceberg_scan.table_metadata import (
    IcebergField,
    IcebergPartitionField,
    IcebergPartitionSpecDef,
)


def _columns() -> List[IcebergField]:
    var out = List[IcebergField]()
    out.append(IcebergField(1, "id", True, "long"))
    out.append(IcebergField(2, "name", False, "string"))
    out.append(IcebergField(3, "x", False, "double"))
    out.append(IcebergField(4, "d", False, "date"))
    out.append(IcebergField(5, "ts", False, "timestamp"))
    out.append(IcebergField(6, "i", False, "int"))
    out.append(IcebergField(7, "b", False, "boolean"))
    out.append(IcebergField(8, "price", False, "decimal(9,2)"))
    out.append(IcebergField(9, "f", False, "float"))
    out.append(IcebergField(10, "region", False, "string"))
    return out^


def _long(v: Int) -> ScalarValue:
    return ScalarValue.from_int64(Int64(v))


def _cmp(column: String, op: UInt8, var lit: ScalarValue) -> Expr:
    return Expr.binary(op, Expr.col_ref(column), Expr.literal(lit^))


def _is_null(column: String) -> Expr:
    return Expr.unary(UN_IS_NULL, Expr.col_ref(column))


def _is_not_null(column: String) -> Expr:
    return Expr.unary(UN_IS_NOT_NULL, Expr.col_ref(column))


def _preds(var e: Expr) -> List[IcebergPrunePredicate]:
    return prune_predicates_of(Optional[Expr](e^), _columns())


def _no_spec() -> IcebergPartitionSpecDef:
    return IcebergPartitionSpecDef(0, List[IcebergPartitionField]())


def _kept(e: IcebergFileEntry, var expr: Expr) -> Bool:
    return entry_may_match(e, _no_spec(), _preds(expr^))


def _set_bounds(mut e: IcebergFileEntry, id: Int, lo: List[UInt8], hi: List[UInt8]):
    e.lower_bounds.ids.append(id)
    e.lower_bounds.bounds.append(lo.copy())
    e.upper_bounds.ids.append(id)
    e.upper_bounds.bounds.append(hi.copy())


def _set_counts(mut e: IcebergFileEntry, id: Int, values: Int, nulls: Int):
    e.value_counts.ids.append(id)
    e.value_counts.counts.append(Int64(values))
    e.null_value_counts.ids.append(id)
    e.null_value_counts.counts.append(Int64(nulls))


def _set_nans(mut e: IcebergFileEntry, id: Int, nans: Int):
    e.nan_value_counts.ids.append(id)
    e.nan_value_counts.counts.append(Int64(nans))


def _longs(lo: Int, hi: Int) -> IcebergFileEntry:
    var e = IcebergFileEntry()
    _set_bounds(e, 1, fixture_long_bytes(Int64(lo)), fixture_long_bytes(Int64(hi)))
    return e^


def test_integer_bounds_skip_by_each_comparison() raises:
    var e = _longs(10, 20)
    assert_false(_kept(e, _cmp("id", BIN_EQ, _long(5))))
    assert_false(_kept(e, _cmp("id", BIN_EQ, _long(21))))
    assert_true(_kept(e, _cmp("id", BIN_EQ, _long(10))))
    assert_true(_kept(e, _cmp("id", BIN_EQ, _long(15))))
    assert_true(_kept(e, _cmp("id", BIN_EQ, _long(20))))
    assert_false(_kept(e, _cmp("id", BIN_LT, _long(10))))
    assert_true(_kept(e, _cmp("id", BIN_LT, _long(11))))
    assert_false(_kept(e, _cmp("id", BIN_LE, _long(9))))
    assert_true(_kept(e, _cmp("id", BIN_LE, _long(10))))
    assert_false(_kept(e, _cmp("id", BIN_GT, _long(20))))
    assert_true(_kept(e, _cmp("id", BIN_GT, _long(19))))
    assert_false(_kept(e, _cmp("id", BIN_GE, _long(21))))
    assert_true(_kept(e, _cmp("id", BIN_GE, _long(20))))
    # <> never skips, even a file whose every value is the literal.
    var same = _longs(7, 7)
    assert_true(_kept(same, _cmp("id", BIN_NE, _long(7))))
    assert_true(_kept(e, _cmp("id", BIN_NE, _long(5))))

    # A literal on the left reads mirrored.
    assert_false(_kept(e, Expr.binary(BIN_LT, Expr.literal(_long(25)), Expr.col_ref("id"))))
    assert_false(_kept(e, Expr.binary(BIN_GT, Expr.literal(_long(5)), Expr.col_ref("id"))))
    assert_false(_kept(e, Expr.binary(BIN_GE, Expr.literal(_long(9)), Expr.col_ref("id"))))
    assert_true(_kept(e, Expr.binary(BIN_LE, Expr.literal(_long(20)), Expr.col_ref("id"))))
    assert_true(_kept(e, Expr.binary(BIN_EQ, Expr.literal(_long(12)), Expr.col_ref("id"))))

    # Two conjuncts: either can skip.
    assert_false(
        _kept(
            e,
            Expr.binary(BIN_AND, _cmp("id", BIN_GT, _long(5)), _cmp("id", BIN_LT, _long(8))),
        )
    )
    assert_true(
        _kept(
            e,
            Expr.binary(BIN_AND, _cmp("id", BIN_GT, _long(5)), _cmp("id", BIN_LT, _long(100))),
        )
    )

    # An int bound written before the column became long is 4 bytes.
    var narrow = IcebergFileEntry()
    _set_bounds(narrow, 1, fixture_int_bytes(10), fixture_int_bytes(20))
    assert_false(_kept(narrow, _cmp("id", BIN_EQ, _long(5))))
    assert_true(_kept(narrow, _cmp("id", BIN_EQ, _long(15))))
    var negative = IcebergFileEntry()
    _set_bounds(negative, 1, fixture_int_bytes(-20), fixture_int_bytes(-10))
    assert_false(_kept(negative, _cmp("id", BIN_EQ, _long(0))))
    assert_true(_kept(negative, _cmp("id", BIN_EQ, _long(-15))))


def test_a_missing_or_malformed_metric_keeps_the_file() raises:
    var none = IcebergFileEntry()
    assert_true(_kept(none, _cmp("id", BIN_EQ, _long(5))))
    assert_true(_kept(none, _cmp("id", BIN_GT, _long(5))))
    var lower_only = IcebergFileEntry()
    lower_only.lower_bounds.ids.append(1)
    lower_only.lower_bounds.bounds.append(fixture_long_bytes(10))
    assert_true(_kept(lower_only, _cmp("id", BIN_GT, _long(100))))
    assert_false(_kept(lower_only, _cmp("id", BIN_LT, _long(5))))
    var upper_only = IcebergFileEntry()
    upper_only.upper_bounds.ids.append(1)
    upper_only.upper_bounds.bounds.append(fixture_long_bytes(20))
    assert_true(_kept(upper_only, _cmp("id", BIN_LT, _long(5))))
    assert_false(_kept(upper_only, _cmp("id", BIN_GT, _long(30))))
    # Bounds of another column say nothing about this one.
    var other = IcebergFileEntry()
    _set_bounds(other, 2, fixture_text_bytes("a"), fixture_text_bytes("b"))
    assert_true(_kept(other, _cmp("id", BIN_EQ, _long(5))))
    # A 3-byte long bound, and a 2-byte boolean bound, are no bound.
    var odd = IcebergFileEntry()
    var three = List[UInt8]()
    three.append(1)
    three.append(2)
    three.append(3)
    _set_bounds(odd, 1, three, three)
    _set_bounds(odd, 7, three, three)
    assert_true(_kept(odd, _cmp("id", BIN_EQ, _long(5))))
    assert_true(_kept(odd, _cmp("b", BIN_EQ, ScalarValue.from_bool(True))))
    var odd_double = IcebergFileEntry()
    _set_bounds(odd_double, 3, three, three)
    assert_true(_kept(odd_double, _cmp("x", BIN_EQ, ScalarValue.from_float(1.0))))


def test_null_counts_skip_is_null_is_not_null_and_all_null_files() raises:
    var no_nulls = IcebergFileEntry()
    _set_counts(no_nulls, 1, 3, 0)
    assert_false(_kept(no_nulls, _is_null("id")))
    assert_true(_kept(no_nulls, _is_not_null("id")))
    var some = IcebergFileEntry()
    _set_counts(some, 1, 3, 2)
    assert_true(_kept(some, _is_null("id")))
    assert_true(_kept(some, _is_not_null("id")))
    var all_null = IcebergFileEntry()
    _set_counts(all_null, 1, 3, 3)
    assert_true(_kept(all_null, _is_null("id")))
    assert_false(_kept(all_null, _is_not_null("id")))
    assert_false(_kept(all_null, _cmp("id", BIN_EQ, _long(5))))
    assert_false(_kept(all_null, _cmp("id", BIN_GT, _long(5))))
    assert_true(_kept(all_null, _cmp("id", BIN_NE, _long(5))))
    # Only the null count, or only the value count, is not enough for IS NOT NULL.
    var nulls_only = IcebergFileEntry()
    nulls_only.null_value_counts.ids.append(1)
    nulls_only.null_value_counts.counts.append(0)
    assert_false(_kept(nulls_only, _is_null("id")))
    assert_true(_kept(nulls_only, _is_not_null("id")))
    var values_only = IcebergFileEntry()
    values_only.value_counts.ids.append(1)
    values_only.value_counts.counts.append(3)
    assert_true(_kept(values_only, _is_null("id")))
    assert_true(_kept(values_only, _is_not_null("id")))
    assert_true(_kept(IcebergFileEntry(), _is_null("id")))


def test_nan_is_never_a_bound_and_greater_than_needs_a_nan_count_of_zero() raises:
    var e = IcebergFileEntry()
    _set_bounds(e, 3, fixture_double_bytes(1.0), fixture_double_bytes(5.0))
    var ten = ScalarValue.from_float(10.0)
    # NaN rows satisfy `>` and `>=`: without a NaN count the file may match.
    assert_true(_kept(e, _cmp("x", BIN_GT, ten.copy())))
    assert_true(_kept(e, _cmp("x", BIN_GE, ten.copy())))
    _set_nans(e, 3, 2)
    assert_true(_kept(e, _cmp("x", BIN_GT, ten.copy())))
    var clean = IcebergFileEntry()
    _set_bounds(clean, 3, fixture_double_bytes(1.0), fixture_double_bytes(5.0))
    _set_nans(clean, 3, 0)
    assert_false(_kept(clean, _cmp("x", BIN_GT, ten.copy())))
    assert_false(_kept(clean, _cmp("x", BIN_GE, ten.copy())))
    assert_false(_kept(clean, _cmp("x", BIN_GT, ScalarValue.from_float(5.0))))
    assert_true(_kept(clean, _cmp("x", BIN_GE, ScalarValue.from_float(5.0))))
    assert_true(_kept(clean, _cmp("x", BIN_GT, ScalarValue.from_float(4.0))))
    # NaN is above every number, so these skip whatever the NaN count.
    assert_false(_kept(e, _cmp("x", BIN_LT, ScalarValue.from_float(0.5))))
    assert_false(_kept(e, _cmp("x", BIN_LE, ScalarValue.from_float(0.5))))
    assert_false(_kept(e, _cmp("x", BIN_EQ, ten.copy())))
    assert_true(_kept(e, _cmp("x", BIN_EQ, ScalarValue.from_float(3.0))))
    assert_true(_kept(e, _cmp("x", BIN_NE, ScalarValue.from_float(3.0))))
    # A NaN literal never skips.
    assert_true(_kept(clean, _cmp("x", BIN_EQ, ScalarValue.from_float(nan[DType.float64]()))))
    assert_true(_kept(clean, _cmp("x", BIN_GT, ScalarValue.from_float(nan[DType.float64]()))))
    # A NaN bound is no bound.
    var nan_lower = IcebergFileEntry()
    _set_bounds(nan_lower, 3, fixture_double_bytes(nan[DType.float64]()), fixture_double_bytes(5.0))
    assert_true(_kept(nan_lower, _cmp("x", BIN_LT, ScalarValue.from_float(0.0))))
    _set_nans(nan_lower, 3, 0)
    assert_false(_kept(nan_lower, _cmp("x", BIN_GT, ten.copy())))
    # An integer literal on a double column is compared as a double.
    assert_false(_kept(clean, _cmp("x", BIN_GT, _long(10))))
    assert_true(_kept(clean, _cmp("x", BIN_GT, _long(2))))
    # A literal no double represents exactly is not understood.
    assert_equal(len(_preds(_cmp("x", BIN_GT, _long(9007199254740993)))), 0)
    # -0.0 is 0.0.
    var zero = IcebergFileEntry()
    _set_bounds(zero, 3, fixture_double_bytes(-0.0), fixture_double_bytes(1.0))
    assert_true(_kept(zero, _cmp("x", BIN_EQ, ScalarValue.from_float(0.0))))
    # A float column holds 4-byte bounds, and so may a double column that was a float.
    var single = IcebergFileEntry()
    _set_bounds(single, 9, fixture_float_bytes(1.5), fixture_float_bytes(2.5))
    assert_false(_kept(single, _cmp("f", BIN_EQ, ScalarValue.from_float(100.0))))
    assert_true(_kept(single, _cmp("f", BIN_EQ, ScalarValue.from_float(2.0))))
    var promoted = IcebergFileEntry()
    _set_bounds(promoted, 3, fixture_float_bytes(1.5), fixture_float_bytes(2.5))
    assert_false(_kept(promoted, _cmp("x", BIN_EQ, ScalarValue.from_float(100.0))))


def test_string_bounds_compare_as_unsigned_bytes_and_may_be_truncated() raises:
    var e = IcebergFileEntry()
    _set_bounds(e, 2, fixture_text_bytes("abc"), fixture_text_bytes("abd"))
    assert_false(_kept(e, _cmp("name", BIN_EQ, ScalarValue.from_string("b"))))
    assert_false(_kept(e, _cmp("name", BIN_EQ, ScalarValue.from_string("a"))))
    assert_false(_kept(e, _cmp("name", BIN_EQ, ScalarValue.from_string(""))))
    assert_true(_kept(e, _cmp("name", BIN_EQ, ScalarValue.from_string("abc"))))
    assert_true(_kept(e, _cmp("name", BIN_EQ, ScalarValue.from_string("abcd"))))
    assert_true(_kept(e, _cmp("name", BIN_EQ, ScalarValue.from_string("abd"))))
    # 'abd' as an upper bound may be the prefix of the longest value.
    assert_true(_kept(e, _cmp("name", BIN_EQ, ScalarValue.from_string("abdz"))))
    assert_false(_kept(e, _cmp("name", BIN_GE, ScalarValue.from_string("zzz"))))
    assert_false(_kept(e, _cmp("name", BIN_LT, ScalarValue.from_string("a"))))
    assert_false(_kept(e, _cmp("name", BIN_LE, ScalarValue.from_string("abb"))))
    assert_true(_kept(e, _cmp("name", BIN_LE, ScalarValue.from_string("abc"))))
    assert_true(_kept(e, _cmp("name", BIN_GT, ScalarValue.from_string("abc"))))

    # Both bounds are the 16-character prefix: the values run past it.
    var cut = IcebergFileEntry()
    _set_bounds(cut, 2, fixture_text_bytes("abcdefghijklmnop"), fixture_text_bytes("abcdefghijklmnop"))
    assert_true(_kept(cut, _cmp("name", BIN_EQ, ScalarValue.from_string("abcdefghijklmnopq"))))
    assert_true(_kept(cut, _cmp("name", BIN_GT, ScalarValue.from_string("abcdefghijklmnopq"))))
    assert_false(_kept(cut, _cmp("name", BIN_EQ, ScalarValue.from_string("abcdefghijklmnoq"))))

    # Unsigned byte order: U+00E9 (0xC3 0xA9) is above 'z' (0x7A).
    var ascii = IcebergFileEntry()
    _set_bounds(ascii, 2, fixture_text_bytes("a"), fixture_text_bytes("z"))
    assert_false(_kept(ascii, _cmp("name", BIN_EQ, ScalarValue.from_string("é"))))
    assert_true(_kept(ascii, _cmp("name", BIN_EQ, ScalarValue.from_string("m"))))


def test_other_types_date_timestamp_int_and_boolean() raises:
    var date = IcebergFileEntry()
    _set_bounds(date, 4, fixture_int_bytes(20700), fixture_int_bytes(20710))
    assert_false(_kept(date, _cmp("d", BIN_GE, ScalarValue.date32(Int32(20711)))))
    assert_false(_kept(date, _cmp("d", BIN_LT, ScalarValue.date32(Int32(20700)))))
    assert_true(_kept(date, _cmp("d", BIN_EQ, ScalarValue.date32(Int32(20705)))))
    # A timestamp literal on a date column is another kind.
    assert_equal(len(_preds(_cmp("d", BIN_EQ, ScalarValue.timestamp_micros(Int64(1788300000000000))))), 0)

    var ts = IcebergFileEntry()
    var lo = Int64(1788300000000000)
    var hi = Int64(1788300001000000)
    _set_bounds(ts, 5, fixture_long_bytes(lo), fixture_long_bytes(hi))
    assert_false(_kept(ts, _cmp("ts", BIN_GT, ScalarValue.timestamp_micros(hi))))
    assert_true(_kept(ts, _cmp("ts", BIN_GE, ScalarValue.timestamp_micros(hi))))
    assert_false(_kept(ts, _cmp("ts", BIN_EQ, ScalarValue.timestamp_micros(lo - 1))))

    var ints = IcebergFileEntry()
    _set_bounds(ints, 6, fixture_int_bytes(1), fixture_int_bytes(9))
    assert_false(_kept(ints, _cmp("i", BIN_EQ, ScalarValue.from_int32(Int32(50)))))
    assert_true(_kept(ints, _cmp("i", BIN_EQ, ScalarValue.from_int32(Int32(5)))))

    var zero = List[UInt8]()
    zero.append(0)
    var one = List[UInt8]()
    one.append(1)
    var falses = IcebergFileEntry()
    _set_bounds(falses, 7, zero, zero)
    assert_false(_kept(falses, _cmp("b", BIN_EQ, ScalarValue.from_bool(True))))
    assert_true(_kept(falses, _cmp("b", BIN_EQ, ScalarValue.from_bool(False))))
    var trues = IcebergFileEntry()
    _set_bounds(trues, 7, one, one)
    assert_false(_kept(trues, _cmp("b", BIN_EQ, ScalarValue.from_bool(False))))


def test_conjuncts_the_evaluator_does_not_understand_are_ignored() raises:
    assert_equal(len(_preds(_cmp("id", BIN_EQ, ScalarValue.from_string("x")))), 0)
    assert_equal(len(_preds(_cmp("name", BIN_EQ, _long(5)))), 0)
    assert_equal(len(_preds(_cmp("price", BIN_GT, _long(5)))), 0)
    assert_equal(len(_preds(_cmp("missing", BIN_EQ, _long(5)))), 0)
    assert_equal(len(_preds(_cmp("id", BIN_EQ, ScalarValue.null(DType.int64)))), 0)
    assert_equal(
        len(_preds(Expr.binary(BIN_OR, _cmp("id", BIN_EQ, _long(1)), _cmp("id", BIN_EQ, _long(2))))),
        0,
    )
    assert_equal(
        len(_preds(Expr.binary(BIN_ADD, Expr.col_ref("id"), Expr.literal(_long(1))))), 0
    )
    assert_equal(len(_preds(Expr.unary(UN_NOT, _is_null("id")))), 0)
    assert_equal(len(_preds(Expr.unary(UN_IS_NULL, Expr.literal(_long(1))))), 0)
    assert_equal(
        len(_preds(Expr.binary(BIN_EQ, Expr.left("id"), Expr.literal(_long(1))))), 0
    )
    assert_equal(
        len(_preds(Expr.binary(BIN_EQ, Expr.col_ref("id"), Expr.col_ref("i")))), 0
    )
    assert_equal(len(_preds(_is_null("price"))), 0)
    assert_equal(len(prune_predicates_of(None, _columns())), 0)
    var good_and_bad = Expr.binary(
        BIN_AND, _cmp("id", BIN_GT, _long(100)), _cmp("price", BIN_GT, _long(1))
    )
    var preds = _preds(good_and_bad^)
    assert_equal(len(preds), 1)
    assert_equal(preds[0].column, "id")
    assert_equal(preds[0].field_id, 1)
    assert_false(_kept(_longs(10, 20), Expr.binary(BIN_AND, _cmp("id", BIN_GT, _long(100)), _cmp("price", BIN_GT, _long(1)))))
    # A boolean literal on a boolean column, an integer on a float column.
    assert_equal(len(_preds(_cmp("b", BIN_EQ, ScalarValue.from_bool(True)))), 1)
    assert_equal(len(_preds(_cmp("f", BIN_EQ, _long(3)))), 1)
    assert_equal(len(_preds(_cmp("b", BIN_EQ, _long(1)))), 0)


def _region_spec() -> IcebergPartitionSpecDef:
    var fields = List[IcebergPartitionField]()
    fields.append(IcebergPartitionField(10, 1000, "region", "identity"))
    fields.append(IcebergPartitionField(1, 1001, "id_bucket", "bucket[4]"))
    return IcebergPartitionSpecDef(0, fields^)


def _partitioned(region: Optional[String]) -> IcebergFileEntry:
    var e = IcebergFileEntry()
    if region:
        e.partition.append(Optional[List[UInt8]](fixture_text_bytes(region.value())))
    else:
        e.partition.append(None)
    e.partition.append(Optional[List[UInt8]](fixture_int_bytes(2)))
    return e^


def _kept_in_spec(e: IcebergFileEntry, spec: IcebergPartitionSpecDef, var expr: Expr) -> Bool:
    return entry_may_match(e, spec, _preds(expr^))


def test_identity_partition_values_skip_entries() raises:
    var spec = _region_spec()
    var eu = _partitioned(Optional[String]("eu"))
    assert_false(_kept_in_spec(eu, spec, _cmp("region", BIN_EQ, ScalarValue.from_string("us"))))
    assert_true(_kept_in_spec(eu, spec, _cmp("region", BIN_EQ, ScalarValue.from_string("eu"))))
    assert_false(_kept_in_spec(eu, spec, _is_null("region")))
    assert_true(_kept_in_spec(eu, spec, _is_not_null("region")))
    assert_true(_kept_in_spec(eu, spec, _cmp("region", BIN_NE, ScalarValue.from_string("eu"))))
    assert_false(_kept_in_spec(eu, spec, _cmp("region", BIN_GT, ScalarValue.from_string("f"))))
    assert_false(_kept_in_spec(eu, spec, _cmp("region", BIN_LT, ScalarValue.from_string("a"))))
    assert_true(_kept_in_spec(eu, spec, _cmp("region", BIN_LE, ScalarValue.from_string("f"))))

    var nothing = _partitioned(None)
    assert_true(_kept_in_spec(nothing, spec, _is_null("region")))
    assert_false(_kept_in_spec(nothing, spec, _cmp("region", BIN_EQ, ScalarValue.from_string("eu"))))
    assert_false(_kept_in_spec(nothing, spec, _is_not_null("region")))

    # Another transform is not projected: the bucket field keeps the file.
    assert_true(_kept_in_spec(eu, spec, _cmp("id", BIN_EQ, _long(5))))
    # A tuple shorter than the spec says nothing.
    assert_true(_kept_in_spec(IcebergFileEntry(), spec, _cmp("region", BIN_EQ, ScalarValue.from_string("us"))))
    # The partition value and the metrics both apply.
    var with_bounds = _partitioned(Optional[String]("eu"))
    _set_bounds(with_bounds, 1, fixture_long_bytes(10), fixture_long_bytes(20))
    assert_false(
        _kept_in_spec(
            with_bounds,
            spec,
            Expr.binary(
                BIN_AND,
                _cmp("region", BIN_EQ, ScalarValue.from_string("eu")),
                _cmp("id", BIN_EQ, _long(5)),
            ),
        )
    )

    # An int value of an identity field under a column now long, and a NaN.
    var fields = List[IcebergPartitionField]()
    fields.append(IcebergPartitionField(1, 1000, "id", "identity"))
    fields.append(IcebergPartitionField(3, 1001, "x", "identity"))
    var by_value = IcebergPartitionSpecDef(0, fields^)
    var e = IcebergFileEntry()
    e.partition.append(Optional[List[UInt8]](fixture_int_bytes(5)))
    e.partition.append(Optional[List[UInt8]](fixture_double_bytes(nan[DType.float64]())))
    assert_false(_kept_in_spec(e, by_value, _cmp("id", BIN_EQ, _long(7))))
    assert_true(_kept_in_spec(e, by_value, _cmp("id", BIN_EQ, _long(5))))
    assert_true(_kept_in_spec(e, by_value, _cmp("x", BIN_EQ, ScalarValue.from_float(1.0))))


def _summary(
    lower: String, upper: String, contains_null: Bool
) -> IcebergPartitionSummary:
    var s = IcebergPartitionSummary()
    s.contains_null = contains_null
    s.lower = Optional[List[UInt8]](fixture_text_bytes(lower))
    s.upper = Optional[List[UInt8]](fixture_text_bytes(upper))
    return s^


def _single_region_spec(transform: String) -> IcebergPartitionSpecDef:
    var fields = List[IcebergPartitionField]()
    fields.append(IcebergPartitionField(10, 1000, "region", transform))
    return IcebergPartitionSpecDef(0, fields^)


def _manifest_may_match(
    m: IcebergManifestFile, spec: IcebergPartitionSpecDef, var expr: Expr
) -> Bool:
    return manifest_may_match(m, spec, _preds(expr^))


def test_partition_summaries_skip_manifests() raises:
    var spec = _single_region_spec("identity")
    var m = IcebergManifestFile()
    m.partitions.append(_summary("b", "f", False))
    assert_false(_manifest_may_match(m, spec, _cmp("region", BIN_EQ, ScalarValue.from_string("z"))))
    assert_false(_manifest_may_match(m, spec, _cmp("region", BIN_EQ, ScalarValue.from_string("a"))))
    assert_true(_manifest_may_match(m, spec, _cmp("region", BIN_EQ, ScalarValue.from_string("c"))))
    assert_false(_manifest_may_match(m, spec, _cmp("region", BIN_GE, ScalarValue.from_string("g"))))
    assert_true(_manifest_may_match(m, spec, _cmp("region", BIN_GT, ScalarValue.from_string("f"))))
    assert_true(_manifest_may_match(m, spec, _cmp("region", BIN_NE, ScalarValue.from_string("c"))))
    assert_false(_manifest_may_match(m, spec, _is_null("region")))
    assert_true(_manifest_may_match(m, spec, _is_not_null("region")))
    var with_nulls = IcebergManifestFile()
    with_nulls.partitions.append(_summary("b", "f", True))
    assert_true(_manifest_may_match(with_nulls, spec, _is_null("region")))

    # A summary count that is not the spec's, and a summary with no bounds.
    assert_true(_manifest_may_match(IcebergManifestFile(), spec, _cmp("region", BIN_EQ, ScalarValue.from_string("z"))))
    var two = IcebergManifestFile()
    two.partitions.append(_summary("b", "f", False))
    two.partitions.append(_summary("b", "f", False))
    assert_true(_manifest_may_match(two, spec, _cmp("region", BIN_EQ, ScalarValue.from_string("z"))))
    var unbounded = IcebergManifestFile()
    unbounded.partitions.append(IcebergPartitionSummary())
    assert_true(_manifest_may_match(unbounded, spec, _cmp("region", BIN_EQ, ScalarValue.from_string("z"))))
    # Another transform, and a predicate on another column.
    assert_true(_manifest_may_match(m, _single_region_spec("truncate[2]"), _cmp("region", BIN_EQ, ScalarValue.from_string("z"))))
    assert_true(_manifest_may_match(m, spec, _cmp("id", BIN_EQ, _long(5))))

    # contains_nan lets `>` skip by the upper bound.
    var fields = List[IcebergPartitionField]()
    fields.append(IcebergPartitionField(3, 1000, "x", "identity"))
    var by_x = IcebergPartitionSpecDef(0, fields^)
    var doubles = IcebergManifestFile()
    var s = IcebergPartitionSummary()
    s.lower = Optional[List[UInt8]](fixture_double_bytes(1.0))
    s.upper = Optional[List[UInt8]](fixture_double_bytes(5.0))
    s.contains_nan = Optional[Bool](False)
    doubles.partitions.append(s.copy())
    assert_false(_manifest_may_match(doubles, by_x, _cmp("x", BIN_GT, ScalarValue.from_float(10.0))))
    var unknown_nan = IcebergManifestFile()
    var u = s.copy()
    u.contains_nan = None
    unknown_nan.partitions.append(u^)
    assert_true(_manifest_may_match(unknown_nan, by_x, _cmp("x", BIN_GT, ScalarValue.from_float(10.0))))
    var has_nan = IcebergManifestFile()
    var h = s.copy()
    h.contains_nan = Optional[Bool](True)
    has_nan.partitions.append(h^)
    assert_true(_manifest_may_match(has_nan, by_x, _cmp("x", BIN_GT, ScalarValue.from_float(10.0))))


def main() raises:
    var suite = TestSuite()
    suite.test[test_integer_bounds_skip_by_each_comparison]()
    suite.test[test_a_missing_or_malformed_metric_keeps_the_file]()
    suite.test[test_null_counts_skip_is_null_is_not_null_and_all_null_files]()
    suite.test[test_nan_is_never_a_bound_and_greater_than_needs_a_nan_count_of_zero]()
    suite.test[test_string_bounds_compare_as_unsigned_bytes_and_may_be_truncated]()
    suite.test[test_other_types_date_timestamp_int_and_boolean]()
    suite.test[test_conjuncts_the_evaluator_does_not_understand_are_ignored]()
    suite.test[test_identity_partition_values_skip_entries]()
    suite.test[test_partition_summaries_skip_manifests]()
    suite^.run()
