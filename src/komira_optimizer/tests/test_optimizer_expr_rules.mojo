# =============================================================================
# Direct tests for the three expression rules of `optimizer_expr` that no
# moved test reaches: constant folding (`fold_constants*`, `_fold_expr`),
# predicate simplification (`simplify_predicates*`, `_simplify_expr`) and the
# IN-clause rewrite (`rewrite_in_clauses*`, `_rewrite_in_expr` and its
# OR-chain helpers).
#
# Every case builds plans and expressions in memory (no file is read) and
# compares a rendered form of the result, so a failure prints the whole
# expression. Each test names the defect it catches.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_IN_LIST,
    EXPR_STRING_OP,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_DIV,
    BIN_MOD,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
    BIN_OR,
    UN_NOT,
    UN_NEGATE,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
    STR_CONTAINS,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_UNION,
    SOURCE_PARQUET,
    JOIN_INNER,
)
from komira_optimizer.optimizer_expr import (
    fold_constants,
    fold_constants_inplace,
    _fold_expr,
    simplify_predicates,
    simplify_predicates_inplace,
    _simplify_expr,
    rewrite_in_clauses,
    rewrite_in_clauses_inplace,
    _rewrite_in_expr,
    _collect_or_eq_values,
    _is_col_eq_literal,
    _get_eq_col_name,
    _count_or_eq_chain,
    _get_eq_chain_col,
)


# =============================================================================
# Builders and a renderer
# =============================================================================

def _c(name: String) -> Expr:
    return Expr.col_ref(name)


def _i(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _i64(v: Int64) -> Expr:
    return Expr.literal(ScalarValue.from_int64(v))


def _f(v: Float64) -> Expr:
    return Expr.literal(ScalarValue.from_float(v))


def _b(v: Bool) -> Expr:
    return Expr.literal(ScalarValue.from_bool(v))


def _bin(op: UInt8, var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(op, l^, r^)


def _op(op: UInt8) -> String:
    if op == BIN_ADD: return "+"
    if op == BIN_SUB: return "-"
    if op == BIN_MUL: return "*"
    if op == BIN_DIV: return "/"
    if op == BIN_MOD: return "%"
    if op == BIN_EQ: return "="
    if op == BIN_NE: return "!="
    if op == BIN_LT: return "<"
    if op == BIN_LE: return "<="
    if op == BIN_GT: return ">"
    if op == BIN_GE: return ">="
    if op == BIN_AND: return "and"
    if op == BIN_OR: return "or"
    return "op" + String(Int(op))


def _uop(op: UInt8) -> String:
    if op == UN_NOT: return "not"
    if op == UN_NEGATE: return "neg"
    if op == UN_IS_NULL: return "isnull"
    if op == UN_IS_NOT_NULL: return "notnull"
    return "un" + String(Int(op))


# Renders an expression: ints and bools as values, binary ops infix and
# parenthesized, unary ops as calls, IN lists as `x in [v,...]`.
def _d(e: Expr) raises -> String:
    if e.tag == EXPR_LITERAL:
        var v = e.literal_value()
        if v.is_bool():
            if v.bool_val:
                return String("true")
            return String("false")
        if v.is_int():
            return String(Int(v.int_val))
        return String("lit?")
    if e.tag == EXPR_COL_REF:
        return e.col_ref_name()
    if e.tag == EXPR_BINARY_OP:
        return "(" + _d(e.binary_left_ref()) + " " + _op(e.binary_op()) + " " + _d(e.binary_right_ref()) + ")"
    if e.tag == EXPR_UNARY_OP:
        return _uop(e.unary_op()) + "(" + _d(e.unary_child_ref()) + ")"
    if e.tag == EXPR_CAST:
        return "cast(" + _d(e.cast_child_ref()) + ")"
    if e.tag == EXPR_ALIAS:
        return _d(e.alias_child_ref()) + " as " + e.alias_name()
    if e.tag == EXPR_IN_LIST:
        var s = _d(e.in_list_child_ref()) + " in ["
        ref vals = e.in_list_values_ref()
        for k in range(len(vals)):
            if k > 0:
                s += ","
            s += String(Int(vals[k].int_val))
        return s + "]"
    return "tag" + String(Int(e.tag))


# Pre-order list of every expression site the rules rewrite: a Scan's pushed
# filter, a Filter's predicate and each Project expression.
def _sites(plan: LogicalPlan, mut out: List[String]) raises:
    if plan.tag == PLAN_SCAN:
        if plan._scan.value()[].filter:
            out.append("scan:" + _d(plan._scan.value()[].filter.value()))
    elif plan.tag == PLAN_FILTER:
        out.append("filter:" + _d(plan._filter.value()[].predicate))
        _sites(plan._filter.value()[].child[], out)
    elif plan.tag == PLAN_PROJECT:
        for k in range(len(plan._project.value()[].exprs)):
            out.append("project:" + _d(plan._project.value()[].exprs[k]))
        _sites(plan._project.value()[].child[], out)
    elif plan.tag == PLAN_AGGREGATE:
        _sites(plan._aggregate.value()[].child[], out)
    elif plan.tag == PLAN_JOIN:
        _sites(plan._join.value()[].left[], out)
        _sites(plan._join.value()[].right[], out)
    elif plan.tag == PLAN_SORT:
        _sites(plan._sort.value()[].child[], out)
    elif plan.tag == PLAN_LIMIT:
        _sites(plan._limit.value()[].child[], out)
    elif plan.tag == PLAN_DISTINCT:
        _sites(plan._distinct.value()[].child[], out)
    elif plan.tag == PLAN_TOPN:
        _sites(plan._topn.value()[].child[], out)
    elif plan.tag == PLAN_UNION:
        for k in range(len(plan._union.value()[].children)):
            _sites(plan._union.value()[].children[k][], out)


def _render(plan: LogicalPlan) raises -> String:
    var out = List[String]()
    _sites(plan, out)
    var s = String("")
    for k in range(len(out)):
        if k > 0:
            s += " | "
        s += out[k]
    return s


def _left_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.BOOL, False))
    sb.add_field(Field("c", ArrowType.INT64, False))
    return sb.build()


