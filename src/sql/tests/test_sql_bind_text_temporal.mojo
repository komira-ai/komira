# =============================================================================
# Binding text -> DATE / TIMESTAMP: CAST, TRY_CAST, strptime, try_strptime
# =============================================================================
#
# What it proves: CAST / TRY_CAST of a text operand to DATE or TIMESTAMP (and
# DuckDB's aliases DATETIME, TIMESTAMP_US) bind to an EXPR_CAST that carries
# the Arrow target and the TRY flag the evaluator parses with; strptime /
# try_strptime bind to their EXPR_STRING_FN_N opcode typed TIMESTAMP_US; and
# every shape this engine does not run is refused by name at bind time (a
# non-text operand, a non-constant format, an unserved directive, a list of
# formats, a wrong argument count), while a NULL format or NULL text is a
# NULL TIMESTAMP as in DuckDB.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.expr import (
    EXPR_CAST,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_STRING_FN_N,
    Expr,
    STRFNN_STRPTIME,
    STRFNN_TRY_STRPTIME,
)
from plan_expr.expr_walk import PlanColRefFields, walk_expr_field

from sql.sql_bind_expr import _bind_scalar
from sql.sql_bind_parquet import ParquetFacts
from sql.sql_bind_scope import CteScope, _build_bind_scope
from sql.sql_catalog import SqlCatalog
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


def _schema() raises -> Schema:
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, False))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    t.add_field(Field(String("f"), ArrowType.STRING, True))
    t.add_field(Field(String("d"), ArrowType.DATE32, True))
    t.add_field(Field.timestamp(String("ts"), ArrowType.TIMESTAMP_US, String(""), True))
    return t.build()


def _bound(sql: String) raises -> Expr:
    """Bind the first select item of `sql` (one SELECT over table t)."""
    var cat = SqlCatalog()
    cat.add_parquet(String("t"), String("t.parquet"), _schema())
    var st = parse_sql(tokenize(sql))
    var scope = _build_bind_scope(
        st.query.from_tables, st.query.joins, cat, CteScope(ParquetFacts())
    )
    var prebound = List[Expr]()
    return _bind_scalar(
        st.query.select_items[0].expr, scope.out_schema, scope, cat,
        CteScope(ParquetFacts()), prebound,
    )


def _err(sql: String) raises -> String:
    try:
        _ = _bound(sql)
    except e:
        return String(e)
    return "bound"


def _type_of(e: Expr) raises -> ArrowType:
    var missing = String("")
    return walk_expr_field[PlanColRefFields](e, _schema(), missing).arrow_type


def _assert_text_cast(sql: String, target: ArrowType, is_try: Bool) raises:
    var e = _bound(sql)
    assert_equal(Int(e.tag), Int(EXPR_CAST), sql)
    assert_true(e.cast_target_arrow() == target, sql)
    assert_equal(e.cast_is_try(), is_try, sql)
    assert_true(_type_of(e) == target, sql)


def test_cast_text_to_date_and_timestamp_binds_a_parsing_cast() raises:
    """CAST / `::` of a text column or literal to DATE, TIMESTAMP, DATETIME or
    TIMESTAMP_US binds to a strict cast to DATE32 / TIMESTAMP_US."""
    _assert_text_cast("SELECT CAST(s AS DATE) FROM t", ArrowType.DATE32, False)
    _assert_text_cast("SELECT s::DATE FROM t", ArrowType.DATE32, False)
    _assert_text_cast("SELECT CAST('2026-09-15' AS DATE) FROM t", ArrowType.DATE32, False)
    _assert_text_cast("SELECT CAST(s AS TIMESTAMP) FROM t", ArrowType.TIMESTAMP_US, False)
    _assert_text_cast("SELECT CAST(s AS DATETIME) FROM t", ArrowType.TIMESTAMP_US, False)
    _assert_text_cast("SELECT CAST(s AS timestamp_us) FROM t", ArrowType.TIMESTAMP_US, False)
    var e = _bound("SELECT CAST(s AS DATE) FROM t")
    assert_equal(Int(e.cast_child_ref().tag), Int(EXPR_COL_REF))


def test_try_cast_text_binds_a_null_on_failure_cast() raises:
    """TRY_CAST of text to DATE / TIMESTAMP binds to the same cast with the
    TRY flag set, on the physical type of the target, and is nullable."""
    _assert_text_cast("SELECT TRY_CAST(s AS DATE) FROM t", ArrowType.DATE32, True)
    _assert_text_cast("SELECT TRY_CAST(s AS TIMESTAMP) FROM t", ArrowType.TIMESTAMP_US, True)
    var d = _bound("SELECT TRY_CAST(s AS DATE) FROM t")
    assert_true(d.cast_target() == DType.int32)
    var t = _bound("SELECT TRY_CAST(s AS TIMESTAMP) FROM t")
    assert_true(t.cast_target() == DType.int64)
    var missing = String("")
    var schema = SchemaBuilder()
    schema.add_field(Field(String("s"), ArrowType.STRING, False))
    assert_true(walk_expr_field[PlanColRefFields](d, schema.build(), missing).nullable)


def test_cast_to_its_own_type_is_the_operand() raises:
    """A DATE cast to DATE, or a TIMESTAMP to TIMESTAMP, is the operand."""
    var d = _bound("SELECT CAST(d AS DATE) FROM t")
    assert_equal(Int(d.tag), Int(EXPR_COL_REF))
    var t = _bound("SELECT TRY_CAST(ts AS TIMESTAMP) FROM t")
    assert_equal(Int(t.tag), Int(EXPR_COL_REF))


