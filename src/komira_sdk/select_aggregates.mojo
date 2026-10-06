# =============================================================================
# select_aggregates — polars' `select` of AGGREGATES is a ONE-ROW reduction
# (2026-09-25)
# =============================================================================
#
# polars 1.44.2: `lf.select(pl.col("v").min(), pl.col("v").max())` answers ONE
# row — every expression reduces the frame, so the frame reduces. DuckDB asks
# the same question as `SELECT min(v), max(v) FROM t`, an AGGREGATE with no
# group keys. The untyped Mojo door spells it
# `select([col("v").min().alias("lo"), col("v").max().alias("hi")])`, and
# `PlanCarrier.select` lowered it to a PROJECT of two aggregate-as-expression
# nodes: MEASURED (the harness lane's `agg_minmax_expr`), SIX rows of
# NULL, null-typed — a silent wrong answer.
#
# `select_as_aggregate` recognises the shape — EVERY expression an
# `EXPR_AGG_FN`, optionally under ONE alias — and hands `PlanCarrier.select`
# the `AggExprArray` of the 0-key AGGREGATE that `group_by([]).agg([...])`
# builds: the same node, named by the same polars rule
# (`author_polars_agg_names`).
#
# ★ AND THE MIXED SHAPE (2026-09-25): a plain column BESIDE an
# aggregate — `select([col("k"), col("v").max().alias("hi")])` — is polars'
# BROADCAST (every row gets the frame's max). As a projection it answered
# `hi` NULL on every row, null-typed (MEASURED, LOCAL darwin probe): a second
# silent wrong answer. `broadcast_aggregates` rewrites each top-level
# aggregate to a WINDOW over the whole frame (`.over([])`, SQL's
# `max(v) OVER ()`), which is exactly polars' broadcast and DuckDB's answer.
# An aggregate inside arithmetic is not rewritten (not this shape).
#
# ★ `bind_agg_operands` — `GroupedCarrier.agg` (and this module's 0-key
# route) re-decide each aggregate's OPERAND over the input schema, as every
# other carrier verb does since `col_expr_bind`: `(col("x") // 0).sum()` in a
# `group_by` summed +-inf / NaN over a DOUBLE where DuckDB sums NULL (NULL),
# and `(col("d") // 4).sum()` over a DECIMAL raised unnamed (MEASURED).
#
# ★ AN AGGREGATE INSIDE AN EXPRESSION (2026-09-25; the round-1
# adversarial review). The engine evaluates an
# aggregate-as-expression inside a projection or a filter by folding the
# RESIDENT BATCH (`compiler_eval_column`'s tag-12 arm, built for a filter
# directly above an aggregate), so over a scan every such shape answered
# wrong, and silently. MEASURED (LOCAL darwin probes; polars 1.44.2 and
# DuckDB 1.5.3 agree on every right answer):
#
#   select([(col("v").max() - col("v").min()).alias("r")])   6 NULL rows, null-typed   (1 row: 10)
#   select([col("k"), (col("v") - col("v").mean()).alias("d")])
#                            GARBAGE int64 (the bits of 1.3333: declared int64,
#                            computed float64)                            (1.3333, NULL, ...)
#   filter(col("v") > col("v").mean())   over 3 row groups     0 rows   (100000 of 300000)
#
# `hoist_aggregates` lifts every aggregate out of the expression into a
# hidden column (`HIDDEN_AGG_PREFIX` + i) and the verb reads that column
# instead:
#   * nothing but aggregates (and literals) in the whole `select` -> the
#     0-key AGGREGATE computes them, a PROJECT above computes the
#     expressions (polars reduces the frame to ONE row, DuckDB's
#     `SELECT max(v) - min(v) FROM t`);
#   * beside a column, in `with_columns`, in a `filter` -> a PARTITION_BY
#     node with no keys adds each as a window over the WHOLE frame
#     (`max(v) OVER ()`, polars' broadcast), the verb reads it, and a final
#     PROJECT drops the hidden columns.
# The walk rebuilds alias / binary / unary / cast / math / CASE nodes; an
# aggregate under any other node is not seen (it keeps the batch fold). An
# aggregate of a COMPUTED operand cannot be a window (the window names one
# input column), so on the broadcast routes it is REFUSED BY NAME; the
# reduction serves it. An unaliased expression over aggregates whose
# leftmost leaf is not a column (polars names it `literal`) is refused by
# name, never answered as a projection. A `filter` directly above an AGGREGATE is left to the
# optimizer's scalar broadcast (`optimizer_scalar_broadcast`), which serves
# ONE aggregate of a plain column under Binary / Unary / Cast / Alias /
# StringOp; under a MathFn / CASE it rewrites the plan (round 3) but
# the in-memory filter gate then declines it, NAMED by the envelope. (Widening that gate answers 0 ROWS over a whole-frame window's
# output; the finding is in commit "fix(optimizer scalar broadcast + a
# trunk-red test)".)
#
# ⛔ The broadcast route's window kernel (`eval_full_partition_agg`) served
# INT64 / FLOAT64 only, so a hoisted aggregate over an INT32 / FLOAT32 column
# failed with the kernel's text; since round 3 it widens INT8/16/32
# and FLOAT32 exactly (`partition_frame_widen`). A
# DECIMAL, DATE or STRING operand is REFUSED BY NAME at the verb
# (`_refuse_unserved_window_operands`; MEASURED by the
# round-3 review: `filter(d > d.mean())`, `s == s.max()`, `dt == dt.max()`).
# =============================================================================