def _right_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, False))
    sb.add_field(Field("y", ArrowType.BOOL, False))
    return sb.build()


def _scan(path: String, var schema: Schema, var filter: Optional[Expr]) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, schema^, None, filter^)


# TopN(Distinct(Limit(Sort(Join(Aggregate(left), right))))): one node of every
# tag the rules recurse through, so a rule that drops the recursion of any
# one of them leaves the sites below it unrewritten.
def _every_node_over(var left: LogicalPlan, var right: LogicalPlan) -> LogicalPlan:
    var gb = ExprArray()
    gb.append(_c("a"))
    var agg = LogicalPlan.aggregate(gb^, AggExprArray(), left^)
    var lon: List[String] = ["a"]
    var ron: List[String] = ["x"]
    var j = LogicalPlan.join(agg^, right^, lon^, ron^, JOIN_INNER)
    var sk: List[String] = ["a"]
    var sd: List[Bool] = [False]
    var s = LogicalPlan.sort(sk^, sd^, j^)
    var l = LogicalPlan.limit(10, s^)
    var d = LogicalPlan.distinct(None, l^)
    var tk: List[String] = ["a"]
    var td: List[Bool] = [False]
    return LogicalPlan.topn(tk^, td^, 5, d^)


# Union(Scan(filter=f)): a tag none of the three rules has an arm for.
def _union_over_filtered_scan(var f: Expr) -> LogicalPlan:
    var children = List[OwnedPointer[LogicalPlan]]()
    var fo: Optional[Expr] = f^
    children.append(OwnedPointer(_scan("u.parquet", _left_schema(), fo^)))
    return LogicalPlan.union(children^, _left_schema())


# =============================================================================
# Rule 5: constant folding, expression level
# =============================================================================

def test_fold_int_arithmetic() raises:
    """Catches: an arithmetic arm computing the wrong operator (the product
    is the default and `+`/`-` overwrite it, so a lost overwrite shows)."""
    assert_equal(_d(_fold_expr(_bin(BIN_ADD, _i(2), _i(3)))), "5")
    assert_equal(_d(_fold_expr(_bin(BIN_SUB, _i(2), _i(5)))), "-3")
    assert_equal(_d(_fold_expr(_bin(BIN_MUL, _i(4), _i(5)))), "20")


