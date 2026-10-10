# =============================================================================
# Direct tests of the binder's parquet facts (sql_bind_parquet) and the two
# binder sites that read them (`read_parquet` relations and the NOT IN
# null-freedom check)
# =============================================================================
#
# The binder opens no parquet file: `bind_statement` asks the
# `SqlParquetFooters` its caller passes (a `read_csv`, `read_json` or
# `read_avro` relation still reads its file through `sql_tvf_bind`). These tests pass `_Footers`, a reader with fixed
# answers, or `NoParquetFooters`. What each test proves, and the defect
# (mutant) it would catch:
#   1. `ParquetFacts` records a schema and a null count once per key, answers
#      `schema_of` / `null_count` for what it holds, raises for an unread
#      schema and answers None for an unread count.
#      (mutants: `add_schema` without its has-check keeps the second schema;
#      `null_count` matching on the path alone)
#   2. `path_has_glob` is true for each of `*`, `?`, `[`; `is_parquet_tvf_kind`
#      is false for CSV / JSON / Avro only.
#      (mutant: one of the three glob characters dropped)
#   3. `collect_parquet_facts` reads the footer schema of every `read_parquet`
#      relation (FROM, CTE body, subquery body), none for a CSV relation, and
#      no null count when the statement holds no NOT IN.
#      (mutant: `_stmt_has_not_in` always True)
#   4. With a NOT IN it reads the null count of every column of every
#      non-glob parquet relation, catalog parquet tables included; a reader
#      that raises leaves the count unknown; an in-memory table has none.
#   5. `NoParquetFooters` refuses a `read_parquet` relation by name; a
#      `read_parquet` relation binds to a parquet scan over the reader's
#      schema, and a reader error propagates.
#   6. NOT IN keeps only the run-time NULL checks the recorded counts do not
#      rule out (the bare anti join when both columns are NULL-free).
#      (mutant: `_rel_col_null_free` ignores the count's value)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder

from komira_sql.sql_token import tokenize
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_bind_parquet import NoParquetFooters, SqlParquetFooters
from komira_sql.sql_binder import bind_statement