from komira_arrow.schema import Schema
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.agg_expr import AGG_COUNT
from komira_plan_expr.expr import (
    Expr, WhenCaseData,
    EXPR_AGG_FN, EXPR_ALIAS, EXPR_BINARY_OP, EXPR_UNARY_OP, EXPR_CAST,
    EXPR_MATH_FN, EXPR_MATH_FN2, EXPR_WHEN, EXPR_COL_REF,
)
from komira_plan_expr.expr_walk import walk_expr_column_refs, ordered_name_sink
from komira_plan_expr.agg_expr import AggExpr
from komira_plan_ir.logical_plan import ExprArray, AggExprArray, LogicalPlan
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.col_expr_bind import (
    bind_unbound_expr, bind_unbound_exprs, over_refusal,
)

from .agg_output_naming import (
    author_polars_agg_names, polars_agg_out_name, polars_root_name,
)


def _agg_of(agg: Expr, var name: Optional[String]) -> AggExpr:
    """The `AggExpr` an aggregate-as-expression node names: its op, its child
    as built (`bind_agg_operands` re-decides it AFTER the names are authored)
    and the alias, if any."""
    var child = Optional[Expr](agg.agg_fn_child_ref().copy())
    return AggExpr(agg.agg_fn_op(), child^, name^)


def select_as_aggregate(
    exprs: ExprArray, schema: Schema, mut why: String
) -> Optional[AggExprArray]:
    """The 0-key aggregate `exprs` IS, when every one of them is an aggregate
    (`col(v).min()`, `col(v).sum().alias("s")`, ...); None otherwise. When
    this surface's naming refuses one of them (an unaliased aggregate whose
    argument's LEFTMOST leaf is not a column, `lit(1).sum()` -- polars names
    it `literal`) this returns None with the refusal in `why`, and the
    caller REFUSES BY NAME. ⛔ It used to fall back
    to the projection path, which answered one NULL row per input row (the
    review: `select([col("x").sqrt().sum()])`, before
    `polars_root_name` learned the function arms)."""
    if len(exprs) == 0:
        return None
    var aggs = AggExprArray()
    for i in range(len(exprs)):
        ref e = exprs[i]
        if e.tag == EXPR_AGG_FN:
            aggs.append(_agg_of(e, None))
        elif e.tag == EXPR_ALIAS and e.alias_child_ref().tag == EXPR_AGG_FN:
            aggs.append(
                _agg_of(e.alias_child_ref(), Optional(e.alias_name()))
            )
        else:
            return None
    try:
        author_polars_agg_names(aggs)
    except e:
        why = String(e)
        return None
    bind_agg_operands(aggs, schema)
    return aggs^