def test_non_text_operands_are_refused_by_name() raises:
    """A number, a TIMESTAMP to DATE and a DATE to TIMESTAMP are other casts,
    refused naming the operand's type and the target."""
    assert_equal(
        _err("SELECT CAST(k AS DATE) FROM t"),
        "SQL not supported: CAST from int64 to DATE. DATE and TIMESTAMP are"
        " reached from TEXT here (DuckDB's text grammar,"
        " `YYYY-MM-DD[ HH:MM:SS[.ffffff]]`), and from a value already of that"
        " type; a cast from a number, or between DATE and TIMESTAMP, is not run"
        " by this engine.",
    )
    assert_true(
        _err("SELECT CAST(ts AS DATE) FROM t").startswith(
            "SQL not supported: CAST from timestamp[us] to DATE."
        )
    )
    assert_true(
        _err("SELECT TRY_CAST(d AS TIMESTAMP) FROM t").startswith(
            "SQL not supported: CAST from date32 to TIMESTAMP."
        )
    )


def test_other_temporal_targets_and_numeric_try_cast_keep_their_refusals() raises:
    """TIMESTAMP_NS / TIMESTAMPTZ / TIME from text are not served and keep
    the target table's refusal; TRY_CAST to a number is still refused."""
    for ty in [String("TIMESTAMP_NS"), String("TIMESTAMPTZ"), String("TIME")]:
        assert_true(
            _err("SELECT CAST(s AS " + ty + ") FROM t").startswith(
                "SQL not supported: CAST to " + ty + ". This engine converts to"
                " INTEGER / BIGINT / REAL / DOUBLE"
            ),
            ty,
        )
    assert_true(
        _err("SELECT TRY_CAST(s AS BIGINT) FROM t").startswith(
            "SQL not supported: TRY_CAST. Its contract"
        )
    )


def test_strptime_binds_its_opcode_typed_timestamp() raises:
    """`strptime` / `try_strptime` over text and a format literal bind to their
    EXPR_STRING_FN_N opcode, typed TIMESTAMP_US."""
    var e = _bound("SELECT strptime(s, '%m/%d/%Y') FROM t")
    assert_equal(Int(e.tag), Int(EXPR_STRING_FN_N))
    assert_equal(Int(e.string_fn_n_op()), Int(STRFNN_STRPTIME))
    assert_equal(e.string_fn_n_num_args(), 2)
    assert_equal(Int(e.string_fn_n_arg_ref(1).tag), Int(EXPR_LITERAL))
    assert_true(_type_of(e) == ArrowType.TIMESTAMP_US)
    var t = _bound("SELECT try_strptime('15 Sep 2026', '%d %b %Y') FROM t")
    assert_equal(Int(t.string_fn_n_op()), Int(STRFNN_TRY_STRPTIME))
    assert_true(_type_of(t) == ArrowType.TIMESTAMP_US)


def test_strptime_null_format_or_text_is_a_null_timestamp() raises:
    """DuckDB answers NULL for a NULL format and for NULL text."""
    for sql in [
        String("SELECT strptime(s, NULL) FROM t"),
        String("SELECT try_strptime(NULL, '%Y') FROM t"),
    ]:
        var e = _bound(sql)
        assert_equal(Int(e.tag), Int(EXPR_CAST), sql)
        assert_true(e.cast_target_arrow() == ArrowType.TIMESTAMP_US, sql)
        assert_equal(Int(e.cast_child_ref().tag), Int(EXPR_LITERAL), sql)
        assert_true(e.cast_child_ref().literal_value().is_null(), sql)


def test_strptime_refusals_name_what_is_not_served() raises:
    """A non-constant format (DuckDB's own words), an unserved directive, an
    unknown directive (DuckDB's own words), a non-text operand, a non-string
    format and a wrong argument count are refused at bind time."""
    assert_equal(
        _err("SELECT strptime(s, f) FROM t"),
        "Invalid Input Error: strptime format must be a constant",
    )
    assert_equal(
        _err("SELECT strptime(s, '%Y-%m-%d %z') FROM t"),
        "SQL not supported: the strptime directive %z. DuckDB's strptime returns"
        " TIMESTAMP WITH TIME ZONE when the format holds %z or %Z, and the"
        " instant that names depends on a session time zone this engine does"
        " not have. Parse the text without its zone.",
    )
    assert_equal(
        _err("SELECT try_strptime(s, '%q') FROM t"),
        "Invalid Input Error: Failed to parse format specifier %q: Unrecognized"
        " format for strftime/strptime: %q",
    )
    assert_equal(
        _err("SELECT strptime(k, '%Y') FROM t"),
        "SQL not supported: `strptime` parses TEXT, but this argument is of type int64.",
    )
    assert_equal(
        _err("SELECT strptime(s, 5) FROM t"),
        "SQL bind error: the format of `strptime` must be a string, like '%Y-%m-%d'.",
    )
    assert_equal(
        _err("SELECT strptime(s) FROM t"),
        "SQL bind error: `strptime` takes two arguments, the text and a format"
        " string, but got 1.",
    )
    assert_true(_err("SELECT strftime(d, '%Y') FROM t").startswith("SQL not supported: `strftime` RENDERS"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
