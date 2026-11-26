# =============================================================================
# UNION ALL binding: common column types, branch projections, ORDER BY / LIMIT
# above the union (sql_parser, sql_binder, sql_bind_union)
# =============================================================================
#
# Every query binds against a catalog of parquet tables registered with a
# given schema (`add_parquet` opens no file) and `NoParquetFooters`, so no test
# reads a file. Table `t_<kind>` has one column `x` of that kind. What each
# test proves:
#   1. Branches of one type keep it (a decimal keeps its precision and scale,
#      a timestamp its zone).
#   2. Two integers of one signedness take the wider; a signed with an unsigned
#      integer take the signed type of twice the unsigned width, or the signed
#      one when it is wider than the unsigned one; both orders.
#   3. An unsigned 64-bit integer with any signed integer is refused, naming
#      both types and DuckDB's HUGEINT.
#   4. An integer with a float takes the float; two floats take FLOAT64.
#   5. A decimal with an integer takes the decimal that holds the integer's
#      digits; two decimals take the larger scale and the larger count of
#      integer digits; a result past 38 digits is refused; a decimal with a
#      float takes the float.
#   6. Two zone-less timestamps take the finer unit; a zone on either side or a
#      nanosecond side with another unit is refused.
#   7. A 32- or 64-bit signed integer with a string takes the string, as in
#      DuckDB, in either order. Pairs with no common type (a string with any
#      other number, string with large string, bool with number, date with
#      timestamp, float16 with integer, decimal with string) are refused with
#      the column number, name and both types.
#   8. The union is nullable when any branch is, on every kind of column; its
#      names are the first branch's; each column folds on its own.
#   9. A chain folds left to right into ONE union node with a child per
#      branch; a refusal in a later branch names the branches before it.
#  10. A branch with another name or type is cast and renamed in its own
#      SELECT-list projection, by position (so two columns of one name, two
#      bare literals included, stay two columns), or under one added
#      projection when it ends in none; a branch equal in names and types is
#      left as it is.
#  11. Bare integer literals of every branch are INT32 when they fit and widen
#      to INT64 beside a larger literal.
#  12. ORDER BY / LIMIT / OFFSET after the last branch sort and window the whole
#      union (the plan's root is above the union node); on the first or a
#      middle branch they are a syntax error naming the clause.
#  13. `FROM (a UNION ALL b) u` binds to a union under the outer select, also
#      with a trailing ORDER BY / LIMIT inside the parentheses.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_ir.logical_plan import (
    LogicalPlan, PLAN_LIMIT, PLAN_PROJECT, PLAN_SORT, PLAN_UNION,
)

from sql.sql_token import tokenize
from sql.sql_parser import parse_sql
from sql.sql_catalog import SqlCatalog
from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_binder import bind_statement


def _x(at: ArrowType, nullable: Bool = False) -> Field:
    return Field(String("x"), at, nullable)


def _add(mut cat: SqlCatalog, kind: String, f: Field):
    var sb = SchemaBuilder()
    sb.add_field(f)
    cat.add_parquet(String("t_") + kind, String("t_") + kind + ".parquet", sb.build())