def bind_agg_operands(mut aggs: AggExprArray, schema: Schema):
    """Re-decide every aggregate's operand(s) over `schema` (`col_expr_bind`,
    no float narrowing: an operand is not an output column's value). Names
    must be authored BEFORE this (the polars root name reads the tree as
    the customer built it)."""
    for i in range(len(aggs)):
        ref ae = aggs[i]
        if ae.child:
            ae.child = Optional[Expr](
                bind_unbound_expr(ae.child.value(), schema, False)
            )
        if ae.child1:
            ae.child1 = Optional[Expr](
                bind_unbound_expr(ae.child1.value(), schema, False)
            )
        if ae.child2:
            ae.child2 = Optional[Expr](
                bind_unbound_expr(ae.child2.value(), schema, False)
            )
        if ae.child3:
            ae.child3 = Optional[Expr](
                bind_unbound_expr(ae.child3.value(), schema, False)
            )


def _is_top_aggregate(e: Expr) -> Bool:
    if e.tag == EXPR_AGG_FN:
        return True
    return e.tag == EXPR_ALIAS and e.alias_child_ref().tag == EXPR_AGG_FN


def broadcast_aggregates(
    exprs: ExprArray, beside_the_frame: Bool, mut why: String
) -> Optional[ExprArray]:
    """polars' BROADCAST: every top-level aggregate (optionally aliased)
    becomes a window over the WHOLE frame (`.over([])`), named as polars
    names it (its alias, else its root column). None when there is nothing
    to broadcast: no aggregate, or — for `select` (`beside_the_frame`
    False) — ONLY aggregates, which is `select_as_aggregate`'s ONE-row
    reduction. `with_columns` passes True: its aggregates always sit beside
    the frame's own columns. An aggregate `.over()` cannot serve (a computed
    operand) carries its named refusal, as any `.over()` does. An unaliased
    aggregate whose argument's leftmost leaf is not a column returns None
    with the refusal in `why` (⛔ it was kept as built, a NULL column: the review)."""
    var n_agg = 0
    for i in range(len(exprs)):
        if _is_top_aggregate(exprs[i]):
            n_agg += 1
    if n_agg == 0 or (n_agg == len(exprs) and not beside_the_frame):
        return None
    var out = ExprArray()
    for i in range(len(exprs)):
        ref e = exprs[i]
        if not _is_top_aggregate(e):
            out.append(e.copy())
            continue
        var name: String
        var agg: Expr
        if e.tag == EXPR_ALIAS:
            name = e.alias_name()
            agg = e.alias_child_ref().copy()
        else:
            var root = polars_root_name(e.agg_fn_child_ref())
            if not root:
                why = _owned(_UNNAMED)
                return None
            name = polars_agg_out_name(e.agg_fn_op(), True, String(root.value()))
            agg = e.copy()
        out.append(Expr.alias(agg^.over(List[String]()), name))
    return out^


# =============================================================================
# An aggregate INSIDE an expression (see the module header)
# =============================================================================

comptime HIDDEN_AGG_PREFIX = "__komira_agg_"

comptime _UNNAMED = (
    "an expression over an aggregate has no column as its LEFTMOST leaf"
    " (polars names it `literal`), and an unaliased expression over an"
    " aggregate here takes its name from that column. Name it with"
    " `.alias(\"...\")`"
)

