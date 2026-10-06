# =============================================================================
# The expression nodes of komira_sql.sql_ast: constructors, copy() and the
# aggregate detectors
# =============================================================================
#
#   1. Each SqlExpr constructor sets its tag and the fields its node reads
#      (and leaves the others at their defaults).
#      (mutant caught: a constructor writing another tag or field)
#   2. contains_aggregate() finds an aggregate in every child slot: the left
#      child of a binary node, a LIKE child, a NOT / IS NULL child, a call
#      argument, a CASE condition, result and ELSE; a statistical aggregate
#      call; and is False when every one of those holds no aggregate. A
#      fast-path aggregate's own argument is not walked, and a LIKE node with
#      no child is not an aggregate.
#      (mutants caught: the left-child walk removed, SX_UNARY dropped from
#      the LIKE arm, any CASE slab skipped)
#   3. copy() is deep for every child slot (binary, aggregate, call
#      arguments, CASE conditions / results / ELSE, window metadata, the
#      header fields), and an edit to the copy leaves the original unchanged.
#      (mutant caught: a slot not copied, or a header field not copied)
#   4. agg_has_arg(): True for sum(x), False for COUNT(*), for a non-aggregate
#      and for an aggregate node with no argument slot.
#      (mutant caught: the SX_STAR test inverted)
#   5. SqlWindowData: the constructor's defaults (one empty qualifier per
#      PARTITION BY and ORDER BY name, the default frame) and set_frame().
#      (mutant caught: a qualifier list not parallel to its names)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_collections.slab import Slab
from komira_sql.sql_ast import (
    SqlExpr,
    SqlWindowData,
    SX_COLUMN,
    SX_INT,
    SX_FLOAT,
    SX_STRING,
    SX_BINARY,
    SX_AGG,
    SX_STAR,
    SX_DATE,
    SX_LIKE,
    SX_CALL,
    SX_SUBQUERY,
    SX_CASE,
    SX_WINDOW,
    SX_UNARY,
    SX_BOOL,
    SX_TIMESTAMP,
    SX_NULL,
    TSLIT_NAIVE,
    TSLIT_AWARE,
    SXWIN_SUM,
    SXFRAME_ROWS,
    SXFRAME_RANGE,
    SXFRAME_UNBOUNDED_PRECEDING,
    SXFRAME_PRECEDING,
    SXFRAME_CURRENT_ROW,
    SXFRAME_FOLLOWING,
    SXOP_EQ,
    SXOP_SUB,
    SXUN_NOT,
    SXUN_IS_NULL,
    SXLIKE_LIKE,
    SXLIKE_ILIKE,
    SXAGG_SUM,
    SXAGG_COUNT,
)


def _sum_x() -> SqlExpr:
    return SqlExpr.agg(SXAGG_SUM, SqlExpr.column("x"))


def _one(var e: SqlExpr) -> Slab[SqlExpr]:
    var s = Slab[SqlExpr]()
    s.append(e^)
    return s^


def _window() -> SqlWindowData:
    var part: List[String] = ["p", "q"]
    var order: List[String] = ["o"]
    var desc: List[Bool] = [True]
    return SqlWindowData(SXWIN_SUM, "v", part^, order^, desc^)


def test_leaf_constructors() raises:
    var c = SqlExpr.column("k", "t")
    assert_equal(Int(c.tag), Int(SX_COLUMN))
    assert_equal(c.text, "k")
    assert_equal(c.qualifier, "t")
    var c0 = SqlExpr.column("k")
    assert_equal(c0.qualifier, "")
    var i = SqlExpr.int_lit(-3)
    assert_equal(Int(i.tag), Int(SX_INT))
    assert_equal(i.int_val, Int64(-3))
    var f = SqlExpr.float_lit(2.5)
    assert_equal(Int(f.tag), Int(SX_FLOAT))
    assert_equal(f.float_val, 2.5)
    var s = SqlExpr.string_lit("hi")
    assert_equal(Int(s.tag), Int(SX_STRING))
    assert_equal(s.text, "hi")
    var d = SqlExpr.date_lit("1995-03-15")
    assert_equal(Int(d.tag), Int(SX_DATE))
    assert_equal(d.text, "1995-03-15")
    var naive = SqlExpr.timestamp_lit("1995-03-15 01:02:03", False)
    assert_equal(Int(naive.tag), Int(SX_TIMESTAMP))
    assert_equal(Int(naive.op), Int(TSLIT_NAIVE))
    var aware = SqlExpr.timestamp_lit("1995-03-15 01:02:03+02", True)
    assert_equal(Int(aware.op), Int(TSLIT_AWARE))
    assert_equal(aware.text, "1995-03-15 01:02:03+02")
    assert_equal(Int(SqlExpr.star().tag), Int(SX_STAR))
    var t = SqlExpr.bool_lit(True)
    assert_equal(Int(t.tag), Int(SX_BOOL))
    assert_equal(t.int_val, Int64(1))
    assert_equal(SqlExpr.bool_lit(False).int_val, Int64(0))
    assert_equal(Int(SqlExpr.null_lit().tag), Int(SX_NULL))
    var q = SqlExpr.subquery(4)
    assert_equal(Int(q.tag), Int(SX_SUBQUERY))
    assert_equal(q.subquery_index(), 4)
    # The bare constructor's defaults.
    var bare = SqlExpr(SX_INT)
    assert_equal(Int(bare.op), 0)
    assert_equal(bare.text, "")
    assert_false(bare.agg_distinct)
    assert_false(bare.like_negate)
    assert_false(Bool(bare._binary))
    assert_false(Bool(bare._window))