def _catalog() raises -> SqlCatalog:
    var cat = SqlCatalog()
    _add(cat, "i8", _x(ArrowType.INT8))
    _add(cat, "i16", _x(ArrowType.INT16))
    _add(cat, "i32", _x(ArrowType.INT32))
    _add(cat, "i64", _x(ArrowType.INT64))
    _add(cat, "u8", _x(ArrowType.UINT8))
    _add(cat, "u16", _x(ArrowType.UINT16))
    _add(cat, "u32", _x(ArrowType.UINT32))
    _add(cat, "u64", _x(ArrowType.UINT64))
    _add(cat, "f16", _x(ArrowType.FLOAT16))
    _add(cat, "f32", _x(ArrowType.FLOAT32))
    _add(cat, "f64", _x(ArrowType.FLOAT64))
    _add(cat, "str", _x(ArrowType.STRING))
    _add(cat, "lstr", _x(ArrowType.LARGE_STRING))
    _add(cat, "bool", _x(ArrowType.BOOL))
    _add(cat, "date", _x(ArrowType.DATE32))
    _add(cat, "ts_s", Field.timestamp("x", ArrowType.TIMESTAMP_S, "", False))
    _add(cat, "ts_ms", Field.timestamp("x", ArrowType.TIMESTAMP_MS, "", False))
    _add(cat, "ts_us", Field.timestamp("x", ArrowType.TIMESTAMP_US, "", False))
    _add(cat, "ts_ns", Field.timestamp("x", ArrowType.TIMESTAMP_NS, "", False))
    _add(cat, "tz_us", Field.timestamp("x", ArrowType.TIMESTAMP_US, "UTC", False))
    _add(cat, "tz_ms", Field.timestamp("x", ArrowType.TIMESTAMP_MS, "UTC", False))
    _add(
        cat, "tz_us_la",
        Field.timestamp("x", ArrowType.TIMESTAMP_US, "America/Los_Angeles", False),
    )
    _add(cat, "d10_2", Field.decimal128("x", 10, 2, False))
    _add(cat, "d8_4", Field.decimal128("x", 8, 4, False))
    _add(cat, "d4_1", Field.decimal128("x", 4, 1, False))
    _add(cat, "d5_0", Field.decimal128("x", 5, 0, False))
    _add(cat, "d5_2", Field.decimal128("x", 5, 2, False))
    _add(cat, "d38_0", Field.decimal128("x", 38, 0, False))
    _add(cat, "d10_5", Field.decimal128("x", 10, 5, False))
    _add(cat, "d30_25", Field.decimal128("x", 30, 25, False))
    _add(cat, "n_i32", _x(ArrowType.INT32, True))
    _add(cat, "n_str", _x(ArrowType.STRING, True))
    _add(cat, "n_d10_2", Field.decimal128("x", 10, 2, True))
    var pa = SchemaBuilder()
    pa.add_field(_x(ArrowType.INT32))
    pa.add_field(Field(String("y"), ArrowType.STRING, False))
    cat.add_parquet(String("t_pair_a"), String("t_pair_a.parquet"), pa.build())
    var pb = SchemaBuilder()
    pb.add_field(_x(ArrowType.INT64))
    pb.add_field(Field(String("y"), ArrowType.STRING, False))
    cat.add_parquet(String("t_pair_b"), String("t_pair_b.parquet"), pb.build())
    var pc = SchemaBuilder()
    pc.add_field(_x(ArrowType.INT64))
    pc.add_field(Field(String("y"), ArrowType.BOOL, False))
    cat.add_parquet(String("t_pair_c"), String("t_pair_c.parquet"), pc.build())
    return cat^


def _plan(sql: String) raises -> LogicalPlan:
    var cat = _catalog()
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    return bound.take_plan()


def _schema(sql: String) raises -> Schema:
    var plan = _plan(sql)
    return plan.output_schema.copy()


def _err(sql: String) raises -> String:
    var cat = _catalog()
    try:
        _ = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    except e:
        return String(e)
    raise Error("bound, expected a refusal: " + sql)


def _pair_sql(a: String, b: String) -> String:
    return "SELECT x FROM t_" + a + " UNION ALL SELECT x FROM t_" + b


def _check(a: String, b: String, at: ArrowType) raises:
    """`t_a UNION ALL t_b` and `t_b UNION ALL t_a` both give column type `at`."""
    var fwd = _schema(_pair_sql(a, b))
    var rev = _schema(_pair_sql(b, a))
    assert_true(fwd.field_arrow_type(0) == at, a + " then " + b)
    assert_true(rev.field_arrow_type(0) == at, b + " then " + a)