def test_fold_int_comparisons() raises:
    """Catches: a comparison arm with the wrong operator or swapped operands."""
    assert_equal(_d(_fold_expr(_bin(BIN_EQ, _i(2), _i(2)))), "true")
    assert_equal(_d(_fold_expr(_bin(BIN_EQ, _i(2), _i(3)))), "false")
    assert_equal(_d(_fold_expr(_bin(BIN_NE, _i(2), _i(3)))), "true")
    assert_equal(_d(_fold_expr(_bin(BIN_LT, _i(2), _i(3)))), "true")
    assert_equal(_d(_fold_expr(_bin(BIN_LT, _i(3), _i(2)))), "false")
    assert_equal(_d(_fold_expr(_bin(BIN_LE, _i(3), _i(3)))), "true")
    assert_equal(_d(_fold_expr(_bin(BIN_GT, _i(3), _i(2)))), "true")
    assert_equal(_d(_fold_expr(_bin(BIN_GE, _i(2), _i(3)))), "false")


def test_fold_int_overflow_is_left_unfolded() raises:
    """Catches: a fold that wraps on overflow (either bound) instead of
    leaving the node for the checked runtime kernel; and a bound check off
    by one, which would refuse a result that fits exactly."""
    assert_equal(_d(_fold_expr(_bin(BIN_ADD, _i64(Int64.MAX), _i(1)))),
                 "(9223372036854775807 + 1)")
    assert_equal(_d(_fold_expr(_bin(BIN_SUB, _i64(Int64.MIN), _i(1)))),
                 "(-9223372036854775808 - 1)")
    assert_equal(_d(_fold_expr(_bin(BIN_MUL, _i64(Int64.MAX), _i(2)))),
                 "(9223372036854775807 * 2)")
    assert_equal(_d(_fold_expr(_bin(BIN_ADD, _i64(Int64.MAX), _i(0)))),
                 "9223372036854775807")
    assert_equal(_d(_fold_expr(_bin(BIN_SUB, _i64(Int64.MIN), _i(0)))),
                 "-9223372036854775808")


def test_fold_leaves_int_division_and_modulo() raises:
    """Catches: a fold of integer `/` or `%` at plan time (division by zero
    and rounding stay the runtime kernel's)."""
    assert_equal(_d(_fold_expr(_bin(BIN_DIV, _i(6), _i(3)))), "(6 / 3)")
    assert_equal(_d(_fold_expr(_bin(BIN_MOD, _i(7), _i(2)))), "(7 % 2)")


def test_fold_float_arithmetic() raises:
    """Catches: a float arm computing the wrong operator; and a float fold of
    `/` or of a comparison, which the rule does not do."""
    var add = _fold_expr(_bin(BIN_ADD, _f(1.5), _f(2.0)))
    assert_true(add.tag == EXPR_LITERAL, "1.5 + 2.0 folds")
    assert_equal(add.literal_value().float_val, Float64(3.5))
    var sub = _fold_expr(_bin(BIN_SUB, _f(5.0), _f(1.5)))
    assert_equal(sub.literal_value().float_val, Float64(3.5))
    var mul = _fold_expr(_bin(BIN_MUL, _f(2.0), _f(1.25)))
    assert_equal(mul.literal_value().float_val, Float64(2.5))
    assert_true(_fold_expr(_bin(BIN_DIV, _f(1.0), _f(4.0))).tag == EXPR_BINARY_OP,
                "float division is not folded")
    assert_true(_fold_expr(_bin(BIN_GT, _f(2.0), _f(1.0))).tag == EXPR_BINARY_OP,
                "float comparison is not folded")


def test_fold_bool_literals_and_mixed_types() raises:
    """Catches: AND/OR of two bool literals evaluated with the wrong
    connective; a bool `=` folded; and an int-float or float-int pair folded
    as if both were ints or both floats."""
    assert_equal(_d(_fold_expr(_bin(BIN_AND, _b(True), _b(False)))), "false")
    assert_equal(_d(_fold_expr(_bin(BIN_AND, _b(True), _b(True)))), "true")
    assert_equal(_d(_fold_expr(_bin(BIN_OR, _b(False), _b(True)))), "true")
    assert_equal(_d(_fold_expr(_bin(BIN_OR, _b(False), _b(False)))), "false")
    assert_equal(_d(_fold_expr(_bin(BIN_EQ, _b(True), _b(True)))), "(true = true)")
    assert_true(_fold_expr(_bin(BIN_ADD, _i(1), _f(2.0))).tag == EXPR_BINARY_OP,
                "an int-float pair is not folded")
    assert_true(_fold_expr(_bin(BIN_ADD, _f(2.0), _i(1))).tag == EXPR_BINARY_OP,
                "a float-int pair is not folded")
    # A bool and an int literal: no full fold, then the partial AND arm
    # returns the right side for a TRUE left side, whatever its type.
    assert_equal(_d(_fold_expr(_bin(BIN_AND, _b(True), _i(1)))), "1")


