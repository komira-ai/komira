# =============================================================================
# UNION, INTERSECT and EXCEPT binding, and the precedence of a set-operation chain
# (sql_parser, sql_binder, sql_bind_set_op)
# =============================================================================
#
# Every query binds against a catalog of parquet tables registered with a
# given schema (`add_parquet` opens no file) and `NoParquetFooters`, so no test
# reads a file. Table `t_<kind>` has one column `x` of that kind. What each
# test proves:
#   1. INTERSECT and EXCEPT bind to Project(columns) over a Filter over an
#      Aggregate grouped by every column, with MIN and MAX of the side tag, over
#      a two-child union whose children tag the left input 0 and the right 1;
#      INTERSECT keeps groups whose MIN is 0 and MAX is 1, EXCEPT (which
#      computes MAX alone) groups whose MAX is 0. The result has the inputs' columns, named as the left one's.
#   2. INTERSECT binds tighter than UNION ALL and EXCEPT, on either side of
#      them; EXCEPT and INTERSECT each fold left to right; a run of UNION ALL
#      beside them is one union node; a chain of UNION ALL alone is one node.
#   3. The two inputs take the common column type (each input cast under its
#      own projection), and the result is nullable when either input is.
#   4. A column count or type mismatch is refused naming the operator and the
#      branch numbers as the query spells them, also when the left input of
#      the pair is not the head.
#   5. Two result columns of one name, and a column named as a helper column
#      (a file's column can be), are refused by name.
#   6. ORDER BY / LIMIT after the last branch sort and window the whole chain;
#      a derived table holds a chain.
#   7. UNION (bare or DISTINCT) binds to a PLAN_DISTINCT over every column
#      (no column list) of the union of its inputs, named as the left input,
#      with the common types; UNION ALL alone has no distinct.
#   8. UNION folds left to right with UNION ALL and EXCEPT and below
#      INTERSECT: a UNION ALL after a UNION stays outside its distinct, a
#      UNION after a UNION ALL dedups the whole run to its left.
#   9. A UNION's mismatch names UNION and the branches; two result columns of
#      one name are refused for a UNION, not for a UNION ALL; a CTE body holds
#      a chain.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.agg_expr import AGG_MAX, AGG_MIN
from plan_ir.logical_plan import (
    LogicalPlan, PLAN_AGGREGATE, PLAN_FILTER, PLAN_LIMIT, PLAN_PROJECT,
    PLAN_DISTINCT, PLAN_SCAN, PLAN_SORT, PLAN_UNION,
)

from sql.sql_token import tokenize
from sql.sql_parser import parse_sql
from sql.sql_catalog import SqlCatalog
from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_binder import bind_statement


def _add(mut cat: SqlCatalog, name: String, var fields: List[Field]):
    var sb = SchemaBuilder()
    for i in range(len(fields)):
        sb.add_field(fields[i])
    cat.add_parquet(name, name + ".parquet", sb.build())


def _catalog() raises -> SqlCatalog:
    var cat = SqlCatalog()
    _add(cat, "t_a", List[Field]([Field(String("x"), ArrowType.INT32, False)]))
    _add(cat, "t_b", List[Field]([Field(String("x"), ArrowType.INT32, False)]))
    _add(cat, "t_c", List[Field]([Field(String("x"), ArrowType.INT32, False)]))
    _add(cat, "t_d", List[Field]([Field(String("x"), ArrowType.INT32, False)]))
    _add(cat, "t_i64", List[Field]([Field(String("x"), ArrowType.INT64, True)]))
    _add(cat, "t_str", List[Field]([Field(String("x"), ArrowType.STRING, False)]))
    _add(cat, "t_bool", List[Field]([Field(String("x"), ArrowType.BOOL, False)]))
    _add(cat, "t_d10_2", List[Field]([Field.decimal128("x", 10, 2, False)]))
    _add(
        cat, "t_side",
        List[Field]([Field(String("#set_side"), ArrowType.INT32, False)]),
    )
    _add(
        cat, "t_pair",
        List[Field]([
            Field(String("k"), ArrowType.INT32, False),
            Field(String("s"), ArrowType.STRING, True),
        ]),
    )
    return cat^