def _check_decimal(a: String, b: String, precision: Int, scale: Int) raises:
    var fwd = _schema(_pair_sql(a, b))
    var rev = _schema(_pair_sql(b, a))
    assert_true(fwd.field_arrow_type(0) == ArrowType.DECIMAL128, a + " then " + b)
    assert_equal(fwd.field_decimal_precision(0), precision, a + " then " + b)
    assert_equal(fwd.field_decimal_scale(0), scale, a + " then " + b)
    assert_true(rev.field_arrow_type(0) == ArrowType.DECIMAL128, b + " then " + a)
    assert_equal(rev.field_decimal_precision(0), precision, b + " then " + a)
    assert_equal(rev.field_decimal_scale(0), scale, b + " then " + a)


def _refusal_text(
    first: String, second: String, why: String, earlier: String = "branch 1 gives"
) -> String:
    return (
        "SQL not supported: UNION ALL column 1 (x): " + earlier + " " + first
        + " and branch 2 gives " + second + "; " + why
        + ". Cast the columns to one type."
    )


def _check_refused(
    a: String, b: String, a_type: String, b_type: String, why: String
) raises:
    assert_equal(_err(_pair_sql(a, b)), _refusal_text(a_type, b_type, why))
    # The reverse order names the types the other way round.
    assert_equal(_err(_pair_sql(b, a)), _refusal_text(b_type, a_type, why))


comptime _NO_COMMON: String = "no common type this engine casts to"
comptime _HUGEINT: String = "DuckDB's common type is HUGEINT, which Arrow cannot hold"


def _project_depth(p: LogicalPlan) -> Int:
    """The number of Project nodes stacked at the top of `p`."""
    if p.tag != PLAN_PROJECT:
        return 0
    return 1 + _project_depth(p.project_data_ref().child[])


def _conformed_depth(base: Int) -> Int:
    """The projection depth of a branch that needed a cast or a rename, given
    the depth `base` of the same branch when it needed none: its own SELECT
    list is rewritten in place when it ends in one, else one projection is
    added."""
    if base > 0:
        return base
    return 1


def _spine(p: LogicalPlan) -> String:
    """The single-child nodes from the root down to a union, e.g.
    `limit>sort>project>union(2)`; `other` where the walk meets anything else."""
    if p.tag == PLAN_LIMIT:
        return "limit>" + _spine(p.limit_data_ref().child[])
    if p.tag == PLAN_SORT:
        return "sort>" + _spine(p.sort_data_ref().child[])
    if p.tag == PLAN_PROJECT:
        return "project>" + _spine(p.project_data_ref().child[])
    if p.tag == PLAN_UNION:
        return "union(" + String(len(p.union_data_ref().children)) + ")"
    return String("other")


def _union_of(p: LogicalPlan) -> Int:
    """The number of children of the union that `_spine` reaches, else -1."""
    if p.tag == PLAN_LIMIT:
        return _union_of(p.limit_data_ref().child[])
    if p.tag == PLAN_SORT:
        return _union_of(p.sort_data_ref().child[])
    if p.tag == PLAN_PROJECT:
        return _union_of(p.project_data_ref().child[])
    if p.tag == PLAN_UNION:
        return len(p.union_data_ref().children)
    return -1


def test_branches_of_one_type_keep_it() raises:
    _check("i32", "i32", ArrowType.INT32)
    _check("str", "str", ArrowType.STRING)
    _check("f64", "f64", ArrowType.FLOAT64)
    _check("date", "date", ArrowType.DATE32)
    _check_decimal("d10_2", "d10_2", 10, 2)
    var ts = _schema(_pair_sql("tz_us", "tz_us"))
    assert_true(ts.field_arrow_type(0) == ArrowType.TIMESTAMP_US)
    assert_equal(ts.field_tz(0), "UTC")
    var naive = _schema(_pair_sql("ts_ns", "ts_ns"))
    assert_true(naive.field_arrow_type(0) == ArrowType.TIMESTAMP_NS)