def test_inner_node_constructors() raises:
    var a = SqlExpr.agg(SXAGG_COUNT, SqlExpr.column("k"), True, "count")
    assert_equal(Int(a.tag), Int(SX_AGG))
    assert_equal(Int(a.op), Int(SXAGG_COUNT))
    assert_true(a.agg_distinct)
    assert_equal(a.text, "count")
    assert_true(a.is_aggregate())
    var a0 = _sum_x()
    assert_false(a0.agg_distinct)
    assert_equal(a0.text, "")
    var l = SqlExpr.like(SqlExpr.column("s"), "a%", True)
    assert_equal(Int(l.tag), Int(SX_LIKE))
    assert_equal(Int(l.op), Int(SXLIKE_LIKE))
    assert_equal(l.text, "a%")
    assert_true(l.like_negate)
    var il = SqlExpr.like(SqlExpr.column("s"), "A%", False, SXLIKE_ILIKE)
    assert_equal(Int(il.op), Int(SXLIKE_ILIKE))
    assert_false(il.like_negate)
    var u = SqlExpr.unary(SXUN_IS_NULL, SqlExpr.column("s"))
    assert_equal(Int(u.tag), Int(SX_UNARY))
    assert_equal(Int(u.op), Int(SXUN_IS_NULL))
    assert_equal(u._agg.value().arg[].text, "s")
    var call = SqlExpr.call("upper", _one(SqlExpr.column("s")))
    assert_equal(Int(call.tag), Int(SX_CALL))
    assert_equal(call.text, "upper")
    assert_equal(len(call._call.value().args), 1)
    var w = SqlExpr.window(_window())
    assert_equal(Int(w.tag), Int(SX_WINDOW))
    assert_true(w.is_window())
    assert_false(SqlExpr.column("x").is_window())
    assert_equal(w._window.value().arg_col, "v")


def test_contains_aggregate_in_every_slot() raises:
    # The statistical aggregate rides SX_CALL; a scalar call does not.
    assert_true(SqlExpr.call("median", _one(SqlExpr.column("x"))).contains_aggregate())
    assert_false(SqlExpr.call("upper", _one(SqlExpr.column("x"))).contains_aggregate())
    # A call argument: upper(sum(x)).
    assert_true(SqlExpr.call("upper", _one(_sum_x())).contains_aggregate())
    # The LEFT child of a binary node: sum(x) - 1.
    assert_true(
        SqlExpr.binary(SXOP_SUB, _sum_x(), SqlExpr.int_lit(1)).contains_aggregate()
    )
    # A LIKE child and a unary child.
    assert_true(SqlExpr.like(_sum_x(), "1%", False).contains_aggregate())
    assert_false(SqlExpr.like(SqlExpr.column("s"), "1%", False).contains_aggregate())
    assert_true(SqlExpr.unary(SXUN_IS_NULL, _sum_x()).contains_aggregate())
    assert_false(SqlExpr.unary(SXUN_NOT, SqlExpr.column("b")).contains_aggregate())
    # A LIKE node with no child slot is not an aggregate.
    assert_false(SqlExpr(SX_LIKE).contains_aggregate())
    # A CASE: the aggregate in a condition, in a result, in the ELSE.
    assert_true(
        SqlExpr.case(_one(_sum_x()), _one(SqlExpr.int_lit(1)), Slab[SqlExpr]()).contains_aggregate()
    )
    assert_true(
        SqlExpr.case(_one(SqlExpr.column("b")), _one(_sum_x()), Slab[SqlExpr]()).contains_aggregate()
    )
    assert_true(
        SqlExpr.case(_one(SqlExpr.column("b")), _one(SqlExpr.int_lit(1)), _one(_sum_x())).contains_aggregate()
    )
    assert_false(
        SqlExpr.case(
            _one(SqlExpr.column("b")), _one(SqlExpr.int_lit(1)), _one(SqlExpr.int_lit(0))
        ).contains_aggregate()
    )
    # A window node and a leaf hold no aggregate.
    assert_false(SqlExpr.window(_window()).contains_aggregate())
    assert_false(SqlExpr.column("x").contains_aggregate())