def _plan(sql: String) raises -> LogicalPlan:
    var cat = _catalog()
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    return bound.take_plan()


def _err(sql: String) raises -> String:
    var cat = _catalog()
    try:
        _ = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    except e:
        return String(e)
    raise Error("bound, expected a refusal: " + sql)


def _is_set_op(p: LogicalPlan) -> Bool:
    """`p` is the Project > Filter > Aggregate > Union(2) of an INTERSECT or
    an EXCEPT."""
    if p.tag != PLAN_PROJECT:
        return False
    ref f = p.project_data_ref().child[]
    if f.tag != PLAN_FILTER:
        return False
    ref a = f.filter_data_ref().child[]
    if a.tag != PLAN_AGGREGATE:
        return False
    ref u = a.aggregate_data_ref().child[]
    return u.tag == PLAN_UNION and len(u.union_data_ref().children) == 2


def _shape(p: LogicalPlan) raises -> String:
    """The set-operation tree of `p`: `INTERSECT(l, r)` / `EXCEPT(l, r)`,
    `union(a, b, ...)`, a table name for a scan, and `sort` / `limit` above;
    the projections that cast, rename or tag an input are skipped."""
    if _is_set_op(p):
        ref f = p.project_data_ref().child[]
        var pred = String(f.filter_data_ref().predicate)
        var op = String("EXCEPT")
        if "ColRef(#set_lo)" in pred:
            op = "INTERSECT"
        ref u = f.filter_data_ref().child[].aggregate_data_ref().child[]
        ref kids = u.union_data_ref().children
        return (
            op + "(" + _shape(kids[0][]) + ", " + _shape(kids[1][]) + ")"
        )
    if p.tag == PLAN_PROJECT:
        return _shape(p.project_data_ref().child[])
    if p.tag == PLAN_DISTINCT:
        return "DISTINCT(" + _shape(p.distinct_data_ref().child[]) + ")"
    if p.tag == PLAN_SORT:
        return "sort>" + _shape(p.sort_data_ref().child[])
    if p.tag == PLAN_LIMIT:
        return "limit>" + _shape(p.limit_data_ref().child[])
    if p.tag == PLAN_UNION:
        var out = String("union(")
        ref kids = p.union_data_ref().children
        for i in range(len(kids)):
            if i > 0:
                out += ", "
            out += _shape(kids[i][])
        return out + ")"
    if p.tag == PLAN_SCAN:
        return p.scan_data_ref().source_path.replace(".parquet", "")
    raise Error("unexpected plan node " + String(Int(p.tag)))


def test_intersect_binds_to_a_union_grouped_with_min_and_max_of_the_side() raises:
    var p = _plan("SELECT k, s FROM t_pair INTERSECT SELECT k, s FROM t_pair")
    assert_true(_is_set_op(p))
    assert_equal(p.output_schema.num_columns(), 2)
    assert_equal(p.output_schema.field_name(0), "k")
    assert_equal(p.output_schema.field_name(1), "s")
    ref f = p.project_data_ref().child[]
    var pred = String(f.filter_data_ref().predicate)
    assert_true(pred.startswith("BinaryOp(AND, BinaryOp(EQ, ColRef(#set_lo)"), pred)
    assert_true("BinaryOp(EQ, ColRef(#set_hi)" in pred, pred)
    ref a = f.filter_data_ref().child[]
    ref agg = a.aggregate_data_ref()
    assert_equal(len(agg.group_by), 2)
    assert_equal(String(agg.group_by[0]), "ColRef(k)")
    assert_equal(String(agg.group_by[1]), "ColRef(s)")
    assert_equal(len(agg.agg_exprs), 2)
    assert_equal(Int(agg.agg_exprs[0].func), Int(AGG_MIN))
    assert_equal(agg.agg_exprs[0].alias_name.value(), "#set_lo")
    assert_equal(Int(agg.agg_exprs[1].func), Int(AGG_MAX))
    assert_equal(agg.agg_exprs[1].alias_name.value(), "#set_hi")
    ref u = agg.child[]
    assert_equal(u.output_schema.num_columns(), 3)
    assert_equal(u.output_schema.field_name(2), "#set_side")
    assert_true(u.output_schema.field_arrow_type(2) == ArrowType.INT32)
    ref kids = u.union_data_ref().children
    for side in range(2):
        ref child = kids[side][]
        assert_equal(Int(child.tag), Int(PLAN_PROJECT))
        ref exprs = child.project_data_ref().exprs
        assert_equal(len(exprs), 3)
        assert_equal(String(exprs[0]), "ColRef(k)")
        assert_equal(String(exprs[1]), "ColRef(s)")
        assert_equal(exprs[2].alias_name(), "#set_side")
        assert_equal(Int(exprs[2].alias_child().literal_value().int_val), side)


