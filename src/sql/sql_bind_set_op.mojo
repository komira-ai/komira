# =============================================================================
# sql/sql_bind_set_op.mojo
#   Set-operation chains: `<select> UNION [ALL] | INTERSECT | EXCEPT <select>`
#   bound with DuckDB's precedence; UNION bound onto a distinct over a union,
#   INTERSECT / EXCEPT onto a union, a grouped aggregation and a filter.
# =============================================================================
#
# The parser leaves a chain flat: the head SELECT and a linked list of branches
# in the top-level subquery table, each branch's `kind` the operator joining it
# to the branches before it. `_bind_set_chain` binds every branch, then folds
# as DuckDB does: INTERSECT binds tighter than UNION, UNION ALL and EXCEPT, and
# each level folds left to right, so `a UNION ALL b INTERSECT c EXCEPT d` is
# `(a UNION ALL (b INTERSECT c)) EXCEPT d`. Adjacent UNION ALL inputs make one
# `PLAN_UNION` with a child each, and a chain of UNION ALL alone binds exactly
# as it did before INTERSECT and EXCEPT existed.
#
# UNION (bare, or UNION DISTINCT) takes everything to its left as its left
# input, as EXCEPT does: the run of inputs before it and its right input make
# one `PLAN_UNION`, under a `PLAN_DISTINCT` over every column (no column list,
# as SELECT DISTINCT binds). So `a UNION ALL b UNION c` is
# `Distinct(Union(a, b, c))` and `a UNION b UNION ALL c` is
# `Union(Distinct(Union(a, b)), c)`: a UNION ALL after a UNION keeps its
# duplicates. `a UNION b UNION c` is `Distinct(Union(Distinct(Union(a, b)),
# c))`. The distinct compares whole rows with NULLs equal; every NaN is one key
# and 0.0 and -0.0 are one key, as in SELECT DISTINCT (lowering's
# `cut_distinct` groups on every column). Two result columns of one name are
# refused by name, as for INTERSECT and EXCEPT below: the distinct names its
# columns.
#
# INTERSECT and EXCEPT (the set forms; the parser refuses the ALL forms) bind
# each pair to plan nodes the engine already runs:
#
#   Project(c1..cn)
#     Filter(INTERSECT: #set_lo = 0 AND #set_hi = 1 / EXCEPT: #set_hi = 0)
#       Aggregate(GROUP BY c1..cn; MIN(#set_side) AS #set_lo,
#                                  MAX(#set_side) AS #set_hi)
#         Union(Project(left, c1..cn, 0 AS #set_side),
#               Project(right, c1..cn, 1 AS #set_side))
#
# A group is one distinct row. Its #set_lo is 0 when the left input has it and
# its #set_hi is 1 when the right input has it, so INTERSECT keeps the rows of
# both inputs and EXCEPT the rows of the left input alone, each once. The
# grouping compares whole rows with NULLs equal (a NULL key is a group of its
# own), as DuckDB's INTERSECT and EXCEPT do; every NaN is one key and 0.0 and
# -0.0 are one key, as in SELECT DISTINCT. The two inputs first take the common
# column types and the left input's names (`sql_bind_union`), as UNION ALL's
# do. A result column type the grouped sinks have no row for is refused by
# lowering by name, as for SELECT DISTINCT.
#
# EXCEPT needs only #set_hi, so its aggregation computes MAX alone.
#
# Refused by name: two result columns of one name (the grouping and the outer
# projection name columns, so the second would read the first's values), and a
# result column named as one of the helper columns above. A SQL identifier
# cannot spell `#`, but a file's column can, and `SELECT *` passes it on.

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.agg_expr import AGG_MAX, AGG_MIN, AggExpr
from plan_expr.expr import BIN_AND, BIN_EQ, Expr
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import AggExprArray, ExprArray, LogicalPlan, PLAN_SCAN
from sql.sql_ast import SUBQ_INTERSECT, SUBQ_UNION, SUBQ_UNION_ALL, SelectStmt
from sql.sql_bind_scope import CteScope
from sql.sql_bind_union import _union_conform_branch, _union_merge_schema
from sql.sql_binder import _bind_select
from sql.sql_catalog import SqlCatalog
from std.builtin.swap import swap
from std.memory import OwnedPointer

comptime _SIDE: String = "#set_side"
comptime _LO: String = "#set_lo"
comptime _HI: String = "#set_hi"


def _bind_select_with_union(
    body: SelectStmt,
    top: SelectStmt,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
    result_names: Bool,
) raises -> LogicalPlan:
    """Bind `body`, a SELECT that may head a set-operation chain, to a plan: the
    SELECT's own plan when `body.union_all_idx < 0`, else the chain's plan. The
    chain's branch bodies live in `top.subqueries` (the top-level statement's
    table, which `body.union_all_idx` indexes)."""
    var head = _bind_select(
        body, catalog, cte_scope, prebound, result_names,
        body.union_all_idx >= 0,
    )
    if body.union_all_idx < 0:
        return head^
    return _bind_set_chain(
        head^, top, body.union_all_idx, catalog, cte_scope, prebound
    )