def test_integers_of_one_signedness_take_the_wider() raises:
    _check("i8", "i16", ArrowType.INT16)
    _check("i8", "i32", ArrowType.INT32)
    _check("i16", "i64", ArrowType.INT64)
    _check("i32", "i64", ArrowType.INT64)
    _check("u8", "u16", ArrowType.UINT16)
    _check("u8", "u32", ArrowType.UINT32)
    _check("u16", "u64", ArrowType.UINT64)
    _check("u32", "u64", ArrowType.UINT64)


def test_signed_with_unsigned_takes_the_signed_type_of_twice_the_unsigned_width() raises:
    _check("i8", "u8", ArrowType.INT16)
    _check("i16", "u16", ArrowType.INT32)
    _check("i32", "u32", ArrowType.INT64)
    _check("i8", "u16", ArrowType.INT32)
    _check("i8", "u32", ArrowType.INT64)
    _check("i16", "u8", ArrowType.INT16)
    _check("i32", "u8", ArrowType.INT32)
    _check("i32", "u16", ArrowType.INT32)
    _check("i64", "u8", ArrowType.INT64)
    _check("i64", "u32", ArrowType.INT64)


def test_unsigned_64_with_a_signed_integer_is_refused() raises:
    _check_refused("i8", "u64", "int8", "uint64", _HUGEINT)
    _check_refused("i32", "u64", "int32", "uint64", _HUGEINT)
    _check_refused("i64", "u64", "int64", "uint64", _HUGEINT)


def test_integer_with_a_float_takes_the_float() raises:
    _check("i8", "f32", ArrowType.FLOAT32)
    _check("i64", "f32", ArrowType.FLOAT32)
    _check("u32", "f32", ArrowType.FLOAT32)
    _check("i8", "f64", ArrowType.FLOAT64)
    _check("u64", "f64", ArrowType.FLOAT64)
    _check("f32", "f64", ArrowType.FLOAT64)


def test_decimal_with_an_integer_holds_the_integer() raises:
    # The integer is DECIMAL(w, 0): INT8 3, INT16 5, INT32 10, INT64 19,
    # UINT64 20 digits; the result keeps the decimal's scale.
    _check_decimal("d4_1", "i8", 4, 1)
    _check_decimal("d4_1", "u8", 4, 1)
    _check_decimal("d4_1", "i16", 6, 1)
    _check_decimal("d4_1", "u16", 6, 1)
    _check_decimal("d10_2", "i32", 12, 2)
    _check_decimal("d4_1", "u32", 11, 1)
    _check_decimal("d5_2", "i64", 21, 2)
    _check_decimal("d5_0", "u64", 20, 0)


def test_two_decimals_take_the_larger_scale_and_integer_digits() raises:
    _check_decimal("d10_2", "d8_4", 12, 4)
    _check_decimal("d5_2", "d10_5", 10, 5)
    _check_decimal("d4_1", "d4_1", 4, 1)


def test_a_decimal_wider_than_38_digits_is_refused() raises:
    _check_refused(
        "d38_0", "d10_5", "DECIMAL128(38, 0)", "DECIMAL128(10, 5)",
        "the common decimal would need 43 digits, above 38",
    )
    # An integer widens the integer digits, and the decimal's scale stays.
    _check_refused(
        "d30_25", "i64", "DECIMAL128(30, 25)", "int64",
        "the common decimal would need 44 digits, above 38",
    )
    # 38 digits exactly is served.
    _check_decimal("d38_0", "u64", 38, 0)


def test_a_decimal_with_a_float_takes_the_float() raises:
    _check("d10_2", "f32", ArrowType.FLOAT32)
    _check("d10_2", "f64", ArrowType.FLOAT64)


def test_timestamps_take_the_finer_unit() raises:
    _check("ts_s", "ts_ms", ArrowType.TIMESTAMP_MS)
    _check("ts_ms", "ts_us", ArrowType.TIMESTAMP_US)
    _check("ts_s", "ts_us", ArrowType.TIMESTAMP_US)