def test_fold_partial_and_or() raises:
    """Catches: any of the eight identity/annihilator arms returning the wrong
    side, and a non-bool literal (`1`) mistaken for TRUE."""
    assert_equal(_d(_fold_expr(_bin(BIN_AND, _b(True), _c("b")))), "b")
    assert_equal(_d(_fold_expr(_bin(BIN_AND, _c("b"), _b(True)))), "b")
    assert_equal(_d(_fold_expr(_bin(BIN_AND, _b(False), _c("b")))), "false")
    assert_equal(_d(_fold_expr(_bin(BIN_AND, _c("b"), _b(False)))), "false")
    assert_equal(_d(_fold_expr(_bin(BIN_AND, _c("b"), _c("y")))), "(b and y)")
    assert_equal(_d(_fold_expr(_bin(BIN_AND, _i(1), _c("b")))), "(1 and b)")
    assert_equal(_d(_fold_expr(_bin(BIN_OR, _b(True), _c("b")))), "true")
    assert_equal(_d(_fold_expr(_bin(BIN_OR, _c("b"), _b(True)))), "true")
    assert_equal(_d(_fold_expr(_bin(BIN_OR, _b(False), _c("b")))), "b")
    assert_equal(_d(_fold_expr(_bin(BIN_OR, _c("b"), _b(False)))), "b")
    assert_equal(_d(_fold_expr(_bin(BIN_OR, _c("b"), _c("y")))), "(b or y)")
    # Children fold first: (1 < 2) becomes TRUE, then TRUE AND b is b.
    assert_equal(_d(_fold_expr(_bin(BIN_AND, _bin(BIN_LT, _i(1), _i(2)), _c("b")))), "b")


def test_fold_unary() raises:
    """Catches: NOT or negation of a literal computed wrongly; -(INT64_MIN)
    folded (it is not an INT64); NOT applied to an int or negation to a bool;
    and the child not folded before the parent."""
    assert_equal(_d(_fold_expr(Expr.unary(UN_NOT, _b(True)))), "false")
    assert_equal(_d(_fold_expr(Expr.unary(UN_NOT, _b(False)))), "true")
    assert_equal(_d(_fold_expr(Expr.unary(UN_NEGATE, _i(5)))), "-5")
    assert_equal(_d(_fold_expr(Expr.unary(UN_NEGATE, _i64(Int64.MIN)))),
                 "neg(-9223372036854775808)")
    assert_equal(_d(_fold_expr(Expr.unary(UN_NEGATE, _b(True)))), "neg(true)")
    assert_equal(_d(_fold_expr(Expr.unary(UN_NOT, _i(5)))), "not(5)")
    assert_equal(_d(_fold_expr(Expr.unary(UN_IS_NULL, _i(5)))), "isnull(5)")
    assert_equal(_d(_fold_expr(Expr.unary(UN_NOT, _c("b")))), "not(b)")
    assert_equal(_d(_fold_expr(Expr.unary(UN_NOT, _bin(BIN_LT, _i(1), _i(2))))), "false")


def test_fold_cast_alias_and_leaves() raises:
    """Catches: a CAST rebuilt from its bare DType (a TIMESTAMP_MS target
    would come back as plain INT64, the unit-conversion defect the module
    documents); an alias dropped or renamed; a leaf or an opaque node
    rebuilt."""
    var cast = _fold_expr(Expr.cast_to_arrow(_bin(BIN_ADD, _i(1), _i(2)), ArrowType.TIMESTAMP_MS))
    assert_true(cast.tag == EXPR_CAST, "still a cast")
    assert_equal(_d(cast.cast_child_ref()), "3")
    assert_true(cast.cast_target_arrow() == ArrowType.TIMESTAMP_MS,
                "the cast keeps its arrow target")
    assert_equal(_d(_fold_expr(Expr.alias(_bin(BIN_ADD, _i(2), _i(3)), "five"))), "5 as five")
    assert_equal(_d(_fold_expr(_c("a"))), "a")
    assert_equal(_d(_fold_expr(_i(7))), "7")
    var op = _fold_expr(Expr.string_op(STR_CONTAINS, _c("s"), String("x")))
    assert_true(op.tag == EXPR_STRING_OP, "an opaque node is returned as is")