comptime _COMPUTED_BROADCAST = (
    "an aggregate of a COMPUTED expression beside the frame's columns (polars'"
    " broadcast, e.g. `col(\"v\") - (col(\"v\") * 2).mean()`) is not"
    " served: the whole-frame window it needs names one input column, and a"
    " window over a column an earlier verb computed is outside the window"
    " executor's envelope. A `select` of nothing but"
    " aggregates reduces the frame and is served"
)


def _owned(msg: StaticString) -> String:
    """A HEAP copy of a refusal sentence. ⛔ `String(<comptime literal>)` of
    the long sentences above reaches `abort` as GARBAGE (MEASURED, a
    review, Mojo 1.0.0 darwin: `filter(col("x") > (col("x") * 2).mean())`
    died SIGBUS with no message; a 20-line repro prints `ABORT: ...: :`), while
    a string APPENDED into a fresh `String` aborts intact."""
    var s = String()
    s += msg
    return s^


def _rebuildable(tag: UInt8) -> Bool:
    return (
        tag == EXPR_ALIAS or tag == EXPR_BINARY_OP or tag == EXPR_UNARY_OP
        or tag == EXPR_CAST or tag == EXPR_MATH_FN or tag == EXPR_MATH_FN2
        or tag == EXPR_WHEN
    )


def has_aggregate(e: Expr) -> Bool:
    """True when an aggregate-as-expression sits in `e` under nodes
    `hoist_aggregates` rebuilds (or is `e`)."""
    if e.tag == EXPR_AGG_FN:
        return True
    if e.tag == EXPR_ALIAS:
        return has_aggregate(e.alias_child_ref())
    if e.tag == EXPR_BINARY_OP:
        return has_aggregate(e.binary_left_ref()) or has_aggregate(
            e.binary_right_ref()
        )
    if e.tag == EXPR_UNARY_OP:
        return has_aggregate(e.unary_child_ref())
    if e.tag == EXPR_CAST:
        return has_aggregate(e.cast_child_ref())
    if e.tag == EXPR_MATH_FN:
        return has_aggregate(e.math_fn_child_ref())
    if e.tag == EXPR_MATH_FN2:
        return has_aggregate(e.math_fn2_left_ref()) or has_aggregate(
            e.math_fn2_right_ref()
        )
    if e.tag == EXPR_WHEN:
        for i in range(e.when_num_cases()):
            if has_aggregate(e.when_case_condition_ref(i)) or has_aggregate(
                e.when_case_result_ref(i)
            ):
                return True
        return has_aggregate(e.when_default_ref())
    return False


def reads_a_row(e: Expr) -> Bool:
    """True when `e` reads a column OUTSIDE every aggregate (a row-wise
    value: the expression cannot reduce the frame)."""
    if e.tag == EXPR_AGG_FN:
        return False
    if e.tag == EXPR_COL_REF:
        return True
    if e.tag == EXPR_ALIAS:
        return reads_a_row(e.alias_child_ref())
    if e.tag == EXPR_BINARY_OP:
        return reads_a_row(e.binary_left_ref()) or reads_a_row(
            e.binary_right_ref()
        )
    if e.tag == EXPR_UNARY_OP:
        return reads_a_row(e.unary_child_ref())
    if e.tag == EXPR_CAST:
        return reads_a_row(e.cast_child_ref())
    if e.tag == EXPR_MATH_FN:
        return reads_a_row(e.math_fn_child_ref())
    if e.tag == EXPR_MATH_FN2:
        return reads_a_row(e.math_fn2_left_ref()) or reads_a_row(
            e.math_fn2_right_ref()
        )
    if e.tag == EXPR_WHEN:
        for i in range(e.when_num_cases()):
            if reads_a_row(e.when_case_condition_ref(i)):
                return True
            if reads_a_row(e.when_case_result_ref(i)):
                return True
        return reads_a_row(e.when_default_ref())
    var names = List[String]()
    var sink = ordered_name_sink(names)
    walk_expr_column_refs(e, sink)
    return len(names) > 0