def test_timestamps_with_a_zone_or_in_nanoseconds_are_refused() raises:
    _check_refused(
        "tz_ms", "tz_us", "timestamp[ms]", "timestamp[us]", _NO_COMMON
    )
    _check_refused(
        "tz_us", "tz_us_la", "timestamp[us]", "timestamp[us]", _NO_COMMON
    )
    _check_refused(
        "ts_us", "tz_us", "timestamp[us]", "timestamp[us]", _NO_COMMON
    )
    _check_refused(
        "ts_ns", "ts_us", "timestamp[ns]", "timestamp[us]", _NO_COMMON
    )
    _check_refused(
        "date", "ts_us", "date32", "timestamp[us]", _NO_COMMON
    )


def test_a_32_or_64_bit_signed_integer_with_a_string_takes_the_string() raises:
    _check("i32", "str", ArrowType.STRING)
    _check("i64", "str", ArrowType.STRING)
    _check("n_i32", "str", ArrowType.STRING)
    var nullable = _schema(_pair_sql("i64", "n_str"))
    assert_true(nullable.field_nullable(0))
    # The integer branch is cast to the string, the string branch kept.
    var plan = _plan(_pair_sql("i64", "str"))
    ref kids = plan.union_data_ref().children
    assert_true(kids[0][].output_schema.field_arrow_type(0) == ArrowType.STRING)
    assert_true(kids[1][].output_schema.field_arrow_type(0) == ArrowType.STRING)


def test_pairs_with_no_common_type_are_refused() raises:
    _check_refused("str", "i8", "string", "int8", _NO_COMMON)
    _check_refused("str", "i16", "string", "int16", _NO_COMMON)
    _check_refused("str", "u32", "string", "uint32", _NO_COMMON)
    _check_refused("str", "f64", "string", "float64", _NO_COMMON)
    _check_refused("str", "date", "string", "date32", _NO_COMMON)
    _check_refused("lstr", "i64", "large_string", "int64", _NO_COMMON)
    _check_refused("str", "lstr", "string", "large_string", _NO_COMMON)
    _check_refused("bool", "i32", "bool", "int32", _NO_COMMON)
    _check_refused("bool", "f64", "bool", "float64", _NO_COMMON)
    _check_refused("date", "i32", "date32", "int32", _NO_COMMON)
    _check_refused("f16", "i32", "float16", "int32", _NO_COMMON)
    _check_refused("f16", "f32", "float16", "float32", _NO_COMMON)
    _check_refused("d10_2", "str", "DECIMAL128(10, 2)", "string", _NO_COMMON)


def test_the_union_is_nullable_when_any_branch_is() raises:
    var plain = _schema(_pair_sql("i32", "i32"))
    assert_true(not plain.field_nullable(0))
    var same_type = _schema(_pair_sql("i32", "n_i32"))
    assert_true(same_type.field_nullable(0))
    var same_type_rev = _schema(_pair_sql("n_i32", "i32"))
    assert_true(same_type_rev.field_nullable(0))
    var widened = _schema(_pair_sql("n_i32", "i64"))
    assert_true(widened.field_arrow_type(0) == ArrowType.INT64)
    assert_true(widened.field_nullable(0))
    var strings = _schema(_pair_sql("str", "n_str"))
    assert_true(strings.field_nullable(0))
    var decimals = _schema(_pair_sql("d8_4", "n_d10_2"))
    assert_equal(decimals.field_decimal_precision(0), 12)
    assert_true(decimals.field_nullable(0))
    var not_null = _schema(_pair_sql("d8_4", "d10_2"))
    assert_true(not not_null.field_nullable(0))


