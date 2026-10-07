# =============================================================================
# The statement structs of komira_sql.sql_ast
# =============================================================================
#
#   1. TvfOptions defaults (not all-VARCHAR, a header line, `,`), and
#      FromRelation's two constructors: a catalog name carries no TVF path and
#      TVF_NONE; tvf_of carries its path, kind and options.
#      (mutant caught: tvf_of dropping the options it was given)
#   2. SelectStmt's defaults: everything empty, LIMIT and OFFSET absent
#      (not 0), no UNION ALL branch (-1).
#      (mutant caught: OFFSET defaulting to Some(0))
#   3. SelectItem, OrderKey (NULLS placement absent by default, kept when
#      given), CteDef and both SubqueryDef constructors keep what they get.
#   4. JoinClause: the ON form is neither NATURAL nor USING; is_keyed() is
#      True for NATURAL and for a non-empty USING list, False otherwise.
#      (mutant caught: is_keyed() reading only one of the two)
#   5. SqlStatement defaults to a parquet, snappy write with no path, no
#      target and no replace, and keeps every field it is given.
#      (mutant caught: a default codec or format changed)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.write_target import WFMT_CSV, WFMT_PARQUET, WCOMP_SNAPPY, WCOMP_ZSTD
from komira_sql.sql_ast import (
    CteDef,
    FromRelation,
    JoinClause,
    OrderKey,
    SelectItem,
    SelectStmt,
    SqlExpr,
    SqlStatement,
    SubqueryDef,
    TvfOptions,
    FROM_LESS_RELATION,
    TVF_NONE,
    TVF_CSV,
    JK_CROSS,
    JK_LEFT,
    JK_SEMI,
    SUBQ_IN,
    SUBQ_DERIVED,
    STMT_QUERY,
    STMT_COPY,
    STMT_CREATE_TABLE_AS,
    SX_COLUMN,
    SX_STAR,
)


def test_tvf_options_and_from_relations() raises:
    var o = TvfOptions()
    assert_false(o.all_varchar)
    assert_true(o.has_header)
    assert_equal(Int(o.delimiter), ord(","))

    var t = FromRelation.named("lineitem", "l")
    assert_equal(t.name, "lineitem")
    assert_equal(t.rel_alias, "l")
    assert_false(Bool(t.tvf_path))
    assert_equal(Int(t.tvf_kind), Int(TVF_NONE))
    var t0 = FromRelation.named("orders")
    assert_equal(t0.rel_alias, "")

    var opts = TvfOptions()
    opts.all_varchar = True
    opts.has_header = False
    opts.delimiter = UInt8(ord("|"))
    var f = FromRelation.tvf_of("data.csv", TVF_CSV, opts^, "d")
    assert_equal(f.name, "")
    assert_equal(f.tvf_path.value(), "data.csv")
    assert_equal(Int(f.tvf_kind), Int(TVF_CSV))
    assert_equal(f.rel_alias, "d")
    assert_true(f.tvf_opts.all_varchar)
    assert_false(f.tvf_opts.has_header)
    assert_equal(Int(f.tvf_opts.delimiter), ord("|"))
    var f0 = FromRelation.tvf_of("x.csv", TVF_CSV, TvfOptions())
    assert_equal(f0.rel_alias, "")
    # The from-less relation's name holds a space, which no identifier can.
    assert_true(" " in FROM_LESS_RELATION)


def test_select_stmt_defaults() raises:
    var s = SelectStmt()
    assert_equal(len(s.select_items), 0)
    assert_equal(len(s.from_tables), 0)
    assert_equal(len(s.joins), 0)
    assert_false(Bool(s.where_pred))
    assert_equal(len(s.group_by), 0)
    assert_false(Bool(s.having_pred))
    assert_equal(len(s.order_by), 0)
    assert_false(Bool(s.limit))
    assert_false(Bool(s.offset))
    assert_equal(len(s.ctes), 0)
    assert_equal(len(s.subqueries), 0)
    assert_false(s.distinct)
    assert_equal(s.union_all_idx, -1)