def test_except_keeps_the_groups_the_right_input_lacks() raises:
    var p = _plan("SELECT x FROM t_a EXCEPT SELECT x FROM t_b")
    assert_equal(_shape(p), "EXCEPT(t_a, t_b)")
    ref f = p.project_data_ref().child[]
    var pred = String(f.filter_data_ref().predicate)
    assert_true(pred.startswith("BinaryOp(EQ, ColRef(#set_hi)"), pred)
    assert_false("#set_lo" in pred, pred)
    ref agg = f.filter_data_ref().child[].aggregate_data_ref()
    assert_equal(len(agg.agg_exprs), 1)
    assert_equal(Int(agg.agg_exprs[0].func), Int(AGG_MAX))
    assert_equal(agg.agg_exprs[0].alias_name.value(), "#set_hi")
    assert_equal(p.output_schema.num_columns(), 1)
    assert_equal(p.output_schema.field_name(0), "x")


def test_intersect_binds_before_union_all_and_except() raises:
    # On the right of a UNION ALL and of an EXCEPT.
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a UNION ALL SELECT x FROM t_b INTERSECT"
                " SELECT x FROM t_c"
            )
        ),
        "union(t_a, INTERSECT(t_b, t_c))",
    )
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a EXCEPT SELECT x FROM t_b INTERSECT"
                " SELECT x FROM t_c"
            )
        ),
        "EXCEPT(t_a, INTERSECT(t_b, t_c))",
    )
    # On the left of them.
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a INTERSECT SELECT x FROM t_b UNION ALL"
                " SELECT x FROM t_c"
            )
        ),
        "union(INTERSECT(t_a, t_b), t_c)",
    )
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a INTERSECT SELECT x FROM t_b INTERSECT"
                " SELECT x FROM t_c EXCEPT SELECT x FROM t_d"
            )
        ),
        "EXCEPT(INTERSECT(INTERSECT(t_a, t_b), t_c), t_d)",
    )


def test_except_and_union_all_fold_left_to_right() raises:
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a EXCEPT SELECT x FROM t_b EXCEPT"
                " SELECT x FROM t_c"
            )
        ),
        "EXCEPT(EXCEPT(t_a, t_b), t_c)",
    )
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a UNION ALL SELECT x FROM t_b UNION ALL"
                " SELECT x FROM t_c EXCEPT SELECT x FROM t_d"
            )
        ),
        "EXCEPT(union(t_a, t_b, t_c), t_d)",
    )
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a EXCEPT SELECT x FROM t_b UNION ALL"
                " SELECT x FROM t_c UNION ALL SELECT x FROM t_d"
            )
        ),
        "union(EXCEPT(t_a, t_b), t_c, t_d)",
    )
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a UNION ALL SELECT x FROM t_b UNION ALL"
                " SELECT x FROM t_c"
            )
        ),
        "union(t_a, t_b, t_c)",
    )