def test_names_come_from_the_head_and_each_column_folds_on_its_own() raises:
    var named = _schema(
        "SELECT x AS a FROM t_i32 UNION ALL SELECT x AS b FROM t_i64"
    )
    assert_equal(named.field_name(0), "a")
    assert_true(named.field_arrow_type(0) == ArrowType.INT64)
    var pair = _schema(
        "SELECT x, y FROM t_pair_a UNION ALL SELECT x, y FROM t_pair_b"
    )
    assert_equal(pair.num_columns(), 2)
    assert_equal(pair.field_name(0), "x")
    assert_equal(pair.field_name(1), "y")
    assert_true(pair.field_arrow_type(0) == ArrowType.INT64)
    assert_true(pair.field_arrow_type(1) == ArrowType.STRING)
    assert_equal(
        _err("SELECT x, y FROM t_pair_a UNION ALL SELECT x, y FROM t_pair_c"),
        "SQL not supported: UNION ALL column 2 (y): branch 1 gives string and"
        " branch 2 gives bool; no common type this engine casts to."
        " Cast the columns to one type.",
    )


def test_a_chain_folds_left_to_right_into_one_union_node() raises:
    var plan = _plan(
        "SELECT x FROM t_i8 UNION ALL SELECT x FROM t_u8 UNION ALL SELECT x"
        " FROM t_u16"
    )
    assert_equal(Int(plan.tag), Int(PLAN_UNION))
    assert_equal(len(plan.union_data_ref().children), 3)
    # int8 with uint8 is int16, then int16 with uint16 is int32.
    assert_true(plan.output_schema.field_arrow_type(0) == ArrowType.INT32)
    for i in range(3):
        var child_schema = plan.union_data_ref().children[i][].output_schema.copy()
        assert_true(child_schema.field_arrow_type(0) == ArrowType.INT32)
        assert_equal(child_schema.field_name(0), "x")


def test_a_refusal_in_a_later_branch_names_the_branches_before_it() raises:
    assert_equal(
        _err(
            "SELECT x FROM t_i32 UNION ALL SELECT x FROM t_i64 UNION ALL"
            " SELECT x FROM t_bool"
        ),
        "SQL not supported: UNION ALL column 1 (x): branches 1 to 2 give int64"
        " and branch 3 gives bool; no common type this engine casts to."
        " Cast the columns to one type.",
    )
    assert_equal(
        _err(
            "SELECT x FROM t_i32 UNION ALL SELECT x FROM t_i32 UNION ALL"
            " SELECT x, y FROM t_pair_a"
        ),
        "SQL bind error: UNION ALL branch 3 produces 2 column(s) but the first"
        " branch produces 1. Every branch of a UNION ALL must produce the same"
        " number of columns, in the same order.",
    )


def test_a_branch_with_another_name_gets_a_projection() raises:
    var base = _plan(
        "SELECT x AS a FROM t_i32 UNION ALL SELECT x AS a FROM t_i32"
    )
    var head_depth = _project_depth(base.union_data_ref().children[0][])
    var branch_depth = _project_depth(base.union_data_ref().children[1][])
    assert_true(branch_depth > 0)
    var renamed = _plan(
        "SELECT x AS a FROM t_i32 UNION ALL SELECT x FROM t_i32"
    )
    assert_equal(_project_depth(renamed.union_data_ref().children[0][]), head_depth)
    assert_equal(
        _project_depth(renamed.union_data_ref().children[1][]),
        _conformed_depth(branch_depth),
    )
    var branch_schema = renamed.union_data_ref().children[1][].output_schema.copy()
    assert_equal(branch_schema.field_name(0), "a")
    assert_true(branch_schema.field_arrow_type(0) == ArrowType.INT32)