# =============================================================================
# Rule 5: constant folding, plan walk
# =============================================================================

def test_fold_walks_every_node_kind() raises:
    """Catches: dropping the recursion of any of Filter, Project, Aggregate,
    Join (left or right), Sort, Limit, Distinct, TopN, or the Scan-filter
    fold; or folding only a Project's first expression."""
    var sf: Optional[Expr] = _bin(BIN_AND, _bin(BIN_EQ, _i(1), _i(1)), _c("b"))
    var scan = _scan("l.parquet", _left_schema(), sf^)
    var exprs = ExprArray()
    exprs.append(_c("a"))
    exprs.append(_c("b"))
    exprs.append(Expr.alias(_bin(BIN_MUL, _i(2), _i(3)), "six"))
    var proj = LogicalPlan.project(exprs^, scan^)
    var filt = LogicalPlan.filter(_bin(BIN_AND, _bin(BIN_GT, _i(2), _i(1)), _c("b")), proj^)
    var rf: Optional[Expr] = _bin(BIN_OR, _c("y"), _b(False))
    var right = _scan("r.parquet", _right_schema(), rf^)
    var plan = _every_node_over(filt^, right^)

    var out = fold_constants(plan^)

    assert_true(out.tag == PLAN_TOPN, "the root is unchanged")
    assert_equal(_render(out),
                 "filter:b | project:a | project:b | project:6 as six | scan:b | scan:y")


def test_fold_inplace_scan_without_filter_and_unhandled_tag() raises:
    """Catches: a Scan with no pushed filter treated as having one; and a
    rule that starts rewriting under a node kind it documents as untouched
    (UNION here; the module names PARTITION_BY, PARTITION_TOPN, ASOF_JOIN)."""
    var none: Optional[Expr] = None
    var plan = _scan("l.parquet", _left_schema(), none^)
    fold_constants_inplace(plan)
    assert_true(plan.tag == PLAN_SCAN, "a bare scan stays a scan")
    assert_false(Bool(plan._scan.value()[].filter), "and gains no filter")

    var u = _union_over_filtered_scan(_bin(BIN_ADD, _i(1), _i(1)))
    fold_constants_inplace(u)
    assert_true(u.tag == PLAN_UNION, "the union is unchanged")
    assert_equal(_render(u), "scan:(1 + 1)")


# =============================================================================
# Rule 9: predicate simplification
# =============================================================================

def test_simplify_and_or_arms() raises:
    """Catches: any AND/OR identity or annihilator arm returning the wrong
    side; and simplification folding literal arithmetic (that is rule 5's)."""
    assert_equal(_d(_simplify_expr(_bin(BIN_AND, _b(True), _c("b")))), "b")
    assert_equal(_d(_simplify_expr(_bin(BIN_AND, _c("b"), _b(True)))), "b")
    assert_equal(_d(_simplify_expr(_bin(BIN_AND, _b(False), _c("b")))), "false")
    assert_equal(_d(_simplify_expr(_bin(BIN_AND, _c("b"), _b(False)))), "false")
    assert_equal(_d(_simplify_expr(_bin(BIN_AND, _c("b"), _c("y")))), "(b and y)")
    assert_equal(_d(_simplify_expr(_bin(BIN_OR, _b(True), _c("b")))), "true")
    assert_equal(_d(_simplify_expr(_bin(BIN_OR, _c("b"), _b(True)))), "true")
    assert_equal(_d(_simplify_expr(_bin(BIN_OR, _b(False), _c("b")))), "b")
    assert_equal(_d(_simplify_expr(_bin(BIN_OR, _c("b"), _b(False)))), "b")
    assert_equal(_d(_simplify_expr(_bin(BIN_OR, _c("b"), _c("y")))), "(b or y)")
    assert_equal(_d(_simplify_expr(_bin(BIN_ADD, _i(1), _i(2)))), "(1 + 2)")