def test_the_inputs_take_the_common_type_and_either_ones_nullability() raises:
    # INT32 with a nullable INT64: INT64, nullable, the INT32 input cast.
    var p = _plan("SELECT x FROM t_a INTERSECT SELECT x FROM t_i64")
    assert_true(p.output_schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(p.output_schema.field_nullable(0))
    ref u = p.project_data_ref().child[].filter_data_ref().child[].aggregate_data_ref().child[]
    assert_true(u.output_schema.field_arrow_type(0) == ArrowType.INT64)
    ref left_tag = u.union_data_ref().children[0][]
    ref left_cast = left_tag.project_data_ref().child[]
    assert_equal(Int(left_cast.tag), Int(PLAN_PROJECT))
    assert_true(left_cast.output_schema.field_arrow_type(0) == ArrowType.INT64)
    # A decimal with an integer: the decimal that holds both.
    var d = _plan("SELECT x FROM t_d10_2 EXCEPT SELECT x FROM t_a")
    assert_true(d.output_schema.field_arrow_type(0) == ArrowType.DECIMAL128)
    assert_equal(d.output_schema.field_decimal_precision(0), 12)
    assert_equal(d.output_schema.field_decimal_scale(0), 2)
    # The result is named as the left input.
    var named = _plan("SELECT x AS l FROM t_a INTERSECT SELECT x AS r FROM t_b")
    assert_equal(named.output_schema.field_name(0), "l")


def test_a_mismatch_names_the_operator_and_the_branches() raises:
    assert_equal(
        _err("SELECT x FROM t_a INTERSECT SELECT x FROM t_bool"),
        "SQL not supported: INTERSECT column 1 (x): branch 1 gives int32 and"
        " branch 2 gives bool; no common type this engine casts to. Cast the"
        " columns to one type.",
    )
    assert_equal(
        _err("SELECT k, s FROM t_pair EXCEPT SELECT x FROM t_a"),
        "SQL bind error: EXCEPT branch 2 produces 1 column(s) but the first"
        " branch produces 2. Every branch of an EXCEPT must produce the same"
        " number of columns, in the same order.",
    )
    # The left input of an INTERSECT that is not the head is named by its
    # own branch number.
    assert_equal(
        _err(
            "SELECT x FROM t_a UNION ALL SELECT x FROM t_bool INTERSECT"
            " SELECT x FROM t_b"
        ),
        "SQL not supported: INTERSECT column 1 (x): branch 2 gives bool and"
        " branch 3 gives int32; no common type this engine casts to. Cast the"
        " columns to one type.",
    )
    assert_equal(
        _err(
            "SELECT x FROM t_a UNION ALL SELECT x FROM t_b INTERSECT"
            " SELECT k, s FROM t_pair"
        ),
        "SQL bind error: INTERSECT branch 3 produces 2 column(s) but branch 2"
        " produces 1. Every branch of an INTERSECT must produce the same number"
        " of columns, in the same order.",
    )
    # An EXCEPT's left input is every branch before it.
    assert_equal(
        _err(
            "SELECT x FROM t_a UNION ALL SELECT x FROM t_b EXCEPT"
            " SELECT x FROM t_bool"
        ),
        "SQL not supported: EXCEPT column 1 (x): branches 1 to 2 give int32 and"
        " branch 3 gives bool; no common type this engine casts to. Cast the"
        " columns to one type.",
    )
    # A UNION ALL after an EXCEPT folds the EXCEPT's result with the branch.
    assert_equal(
        _err(
            "SELECT x FROM t_a EXCEPT SELECT x FROM t_b UNION ALL"
            " SELECT x FROM t_bool"
        ),
        "SQL not supported: UNION ALL column 1 (x): branches 1 to 2 give int32"
        " and branch 3 gives bool; no common type this engine casts to. Cast"
        " the columns to one type.",
    )


def test_two_result_columns_of_one_name_are_refused() raises:
    assert_equal(
        _err("SELECT x, x FROM t_a INTERSECT SELECT x, x FROM t_b"),
        "SQL not supported: INTERSECT over two columns named `x`. Rows are"
        " compared by column name, so the second would be read as the first."
        " Give the two columns distinct aliases.",
    )
    assert_true(
        "EXCEPT over two columns named `k`"
        in _err("SELECT k, k FROM t_pair EXCEPT SELECT k, k FROM t_pair")
    )


def test_a_column_named_as_a_helper_column_is_refused() raises:
    # A file's column can be named `#set_side`; `SELECT *` passes it on.
    assert_equal(
        _err("SELECT * FROM t_side INTERSECT SELECT * FROM t_side"),
        "SQL not supported: INTERSECT over a column named `#set_side`, the name"
        " of a column the INTERSECT plan adds. Rename the column.",
    )


def test_order_by_and_limit_apply_to_the_whole_chain() raises:
    var p = _plan(
        "SELECT x FROM t_a INTERSECT SELECT x FROM t_b ORDER BY x DESC LIMIT 2"
    )
    assert_equal(_shape(p), "limit>sort>INTERSECT(t_a, t_b)")
    var d = _plan(
        "SELECT x FROM (SELECT x FROM t_a EXCEPT SELECT x FROM t_b) e WHERE x > 1"
    )
    assert_equal(Int(d.tag), Int(PLAN_PROJECT))
    assert_equal(Int(d.project_data_ref().child[].tag), Int(PLAN_FILTER))
    assert_true(_is_set_op(d.project_data_ref().child[].filter_data_ref().child[]))


def test_union_binds_to_a_distinct_over_the_union() raises:
    var p = _plan("SELECT k, s FROM t_pair UNION SELECT k, s FROM t_pair")
    assert_equal(Int(p.tag), Int(PLAN_DISTINCT))
    # Every column, as SELECT DISTINCT: no column list.
    assert_false(Bool(p.distinct_data_ref().columns))
    ref u = p.distinct_data_ref().child[]
    assert_equal(Int(u.tag), Int(PLAN_UNION))
    assert_equal(len(u.union_data_ref().children), 2)
    assert_equal(p.output_schema.num_columns(), 2)
    assert_equal(p.output_schema.field_name(0), "k")
    assert_equal(p.output_schema.field_name(1), "s")
    assert_true(p.output_schema.field_nullable(1))
    # UNION DISTINCT is the same plan.
    assert_equal(
        _shape(_plan("SELECT x FROM t_a UNION DISTINCT SELECT x FROM t_b")),
        "DISTINCT(union(t_a, t_b))",
    )
    # The result is named as the left input and takes the common type.
    var w = _plan("SELECT x AS l FROM t_a UNION SELECT x AS r FROM t_i64")
    assert_equal(w.output_schema.field_name(0), "l")
    assert_true(w.output_schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(w.output_schema.field_nullable(0))
    ref kids = w.distinct_data_ref().child[].union_data_ref().children
    assert_true(kids[0][].output_schema.field_arrow_type(0) == ArrowType.INT64)
    assert_equal(kids[1][].output_schema.field_name(0), "l")
    # An integer with a string: the string.
    var vs = _plan("SELECT x FROM t_a UNION SELECT x FROM t_str")
    assert_true(vs.output_schema.field_arrow_type(0) == ArrowType.STRING)
    # A chain of UNION ALL alone has no distinct.
    assert_equal(
        _shape(_plan("SELECT x FROM t_a UNION ALL SELECT x FROM t_b")),
        "union(t_a, t_b)",
    )


def test_union_folds_left_to_right_beside_union_all_and_except() raises:
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a UNION SELECT x FROM t_b UNION ALL"
                " SELECT x FROM t_c"
            )
        ),
        "union(DISTINCT(union(t_a, t_b)), t_c)",
    )
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a UNION ALL SELECT x FROM t_b UNION"
                " SELECT x FROM t_c"
            )
        ),
        "DISTINCT(union(t_a, t_b, t_c))",
    )
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a UNION SELECT x FROM t_b UNION"
                " SELECT x FROM t_c"
            )
        ),
        "DISTINCT(union(DISTINCT(union(t_a, t_b)), t_c))",
    )
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a UNION ALL SELECT x FROM t_b UNION"
                " SELECT x FROM t_c UNION ALL SELECT x FROM t_d"
            )
        ),
        "union(DISTINCT(union(t_a, t_b, t_c)), t_d)",
    )
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a UNION SELECT x FROM t_b EXCEPT"
                " SELECT x FROM t_c"
            )
        ),
        "EXCEPT(DISTINCT(union(t_a, t_b)), t_c)",
    )
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a EXCEPT SELECT x FROM t_b UNION"
                " SELECT x FROM t_c"
            )
        ),
        "DISTINCT(union(EXCEPT(t_a, t_b), t_c))",
    )


