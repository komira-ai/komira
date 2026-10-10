# =============================================================================
# agg_output_naming.mojo — ★ THE MOJO DATAFRAME SURFACE'S OWN ANSWER TO
# "WHAT IS AN UNALIASED AGGREGATE CALLED?" — and it is POLARS'.
# =============================================================================
#
# Each surface names an unaliased aggregate the way its own ecosystem does
# (pandas and polars for the Python and Mojo surfaces). The name is a field of
# the logical plan, so each surface supplies its own without the plan or the
# executors knowing which convention it follows.
#
# ⇒ The LogicalPlan is the CARRIER, the SURFACE is the AUTHOR, and there is one
# right answer PER ECOSYSTEM rather than one for the repo:
#
#   SQL surface     `sql_binder._unaliased_agg_out_name`  DuckDB's deparse
#                                                          `count(DISTINCT x)`
#   pandas skin     `python/komira/_frame.py`             the INPUT COLUMN
#   polars skin     `python/komira/pl.py`                 the INPUT COLUMN
#   Mojo dataframe  THIS MODULE                           polars' rule
#
# ⛔ THIS MODULE EXISTS RATHER THAN A METHOD ON ONE FRAME BECAUSE THE MOJO
# SURFACE HAS **EIGHT** AGGREGATE TERMINALS, and a rule written at one of them
# is the fifth naming convention rather than the close of the fourth. SIX call
# `author_polars_agg_names` directly:
#
#   plan_carrier.GroupedCarrier.agg   the carrier surface
#   agg_frame.GroupedScanFrame._finalize_agg           grouped, runtime AggExpr
#   agg_frame._finalize_scalar_agg                     ungrouped
#   agg_frame._finalize_scalar_agg_over_breaker        ungrouped over a breaker
#   scan_frame.ScanFrame.agg[A: ExprAggFn]             the trait-built agg
#   inmem_source_frame.…._finalize_agg                 the in-memory source
#
# …and the remaining TWO — the comptime-branded typed-marker terminals
# `typed_dataframe.TypedGroupedDataFrame{,Keyed}._build_{typed,keyed}_agg`,
# reached by `agg_typed[*M]` / `agg[*M]` — get the RUNTIME half through
# `agg` (row 1) and their COMPTIME `S_out` brand from
# `polars_agg_out_name` below, which is the per-aggregate half of the same
# verb. So all eight are on one rule (see the ⛔⛔ block further down, which is
# the record of the day they were not).
#
# Measured while writing this: naming only the first left
# `read_parquet_frame(ctx, p).agg(count())` on `count` while
# `read_parquet(p).group_by([]).agg([count()])` said
# `len` — ONE surface, two words, which is exactly the defect being closed.
#
# ⛔⛔ AND THERE IS AT LEAST ONE **SEVENTH**, FOUND BY A TEST GOING RED AND NOT
# YET LOCATED. MEASURED: `read(ctx, local_csv_source(p))
# .group_by("g").agg(sum(col("a")), sum(col("b")))` still PRODUCES `sum` /
# `sum_1`, where the byte-identical chain over a PARQUET leaf produces `a` / `b`
# (`tests/sdk/test_agg_output_name_path_stable.mojo` proves the parquet side;
# `tests/integration/test_csv_row_to_parquet_e2e.mojo` carries the CSV
# measurement and the full write-up). Both go through
# `GroupedScanFrame._finalize_agg`, which DOES call this verb — so the row-leaf
# result is either a terminal this module has not found, or the plan declaring
# one name while the row-streaming executor produces another. THE SECOND WOULD
# BE THE `agg_0` DEFECT CLASS ON A NEW PATH, so the two are not equally bad and
# the distinction must be measured, not assumed. Read that test's block before
# touching this module.
#
# ⛔⛔ THE COMPTIME-BRANDED TYPED-MARKER PATH IS **IN**, AND THE PARAGRAPH THAT
# STOOD HERE — CALLING IT A STATED RESIDUAL — WAS FALSE THE DAY IT WAS WRITTEN
# (closed one commit later). It said:
#
#     typed_agg_frame.TypedGroupedFrame.agg[*M: AggSpecMarker]
#     typed_agg_frame.agg_typed[*M: AggSpecMarker]
#   still name an unaliased aggregate by `agg_func_base_name` — `sum(v)` there
#   is `sum`, not `v` … DECLARED == PRODUCED still holds on both.
#
# ⚠ IT DID NOT HOLD. Those two build UNALIASED `AggExpr`s and hand them to
# `plan_carrier.GroupedCarrier.agg` — which is one of the six
# terminals one commit moved. So their RUNTIME half moved with it (the plan
# declared `v` / `len`) while their COMPTIME `S_out` brand still said `sum` /
# `count`: DECLARED != the brand, which is the same class of defect — an output
# schema that depends on which half of the surface you ask — this module exists
# to close. It is not a hypothetical: `tests/test_typed_sout_matches_runtime.
# mojo::test_grouped_agg_sout_matches` was RED, `comptime 'sum' vs
# runtime 'lhs_key_gamma'`. The residual was a HALF-MOVE, and a half-move is
# worse than either end state.
#
# ⇒ THE BRAND NOW ASKS THIS MODULE, at comptime, through `polars_agg_out_name`
# (below) — the same per-aggregate rule `author_polars_agg_names` applies to the
# runtime `AggExpr`s. ONE rule, one module, two callers. The comptime side is a
# MIRROR, never a second scheme: it supplies only the facts a TYPE can carry
# (the marker's func code and its column NAME) and lets this module pick the
# string. The falsifier is the drift guard named above.
#
# THE LOCKSTEP EDIT THE OLD PARAGRAPH PREDICTED IS REAL AND IS PART OF THAT
# CLOSE: the brand is referenced as a LITERAL by downstream typed chains
# (`.top_n[2, 10, "count"]`, `.window["part"]().order_by["sum"]()`,
# `ColXI64["sum"]`), and every such literal moves to the aggregated column's own
# name — `count(*)` chains become `"len"`. Those sites are in the same commit as
# this one.
#
# ================== WHAT POLARS ACTUALLY DOES (MEASURED) =====================
#
# polars 1.43.2, in a throwaway venv (polars is not in the repo pixi env), on
# `{"os": [...], "user_id": [...], "v": [...]}`:
#
#     g.agg(pl.col('user_id').n_unique())  -> ['os', 'user_id']
#     g.agg(pl.col('v').min())             -> ['os', 'v']
#     g.agg(pl.col('v').sum())             -> ['os', 'v']
#     g.agg(pl.col('v').sum() * 2)         -> ['os', 'v']   arithmetic KEEPS it
#     g.agg(pl.col('v').sum() + pl.col('user_id').sum())
#                                          -> ['os', 'v']   LEFTMOST root wins
#     g.agg(pl.col('user_id').n_unique().alias('nu')) -> ['os', 'nu']
#     g.agg(pl.len())                      -> ['os', 'len']
#
# So the rule is the expression's ROOT NAME — its leftmost column reference —
# with an explicit alias overriding, and `len` for the one aggregate that has no
# input column at all.
#
# ⚠ ONE MEASURED DIVERGENCE, DELIBERATE AND WRITTEN DOWN RATHER THAN HIDDEN.
# polars makes a DUPLICATE output name a hard error:
#
#     g.agg(pl.col('v').min(), pl.col('v').max())
#       -> polars.exceptions.DuplicateError: column with name 'v' has more than
#          one occurrence
#
# and that is EXACTLY `clickbench/cb06`'s shape (`min(event_date),
# max(event_date)`). This surface does NOT raise: it lets
# `logical_plan.agg_out_field_name`'s `_N` scheme disambiguate (`v`, `v_1`).
# Refusing the shape is a BEHAVIOURAL change whose blast radius is every grouped
# aggregate in the tree, and it is a separate decision from the naming one — so
# it is left out of this module rather than smuggled in here.
# `tests/sdk/test_mojo_surface_agg_output_name.mojo` pins the divergence and
# names polars' actual answer in its failure message.
#
# ⚠ THE NAME IS AUTHORED **INTO THE PLAN**, NOT SYNTHESISED AT EXECUTION, and
# that is the whole point of this module. It is written into `AggExpr.alias_name`
# BEFORE `LogicalPlan.aggregate` derives `output_schema` from it, so the plan's
# DECLARED schema and every executor that reads it see one string. Naming an
# aggregate downstream is the `agg_0` defect `agg_out_field_name`'s header
# records: the output SCHEMA became a function of the DATA (`cb02`, answered
# from the parquet footer, said `count`; `cb03` — the same plan with a different
# predicate literal, decoded — said `agg_0`).
# =============================================================================