def _two(
    mut cat: SqlCatalog,
    name: String,
    c0: String,
    t0: ArrowType,
    c1: String,
    t1: ArrowType,
):
    """Register parquet table `name`(c0 NOT NULL, c1 NULL)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, t0, False))
    sb.add_field(Field(c1, t1, True))
    cat.add_parquet(name, name + ".parquet", sb.build())


def _catalog() raises -> SqlCatalog:
    """t(k, v, s, g, d, ts, i32, dc, b, f32, u64, j), u(k, w, s), kk(k, a),
    mm(k, b), up(K, B), kk2(k, k_right): parquet tables with given schemas
    (no file is opened); mem(k, v): an empty in-memory table."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, False))
    t.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    t.add_field(Field(String("g"), ArrowType.INT64, True))
    t.add_field(Field(String("d"), ArrowType.DATE32, True))
    t.add_field(Field.timestamp(String("ts"), ArrowType.TIMESTAMP_US, String(""), True))
    t.add_field(Field(String("i32"), ArrowType.INT32, True))
    t.add_field(Field.decimal128(String("dc"), 12, 2, True))
    t.add_field(Field(String("b"), ArrowType.BOOL, True))
    t.add_field(Field(String("f32"), ArrowType.FLOAT32, True))
    t.add_field(Field(String("u64"), ArrowType.UINT64, True))
    t.add_field(Field(String("j"), ArrowType.STRING, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    var u = SchemaBuilder()
    u.add_field(Field(String("k"), ArrowType.INT64, False))
    u.add_field(Field(String("w"), ArrowType.INT64, True))
    u.add_field(Field(String("s"), ArrowType.STRING, True))
    cat.add_parquet(String("u"), String("u.parquet"), u.build())
    _two(cat, "kk", "k", ArrowType.INT64, "a", ArrowType.INT64)
    _two(cat, "mm", "k", ArrowType.INT64, "b", ArrowType.INT64)
    _two(cat, "up", "K", ArrowType.INT64, "B", ArrowType.INT64)
    _two(cat, "kk2", "k", ArrowType.INT64, "k_right", ArrowType.INT64)
    cat.add_in_memory(String("mem"), RecordBatch.empty_from_schema(_kv()))
    return cat^


def _kv() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    return sb.build()


@fieldwise_init
struct _Footers(SqlParquetFooters):
    """A footer reader with fixed answers: every path but `missing.parquet`
    has schema (k INT64, v FLOAT64); `k` holds no NULL and `v` holds 3; a
    path named `bad.parquet` raises for null counts."""

    def footer_schema(self, path: String) raises -> Schema:
        if path == "missing.parquet":
            raise Error("no such file: " + path)
        return _kv()

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        if path == "bad.parquet":
            raise Error("unreadable statistics")
        if column == "k":
            return 0
        if column == "v":
            return 3
        return None


def _got(sql: String) raises -> String:
    """The bound plan's text, or `ERR: ` and the binder's message."""
    var cat = _catalog()
    try:
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _gotp(sql: String) raises -> String:
    """`_got` with the `_Footers` reader."""
    var cat = _catalog()
    try:
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, _Footers())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _check(sql: String, want: String) raises:
    assert_equal(_got(sql), want, sql)


def _checkp(sql: String, want: String) raises:
    assert_equal(_gotp(sql), want, sql)
from komira_arrow.record_batch import RecordBatch
from komira_sql.sql_ast import TVF_AVRO, TVF_CSV, TVF_JSON, TVF_NONE, TVF_PARQUET
from komira_sql.sql_bind_parquet import (
    ParquetFacts,
    collect_parquet_facts,
    is_parquet_tvf_kind,
    path_has_glob,
)


def _facts(sql: String) raises -> ParquetFacts:
    var cat = _catalog()
    cat.add_in_memory(String("mem"), RecordBatch.empty_from_schema(_kv()))
    return collect_parquet_facts(parse_sql(tokenize(sql)), cat, _Footers())


def test_parquet_facts_record_once_and_answer() raises:
    var f = ParquetFacts()
    assert_false(f.has_schema("a.parquet"))
    f.add_schema("a.parquet", _kv())
    var sb = SchemaBuilder()
    sb.add_field(Field(String("x"), ArrowType.INT32, True))
    f.add_schema("a.parquet", sb.build())
    assert_true(f.has_schema("a.parquet"))
    var s = f.schema_of("a.parquet")
    assert_equal(s.num_columns(), 2)
    assert_equal(s.field_name(0), "k")
    try:
        _ = f.schema_of("b.parquet")
        raise Error("expected a refusal")
    except e:
        assert_equal(
            String(e), "SQL bind error: no parquet footer was read for 'b.parquet'"
        )
    f.add_null_count("a.parquet", "k", Optional[Int](0))
    f.add_null_count("a.parquet", "k", Optional[Int](9))
    f.add_null_count("a.parquet", "v", Optional[Int](4))
    f.add_null_count("b.parquet", "k", None)
    assert_true(f.has_null_count("a.parquet", "k"))
    assert_false(f.has_null_count("a.parquet", "w"))
    assert_false(f.has_null_count("c.parquet", "k"))
    assert_equal(f.null_count("a.parquet", "k").value(), 0)
    assert_equal(f.null_count("a.parquet", "v").value(), 4)
    assert_false(Bool(f.null_count("b.parquet", "k")))
    assert_false(Bool(f.null_count("b.parquet", "v")))


def test_glob_and_tvf_kind_predicates() raises:
    assert_true(path_has_glob("data/*.parquet"))
    assert_true(path_has_glob("data/f?.parquet"))
    assert_true(path_has_glob("data/f[0-9].parquet"))
    # A glob character at the first byte (find returns 0) is a glob too.
    assert_true(path_has_glob("*.parquet"))
    assert_true(path_has_glob("?.parquet"))
    assert_true(path_has_glob("[ab].parquet"))
    assert_false(path_has_glob("data/f.parquet"))
    assert_false(is_parquet_tvf_kind(TVF_CSV))
    assert_false(is_parquet_tvf_kind(TVF_JSON))
    assert_false(is_parquet_tvf_kind(TVF_AVRO))
    assert_true(is_parquet_tvf_kind(TVF_PARQUET))
    assert_true(is_parquet_tvf_kind(TVF_NONE))


def test_collect_reads_schemas_everywhere_and_no_counts_without_not_in() raises:
    var f = _facts(
        "WITH c AS (SELECT k FROM read_parquet('c.parquet'))"
        " SELECT k FROM read_parquet('a.parquet')"
        " WHERE k > (SELECT max(k) FROM read_parquet('b.parquet'))"
        " AND k IN (SELECT k FROM c)"
    )
    assert_true(f.has_schema("a.parquet"))
    assert_true(f.has_schema("b.parquet"))
    assert_true(f.has_schema("c.parquet"))
    assert_false(f.has_null_count("a.parquet", "k"))
    assert_false(f.has_null_count("t.parquet", "k"))
    # A CSV relation is not a parquet one: no footer is read for it.
    var g = _facts("SELECT * FROM read_csv('x.csv')")
    assert_false(g.has_schema("x.csv"))


def test_collect_reads_counts_when_a_not_in_is_present() raises:
    var f = _facts(
        "SELECT k FROM read_parquet('a.parquet')"
        " WHERE k NOT IN (SELECT k FROM t) AND k IN (SELECT k FROM mem)"
        " AND k IN (SELECT k FROM read_parquet('g*.parquet'))"
        " AND k IN (SELECT k FROM read_parquet('bad.parquet'))"
    )
    assert_equal(f.null_count("a.parquet", "k").value(), 0)
    assert_equal(f.null_count("a.parquet", "v").value(), 3)
    # The catalog's parquet table: every column of its schema, by its file.
    assert_equal(f.null_count("t.parquet", "k").value(), 0)
    assert_equal(f.null_count("t.parquet", "v").value(), 3)
    assert_true(f.has_null_count("t.parquet", "s"))
    assert_false(Bool(f.null_count("t.parquet", "s")))
    # A glob path records its schema but no count.
    assert_true(f.has_schema("g*.parquet"))
    assert_false(f.has_null_count("g*.parquet", "k"))
    # A reader that raises leaves the count recorded as unknown.
    assert_true(f.has_null_count("bad.parquet", "k"))
    assert_false(Bool(f.null_count("bad.parquet", "k")))
    # An in-memory catalog table has no file.
    assert_false(f.has_null_count("mem", "k"))
    # A NOT IN inside a CTE body or a nested subquery counts too.
    var c = _facts(
        "WITH c AS (SELECT k FROM t WHERE k NOT IN (SELECT k FROM u))"
        " SELECT k FROM c"
    )
    assert_true(c.has_null_count("u.parquet", "w"))
    var n = _facts(
        "SELECT k FROM t WHERE k IN (SELECT k FROM u WHERE k NOT IN"
        " (SELECT k FROM kk))"
    )
    assert_true(n.has_null_count("kk.parquet", "a"))


def test_read_parquet_relations_use_the_reader_schema() raises:
    _check(
        "SELECT * FROM read_parquet('x.parquet')",
        "ERR: SQL bind error: read_parquet('x.parquet') needs a parquet footer reader, and this binding was given none"
    )
    _checkp(
        "SELECT * FROM read_parquet('p.parquet')",
        "Scan(path=\"p.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _checkp(
        "SELECT k FROM read_parquet('missing.parquet')",
        "ERR: no such file: missing.parquet"
    )


def test_not_in_uses_recorded_null_counts() raises:
    # `k` holds no NULL in either file: the bare anti join (kind=1) alone.
    _checkp(
        "SELECT k FROM read_parquet('p.parquet') WHERE k NOT IN (SELECT k FROM read_parquet('q.parquet'))",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"p.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    # The subquery's `v` may hold NULLs: the "no NULL y" check (kind=2 scalar).
    _checkp(
        "SELECT k FROM read_parquet('p.parquet') WHERE k NOT IN (SELECT v FROM read_parquet('q.parquet'))",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0)))))\n"
        "    Scan(path=\"p.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    # The outer `v` may hold NULLs: the "x IS NOT NULL or S is empty" check.
    _checkp(
        "SELECT v FROM read_parquet('p.parquet') WHERE v NOT IN (SELECT k FROM read_parquet('q.parquet'))",
        "Project(exprs=[ColRef(v)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(v)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
        "    Scan(path=\"p.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    # A reader that raises leaves the count unknown, a glob path records no
    # count, and a CTE is not a file: each keeps the run-time checks. The
    # catalog tables t and u have recorded counts for `k` (0): the bare anti join.
    _checkp(
        "SELECT k FROM read_parquet('p.parquet') WHERE k NOT IN (SELECT k FROM read_parquet('bad.parquet'))",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0)))))\n"
        "    Scan(path=\"p.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _checkp(
        "SELECT k FROM read_parquet('p*.parquet') WHERE k NOT IN (SELECT k FROM read_parquet('q.parquet'))",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0))))))\n"
        "    Scan(path=\"p*.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _checkp(
        "SELECT k FROM t WHERE k NOT IN (SELECT k FROM u)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _checkp(
        "SELECT k FROM t WHERE k NOT IN (SELECT k FROM read_parquet('q.parquet') WHERE read_parquet.k > 1)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _checkp(
        "WITH c AS (SELECT k FROM read_parquet('c.parquet')) SELECT k FROM c WHERE k NOT IN (SELECT k FROM c)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0)))))))\n"
        "    Project(exprs=[ColRef(k)])\n"
        "      Scan(path=\"c.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