def test_a_branch_of_another_type_is_cast_under_one_projection() raises:
    var base = _plan("SELECT x FROM t_i32 UNION ALL SELECT x FROM t_i32")
    var head_depth = _project_depth(base.union_data_ref().children[0][])
    var branch_depth = _project_depth(base.union_data_ref().children[1][])
    var widened = _plan("SELECT x FROM t_i32 UNION ALL SELECT x FROM t_i64")
    assert_equal(
        _project_depth(widened.union_data_ref().children[0][]),
        _conformed_depth(head_depth),
    )
    var i64_base = _plan("SELECT x FROM t_i64 UNION ALL SELECT x FROM t_i64")
    assert_equal(
        _project_depth(widened.union_data_ref().children[1][]),
        _project_depth(i64_base.union_data_ref().children[1][]),
    )
    assert_true(branch_depth > 0)
    for i in range(2):
        var s = widened.union_data_ref().children[i][].output_schema.copy()
        assert_true(s.field_arrow_type(0) == ArrowType.INT64)
        assert_equal(s.field_name(0), "x")
    var decimals = _plan("SELECT x FROM t_d10_2 UNION ALL SELECT x FROM t_d8_4")
    for i in range(2):
        var d = decimals.union_data_ref().children[i][].output_schema.copy()
        assert_true(d.field_arrow_type(0) == ArrowType.DECIMAL128)
        assert_equal(d.field_decimal_precision(0), 12)
        assert_equal(d.field_decimal_scale(0), 4)


def test_a_branch_of_equal_schema_gets_no_projection() raises:
    var plan = _plan("SELECT x FROM t_i64 UNION ALL SELECT x FROM t_i64")
    var first = _project_depth(plan.union_data_ref().children[0][])
    var second = _project_depth(plan.union_data_ref().children[1][])
    var mixed = _plan("SELECT x FROM t_i64 UNION ALL SELECT x FROM t_i32")
    assert_equal(_project_depth(mixed.union_data_ref().children[0][]), first)
    assert_equal(
        _project_depth(mixed.union_data_ref().children[1][]),
        _conformed_depth(second),
    )


def test_a_branch_with_two_columns_of_one_name_is_cast_by_position() raises:
    # Branch 2 has two columns named `a` and both need a cast to BIGINT. Its
    # own SELECT list is rewritten by position, so it stays two columns, each
    # still its own expression.
    var plan = _plan(
        "SELECT x AS a, x + 1 AS a FROM t_i64 UNION ALL SELECT x AS a, x + 2"
        " AS a FROM t_i32"
    )
    assert_equal(Int(plan.tag), Int(PLAN_UNION))
    ref branch = plan.union_data_ref().children[1][]
    assert_equal(Int(branch.tag), Int(PLAN_PROJECT))
    assert_equal(branch.output_schema.num_columns(), 2)
    for c in range(2):
        assert_equal(branch.output_schema.field_name(c), "a")
        assert_true(branch.output_schema.field_arrow_type(c) == ArrowType.INT64)
    ref exprs = branch.project_data_ref().exprs
    assert_true(String(exprs[0]) != String(exprs[1]), String(exprs[0]))
    # Two bare literals are both `literal`; the branch binds as two columns.
    var lits = _plan("SELECT x AS n, x AS m FROM t_i64 UNION ALL SELECT 9, 10")
    assert_equal(lits.output_schema.num_columns(), 2)
    assert_equal(lits.output_schema.field_name(0), "n")
    assert_equal(lits.output_schema.field_name(1), "m")
    ref lit_branch = lits.union_data_ref().children[1][]
    for c in range(2):
        assert_true(lit_branch.output_schema.field_arrow_type(c) == ArrowType.INT64)
    assert_equal(lit_branch.output_schema.field_name(1), "m")
    # Equal in names and types, a branch needs no projection and binds.
    var same = _plan(
        "SELECT x AS a, x AS a FROM t_i64 UNION ALL SELECT x AS a, x AS a"
        " FROM t_i64"
    )
    assert_equal(Int(same.tag), Int(PLAN_UNION))
    assert_equal(same.output_schema.num_columns(), 2)


def test_int_literals_of_every_branch_are_int32() raises:
    var both = _schema("select 1 as n union all select 2")
    assert_equal(both.field_name(0), "n")
    assert_true(both.field_arrow_type(0) == ArrowType.INT32)
    var wide_last = _schema("select 1 as n union all select 5000000000")
    assert_true(wide_last.field_arrow_type(0) == ArrowType.INT64)
    var wide_first = _schema("select 5000000000 as n union all select 1")
    assert_true(wide_first.field_arrow_type(0) == ArrowType.INT64)
    var chain = _schema("select 1 as n union all select 2 union all select 3")
    assert_true(chain.field_arrow_type(0) == ArrowType.INT32)