def test_items_keys_ctes_and_subqueries() raises:
    var item = SelectItem(SqlExpr.column("k"), Optional[String]("kk"), False)
    assert_equal(item.expr.text, "k")
    assert_equal(item.out_alias.value(), "kk")
    assert_false(item.is_star)
    var star = SelectItem(SqlExpr.star(), None, True)
    assert_true(star.is_star)
    assert_equal(Int(star.expr.tag), Int(SX_STAR))
    assert_false(Bool(star.out_alias))

    var k = OrderKey(SqlExpr.column("k"), True)
    assert_true(k.descending)
    assert_false(Bool(k.nulls_first))
    var k2 = OrderKey(SqlExpr.column("k"), False, Optional[Bool](True))
    assert_false(k2.descending)
    assert_true(k2.nulls_first.value())

    var body = SelectStmt()
    body.distinct = True
    var cte = CteDef("w", body^)
    assert_equal(cte.name, "w")
    assert_true(cte.body.distinct)

    var sq = SubqueryDef(SelectStmt(), SUBQ_IN, "x")
    assert_equal(Int(sq.kind), Int(SUBQ_IN))
    assert_equal(sq.in_lhs_col, "x")
    assert_equal(sq.derived_alias, "")
    assert_equal(len(sq.col_names), 0)
    var sq0 = SubqueryDef(SelectStmt(), SUBQ_DERIVED)
    assert_equal(sq0.in_lhs_col, "")
    var cols: List[String] = ["c1", "c2"]
    var dt = SubqueryDef(SelectStmt(), SUBQ_DERIVED, "", "d", cols^)
    assert_equal(dt.derived_alias, "d")
    assert_equal(len(dt.col_names), 2)
    assert_equal(dt.col_names[1], "c2")


def test_join_clauses() raises:
    var cross = JoinClause(JK_CROSS, None)
    assert_equal(Int(cross.kind), Int(JK_CROSS))
    assert_false(Bool(cross.on_pred))
    assert_false(cross.natural)
    assert_equal(len(cross.using_cols), 0)
    assert_false(cross.is_keyed())

    var left = JoinClause(JK_LEFT, Optional[SqlExpr](SqlExpr.column("p")))
    assert_equal(Int(left.on_pred.value().tag), Int(SX_COLUMN))
    assert_false(left.is_keyed())

    var natural = JoinClause(JK_SEMI, None, True, List[String]())
    assert_true(natural.natural)
    assert_true(natural.is_keyed())

    var using_cols: List[String] = ["k"]
    var usingj = JoinClause(JK_LEFT, None, False, using_cols^)
    assert_false(usingj.natural)
    assert_equal(usingj.using_cols[0], "k")
    assert_true(usingj.is_keyed())

    var neither = JoinClause(JK_LEFT, Optional[SqlExpr](SqlExpr.column("p")), False, List[String]())
    assert_false(neither.is_keyed())


def test_sql_statement() raises:
    var q = SqlStatement(STMT_QUERY, SelectStmt())
    assert_equal(Int(q.kind), Int(STMT_QUERY))
    assert_equal(q.dest_path, "")
    assert_equal(q.target_table, "")
    assert_equal(Int(q.fmt), Int(WFMT_PARQUET))
    assert_equal(Int(q.codec), Int(WCOMP_SNAPPY))
    assert_false(q.replace)
    assert_equal(q.query.union_all_idx, -1)

    var cp = SqlStatement(STMT_COPY, SelectStmt(), "out.csv", "", WFMT_CSV, WCOMP_ZSTD)
    assert_equal(Int(cp.kind), Int(STMT_COPY))
    assert_equal(cp.dest_path, "out.csv")
    assert_equal(Int(cp.fmt), Int(WFMT_CSV))
    assert_equal(Int(cp.codec), Int(WCOMP_ZSTD))

    var ctas = SqlStatement(STMT_CREATE_TABLE_AS, SelectStmt(), target_table="t2", replace=True)
    assert_equal(Int(ctas.kind), Int(STMT_CREATE_TABLE_AS))
    assert_equal(ctas.target_table, "t2")
    assert_true(ctas.replace)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
