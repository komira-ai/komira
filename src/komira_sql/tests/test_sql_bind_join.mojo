# =============================================================================
# Direct tests of join binding: outer, keyed (NATURAL / USING), semi and
# anti joins (sql_bind_join, sql_binder)
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch:
#   1. LEFT / RIGHT / FULL bind a real outer join whose ON is split into
#      equi-keys (either written order) and a residual carried on the node
#      (LEFT only); a pure non-equi ON, a RIGHT / FULL residual and an
#      unknown or ambiguous ON column are refused by name.
#      (mutant: `_classify_side` swaps the sides of `mm.k = kk.k`)
#   2. NATURAL / USING bind INNER / LEFT joins on the shared or listed keys
#      and coalesce them onto the left column (case-insensitive key match,
#      each side's own spelling); a NATURAL join with no shared name, a USING
#      name missing from a side, and NATURAL / USING at RIGHT / FULL are
#      refused.
#      (mutant: the keyed projection keeps the right key column)
#   3. SEMI / ANTI bind the left columns only: ON equi-keys, USING / NATURAL
#      keys, a right-only conjunct as a filter on the right input, a
#      left-only conjunct as a filter on the left input for SEMI (refused for
#      ANTI); cross-side non-equi conjuncts, ORs and an unqualified column
#      both sides have are refused; the right relation's names are not
#      visible afterwards.
#      (mutant: the ANTI left-only refusal removed, so it filters the left)

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