def test_intersect_binds_before_union() raises:
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a UNION SELECT x FROM t_b INTERSECT"
                " SELECT x FROM t_c"
            )
        ),
        "DISTINCT(union(t_a, INTERSECT(t_b, t_c)))",
    )
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a INTERSECT SELECT x FROM t_b UNION"
                " SELECT x FROM t_c"
            )
        ),
        "DISTINCT(union(INTERSECT(t_a, t_b), t_c))",
    )


def test_a_union_mismatch_names_union_and_the_branches() raises:
    assert_equal(
        _err("SELECT x FROM t_a UNION SELECT x FROM t_bool"),
        "SQL not supported: UNION column 1 (x): branch 1 gives int32 and"
        " branch 2 gives bool; no common type this engine casts to. Cast the"
        " columns to one type.",
    )
    assert_equal(
        _err("SELECT k, s FROM t_pair UNION SELECT x FROM t_a"),
        "SQL bind error: UNION branch 2 produces 1 column(s) but the first"
        " branch produces 2. Every branch of a UNION must produce the same"
        " number of columns, in the same order.",
    )
    # Each branch is named by the operator that joins it.
    assert_equal(
        _err(
            "SELECT x FROM t_a UNION ALL SELECT x FROM t_b UNION"
            " SELECT x FROM t_bool"
        ),
        "SQL not supported: UNION column 1 (x): branches 1 to 2 give int32 and"
        " branch 3 gives bool; no common type this engine casts to. Cast the"
        " columns to one type.",
    )
    assert_equal(
        _err(
            "SELECT x FROM t_a UNION SELECT x FROM t_b UNION ALL"
            " SELECT x FROM t_bool"
        ),
        "SQL not supported: UNION ALL column 1 (x): branches 1 to 2 give int32"
        " and branch 3 gives bool; no common type this engine casts to. Cast"
        " the columns to one type.",
    )