def test_agg_has_arg() raises:
    assert_true(_sum_x().agg_has_arg())
    assert_false(SqlExpr.agg(SXAGG_COUNT, SqlExpr.star()).agg_has_arg())
    assert_false(SqlExpr.column("x").agg_has_arg())
    assert_false(SqlExpr(SX_AGG).agg_has_arg())


def test_copy_is_deep_for_every_slot() raises:
    var orig = SqlExpr.column("k", "t")
    orig.int_val = 9
    orig.float_val = 1.5
    orig.op = 3
    orig.agg_distinct = True
    orig.like_negate = True
    var dup = orig.copy()
    assert_equal(dup.text, "k")
    assert_equal(dup.qualifier, "t")
    assert_equal(dup.int_val, Int64(9))
    assert_equal(dup.float_val, 1.5)
    assert_equal(Int(dup.op), 3)
    assert_true(dup.agg_distinct)
    assert_true(dup.like_negate)

    # Binary and aggregate slots: edit the copy, the original keeps its value.
    var b = SqlExpr.binary(SXOP_EQ, SqlExpr.column("a"), _sum_x())
    var b2 = b.copy()
    b2._binary.value().left[].text = "changed"
    assert_equal(b._binary.value().left[].text, "a")
    assert_equal(b2._binary.value().right[]._agg.value().arg[].text, "x")

    # Call arguments.
    var args = Slab[SqlExpr]()
    args.append(SqlExpr.column("a"))
    args.append(SqlExpr.int_lit(2))
    var call = SqlExpr.call("f", args^)
    var call2 = call.copy()
    ref ca = call2._call.value().args
    assert_equal(len(ca), 2)
    assert_equal(ca[0].text, "a")
    assert_equal(ca[1].int_val, Int64(2))

    # CASE conditions, results and ELSE.
    var cs = SqlExpr.case(
        _one(SqlExpr.column("c")), _one(SqlExpr.int_lit(1)), _one(SqlExpr.int_lit(0))
    )
    var cs2 = cs.copy()
    assert_equal(Int(cs2.tag), Int(SX_CASE))
    ref cd = cs2._case.value()
    assert_equal(len(cd.conds), 1)
    assert_equal(cd.conds[0].text, "c")
    assert_equal(len(cd.results), 1)
    assert_equal(cd.results[0].int_val, Int64(1))
    assert_equal(len(cd.otherwise), 1)
    assert_equal(cd.otherwise[0].int_val, Int64(0))
    var cs_empty = SqlExpr.case(Slab[SqlExpr](), Slab[SqlExpr](), Slab[SqlExpr]())
    assert_equal(len(cs_empty.copy()._case.value().otherwise), 0)

    # Window metadata, and a LIKE child.
    var w2 = SqlExpr.window(_window()).copy()
    assert_equal(w2._window.value().arg_col, "v")
    assert_equal(len(w2._window.value().partition_by), 2)
    var lk = SqlExpr.like(SqlExpr.column("s"), "z%", True).copy()
    assert_equal(lk._agg.value().arg[].text, "s")
    assert_equal(lk.text, "z%")


def test_window_data_defaults_and_frame() raises:
    var w = _window()
    assert_equal(Int(w.func), Int(SXWIN_SUM))
    assert_equal(w.arg_qual, "")
    assert_equal(len(w.partition_qual), 2)
    assert_equal(w.partition_qual[0], "")
    assert_equal(w.partition_qual[1], "")
    assert_equal(len(w.order_qual), 1)
    assert_equal(w.order_by[0], "o")
    assert_true(w.descending[0])
    assert_false(w.has_frame)
    assert_equal(Int(w.frame_units), Int(SXFRAME_ROWS))
    assert_equal(Int(w.frame_start_tag), Int(SXFRAME_UNBOUNDED_PRECEDING))
    assert_equal(Int(w.frame_end_tag), Int(SXFRAME_CURRENT_ROW))
    assert_equal(w.value_offset, Int64(0))
    assert_false(w.has_default)
    assert_equal(Int(w.default_kind), Int(SX_INT))
    assert_equal(w.default_text, "")
    w.set_frame(SXFRAME_RANGE, SXFRAME_PRECEDING, 2, SXFRAME_FOLLOWING, 3)
    assert_true(w.has_frame)
    assert_equal(Int(w.frame_units), Int(SXFRAME_RANGE))
    assert_equal(Int(w.frame_start_tag), Int(SXFRAME_PRECEDING))
    assert_equal(w.frame_start_offset, Int64(2))
    assert_equal(Int(w.frame_end_tag), Int(SXFRAME_FOLLOWING))
    assert_equal(w.frame_end_offset, Int64(3))
    # A global window: no PARTITION BY, no ORDER BY, so no qualifiers.
    var g = SqlWindowData(SXWIN_SUM, "", List[String](), List[String](), List[Bool]())
    assert_equal(len(g.partition_qual), 0)
    assert_equal(len(g.order_qual), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