def test_outer_joins() raises:
    _check(
        "SELECT * FROM t LEFT JOIN u ON t.k = u.k",
        "Project(exprs=[ColRef(k), ColRef(v), ColRef(s), ColRef(g), ColRef(d), ColRef(ts), ColRef(i32), ColRef(dc), ColRef(b), ColRef(f32), ColRef(u64), ColRef(j), Alias(ColRef(k_right), \"k\"), ColRef(w), Alias(ColRef(s_right), \"s\")])\n"
        "  Join(type=LEFT, on=[k=k])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk RIGHT JOIN mm ON kk.k = mm.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=RIGHT, on=[k=k])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk FULL JOIN mm ON kk.k = mm.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=FULL, on=[k=k])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON mm.k = kk.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=LEFT, on=[k=k])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON (kk.k = mm.k)",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=LEFT, on=[k=k])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON kk.k = mm.k AND kk.a = mm.b",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=LEFT, on=[k=k, a=b])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON kk.k = mm.k AND mm.b > 3",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=LEFT, on=[k=k], residual=BinaryOp(GT, ColRef(b), Literal(ScalarValue(int64, 3))))\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON kk.k = mm.k AND (kk.a = 1 OR mm.b = 2)",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=LEFT, on=[k=k], residual=BinaryOp(OR, BinaryOp(EQ, ColRef(a), Literal(ScalarValue(int64, 1))), BinaryOp(EQ, ColRef(b), Literal(ScalarValue(int64, 2)))))\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON kk.k = mm.k AND mm.b IN (1, 2)",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=LEFT, on=[k=k], residual=BinaryOp(OR, BinaryOp(EQ, ColRef(b), Literal(ScalarValue(int64, 1))), BinaryOp(EQ, ColRef(b), Literal(ScalarValue(int64, 2)))))\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON kk.k = mm.k AND kk.a > (SELECT max(w) FROM u)",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=LEFT, on=[k=k], residual=BinaryOp(GT, ColRef(a), CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2)))\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON kk.k = mm.k + 1",
        "ERR: SQL not supported: a LEFT JOIN ON needs at least one `left = right` equi-key (a pure non-equi outer join is not served by this path)"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON kk.k = mm.k WHERE mm.b > 1",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(b), Literal(ScalarValue(int64, 1))))\n"
        "    Join(type=LEFT, on=[k=k])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk JOIN mm ON kk.k = mm.k LEFT JOIN u ON u.k = mm.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b), Alias(ColRef(k_right_2), \"k\"), ColRef(w), ColRef(s)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(k), ColRef(k_right)))\n"
        "    Join(type=LEFT, on=[k_right=k])\n"
        "      Join(type=CROSS, on=[])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Project(exprs=[Alias(ColRef(k), \"k_right_2\"), ColRef(w), ColRef(s)])\n"
        "        Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON kk.k = mm.k LEFT JOIN u ON u.w = kk.a AND u.k = mm.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b), Alias(ColRef(k_right_2), \"k\"), ColRef(w), ColRef(s)])\n"
        "  Join(type=LEFT, on=[a=w, k_right=k])\n"
        "    Join(type=LEFT, on=[k=k])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Project(exprs=[Alias(ColRef(k), \"k_right_2\"), ColRef(w), ColRef(s)])\n"
        "      Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_outer_join_refusals() raises:
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON kk.a > mm.b",
        "ERR: SQL not supported: a LEFT JOIN ON needs at least one `left = right` equi-key (a pure non-equi outer join is not served by this path)"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON k = b",
        "ERR: SQL not supported: a LEFT JOIN ON needs at least one `left = right` equi-key (a pure non-equi outer join is not served by this path)"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON kk.k = 1",
        "ERR: SQL not supported: a LEFT JOIN ON needs at least one `left = right` equi-key (a pure non-equi outer join is not served by this path)"
    )
    _check(
        "SELECT * FROM kk RIGHT JOIN mm ON kk.k = mm.k AND mm.b > 3",
        "ERR: SQL not supported: a RIGHT OUTER JOIN whose ON carries a non-equi residual — the equi-keys are served but the residual is not (this binder carries a non-equi ON residual on a LEFT join only). The equi-only form of this join (`ON <equi conjuncts>` with the residual moved to a WHERE) is served, but note that a WHERE does NOT preserve the outer rows a residual ON would."
    )
    _check(
        "SELECT * FROM kk FULL JOIN mm ON kk.k = mm.k AND kk.a > 1",
        "ERR: SQL not supported: a FULL OUTER JOIN whose ON carries a non-equi residual — the equi-keys are served but the residual is not (this binder carries a non-equi ON residual on a LEFT join only). The equi-only form of this join (`ON <equi conjuncts>` with the residual moved to a WHERE) is served, but note that a WHERE does NOT preserve the outer rows a residual ON would."
    )
    _check(
        "SELECT * FROM kk RIGHT JOIN mm ON kk.a > mm.b",
        "ERR: SQL not supported: a RIGHT JOIN ON needs at least one `left = right` equi-key (a pure non-equi outer join is not served by this path)"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON kk.k = zz.k",
        "ERR: SQL bind error: unknown column 'zz.k'"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON kk.k = mm.zz",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=LEFT, on=[k=zz])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON a = b",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=LEFT, on=[a=b])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON k = mm.k",
        "ERR: SQL not supported: a LEFT JOIN ON needs at least one `left = right` equi-key (a pure non-equi outer join is not served by this path)"
    )