from std.collections import Optional

from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF, EXPR_ALIAS, EXPR_BINARY_OP, EXPR_UNARY_OP, EXPR_CAST,
    EXPR_MATH_FN, EXPR_MATH_FN2, EXPR_STRING_OP, EXPR_STRING_FN,
    EXPR_SUBSTRING, EXPR_IN_LIST, EXPR_AGG_FN, EXPR_WHEN, EXPR_LITERAL,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_ir.logical_plan import AggExprArray, agg_func_base_name


# ★ THE ONE PLACE `count(*)`'s OUTPUT NAME IS SPELLED FOR THIS SURFACE.
# polars spells `count(*)` as `pl.len()` and names it `len` (MEASURED — see the
# header). It is the same string the polars SKIN authors
# (`python/komira/pl.py:LEN_OUTPUT`). Both the RUNTIME authoring verb
# (`author_polars_agg_names`) and the COMPTIME brand
# (`typed_udf_helpers._build_grouped_agg_out_schema`) read it from HERE, so the
# two cannot drift into two words for one thing.
comptime COUNT_STAR_OUTPUT_NAME: StaticString = "len"


def polars_agg_out_name(func: UInt8, has_root: Bool, imm root: String) -> String:
    """★ THE PER-AGGREGATE HALF of this surface's rule — the name ONE unaliased
    aggregate's output column gets, given its func code and its polars ROOT NAME.

    Split out of `author_polars_agg_names` (which is the whole-array,
    `AggExpr`-shaped verb) so that a caller holding no `AggExpr` can ask the
    SAME authority for the SAME string. There is exactly one such caller and it
    is the reason this function exists: the COMPTIME grouped-agg brand
    `typed_udf_helpers._build_grouped_agg_out_schema`, which must produce the
    string the runtime plan will carry BEFORE any `AggExpr` exists — the typed
    marker pack `*M` is a TYPE, not a value.

    ⚠ THIS IS WHY THE COMPTIME MIRROR IS NOT A SECOND NAMING SCHEME. The mirror
    supplies the two facts it can see at comptime (the marker's func code and
    its column name); the RULE stays here. `tests/test_typed_sout_matches_
    runtime.mojo::test_grouped_agg_sout_matches` is the falsifier — it compares
    the comptime brand against the runtime plan's `output_schema` name by name.

    `has_root` / `root` are the caller's answer to "does this aggregate name a
    column, and which" — `polars_root_name` of the child for the runtime verb,
    the marker's `NAME` for the comptime brand. A childless aggregate passes
    `has_root=False`.

    ⚠ IT DOES NOT DISAMBIGUATE. `logical_plan.agg_out_field_name`'s `_N` scheme
    is the ONE place collisions are resolved (the comptime brand mirrors it in
    `_grouped_agg_disambiguate`); see `author_polars_agg_names`' header."""
    var out = String()
    if has_root:
        out.write(root)
        return out^
    # count(*) — polars' `pl.len()`. Any OTHER child-less aggregate is a shape
    # this surface does not build; it falls back to the engine's own word rather
    # than being named `len`, which would be a lie about what it computes.
    if func == AGG_COUNT:
        out.write(COUNT_STAR_OUTPUT_NAME)
        return out^
    out.write(agg_func_base_name(func))
    return out^