def test_simplify_not_not_and_wrappers() raises:
    """Catches: NOT NOT x not collapsed; a NOT over another unary op (or a
    non-NOT over NOT) collapsed; the inner pair not simplified first; a CAST
    losing its arrow target; an alias dropped; a leaf rebuilt."""
    assert_equal(_d(_simplify_expr(Expr.unary(UN_NOT, Expr.unary(UN_NOT, _c("b"))))), "b")
    assert_equal(_d(_simplify_expr(Expr.unary(UN_NOT, Expr.unary(UN_NEGATE, _c("a"))))),
                 "not(neg(a))")
    assert_equal(_d(_simplify_expr(Expr.unary(UN_NEGATE, Expr.unary(UN_NOT, _c("b"))))),
                 "neg(not(b))")
    assert_equal(_d(_simplify_expr(Expr.unary(UN_NOT, _c("b")))), "not(b)")
    assert_equal(_d(_simplify_expr(
        Expr.unary(UN_NOT, Expr.unary(UN_NOT, Expr.unary(UN_NOT, _c("b")))))), "not(b)")
    var cast = _simplify_expr(Expr.cast_to_arrow(_bin(BIN_AND, _c("b"), _b(True)), ArrowType.TIMESTAMP_MS))
    assert_equal(_d(cast), "cast(b)")
    assert_true(cast.cast_target_arrow() == ArrowType.TIMESTAMP_MS,
                "the cast keeps its arrow target")
    assert_equal(_d(_simplify_expr(Expr.alias(_bin(BIN_OR, _c("b"), _b(False)), "p"))), "b as p")
    assert_equal(_d(_simplify_expr(_i(5))), "5")


def test_simplify_walks_every_node_kind() raises:
    """Catches: dropping the recursion of any node kind, the Scan-filter arm,
    or simplifying only the first Project expression."""
    var sf: Optional[Expr] = _bin(BIN_OR, _b(False), _c("b"))
    var scan = _scan("l.parquet", _left_schema(), sf^)
    var exprs = ExprArray()
    exprs.append(_c("a"))
    exprs.append(Expr.alias(Expr.unary(UN_NOT, Expr.unary(UN_NOT, _c("b"))), "nb"))
    var proj = LogicalPlan.project(exprs^, scan^)
    var filt = LogicalPlan.filter(_bin(BIN_AND, _c("b"), _b(True)), proj^)
    var rf: Optional[Expr] = _bin(BIN_AND, _c("y"), _b(True))
    var right = _scan("r.parquet", _right_schema(), rf^)
    var plan = _every_node_over(filt^, right^)

    var out = simplify_predicates(plan^)

    assert_equal(_render(out), "filter:b | project:a | project:b as nb | scan:b | scan:y")


def test_simplify_inplace_bare_scan_and_unhandled_tag() raises:
    """Catches: a Scan with no filter given one, and a rewrite under UNION."""
    var none: Optional[Expr] = None
    var plan = _scan("l.parquet", _left_schema(), none^)
    simplify_predicates_inplace(plan)
    assert_false(Bool(plan._scan.value()[].filter), "a bare scan gains no filter")

    var u = _union_over_filtered_scan(_bin(BIN_AND, _c("b"), _b(True)))
    simplify_predicates_inplace(u)
    assert_equal(_render(u), "scan:(b and true)")


# =============================================================================
# Rule 21: IN-clause rewrite
# =============================================================================

def test_in_collapses_same_column_or_chain() raises:
    """Catches: a chain not collapsed, values lost or reordered, either
    nesting direction refused, or a literal-on-the-left leaf skipped."""
    var left_nested = _bin(BIN_OR, _bin(BIN_OR, _bin(BIN_EQ, _c("a"), _i(1)),
                                        _bin(BIN_EQ, _c("a"), _i(2))),
                           _bin(BIN_EQ, _c("a"), _i(3)))
    assert_equal(_d(_rewrite_in_expr(left_nested^)), "a in [1,2,3]")
    var right_nested = _bin(BIN_OR, _bin(BIN_EQ, _c("a"), _i(1)),
                            _bin(BIN_OR, _bin(BIN_EQ, _c("a"), _i(2)),
                                 _bin(BIN_EQ, _c("a"), _i(3))))
    assert_equal(_d(_rewrite_in_expr(right_nested^)), "a in [1,2,3]")
    var lit_left = _bin(BIN_OR, _bin(BIN_EQ, _i(1), _c("a")), _bin(BIN_EQ, _c("a"), _i(2)))
    assert_equal(_d(_rewrite_in_expr(lit_left^)), "a in [1,2]")