def _take(mut slot: LogicalPlan) -> LogicalPlan:
    """The plan in `slot`, leaving an empty scan in its place."""
    var taken = LogicalPlan(PLAN_SCAN, Schema())
    swap(taken, slot)
    return taken^


def _bind_set_chain(
    var head: LogicalPlan,
    top: SelectStmt,
    first_idx: Int,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> LogicalPlan:
    """`<select> <op> <select> [<op> ...]` -> one plan, with DuckDB's
    precedence (module header).

    Iterative: the branch bodies live in the top-level statement's
    `subqueries` table, so the chain is a linked list of indices into one
    table, walked with a loop. Recursing through each branch body would
    re-enter `_bind_select` from inside itself, a shape the Mojo compiler
    hangs on.

    Each branch's bare integer result literals are INT32 as in a lone SELECT,
    so `SELECT 1 UNION ALL SELECT 5000000000` widens to BIGINT. Branch numbers
    in errors count from 1 at the head, in the order the query spells them.
    """
    # Bind every branch, in order. kinds[i] joins branch i + 1 to the ones
    # before it; kinds[0] is unused.
    var plans = List[OwnedPointer[LogicalPlan]]()
    var kinds = List[UInt8]()
    plans.append(OwnedPointer(head^))
    kinds.append(SUBQ_UNION_ALL)
    var idx = first_idx
    while idx >= 0:
        ref sd = top.subqueries[idx]
        var plan = _bind_select(
            sd.body, catalog, cte_scope, prebound, False, True
        )
        plans.append(OwnedPointer(plan^))
        kinds.append(sd.kind)
        idx = sd.body.union_all_idx

    # INTERSECT first: each one folds its right branch into the term on its
    # left. A term records the operator joining it to the terms before it and
    # the number of its first branch.
    var terms = List[OwnedPointer[LogicalPlan]]()
    var term_kinds = List[UInt8]()
    var term_first = List[Int]()
    for i in range(len(plans)):
        if i > 0 and kinds[i] == SUBQ_INTERSECT:
            var last = len(terms) - 1
            var left = _take(terms[last][])
            var right = _take(plans[i][])
            terms[last][] = _bind_set_pair(
                SUBQ_INTERSECT, left^, term_first[last], right^, i + 1
            )
        else:
            terms.append(OwnedPointer(_take(plans[i][])))
            term_kinds.append(kinds[i])
            term_first.append(i + 1)

    # Then UNION ALL, UNION and EXCEPT, left to right: a run of UNION ALL
    # terms is one union node; a UNION closes the run with its right input
    # under a distinct, and an EXCEPT takes everything to its left as its left
    # input.
    var run = List[OwnedPointer[LogicalPlan]]()
    var run_first = List[Int]()
    var run_ops = List[String]()
    for j in range(len(terms)):
        if j == 0 or term_kinds[j] == SUBQ_UNION_ALL:
            run.append(OwnedPointer(_take(terms[j][])))
            run_first.append(term_first[j])
            run_ops.append(String("UNION ALL"))
        elif term_kinds[j] == SUBQ_UNION:
            run.append(OwnedPointer(_take(terms[j][])))
            run_first.append(term_first[j])
            run_ops.append(String("UNION"))
            var deduped = _union_distinct_of(run^, run_first, run_ops)
            run = List[OwnedPointer[LogicalPlan]]()
            run.append(OwnedPointer(deduped^))
            run_first = List[Int]()
            run_first.append(1)
            run_ops = List[String]()
            run_ops.append(String("UNION ALL"))
        else:
            var left = _union_all_of(run^, run_first, run_ops)
            var right = _take(terms[j][])
            var pair = _bind_set_pair(
                term_kinds[j], left^, 1, right^, term_first[j]
            )
            run = List[OwnedPointer[LogicalPlan]]()
            run.append(OwnedPointer(pair^))
            run_first = List[Int]()
            run_first.append(1)
            run_ops = List[String]()
            run_ops.append(String("UNION ALL"))
    return _union_all_of(run^, run_first, run_ops)


def _union_all_of(
    var inputs: List[OwnedPointer[LogicalPlan]],
    firsts: List[Int],
    ops: List[String],
) raises -> LogicalPlan:
    """The UNION ALL of `inputs` (the first starting at branch 1, input `k` at
    branch `firsts[k]`, joined to the inputs before it by the operator
    `ops[k]`, which errors name): the one input itself, else one `PLAN_UNION`
    with a child per input, each conformed to the common column types and the
    first input's names."""
    if len(inputs) == 1:
        return _take(inputs[0][])
    var out_schema = inputs[0][].output_schema.copy()
    for k in range(1, len(inputs)):
        out_schema = _union_merge_schema(
            out_schema, inputs[k][].output_schema, firsts[k], ops[k]
        )
    for k in range(len(inputs)):
        var taken = _take(inputs[k][])
        inputs[k][] = _union_conform_branch(taken^, out_schema, firsts[k])
    return LogicalPlan.union(inputs^, out_schema^)


def _union_distinct_of(
    var inputs: List[OwnedPointer[LogicalPlan]],
    firsts: List[Int],
    ops: List[String],
) raises -> LogicalPlan:
    """`inputs` (two or more, the last joined by a UNION) as one union under a
    `PLAN_DISTINCT` over every column (module header)."""
    var union = _union_all_of(inputs^, firsts, ops)
    var schema = union.output_schema.copy()
    for i in range(schema.num_columns()):
        for j in range(i + 1, schema.num_columns()):
            if schema.field_name(i) == schema.field_name(j):
                raise Error(
                    "SQL not supported: UNION over two columns named `"
                    + String(schema.field_name(i)) + "`. Rows are compared by"
                    " column name, so the second would be read as the first."
                    " Give the two columns distinct aliases."
                )
    var all_columns: Optional[List[String]] = None
    return LogicalPlan.distinct(all_columns^, union^)


def _bind_set_pair(
    kind: UInt8,
    var left: LogicalPlan,
    left_first: Int,
    var right: LogicalPlan,
    right_first: Int,
) raises -> LogicalPlan:
    """`left INTERSECT right` or `left EXCEPT right` (`kind`), the set forms,
    as the module header's union, aggregation, filter and projection.
    `left` starts at branch `left_first` and `right` at `right_first`."""
    var op = String("INTERSECT") if kind == SUBQ_INTERSECT else String("EXCEPT")
    var schema = _union_merge_schema(
        left.output_schema, right.output_schema, right_first, op, left_first
    )
    var n = schema.num_columns()
    for i in range(n):
        var name = String(schema.field_name(i))
        if name == _SIDE or name == _LO or name == _HI:
            raise Error(
                "SQL not supported: " + op + " over a column named `" + name
                + "`, the name of a column the " + op + " plan adds. Rename"
                " the column."
            )
        for j in range(i + 1, n):
            if name == String(schema.field_name(j)):
                raise Error(
                    "SQL not supported: " + op + " over two columns named `"
                    + name + "`. Rows are compared by column name, so the"
                    " second would be read as the first. Give the two columns"
                    " distinct aliases."
                )
    # The names are unique (checked above), so the conform's refusal of a
    # branch with two columns of one name cannot fire here.
    var l = _union_conform_branch(left^, schema, left_first)
    var r = _union_conform_branch(right^, schema, right_first)
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_tag_side(l^, schema, 0)))
    children.append(OwnedPointer(_tag_side(r^, schema, 1)))
    var union_fields = SchemaBuilder()
    for i in range(n):
        union_fields.add_field(schema.field_at(i))
    union_fields.add_field(Field(String(_SIDE), ArrowType.INT32, False))
    var union = LogicalPlan.union(children^, union_fields.build())

    var groups = ExprArray()
    for i in range(n):
        groups.append(Expr.col_ref(String(schema.field_name(i))))
    var aggs = AggExprArray()
    if kind == SUBQ_INTERSECT:
        aggs.append(
            AggExpr(
                AGG_MIN, Optional(Expr.col_ref(_SIDE)), Optional(String(_LO))
            )
        )
    aggs.append(
        AggExpr(AGG_MAX, Optional(Expr.col_ref(_SIDE)), Optional(String(_HI)))
    )
    var grouped = LogicalPlan.aggregate(groups^, aggs^, union^)

    # EXCEPT: no row of the group came from the right input.
    var keep = Expr.binary(BIN_EQ, Expr.col_ref(_HI), _side_literal(0))
    if kind == SUBQ_INTERSECT:
        # INTERSECT: a row of the group came from each input.
        keep = Expr.binary(
            BIN_AND,
            Expr.binary(BIN_EQ, Expr.col_ref(_LO), _side_literal(0)),
            Expr.binary(BIN_EQ, Expr.col_ref(_HI), _side_literal(1)),
        )
    var kept = LogicalPlan.filter(keep^, grouped^)

    var out = ExprArray()
    for i in range(n):
        out.append(Expr.col_ref(String(schema.field_name(i))))
    return LogicalPlan.project(out^, kept^)


def _side_literal(side: Int32) -> Expr:
    """The INT32 literal `side` (0 for the left input, 1 for the right)."""
    return Expr.literal(ScalarValue.from_int32(side))


def _tag_side(var plan: LogicalPlan, schema: Schema, side: Int32) -> LogicalPlan:
    """`plan`, whose columns are `schema`'s, under a projection that keeps
    every column and adds `side AS #set_side`."""
    var exprs = ExprArray()
    for i in range(schema.num_columns()):
        exprs.append(Expr.col_ref(String(schema.field_name(i))))
    exprs.append(Expr.alias(_side_literal(side), String(_SIDE)))
    return LogicalPlan.project(exprs^, plan^)