def hoist_aggregates(e: Expr, mut aggs: List[Expr]) -> Expr:
    """`e` with every aggregate-as-expression replaced by a reference to the
    hidden column `HIDDEN_AGG_PREFIX` + i, the aggregate appended to `aggs`
    (i is its index there). Rebuilds the nodes `has_aggregate` walks; any
    other node is returned as built."""
    if e.tag == EXPR_AGG_FN:
        var name = String(HIDDEN_AGG_PREFIX) + String(len(aggs))
        aggs.append(e.copy())
        return Expr.col_ref(name)
    if e.tag == EXPR_ALIAS:
        return Expr.alias(
            hoist_aggregates(e.alias_child_ref(), aggs), e.alias_name()
        )
    if e.tag == EXPR_BINARY_OP:
        var l = hoist_aggregates(e.binary_left_ref(), aggs)
        var r = hoist_aggregates(e.binary_right_ref(), aggs)
        return Expr.binary_with_division_intent(
            e.binary_op(), l^, r^, e.binary_division_intent()
        )
    if e.tag == EXPR_UNARY_OP:
        return Expr.unary(e.unary_op(), hoist_aggregates(e.unary_child_ref(), aggs))
    if e.tag == EXPR_CAST:
        return Expr.cast_preserving_arrow(
            hoist_aggregates(e.cast_child_ref(), aggs), e
        )
    if e.tag == EXPR_MATH_FN:
        return Expr.math_fn(
            e.math_fn_op(), hoist_aggregates(e.math_fn_child_ref(), aggs)
        )
    if e.tag == EXPR_MATH_FN2:
        var l = hoist_aggregates(e.math_fn2_left_ref(), aggs)
        var r = hoist_aggregates(e.math_fn2_right_ref(), aggs)
        return Expr.math_fn2(e.math_fn2_op(), l^, r^)
    if e.tag == EXPR_WHEN:
        var cases = List[WhenCaseData]()
        for i in range(e.when_num_cases()):
            var c = hoist_aggregates(e.when_case_condition_ref(i), aggs)
            var r = hoist_aggregates(e.when_case_result_ref(i), aggs)
            cases.append(WhenCaseData(c^, r^))
        return Expr.when(cases^, hoist_aggregates(e.when_default_ref(), aggs))
    return e.copy()


def has_nested_aggregate(exprs: ExprArray) -> Bool:
    """True when some expression carries an aggregate BELOW its top (under
    an optional alias) — the shapes `broadcast_aggregates` and
    `select_as_aggregate` do not take."""
    for i in range(len(exprs)):
        if has_aggregate(exprs[i]) and not _is_top_aggregate(exprs[i]):
            return True
    return False


def _output_name(e: Expr) -> Optional[String]:
    """polars' output name of a select / with_columns expression: its alias,
    else its root column (`polars_root_name`)."""
    if e.tag == EXPR_ALIAS:
        return Optional(e.alias_name())
    return polars_root_name(e)


def aggregate_expr_refusal(exprs: ExprArray, broadcast: Bool) -> String:
    """Why an expression list carrying aggregates cannot be served, or "".
    Every expression that carries an aggregate needs a polars output name;
    on a `broadcast` route every aggregate's operand must be a plain
    column."""
    for i in range(len(exprs)):
        if not has_aggregate(exprs[i]):
            continue
        if exprs[i].tag != EXPR_COL_REF and not _output_name(exprs[i]):
            return _owned(_UNNAMED)
        if broadcast:
            var aggs = List[Expr]()
            _ = hoist_aggregates(exprs[i], aggs)
            for j in range(len(aggs)):
                if not aggs[j].agg_fn_child_ref().is_col_ref():
                    return _owned(_COMPUTED_BROADCAST)
    return String("")