def polars_root_name(e: Expr, literal_named: Bool = False) -> Optional[String]:
    """polars' ROOT NAME of an expression — its LEFTMOST LEAF.

    A column leaf is its name. A LITERAL leaf is `literal` when
    `literal_named` (polars 1.44.2, MEASURED: `pl.lit(1) +
    pl.col("v")`, `when(v > 5).then(1).otherwise(0)`, `(pl.lit(2) *
    pl.col("v")).sum()` and even `pl.lit(1).sum()` are ALL named `literal`),
    else `None`. ⛔ This docstring used to say polars REFUSES `pl.lit(1)
    .sum()`: it does not (it answers 1, named `literal`); the polars SKIN
    (`python/komira/pl.py::Expr._as_agg`) is what refuses it.

    ⚠ SYNTACTIC, NEVER SCHEMA-DERIVED. polars' root name is a property of the
    EXPRESSION, so it is available at plan-BUILD time — which is what lets this
    surface write the name into the plan rather than infer it later. Resolving
    it against a schema would also be wrong for a scan whose schema is not known
    until execution, which is every `read_parquet(...)` this surface builds.

    ⚠ AN ALIAS INSIDE THE EXPRESSION WINS, matching polars: `pl.col('a')
    .alias('x').sum()` is `x`. That is the EXPRESSION-level alias
    (`Expr.alias`), distinct from the AGGREGATE-level one (`AggExpr.alias`) the
    caller checks first.

    ⚠ THE WALK IS DELIBERATELY SHORT. It covers col_ref, alias, binary (the
    LEFT operand, which is what makes it *leftmost*), unary, cast, the
    function nodes (math / two-argument math by its FIRST operand / string op
    / string fn / substring), `is_in`, and an aggregate-as-expression (its
    operand: `pl.col("v").max() - pl.col("v").min()` is `v`), and a CASE by
    its FIRST `then` (MEASURED, polars 1.44.2: `when(v > 5).then(v)
    .otherwise(0)` is `v`, `when(..).then(k * 2).otherwise(v)` is `k`).
    WHO ASKS FOR `literal`: `select` / `with_columns` of a NON-aggregate
    expression (`select_aggregates.name_unaliased`) pass `literal_named`, so
    `select(lit(1) + col("v"))` is `literal` and `with_columns(when(v > 5,
    1, 0))` APPENDS `literal`, as polars does. ⛔ Until a later fix they did
    not, and the engine named them (`expr`, `case`) -- MEASURED. The AGGREGATE routes (the terminals, a `select` of
    aggregates, a nested / broadcast aggregate) do NOT pass it: an
    unaliased aggregate whose leftmost leaf is a literal (or a node this walk
    does not descend) is REFUSED BY NAME there, and `.alias(...)` serves it
    (see `author_polars_agg_names`). ⛔ Until that fix this sentence
    said a CASE was refused; with_columns APPENDED `case` and kept `v` where
    polars REPLACES `v`.

    ★ THE FUNCTION ARMS (2026-09-25): polars keeps the input's name
    through a function node (MEASURED, polars 1.44.2: `pl.col("x").sqrt()
    .sum()` is `x`). Without them `select([col("x").sqrt().sum()])` found no
    name and fell back to a PROJECT of the aggregate-as-expression: six NULL
    rows, null-typed, a silent wrong answer (the caller now refuses by name when this
    returns `None`)."""
    if e.tag == EXPR_COL_REF:
        return Optional(e.col_ref_name())
    if e.tag == EXPR_ALIAS:
        return Optional(e.alias_name())
    if e.tag == EXPR_LITERAL and literal_named:
        return Optional(String("literal"))
    if e.tag == EXPR_BINARY_OP:
        return polars_root_name(e.binary_left_ref(), literal_named)
    if e.tag == EXPR_UNARY_OP:
        return polars_root_name(e.unary_child_ref(), literal_named)
    if e.tag == EXPR_CAST:
        return polars_root_name(e.cast_child_ref(), literal_named)
    if e.tag == EXPR_MATH_FN:
        return polars_root_name(e.math_fn_child_ref(), literal_named)
    if e.tag == EXPR_MATH_FN2:
        return polars_root_name(e.math_fn2_left_ref(), literal_named)
    if e.tag == EXPR_STRING_OP:
        return polars_root_name(e.string_op_child_ref(), literal_named)
    if e.tag == EXPR_STRING_FN:
        return polars_root_name(e.string_fn_child_ref(), literal_named)
    if e.tag == EXPR_SUBSTRING:
        return polars_root_name(e.substring_child_ref(), literal_named)
    if e.tag == EXPR_IN_LIST:
        return polars_root_name(e.in_list_child_ref(), literal_named)
    if e.tag == EXPR_AGG_FN:
        return polars_root_name(e.agg_fn_child_ref(), literal_named)
    if e.tag == EXPR_WHEN and e.when_num_cases() > 0:
        return polars_root_name(e.when_case_result_ref(0), literal_named)
    return None