def test_keyed_joins() raises:
    _check(
        "SELECT * FROM kk NATURAL JOIN mm",
        "Project(exprs=[ColRef(k), ColRef(a), ColRef(b)])\n"
        "  Join(type=INNER, on=[k=k])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk JOIN mm USING (k)",
        "Project(exprs=[ColRef(k), ColRef(a), ColRef(b)])\n"
        "  Join(type=INNER, on=[k=k])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk LEFT JOIN mm USING (k)",
        "Project(exprs=[ColRef(k), ColRef(a), ColRef(b)])\n"
        "  Join(type=LEFT, on=[k=k])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk NATURAL LEFT JOIN mm",
        "Project(exprs=[ColRef(k), ColRef(a), ColRef(b)])\n"
        "  Join(type=LEFT, on=[k=k])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk NATURAL JOIN u",
        "Project(exprs=[ColRef(k), ColRef(a), ColRef(w), ColRef(s)])\n"
        "  Join(type=INNER, on=[k=k])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk NATURAL JOIN up",
        "Project(exprs=[ColRef(k), ColRef(a), ColRef(B)])\n"
        "  Join(type=INNER, on=[k=K])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"up.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk JOIN up USING (k)",
        "Project(exprs=[ColRef(k), ColRef(a), ColRef(B)])\n"
        "  Join(type=INNER, on=[k=K])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"up.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM up JOIN kk USING (k)",
        "Project(exprs=[ColRef(K), ColRef(B), ColRef(a)])\n"
        "  Join(type=INNER, on=[K=k])\n"
        "    Scan(path=\"up.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT up.K, kk.k FROM kk JOIN up USING (k)",
        "Project(exprs=[Alias(ColRef(k), \"K\"), ColRef(k)])\n"
        "  Project(exprs=[ColRef(k), ColRef(k)])\n"
        "    Project(exprs=[ColRef(k), ColRef(a), ColRef(B)])\n"
        "      Join(type=INNER, on=[k=K])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"up.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk JOIN kk AS k2 USING (k)",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(a_right), \"a\")])\n"
        "  Project(exprs=[ColRef(k), ColRef(a), ColRef(a_right)])\n"
        "    Join(type=INNER, on=[k=k])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT mm.k, k FROM kk JOIN mm USING (k)",
        "Project(exprs=[ColRef(k), ColRef(k)])\n"
        "  Project(exprs=[ColRef(k), ColRef(a), ColRef(b)])\n"
        "    Join(type=INNER, on=[k=k])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_keyed_join_refusals() raises:
    _check(
        "SELECT * FROM kk JOIN mm USING (zz)",
        "ERR: SQL bind error: USING column 'zz' is not a column of the left side of the join"
    )
    _check(
        "SELECT * FROM kk NATURAL RIGHT JOIN mm",
        "ERR: SQL not supported: NATURAL / USING at a RIGHT OUTER JOIN — the shared key must be emitted as COALESCE(left.k, right.k) and this binder projects the left key column verbatim, which is NULL on every row only the right side contributed. Spell the same join as `RIGHT JOIN ... ON l.k = r.k`, which is served and emits both key columns."
    )
    _check(
        "SELECT * FROM kk RIGHT JOIN mm USING (k)",
        "ERR: SQL not supported: NATURAL / USING at a RIGHT OUTER JOIN — the shared key must be emitted as COALESCE(left.k, right.k) and this binder projects the left key column verbatim, which is NULL on every row only the right side contributed. Spell the same join as `RIGHT JOIN ... ON l.k = r.k`, which is served and emits both key columns."
    )
    _check(
        "SELECT * FROM kk FULL JOIN mm USING (k)",
        "ERR: SQL not supported: NATURAL / USING at a FULL OUTER JOIN — the shared key must be emitted as COALESCE(left.k, right.k) and this binder projects the left key column verbatim, which is NULL on every row only the right side contributed. Spell the same join as `FULL JOIN ... ON l.k = r.k`, which is served and emits both key columns."
    )


def test_semi_and_anti_joins() raises:
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = mm.k",
        "Join(type=SEMI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk ANTI JOIN mm ON kk.k = mm.k",
        "Join(type=ANTI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON mm.k = kk.k",
        "Join(type=SEMI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm USING (k)",
        "Join(type=SEMI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk ANTI JOIN mm USING (k)",
        "Join(type=ANTI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk NATURAL SEMI JOIN mm",
        "Join(type=SEMI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk NATURAL ANTI JOIN u",
        "Join(type=ANTI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = mm.k AND mm.b > 250",
        "Join(type=SEMI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(b), Literal(ScalarValue(int64, 250))))\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk ANTI JOIN mm ON kk.k = mm.k AND mm.b > 250",
        "Join(type=ANTI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(b), Literal(ScalarValue(int64, 250))))\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = mm.k AND kk.a > 1",
        "Join(type=SEMI, on=[k=k])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 1))))\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = mm.k AND 1 = 1",
        "Join(type=SEMI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Filter(predicate=BinaryOp(EQ, Literal(ScalarValue(int64, 1)), Literal(ScalarValue(int64, 1))))\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = mm.k AND mm.b > (SELECT max(w) FROM u)",
        "Join(type=SEMI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(b), CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2)))\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN kk y ON kk.k = y.k",
        "Join(type=SEMI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk AS x SEMI JOIN mm AS y ON x.k = y.k",
        "Join(type=SEMI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = mm.k JOIN u ON u.k = kk.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(w), ColRef(s)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(k_right), ColRef(k)))\n"
        "    Join(type=CROSS, on=[])\n"
        "      Join(type=SEMI, on=[k=k])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = mm.k LEFT JOIN u ON u.k = kk.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(w), ColRef(s)])\n"
        "  Join(type=LEFT, on=[k=k])\n"
        "    Join(type=SEMI, on=[k=k])\n"
        "      Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "      Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT kk.a FROM kk SEMI JOIN mm ON kk.k = mm.k",
        "Project(exprs=[ColRef(a)])\n"
        "  Join(type=SEMI, on=[k=k])\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_semi_and_anti_join_refusals() raises:
    _check(
        "SELECT * FROM kk ANTI JOIN mm ON kk.k = mm.k AND kk.a > 1",
        "ERR: SQL not supported: an ANTI JOIN whose ON condition carries a conjunct on the LEFT side only. An ANTI join KEEPS the left rows that conjunct rejects (they match nothing), so it cannot be applied as a filter, and this door has no ANTI-join residual. The equivalent spelling is `WHERE NOT EXISTS (SELECT 1 FROM <right> WHERE <the whole ON condition>)`."
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.a > mm.b",
        "ERR: SQL not supported: a SEMI JOIN whose ON condition carries a conjunct that reads BOTH sides and is not a `left_column = right_column` equi-key (a non-equality across the sides, an OR, or an expression). Equi-keys, and conjuncts that read one side only, are served on this join; a cross-side condition the join node did not apply would silently answer the equi-only join. The equivalent spelling is `WHERE EXISTS (SELECT 1 FROM <right> WHERE <the whole ON condition>)`."
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = mm.k OR kk.a = mm.b",
        "ERR: SQL not supported: a SEMI JOIN whose ON condition carries a conjunct that reads BOTH sides and is not a `left_column = right_column` equi-key (a non-equality across the sides, an OR, or an expression). Equi-keys, and conjuncts that read one side only, are served on this join; a cross-side condition the join node did not apply would silently answer the equi-only join. The equivalent spelling is `WHERE EXISTS (SELECT 1 FROM <right> WHERE <the whole ON condition>)`."
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON k = k",
        "ERR: SQL bind error: column 'k' in the SEMI JOIN's ON condition is ambiguous or names neither side of the join — qualify it with the table name or alias of the side it belongs to"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = mm.k AND k > 1",
        "ERR: SQL not supported: a SEMI JOIN ON conjunct is ambiguous — an unqualified column it reads exists on BOTH sides. Qualify it with the table name or alias of the side it belongs to."
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON a = b",
        "Join(type=SEMI, on=[a=b])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.a > 1",
        "ERR: SQL not supported: a SEMI JOIN whose ON condition has no `left_column = right_column` equi-key. The equivalent spelling is `WHERE EXISTS (SELECT 1 FROM <right> WHERE <the ON condition>)`."
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = mm.k AND mm.zz > 1",
        "ERR: SQL not supported: a SEMI JOIN whose ON condition carries a conjunct that reads BOTH sides and is not a `left_column = right_column` equi-key (a non-equality across the sides, an OR, or an expression). Equi-keys, and conjuncts that read one side only, are served on this join; a cross-side condition the join node did not apply would silently answer the equi-only join. The equivalent spelling is `WHERE EXISTS (SELECT 1 FROM <right> WHERE <the whole ON condition>)`."
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = mm.k AND zz.b > 1",
        "ERR: SQL not supported: a SEMI JOIN whose ON condition carries a conjunct that reads BOTH sides and is not a `left_column = right_column` equi-key (a non-equality across the sides, an OR, or an expression). Equi-keys, and conjuncts that read one side only, are served on this join; a cross-side condition the join node did not apply would silently answer the equi-only join. The equivalent spelling is `WHERE EXISTS (SELECT 1 FROM <right> WHERE <the whole ON condition>)`."
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm USING (zz)",
        "ERR: SQL bind error: USING column 'zz' is not a column of the left side of the join"
    )
    _check(
        "SELECT mm.b FROM kk SEMI JOIN mm ON kk.k = mm.k",
        "ERR: SQL bind error: unknown column 'mm.b'"
    )


def test_more_join_shapes() raises:
    _check(
        "SELECT * FROM kk LEFT JOIN mm ON kk.k = mm.k AND mm.b > 3 AND kk.a < 2",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Join(type=LEFT, on=[k=k], residual=BinaryOp(AND, BinaryOp(GT, ColRef(b), Literal(ScalarValue(int64, 3))), BinaryOp(LT, ColRef(a), Literal(ScalarValue(int64, 2)))))\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk NATURAL JOIN (SELECT w FROM u) d",
        "ERR: SQL bind error: NATURAL JOIN has no column name in common between the two relations — there is nothing to join on. Use CROSS JOIN if a cross-product is what was intended."
    )
    _check(
        "SELECT * FROM kk JOIN u USING (a)",
        "ERR: SQL bind error: USING column 'a' is not a column of the right side of the join"
    )
    _check(
        "SELECT * FROM kk JOIN mm USING (k, k)",
        "ERR: SQL bind error: USING column 'k' is named twice"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = zz.b",
        "ERR: SQL bind error: column 'zz.b' in the SEMI JOIN's ON condition is ambiguous or names neither side of the join — qualify it with the table name or alias of the side it belongs to"
    )
    _check(
        "SELECT * FROM kk ANTI JOIN mm ON kk.a > mm.b",
        "ERR: SQL not supported: an ANTI JOIN whose ON condition carries a conjunct that reads BOTH sides and is not a `left_column = right_column` equi-key (a non-equality across the sides, an OR, or an expression). Equi-keys, and conjuncts that read one side only, are served on this join; a cross-side condition the join node did not apply would silently answer the equi-only join. The equivalent spelling is `WHERE NOT EXISTS (SELECT 1 FROM <right> WHERE <the whole ON condition>)`."
    )
    _check(
        "SELECT * FROM kk ANTI JOIN mm ON a = b",
        "Join(type=ANTI, on=[a=b])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN u ON kk.k = u.k AND s = 'x'",
        "Join(type=SEMI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(s), Literal(ScalarValue(utf8, \"x\"))))\n"
        "    Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = mm.k AND mm.b > 1 AND mm.b < 9",
        "Join(type=SEMI, on=[k=k])\n"
        "  Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(GT, ColRef(b), Literal(ScalarValue(int64, 1))), BinaryOp(LT, ColRef(b), Literal(ScalarValue(int64, 9)))))\n"
        "    Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = mm.k AND kk.a > 1 AND kk.a < 9",
        "Join(type=SEMI, on=[k=k])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 1))), BinaryOp(LT, ColRef(a), Literal(ScalarValue(int64, 9)))))\n"
        "    Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "  Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT * FROM kk SEMI JOIN mm ON kk.k = mm.k AND b2 > 1",
        "ERR: SQL not supported: a SEMI JOIN whose ON condition carries a conjunct that reads BOTH sides and is not a `left_column = right_column` equi-key (a non-equality across the sides, an OR, or an expression). Equi-keys, and conjuncts that read one side only, are served on this join; a cross-side condition the join node did not apply would silently answer the equi-only join. The equivalent spelling is `WHERE EXISTS (SELECT 1 FROM <right> WHERE <the whole ON condition>)`."
    )
    _check(
        "SELECT * FROM kk JOIN mm ON kk.k = mm.k ORDER BY kk.k",
        "Project(exprs=[ColRef(k), ColRef(a), Alias(ColRef(k_right), \"k\"), ColRef(b)])\n"
        "  Sort(keys=[k ASC])\n"
        "    Filter(predicate=BinaryOp(EQ, ColRef(k), ColRef(k_right)))\n"
        "      Join(type=CROSS, on=[])\n"
        "        Scan(path=\"kk.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "        Scan(path=\"mm.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