def predicate_aggregate_refusal(predicate: Expr) -> String:
    """`aggregate_expr_refusal` for a filter predicate (a broadcast route;
    the predicate needs no name)."""
    var aggs = List[Expr]()
    _ = hoist_aggregates(predicate, aggs)
    for j in range(len(aggs)):
        if not aggs[j].agg_fn_child_ref().is_col_ref():
            return _owned(_COMPUTED_BROADCAST)
    return String("")


def _named_hoisted(
    exprs: ExprArray, mut aggs: List[Expr], name_every: Bool
) -> ExprArray:
    """Each expression with its aggregates hoisted, aliased by polars' name
    when it carries an aggregate (or `name_every`) and is not a bare
    column. Precondition: `aggregate_expr_refusal` returned ""."""
    var out = ExprArray()
    for i in range(len(exprs)):
        ref e = exprs[i]
        if e.tag == EXPR_COL_REF:
            out.append(e.copy())
            continue
        var carries = has_aggregate(e)
        var body: Expr
        if e.tag == EXPR_ALIAS:
            body = hoist_aggregates(e.alias_child_ref(), aggs)
        else:
            body = hoist_aggregates(e, aggs)
        var name = _output_name(e)
        if name and (carries or name_every):
            out.append(Expr.alias(body^, name.value()))
        elif e.tag == EXPR_ALIAS:
            out.append(Expr.alias(body^, e.alias_name()))
        else:
            out.append(body^)
    return out^


def _column_refs(schema: Schema) -> ExprArray:
    var out = ExprArray()
    for c in range(schema.num_columns()):
        out.append(Expr.col_ref(schema.field_name(c)))
    return out^


def _refuse_unserved_window_operands(aggs: List[Expr], schema: Schema) raises:
    """REFUSE BY NAME a hoisted SUM / MEAN / MIN / MAX whose operand column
    the whole-frame window kernel does not serve (`eval_full_partition_agg`:
    INT8/16/32/64 and FLOAT32/64; COUNT takes any column). ⛔ Such an
    operand failed at run time with the kernel's own text ("full_partition_
    frame: unsupported type ...", MEASURED for DECIMAL / DATE / STRING by the
    round-2 review)."""
    for j in range(len(aggs)):
        var op = aggs[j].agg_fn_op()
        if op == AGG_COUNT:
            continue
        ref child = aggs[j].agg_fn_child_ref()
        if not child.is_col_ref():
            continue
        var name = child.col_ref_name()
        var t: ArrowType
        try:
            t = schema.field_arrow_type(schema.column_index(name))
        except:
            continue
        if (
            t == ArrowType.INT8 or t == ArrowType.INT16 or t == ArrowType.INT32
            or t == ArrowType.INT64 or t == ArrowType.FLOAT32
            or t == ArrowType.FLOAT64
        ):
            continue
        var s = String("an aggregate of the ")
        s += String(t)
        s += " column `"
        s += name
        s += (
            "` beside the frame's columns (polars' broadcast) is not served:"
            " the whole-frame window it needs takes an integer or float"
            " column. A `select` of nothing but"
            " aggregates reduces the frame and is served"
        )
        raise Error(s)


def _with_hidden_windows(
    var input: LogicalPlan, aggs: List[Expr]
) raises -> LogicalPlan:
    """`input`'s columns plus each aggregate as a window over the WHOLE frame
    (`agg OVER ()`), named `HIDDEN_AGG_PREFIX` + i: a PLAN_PARTITION_BY node
    with no keys.

    ⚠ A NODE, NOT A PROJECT OF `EXPR_WINDOW_FN`. MEASURED (LOCAL darwin, this
    lane's probe): a PROJECT reading `v - __komira_agg_0` over a PROJECT that
    computes `__komira_agg_0` as a window died with the unnamed
    "PipelineCompiler: unsupported projection expression tag: 13" -- the two
    projections are merged before the window rewrite runs, which leaves the
    window NESTED in arithmetic. The PartitionBy node is what that rewrite
    builds anyway, and it DECLARES each output's type (a PROJECT's window
    declares `null`), so the verb above binds over real
    types. Precondition: every aggregate's operand is a plain column."""
    _refuse_unserved_window_operands(aggs, input.output_schema)
    var parts = List[PartitionExpr]()
    for j in range(len(aggs)):
        var w = aggs[j].copy().over(List[String]())
        ref wd = w.window_fn_data_ref()
        parts.append(
            PartitionExpr(
                wd.func,
                wd.arg_col.copy(),
                wd.arg_offset,
                ScalarValue(),
                False,
                wd.frame.copy(),
                String(HIDDEN_AGG_PREFIX) + String(j),
            )
        )
    return LogicalPlan.partition_by(
        List[String](), List[String](), List[Bool](), parts^, input^
    )