def test_in_refuses_non_uniform_chains() raises:
    """Catches: collapsing an OR over two columns, over a non-equality, over
    `col = col`, over `lit = lit`, or over a bare boolean column (each would
    change the predicate's meaning)."""
    assert_equal(_d(_rewrite_in_expr(_bin(BIN_OR, _bin(BIN_EQ, _c("a"), _i(1)),
                                         _bin(BIN_EQ, _c("c"), _i(2))))),
                 "((a = 1) or (c = 2))")
    assert_equal(_d(_rewrite_in_expr(_bin(BIN_OR, _bin(BIN_EQ, _c("a"), _i(1)),
                                         _bin(BIN_GT, _c("a"), _i(2))))),
                 "((a = 1) or (a > 2))")
    assert_equal(_d(_rewrite_in_expr(_bin(BIN_OR, _bin(BIN_EQ, _c("a"), _c("c")),
                                         _bin(BIN_EQ, _c("a"), _i(1))))),
                 "((a = c) or (a = 1))")
    assert_equal(_d(_rewrite_in_expr(_bin(BIN_OR, _bin(BIN_EQ, _i(1), _i(1)),
                                         _bin(BIN_EQ, _c("a"), _i(2))))),
                 "((1 = 1) or (a = 2))")
    assert_equal(_d(_rewrite_in_expr(_bin(BIN_OR, _bin(BIN_EQ, _c("a"), _i(1)), _c("b")))),
                 "((a = 1) or b)")


def test_in_recurses_through_wrappers() raises:
    """Catches: no recursion under AND, under a non-uniform OR (either side),
    under NOT, CAST (and the CAST losing its arrow target) or an alias."""
    var two = _bin(BIN_OR, _bin(BIN_EQ, _c("a"), _i(1)), _bin(BIN_EQ, _c("a"), _i(2)))
    assert_equal(_d(_rewrite_in_expr(_bin(BIN_AND, two.copy(), _c("b")))), "(a in [1,2] and b)")
    assert_equal(_d(_rewrite_in_expr(_bin(BIN_OR, _bin(BIN_AND, _c("b"), two.copy()), _c("y")))),
                 "((b and a in [1,2]) or y)")
    var c34 = _bin(BIN_OR, _bin(BIN_EQ, _c("c"), _i(3)), _bin(BIN_EQ, _c("c"), _i(4)))
    assert_equal(_d(_rewrite_in_expr(_bin(BIN_OR, two.copy(), c34^))), "(a in [1,2] or c in [3,4])")
    assert_equal(_d(_rewrite_in_expr(Expr.unary(UN_NOT, two.copy()))), "not(a in [1,2])")
    assert_equal(_d(_rewrite_in_expr(Expr.alias(two.copy(), "p"))), "a in [1,2] as p")
    var cast = _rewrite_in_expr(Expr.cast_to_arrow(two.copy(), ArrowType.TIMESTAMP_MS))
    assert_equal(_d(cast), "cast(a in [1,2])")
    assert_true(cast.cast_target_arrow() == ArrowType.TIMESTAMP_MS,
                "the cast keeps its arrow target")
    assert_equal(_d(_rewrite_in_expr(_bin(BIN_EQ, _c("a"), _i(1)))), "(a = 1)")
    assert_equal(_d(_rewrite_in_expr(_c("a"))), "a")


def test_in_list_edge_folds() raises:
    """Catches: `x IN ()` not folded to FALSE; `x IN (v)` not turned into
    `x = v` (or turned into `v = x`); a two-value list rewritten."""
    var empty = List[ScalarValue]()
    assert_equal(_d(_rewrite_in_expr(Expr.in_list_node(_c("a"), empty^))), "false")
    var one: List[ScalarValue] = [ScalarValue.from_int(5)]
    assert_equal(_d(_rewrite_in_expr(Expr.in_list_node(_c("a"), one^))), "(a = 5)")
    var two: List[ScalarValue] = [ScalarValue.from_int(1), ScalarValue.from_int(2)]
    assert_equal(_d(_rewrite_in_expr(Expr.in_list_node(_c("a"), two^))), "a in [1,2]")