def test_order_by_and_limit_after_the_last_branch_sit_above_the_union() raises:
    var both = _plan(
        "SELECT x FROM t_i32 UNION ALL SELECT x FROM t_i64 ORDER BY x DESC"
        " LIMIT 2"
    )
    assert_equal(Int(both.tag), Int(PLAN_LIMIT))
    assert_equal(both.limit_data_ref().n, 2)
    assert_equal(both.limit_data_ref().offset, 0)
    var spine = _spine(both)
    assert_true(spine.startswith("limit>"), spine)
    assert_true("sort>" in spine, spine)
    assert_true(spine.endswith("union(2)"), spine)
    assert_true(both.output_schema.field_arrow_type(0) == ArrowType.INT64)
    var sorted_only = _plan(
        "SELECT x FROM t_i32 UNION ALL SELECT x FROM t_i64 ORDER BY x"
    )
    var sorted_spine = _spine(sorted_only)
    assert_true("sort>" in sorted_spine, sorted_spine)
    assert_true("limit" not in sorted_spine, sorted_spine)
    assert_true(sorted_spine.endswith("union(2)"), sorted_spine)
    var window = _plan(
        "SELECT x FROM t_i32 UNION ALL SELECT x FROM t_i64 LIMIT 3 OFFSET 1"
    )
    assert_equal(Int(window.tag), Int(PLAN_LIMIT))
    assert_equal(window.limit_data_ref().n, 3)
    assert_equal(window.limit_data_ref().offset, 1)
    assert_true(_spine(window).endswith("union(2)"), _spine(window))
    var three = _plan(
        "SELECT x FROM t_i8 UNION ALL SELECT x FROM t_i16 UNION ALL SELECT x"
        " FROM t_i32 ORDER BY x LIMIT 1"
    )
    assert_equal(_union_of(three), 3)


def test_order_by_or_limit_before_the_last_branch_is_a_syntax_error() raises:
    assert_equal(
        _err("SELECT x FROM t_i32 ORDER BY x UNION ALL SELECT x FROM t_i64"),
        "SQL syntax error: ORDER BY before UNION ALL. ORDER BY, LIMIT and"
        " OFFSET apply to the whole UNION ALL, so they must follow its last"
        " branch.",
    )
    assert_true(
        "LIMIT before UNION ALL"
        in _err("SELECT x FROM t_i32 LIMIT 1 UNION ALL SELECT x FROM t_i64")
    )
    assert_true(
        "ORDER BY before UNION ALL"
        in _err(
            "SELECT x FROM t_i32 UNION ALL SELECT x FROM t_i64 ORDER BY x"
            " UNION ALL SELECT x FROM t_i8"
        )
    )


def test_a_derived_table_over_a_union_binds_to_a_union_under_the_outer_select() raises:
    var plan = _plan(
        "SELECT x FROM (SELECT x FROM t_i32 UNION ALL SELECT x FROM t_i64) u"
    )
    var spine = _spine(plan)
    assert_true(spine.startswith("project>"), spine)
    assert_true(spine.endswith("union(2)"), spine)
    assert_true(plan.output_schema.field_arrow_type(0) == ArrowType.INT64)
    assert_equal(plan.output_schema.field_name(0), "x")
    var ordered = _plan(
        "SELECT x FROM (SELECT x FROM t_i32 UNION ALL SELECT x FROM t_i64"
        " ORDER BY x LIMIT 1) u"
    )
    var ordered_spine = _spine(ordered)
    assert_true("limit>" in ordered_spine, ordered_spine)
    assert_true(ordered_spine.endswith("union(2)"), ordered_spine)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