def select_reducing_aggregates(
    exprs: ExprArray, var input: LogicalPlan
) -> LogicalPlan:
    """`select(exprs)` where the aggregates are nested and no expression
    reads a column outside one: the 0-key AGGREGATE of every aggregate
    (hidden names), a PROJECT above it computing the expressions. ONE row.
    Precondition: `aggregate_expr_refusal(exprs, False)` returned ""."""
    var aggs = List[Expr]()
    var outs = _named_hoisted(exprs, aggs, False)
    var arr = AggExprArray()
    for j in range(len(aggs)):
        arr.append(
            AggExpr(
                aggs[j].agg_fn_op(),
                Optional[Expr](aggs[j].agg_fn_child_ref().copy()),
                Optional[String](String(HIDDEN_AGG_PREFIX) + String(j)),
            )
        )
    bind_agg_operands(arr, input.output_schema)
    var agg_plan = LogicalPlan.aggregate(ExprArray(), arr^, input^)
    var bound = bind_unbound_exprs(outs, agg_plan.output_schema, True)
    return LogicalPlan.project(bound^, agg_plan^)


def select_broadcasting_aggregates(
    exprs: ExprArray, var input: LogicalPlan
) raises -> LogicalPlan:
    """`select(exprs)` where a nested aggregate sits beside a row-wise value:
    each aggregate a whole-frame window in a PROJECT under the one the
    expressions compute (polars' broadcast). Precondition:
    `aggregate_expr_refusal(exprs, True)` returned ""."""
    var aggs = List[Expr]()
    var outs = _named_hoisted(exprs, aggs, False)
    var inner = _with_hidden_windows(input^, aggs)
    var bound = bind_unbound_exprs(outs, inner.output_schema, True)
    return LogicalPlan.project(bound^, inner^)


def with_hidden_aggregate_windows(
    exprs: ExprArray, var input: LogicalPlan, mut hoisted: ExprArray
) raises -> LogicalPlan:
    """`with_columns`' half: `input` plus every aggregate of `exprs` (top-level
    ones too) as a hidden whole-frame window; `hoisted` receives the
    expressions, reading them, each named as polars names it. The caller
    builds the with_columns node over the result and drops the hidden
    columns (`drop_hidden_columns`). Precondition:
    `aggregate_expr_refusal(exprs, True)` returned ""."""
    var aggs = List[Expr]()
    hoisted = _named_hoisted(exprs, aggs, True)
    return _with_hidden_windows(input^, aggs)


def drop_hidden_columns(var plan: LogicalPlan) -> LogicalPlan:
    """A PROJECT of `plan`'s columns without the hidden aggregate ones."""
    var keep = ExprArray()
    ref sch = plan.output_schema
    for c in range(sch.num_columns()):
        var n = sch.field_name(c)
        if not n.startswith(HIDDEN_AGG_PREFIX):
            keep.append(Expr.col_ref(n))
    return LogicalPlan.project(keep^, plan^)