def test_a_union_over_two_result_columns_of_one_name_is_refused() raises:
    assert_equal(
        _err("SELECT x, x FROM t_a UNION SELECT x, x FROM t_b"),
        "SQL not supported: UNION over two columns named `x`. Rows are"
        " compared by column name, so the second would be read as the first."
        " Give the two columns distinct aliases.",
    )
    # A UNION ALL compares no rows, so it keeps both columns.
    var kept = _plan("SELECT x, x FROM t_a UNION ALL SELECT x, x FROM t_b")
    assert_equal(kept.output_schema.num_columns(), 2)


def test_a_union_sorts_and_lives_in_a_cte() raises:
    assert_equal(
        _shape(
            _plan(
                "SELECT x FROM t_a UNION SELECT x FROM t_b ORDER BY x LIMIT 2"
            )
        ),
        "limit>sort>DISTINCT(union(t_a, t_b))",
    )
    assert_equal(
        _shape(
            _plan(
                "WITH c AS (SELECT x FROM t_a UNION SELECT x FROM t_b)"
                " SELECT x FROM c"
            )
        ),
        "DISTINCT(union(t_a, t_b))",
    )
    assert_equal(
        _shape(
            _plan(
                "WITH c AS (SELECT x FROM t_a INTERSECT SELECT x FROM t_b)"
                " SELECT x FROM c"
            )
        ),
        "INTERSECT(t_a, t_b)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