def author_polars_agg_names(mut aggs: AggExprArray) raises:
    """Fill every UNALIASED `AggExpr` in `aggs` with polars' output name.

    ★ THIS IS THE MOJO SURFACE'S AUTHORING VERB. Every one of the aggregate
    terminals listed in this module's header calls it, immediately before its
    `LogicalPlan.aggregate(...)` — so what the plan DECLARES is what the surface
    CHOSE, and no executor has anything left to synthesise.

    * an aggregate that already carries `.alias(...)` is left ALONE (polars'
      alias wins too — MEASURED)
    * anything else asks `polars_agg_out_name` (just above) — the shared
      per-aggregate rule — with `polars_root_name` of its child, or with no root
      at all when the aggregate is child-less. `AGG_COUNT` with no child is
      `count(*)`, which polars spells `pl.len()` and names **`len`** (MEASURED);
      that string lives in `COUNT_STAR_OUTPUT_NAME` because the COMPTIME brand
      needs the same one

    ⚠ IT DOES NOT DISAMBIGUATE, ON PURPOSE. `logical_plan.agg_out_field_name`
    owns the `_N` collision scheme and is the ONE place it may live; this verb
    assigning `v` twice and letting that authority resolve it to `v` / `v_1` is
    the correct division. A second collision scheme here would be the fifth
    naming convention this whole area exists to stop creating.

    ⚠ IT IS IDEMPOTENT, and that matters because the terminals compose (a
    grouped agg over a breaker runs one terminal's output through another's
    input). A second pass sees every aggregate aliased and changes nothing.

    Raises when an aggregate's argument has no column as its leftmost leaf
    (polars names it `literal`; this route does not take that name), with
    `.alias(...)` as the remedy."""
    for i in range(len(aggs)):
        ref ae = aggs[i]
        if ae.alias_name:
            continue
        if not ae.child:
            ae.alias_name = Optional(
                polars_agg_out_name(ae.func, False, String())
            )
            continue
        var root = polars_root_name(ae.child.value())
        if not root:
            raise Error(
                "this aggregate's argument has no column as its LEFTMOST leaf"
                " (polars names it `literal`), and an unaliased aggregate here"
                " takes its name from that column. Name it with"
                " `.alias(\"...\")`"
            )
        ae.alias_name = Optional(
            polars_agg_out_name(ae.func, True, String(root.value()))
        )