def test_in_chain_helpers() raises:
    """Catches, in the helpers the rewrite trusts: a `col = col` or `lit = lit`
    leaf accepted, a non-equality accepted, the column taken from the wrong
    side, and values collected from leaves that carry none."""
    assert_true(_is_col_eq_literal(_bin(BIN_EQ, _c("a"), _i(1))), "a = 1")
    assert_true(_is_col_eq_literal(_bin(BIN_EQ, _i(1), _c("a"))), "1 = a")
    assert_false(_is_col_eq_literal(_bin(BIN_EQ, _c("a"), _c("c"))), "a = c")
    assert_false(_is_col_eq_literal(_bin(BIN_EQ, _i(1), _i(2))), "1 = 2")
    assert_false(_is_col_eq_literal(_bin(BIN_GT, _c("a"), _i(1))), "a > 1")
    assert_false(_is_col_eq_literal(_c("a")), "a")

    assert_equal(_get_eq_col_name(_bin(BIN_EQ, _c("a"), _i(1))), "a")
    assert_equal(_get_eq_col_name(_bin(BIN_EQ, _i(1), _c("a"))), "a")
    assert_equal(_get_eq_col_name(_bin(BIN_EQ, _c("a"), _c("c"))), "")
    assert_equal(_get_eq_col_name(_bin(BIN_GT, _c("a"), _i(1))), "")
    assert_equal(_get_eq_col_name(_c("a")), "")

    assert_equal(_get_eq_chain_col(_c("a")), "")
    assert_equal(_get_eq_chain_col(_bin(BIN_GT, _c("a"), _i(1))), "")
    assert_equal(_get_eq_chain_col(_bin(BIN_OR, _bin(BIN_EQ, _c("a"), _i(1)),
                                        _bin(BIN_EQ, _c("c"), _i(2)))), "a")

    assert_equal(_count_or_eq_chain(_c("a")), 0)
    assert_equal(_count_or_eq_chain(_bin(BIN_EQ, _c("a"), _i(1))), 1)
    assert_equal(_count_or_eq_chain(_bin(BIN_EQ, _c("a"), _c("c"))), 0)
    assert_equal(_count_or_eq_chain(_bin(BIN_GT, _c("a"), _i(1))), 0)

    var none = List[ScalarValue]()
    _collect_or_eq_values(_c("a"), none)
    _collect_or_eq_values(_bin(BIN_GT, _c("a"), _i(1)), none)
    _collect_or_eq_values(_bin(BIN_EQ, _c("a"), _c("c")), none)
    assert_equal(len(none), 0, "no values from non-leaves")
    var vals = List[ScalarValue]()
    _collect_or_eq_values(_bin(BIN_OR, _bin(BIN_EQ, _c("a"), _i(1)),
                               _bin(BIN_EQ, _i(2), _c("a"))), vals)
    assert_equal(len(vals), 2)
    assert_equal(Int(vals[0].int_val), 1)
    assert_equal(Int(vals[1].int_val), 2)


def test_in_walks_every_node_kind() raises:
    """Catches: dropping the recursion of any node kind, or rewriting only
    the first Project expression. (The rule has no Scan arm: a Scan is a
    leaf to it.)"""
    var none: Optional[Expr] = None
    var scan = _scan("l.parquet", _left_schema(), none^)
    var exprs = ExprArray()
    exprs.append(_c("a"))
    exprs.append(Expr.alias(_bin(BIN_OR, _bin(BIN_EQ, _c("c"), _i(3)),
                                 _bin(BIN_EQ, _c("c"), _i(4))), "p"))
    var proj = LogicalPlan.project(exprs^, scan^)
    var filt = LogicalPlan.filter(_bin(BIN_OR, _bin(BIN_EQ, _c("a"), _i(1)),
                                       _bin(BIN_EQ, _c("a"), _i(2))), proj^)
    var none_r: Optional[Expr] = None
    var rscan = _scan("r.parquet", _right_schema(), none_r^)
    var right = LogicalPlan.filter(_bin(BIN_OR, _bin(BIN_EQ, _c("x"), _i(7)),
                                        _bin(BIN_EQ, _c("x"), _i(8))), rscan^)
    var plan = _every_node_over(filt^, right^)

    var out = rewrite_in_clauses(plan^)

    assert_equal(_render(out),
                 "filter:a in [1,2] | project:a | project:c in [3,4] as p | filter:x in [7,8]")


def test_in_inplace_unhandled_tag() raises:
    """Catches: a rewrite under UNION, which the rule has no arm for."""
    var u = _union_over_filtered_scan(_bin(BIN_OR, _bin(BIN_EQ, _c("a"), _i(1)),
                                           _bin(BIN_EQ, _c("a"), _i(2))))
    rewrite_in_clauses_inplace(u)
    assert_true(u.tag == PLAN_UNION, "the union is unchanged")
    assert_equal(_render(u), "scan:((a = 1) or (a = 2))")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