def filter_over_aggregates(
    var predicate: Expr, var input: LogicalPlan
) raises -> LogicalPlan:
    """`filter(predicate)` where the predicate carries whole-frame aggregates
    (`col("v") > col("v").mean()`): the hidden windows, the filter reading
    them, the input's columns back. Precondition:
    `predicate_aggregate_refusal(predicate)` returned ""."""
    var aggs = List[Expr]()
    var pred = hoist_aggregates(predicate, aggs)
    var back = _column_refs(input.output_schema)
    var inner = _with_hidden_windows(input^, aggs)
    _refuse_narrow_int_compare(pred, inner.output_schema)
    var bound = bind_unbound_expr(pred, inner.output_schema, False)
    var f = LogicalPlan.filter(bound^, inner^)
    return LogicalPlan.project(back^, f^)


def _refuse_narrow_int_compare(pred: Expr, schema: Schema) raises:
    """REFUSE BY NAME a hoisted-aggregate filter whose predicate reads an
    INT8 / INT16 column (the input's own, or a MIN / MAX window over one,
    which keeps the operand's type). The engine's column-vs-column compare
    (`compiler_eval_predicate._eval_col_vs_col`,
    `compiler_eval_column._eval_col_vs_col_promoted`) takes INT32 / INT64 /
    FLOAT32 / FLOAT64 only, so these failed with ITS text -- MEASURED
    (the round-3 review, LOCAL darwin): `filter(i8 > i8.mean())` raised
    "unsupported column type pair: int8 vs float64" and `filter(i16 ==
    i16.min())` "_eval_col_vs_col: unsupported column type: int16" (DuckDB
    1.5.3: k 1, 2 and k 5). Widening the compare is the engine's half.
    ⛔ The refusal names NO remedy on purpose: the obvious one,
    `with_columns(col("i8").cast(DType.int64).alias("i8"))` first, fails too
    -- MEASURED (LOCAL darwin, fxn.parquet): the hidden window
    over the cast column is out of the window executor's T14 envelope."""
    var names = List[String]()
    var sink = ordered_name_sink(names)
    walk_expr_column_refs(pred, sink)
    for i in range(len(names)):
        var t: ArrowType
        try:
            t = schema.field_arrow_type(schema.column_index(names[i]))
        except:
            continue
        if t != ArrowType.INT8 and t != ArrowType.INT16:
            continue
        var s = String("a filter comparing the ")
        s += String(t)
        s += " column `"
        s += names[i]
        s += (
            "` with a whole-frame aggregate is not served: the engine's"
            " column-vs-column compare takes INT32 / INT64 / FLOAT32 / FLOAT64"
            " columns, and a cast of the column first"
            " puts the aggregate's window over a COMPUTED column, which the"
            " window executor does not serve either"
        )
        raise Error(s)


def name_unaliased(exprs: ExprArray) -> ExprArray:
    """polars' output NAME for every unaliased computed expression of a
    `select` / `with_columns`: its LEFTMOST LEAF (`pl.col("a") * 2` is `a`,
    so `with_columns` REPLACES `a`; `pl.lit(1) + pl.col("a")` and a CASE
    whose first THEN is a literal are `literal`, so `with_columns` APPENDS
    `literal`). A bare column, an aliased expression, a top-level aggregate
    (`broadcast_aggregates` names it) and an expression whose leftmost leaf
    the walk does not reach are left as built. ⛔ Until 2026-09-25
    the engine named every one (`expr`, `case`, ...), and
    until a later fix a literal-rooted one (the round-3 review: `select(lit(1)
    + col("v"))` was `expr`, `when(v > 5, 1, 0)` was `case`)."""
    var out = ExprArray()
    for i in range(len(exprs)):
        ref e = exprs[i]
        if e.tag == EXPR_ALIAS or e.tag == EXPR_COL_REF or _is_top_aggregate(e):
            out.append(e.copy())
            continue
        var root = polars_root_name(e, True)
        if root:
            out.append(Expr.alias(e.copy(), root.value()))
        else:
            out.append(e.copy())
    return out^
