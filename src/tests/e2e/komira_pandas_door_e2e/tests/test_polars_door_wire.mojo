# =============================================================================
# The polars door's plans, read off protoc's bytes, and the two doors held to
# each other.
# =============================================================================
#
# Each fixture `fixtures/<stem>.txtpb` is a plan in the shape a polars-shaped
# frontend emits for polars 1.44.2 (or, for the cross-door pair, a pandas-shaped
# one). A `proto_encode` build action runs protoc over it and the bytes are
# staged as `wire/<stem>.hex`, so what this file decodes was written by the
# reference implementation; no encoder of this repository touched it.
#
# For every fixture, in this order:
#   1. `plan_wire_admit` (the structural gate) accepts the bytes;
#   2. `plan_from_bytes` decodes them (the structural gate again, the
#      output-schema check per node, the value gate);
#   3. `plan_wire_check_values` (the value gate) accepts the decoded plan;
#   4. the fields the fixture exists for are asserted on the decoded plan by
#      name, so a defect there fails with that field's message first;
#   5. the decoded plan equals the plan `polars_plans` (or `door_plans`)
#      builds: the same render and `structural_hash`, the same output schema
#      field by field, and the same `plan_shape`.
#
# Step 5's `plan_shape` is what sees the fields the render leaves out: a
# `nulls_first` equal to the derived NULLS LAST, and the output schema. The
# render prints every PARTITION_BY function in full (name, column, offset,
# frame, alias, and the default when `has_default` is set); `plan_shape` adds
# `has_default` itself and the default value when it is unset.
#
# The cross-door checks compare ENCODINGS: protoc's bytes of the pandas
# `groupby(sort=False)` fixture and of the polars `group_by` fixture (written
# in different field orders), and this repository's encoder over the plans
# the two doors' Mojo builders make on separate paths.
#
# Mutants run against this file (each planted, built red, reverted; the
# decoder mutants with komira_plan_wire's own welded tests set aside, so the
# red is this file's):
#   M1 the pandas sort=True fixture loses its SORT node;
#   M2 `door_plans.groupby_sum_plan(True)` loses its SORT node;
#   M3 the decoder's LIMIT arm swaps `n` and `offset`;
#   M4 the decoder's SORT arm drops the wire's `nulls_first`;
#   M5 the decoder reads BIN_OR as BIN_AND;
#   M6 the decoder gives a partition function the running frame;
#   M7 the decoder reads UN_IS_NOT_NULL as UN_IS_NULL;
#   M8 the decoder reads AGG_SUM as AGG_ANY_VALUE;
#   M9 the select(col.sum()) fixture becomes the dropped-aggregate shape
#      (the column projected, its sum gone).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_pandas_door_e2e import (
    bytes_hex,
    dropped_sum_plan,
    groupby_sum_plan,
    partition_expr_shape,
    plan_shape,
    polars_agg_over_plan,
    polars_group_by_sum_plan,
    polars_is_in_plan,
    polars_pipeline_plan,
    polars_select_sum_plan,
    polars_sort_plan,
    polars_sum_horizontal_plan,
    sales_scan,
    sales_schema,
    schema_shape,
    wire_bytes_from_hex,
)
from komira_plan_expr.agg_expr import AGG_SUM
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import (
    BIN_ADD,
    BIN_AND,
    BIN_EQ,
    BIN_GT,
    BIN_MUL,
    BIN_OR,
    EXPR_ALIAS,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_UNARY_OP,
    EXPR_WHEN,
    Expr,
    UN_IS_NOT_NULL,
    UN_IS_NULL,
)
from komira_plan_expr.partition_expr import PartitionExpr, PF_SUM
from komira_plan_expr.partition_frame import (
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_UNITS_ROWS,
    PartitionFrame,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_FILTER,
    PLAN_LIMIT,
    PLAN_PARTITION_BY,
    PLAN_PROJECT,
    PLAN_SCAN,
    PLAN_SORT,
)
from komira_plan_wire import (
    plan_from_bytes,
    plan_to_bytes,
    plan_wire_admit,
    plan_wire_check_values,
    plan_wire_supported_versions,
)


def _wire(stem: String) raises -> List[UInt8]:
    var path = String("wire/") + stem + ".hex"
    var text = String("")
    with open(path, "r") as f:
        text = f.read()
    return wire_bytes_from_hex(text)


def _admitted(stem: String) raises -> LogicalPlan:
    """Steps 1 to 3: the bytes pass both gates and decode."""
    var bytes = _wire(stem)
    plan_wire_admit(bytes, plan_wire_supported_versions())
    var p = plan_from_bytes(bytes^)
    plan_wire_check_values(p)
    return p^


def _assert_same_plan(
    stem: String, decoded: LogicalPlan, expected: LogicalPlan
) raises:
    """Step 5: the decoded plan is the plan built in Mojo."""
    assert_equal(
        String(decoded), String(expected),
        stem + ": the decoded plan renders differently from the Mojo-built one",
    )
    assert_equal(
        decoded.structural_hash(), expected.structural_hash(),
        stem + ": structural_hash differs from the Mojo-built plan's",
    )
    assert_equal(
        schema_shape(decoded.output_schema),
        schema_shape(expected.output_schema),
        stem + ": the decoded plan's output schema differs (the render does"
        + " not carry it)",
    )
    assert_equal(
        plan_shape(decoded), plan_shape(expected),
        stem + ": a payload field differs from the Mojo-built plan's",
    )


def _assert_col(stem: String, e: Expr, name: String, what: String) raises:
    assert_equal(Int(e.tag), Int(EXPR_COL_REF), stem + ": " + what)
    assert_equal(e.col_ref_name(), name, stem + ": " + what)


def _assert_passthrough(stem: String, exprs_len: Int, p: LogicalPlan) raises:
    """`with_columns`' first half: one column reference per sales column, in
    order, then exactly one appended expression."""
    ref d = p.project_data_ref()
    var cols = sales_schema()
    assert_equal(
        exprs_len, cols.num_columns() + 1,
        stem + ": with_columns keeps every input column and appends one",
    )
    for i in range(cols.num_columns()):
        _assert_col(
            stem, d.exprs[i], cols.field_name(i),
            "with_columns passes input column " + String(i) + " through",
        )


def test_pipeline_scan_filter_with_columns_group_by_sort_limit() raises:
    """The six verbs in one plan, each node's field asserted top down."""
    var stem = String("polars_pipeline")
    var p = _admitted(stem)
    assert_equal(Int(p.tag), Int(PLAN_LIMIT), stem + ": the root is LIMIT")
    ref lim = p.limit_data_ref()
    assert_equal(
        lim.n, 3,
        stem + ": limit(3) decoded with n=" + String(lim.n) + " offset="
        + String(lim.offset),
    )
    assert_equal(lim.offset, 0, stem + ": limit(3) starts at row 0")

    ref sort_node = lim.child[]
    assert_equal(
        Int(sort_node.tag), Int(PLAN_SORT), stem + ": SORT under LIMIT"
    )
    ref s = sort_node.sort_data_ref()
    assert_equal(len(s.keys), 1, stem + ": one sort key")
    assert_equal(s.keys[0], String("revenue"), stem + ": sort key")
    assert_true(s.descending[0], stem + ": descending=True")
    assert_equal(len(s.nulls_first), 1, stem + ": one nulls_first per key")
    assert_true(
        s.nulls_first[0],
        stem + ": polars' default nulls_last=False puts nulls FIRST, on a"
        + " descending key too; decoded nulls last",
    )

    ref agg_node = s.child[]
    assert_equal(
        Int(agg_node.tag), Int(PLAN_AGGREGATE),
        stem + ": group_by.agg is an AGGREGATE directly under the SORT"
        + " (polars' group_by adds no sort of its own)",
    )
    ref a = agg_node.aggregate_data_ref()
    assert_equal(len(a.group_by), 1, stem + ": one group key")
    _assert_col(stem, a.group_by[0], String("region"), "the group key")
    assert_equal(len(a.agg_exprs), 1, stem + ": one aggregate")
    ref sum_rev = a.agg_exprs[0]
    assert_equal(Int(sum_rev.func), Int(AGG_SUM), stem + ": the agg is SUM")
    assert_true(sum_rev.child.__bool__(), stem + ": SUM reads a column")
    _assert_col(stem, sum_rev.child.value(), String("revenue"), "SUM's input")
    assert_equal(
        sum_rev.alias_name.value(), String("revenue"),
        stem + ": an unaliased sum is named after its column",
    )

    ref proj_node = a.child[]
    assert_equal(
        Int(proj_node.tag), Int(PLAN_PROJECT),
        stem + ": with_columns is a PROJECT",
    )
    ref pr = proj_node.project_data_ref()
    _assert_passthrough(stem, len(pr.exprs), proj_node)
    ref revenue = pr.exprs[5]
    assert_equal(Int(revenue.tag), Int(EXPR_ALIAS), stem + ": the new column")
    assert_equal(revenue.alias_name(), String("revenue"), stem + ": its name")
    ref mul = revenue.alias_child_ref()
    assert_equal(Int(mul.tag), Int(EXPR_BINARY_OP), stem + ": price * qty")
    assert_equal(Int(mul.binary_op()), Int(BIN_MUL), stem + ": price * qty")
    _assert_col(stem, mul.binary_left_ref(), String("price"), "the left factor")
    _assert_col(stem, mul.binary_right_ref(), String("qty"), "the right factor")

    ref filt_node = pr.child[]
    assert_equal(
        Int(filt_node.tag), Int(PLAN_FILTER), stem + ": filter is a FILTER"
    )
    ref pred = filt_node.filter_data_ref().predicate
    assert_equal(Int(pred.tag), Int(EXPR_BINARY_OP), stem + ": qty > 2")
    assert_equal(Int(pred.binary_op()), Int(BIN_GT), stem + ": qty > 2")
    _assert_col(stem, pred.binary_left_ref(), String("qty"), "the compared")
    assert_equal(
        Int(pred.binary_right_ref().literal_value().int_val), 2,
        stem + ": the bound",
    )
    assert_equal(
        Int(filt_node.filter_data_ref().child[].tag), Int(PLAN_SCAN),
        stem + ": the FILTER reads the scan",
    )
    _assert_same_plan(stem, p, polars_pipeline_plan())


def _assert_region_eq(stem: String, e: Expr, value: String) raises:
    assert_equal(Int(e.tag), Int(EXPR_BINARY_OP), stem + ": region = " + value)
    assert_equal(Int(e.binary_op()), Int(BIN_EQ), stem + ": region = " + value)
    _assert_col(stem, e.binary_left_ref(), String("region"), "is_in's column")
    ref lit = e.binary_right_ref()
    assert_equal(Int(lit.tag), Int(EXPR_LITERAL), stem + ": a member")
    assert_true(lit.literal_value().is_string(), stem + ": a string member")
    assert_equal(
        lit.literal_value().string_val, value, stem + ": the member's value"
    )


def test_is_in() raises:
    """`is_in(["north", "west"])`: the OR of one `=` per member, as
    `col_expr.is_in` lowers it."""
    var stem = String("polars_is_in")
    var p = _admitted(stem)
    assert_equal(Int(p.tag), Int(PLAN_FILTER), stem + ": the root is FILTER")
    ref pred = p.filter_data_ref().predicate
    assert_equal(Int(pred.tag), Int(EXPR_BINARY_OP), stem + ": an OR")
    assert_equal(
        Int(pred.binary_op()), Int(BIN_OR),
        stem + ": is_in joins its members with OR; decoded op "
        + String(Int(pred.binary_op())) + " (BIN_AND="
        + String(Int(BIN_AND)) + " keeps no row: region cannot be two values)",
    )
    _assert_region_eq(stem, pred.binary_left_ref(), String("north"))
    _assert_region_eq(stem, pred.binary_right_ref(), String("west"))
    _assert_same_plan(stem, p, polars_is_in_plan())


def test_agg_over_is_a_whole_partition_broadcast() raises:
    """`col("price").sum().over("region")`: one PARTITION_BY, a SUM over the
    whole partition, so every row of a region carries the region's total."""
    var stem = String("polars_agg_over")
    var p = _admitted(stem)
    assert_equal(
        Int(p.tag), Int(PLAN_PARTITION_BY), stem + ": the root is PARTITION_BY"
    )
    ref d = p.partition_by_data_ref()
    assert_equal(len(d.partition_keys), 1, stem + ": one partition key")
    assert_equal(d.partition_keys[0], String("region"), stem + ": over(region)")
    assert_equal(len(d.order_keys), 0, stem + ": over() with no order_by")
    assert_equal(len(d.descending), 0, stem + ": no order flags")
    assert_equal(len(d.partition_exprs), 1, stem + ": one function")
    ref x = d.partition_exprs[0]
    assert_equal(Int(x.func), Int(PF_SUM), stem + ": the function is SUM")
    assert_equal(x.column, String("price"), stem + ": SUM's column")
    assert_equal(x.alias_name, String("region_total"), stem + ": its name")
    assert_false(x.has_default, stem + ": a SUM has no default")
    assert_true(
        x.frame.is_full_partition(),
        stem + ": a broadcast reads the WHOLE partition; decoded frame "
        + partition_expr_shape(x) + " (a running frame is cum_sum, a"
        + " different column)",
    )
    assert_equal(
        Int(x.frame.units), Int(FRAME_UNITS_ROWS), stem + ": a ROWS frame"
    )
    assert_equal(
        p.output_schema.field_name(5), String("region_total"),
        stem + ": the window's output is appended after the input columns",
    )
    # The in-tree polars surface spells the same window: `Expr.over` on the
    # aggregate names this function, column and frame.
    var w = col("price").sum().over("region")
    assert_true(w.is_window_fn(), "col(price).sum().over(region) is a window")
    ref wf = w.window_fn_data_ref()
    assert_equal(Int(wf.func), Int(x.func), stem + ": Expr.over's function")
    assert_equal(wf.arg_col, x.column, stem + ": Expr.over's column")
    assert_equal(wf.partition_by[0], d.partition_keys[0], stem + ": its key")
    assert_equal(
        String(wf.frame), String(x.frame), stem + ": Expr.over's frame"
    )
    _assert_same_plan(stem, p, polars_agg_over_plan())


def _assert_coalesce_zero(stem: String, e: Expr, column: String) raises:
    """`coalesce(column, 0.0)`: CASE WHEN column IS NOT NULL THEN column
    ELSE 0.0."""
    var what = String("coalesce(") + column + ", 0.0)"
    assert_equal(Int(e.tag), Int(EXPR_WHEN), stem + ": " + what)
    assert_equal(e.when_num_cases(), 1, stem + ": " + what + " has one case")
    ref cond = e.when_case_condition_ref(0)
    assert_equal(Int(cond.tag), Int(EXPR_UNARY_OP), stem + ": the guard")
    assert_equal(
        Int(cond.unary_op()), Int(UN_IS_NOT_NULL),
        stem + ": " + what + " keeps the value when it IS NOT NULL; decoded op "
        + String(Int(cond.unary_op())) + " (UN_IS_NULL="
        + String(Int(UN_IS_NULL)) + " answers NULL for every present value)",
    )
    _assert_col(stem, cond.unary_child_ref(), column, "the guarded column")
    _assert_col(stem, e.when_case_result_ref(0), column, "the kept value")
    ref zero = e.when_default_ref()
    assert_equal(Int(zero.tag), Int(EXPR_LITERAL), stem + ": the ELSE")
    assert_true(
        zero.literal_value().is_float(),
        stem + ": the ELSE is the float 0.0 beside a float64 column",
    )
    assert_equal(
        zero.literal_value().float_val, Float64(0), stem + ": the ELSE is 0"
    )


def test_sum_horizontal_skips_nulls() raises:
    """`sum_horizontal("price", "discount")`: each operand coalesced to 0.0,
    so a null is skipped and an all-null row is 0, as polars answers."""
    var stem = String("polars_sum_horizontal")
    var p = _admitted(stem)
    assert_equal(Int(p.tag), Int(PLAN_PROJECT), stem + ": the root is PROJECT")
    ref d = p.project_data_ref()
    _assert_passthrough(stem, len(d.exprs), p)
    ref gross = d.exprs[5]
    assert_equal(Int(gross.tag), Int(EXPR_ALIAS), stem + ": the new column")
    assert_equal(gross.alias_name(), String("gross"), stem + ": its name")
    ref add = gross.alias_child_ref()
    assert_equal(Int(add.tag), Int(EXPR_BINARY_OP), stem + ": a sum")
    assert_equal(Int(add.binary_op()), Int(BIN_ADD), stem + ": a sum")
    _assert_coalesce_zero(stem, add.binary_left_ref(), String("price"))
    _assert_coalesce_zero(stem, add.binary_right_ref(), String("discount"))
    assert_equal(
        Int(p.output_schema.field_arrow_type(5).type_id),
        Int(ArrowType.FLOAT64.type_id),
        stem + ": the sum of two float64 columns is float64",
    )
    _assert_same_plan(stem, p, polars_sum_horizontal_plan())


def _assert_null_cells(stem: String, p: LogicalPlan, nulls_last: Bool) raises:
    assert_equal(Int(p.tag), Int(PLAN_SORT), stem + ": the root is SORT")
    ref d = p.sort_data_ref()
    assert_equal(len(d.keys), 2, stem + ": two keys")
    assert_equal(d.keys[0], String("region"), stem + ": key 0")
    assert_equal(d.keys[1], String("price"), stem + ": key 1")
    assert_false(d.descending[0], stem + ": key 0 ascending")
    assert_true(d.descending[1], stem + ": key 1 descending")
    assert_equal(len(d.nulls_first), 2, stem + ": one nulls_first per key")
    var where = String("nulls last") if nulls_last else String("nulls first")
    assert_equal(
        d.nulls_first[0], not nulls_last,
        stem + ": the ascending key's cell, " + where + "; decoded nulls_first="
        + String(d.nulls_first[0]),
    )
    assert_equal(
        d.nulls_first[1], not nulls_last,
        stem + ": the descending key's cell, " + where + "; decoded"
        + " nulls_first=" + String(d.nulls_first[1]),
    )


def test_sort_null_order_cells() raises:
    """The four cells: nulls first and last, on an ascending and on a
    descending key. polars' default (`nulls_last=False`) is nulls FIRST in
    both directions, which is not the engine's derived placement, so it has
    to travel on the wire."""
    var first = _admitted(String("polars_sort_nulls_first"))
    _assert_null_cells(String("polars_sort_nulls_first"), first, False)
    _assert_same_plan(
        String("polars_sort_nulls_first"), first, polars_sort_plan(False)
    )
    var last = _admitted(String("polars_sort_nulls_last"))
    _assert_null_cells(String("polars_sort_nulls_last"), last, True)
    _assert_same_plan(
        String("polars_sort_nulls_last"), last, polars_sort_plan(True)
    )
    assert_true(
        String(first) != String(last),
        "the render shows a deviation from the derived NULLS LAST, so the"
        + " default (nulls first) and nulls_last=True render differently",
    )


def test_select_sum_keeps_the_sum() raises:
    """The dropped-aggregate defect: a polars-shaped `select(col("price")
    .sum())` once lost the aggregate and returned the column, one row per
    input row, with nothing raised. Its plan is a whole-frame AGGREGATE whose
    one output is the sum."""
    var stem = String("polars_select_sum")
    var p = _admitted(stem)
    assert_equal(
        Int(p.tag), Int(PLAN_AGGREGATE),
        stem + ": select(col.sum()) decoded as plan tag " + String(Int(p.tag))
        + ", not an AGGREGATE: the sum is gone",
    )
    ref d = p.aggregate_data_ref()
    assert_equal(len(d.group_by), 0, stem + ": a whole-frame aggregate")
    assert_equal(len(d.agg_exprs), 1, stem + ": one aggregate")
    ref a = d.agg_exprs[0]
    assert_equal(
        Int(a.func), Int(AGG_SUM),
        stem + ": the aggregate decoded as func " + String(Int(a.func))
        + ", not SUM: the frame's total is not what comes back",
    )
    _assert_col(stem, a.child.value(), String("price"), "SUM's input")
    assert_equal(p.output_schema.num_columns(), 1, stem + ": one output column")
    assert_equal(
        p.output_schema.field_name(0), String("price"),
        stem + ": named after its column",
    )
    assert_true(
        plan_shape(p) != plan_shape(dropped_sum_plan()),
        stem + ": the decoded plan is the dropped-aggregate plan (the column,"
        + " not its sum)",
    )
    _assert_same_plan(stem, p, polars_select_sum_plan())


def test_groupby_sort_false_is_byte_identical_to_group_by() raises:
    """pandas `groupby("cust_id", sort=False).agg({"amount": "sum"})` and
    polars `group_by("cust_id").agg(col("amount").sum())` are ONE plan: the
    same protoc bytes from two fixtures written in different field orders,
    and the same encoding of the two doors' Mojo-built plans. They are one
    plan only because the key `cust_id` is non-nullable: pandas' default
    `dropna=True` drops a null group that polars keeps."""
    var pd_bytes = bytes_hex(_wire(String("pandas_groupby_sum_unsorted")))
    var pl_bytes = bytes_hex(_wire(String("polars_group_by_sum")))
    assert_equal(
        pd_bytes, pl_bytes,
        "protoc's bytes for groupby(sort=False) and group_by differ",
    )
    var pd = _admitted(String("pandas_groupby_sum_unsorted"))
    var pl = _admitted(String("polars_group_by_sum"))
    _assert_same_plan(
        String("pandas_groupby_sum_unsorted"), pd, groupby_sum_plan(False)
    )
    _assert_same_plan(
        String("polars_group_by_sum"), pl, polars_group_by_sum_plan()
    )
    assert_equal(
        bytes_hex(plan_to_bytes(groupby_sum_plan(False))),
        bytes_hex(plan_to_bytes(polars_group_by_sum_plan())),
        "the two doors' Mojo-built plans encode differently",
    )
    assert_equal(
        bytes_hex(plan_to_bytes(pd)), bytes_hex(plan_to_bytes(pl)),
        "the two decoded plans re-encode differently",
    )


def test_groupby_default_sort_differs_by_the_sort_alone() raises:
    """pandas' default `sort=True` is a different question from polars'
    `group_by` (which documents no order), so the bytes must differ, and the
    difference must be exactly a SORT on the group key over the same
    AGGREGATE."""
    var sorted_bytes = bytes_hex(_wire(String("pandas_groupby_sum_sorted")))
    var pl_bytes = bytes_hex(_wire(String("polars_group_by_sum")))
    assert_true(
        sorted_bytes != pl_bytes,
        "groupby(sort=True) encodes to group_by's bytes: the SORT is gone",
    )
    var stem = String("pandas_groupby_sum_sorted")
    var srt = _admitted(stem)
    assert_equal(
        Int(srt.tag), Int(PLAN_SORT),
        stem + ": the root is not a SORT; groupby(sort=True) promises sorted"
        + " keys",
    )
    ref d = srt.sort_data_ref()
    assert_equal(len(d.keys), 1, stem + ": one sort key")
    assert_equal(d.keys[0], String("cust_id"), stem + ": the group key")
    assert_false(d.descending[0], stem + ": ascending")
    var pl = _admitted(String("polars_group_by_sum"))
    assert_equal(
        bytes_hex(plan_to_bytes(d.child[])), bytes_hex(plan_to_bytes(pl)),
        stem + ": under the SORT is not group_by's plan",
    )
    _assert_same_plan(stem, srt, groupby_sum_plan(True))
    assert_true(
        bytes_hex(plan_to_bytes(groupby_sum_plan(True)))
        != bytes_hex(plan_to_bytes(polars_group_by_sum_plan())),
        "the pandas door's Mojo-built sort=True plan encodes as group_by's",
    )


def test_the_comparison_sees_each_key_field() raises:
    """Step 5 is not blind to the fields the decoder mutants move: Mojo-built
    plans or payloads that differ only there have different shapes."""
    assert_true(
        plan_shape(polars_sort_plan(False))
        != plan_shape(polars_sort_plan(True)),
        "plan_shape cannot tell nulls first from nulls last",
    )
    assert_true(
        plan_shape(LogicalPlan.limit(3, polars_select_sum_plan()))
        != plan_shape(LogicalPlan.limit(0, polars_select_sum_plan(), 3)),
        "plan_shape cannot tell LIMIT 3 from LIMIT 0 OFFSET 3",
    )
    var whole = PartitionExpr.agg_with_frame(
        PF_SUM, String("price"), PartitionFrame.default_unordered()
    )
    var running = PartitionExpr.agg_with_frame(
        PF_SUM, String("price"), PartitionFrame.default_ordered()
    )
    assert_true(
        partition_expr_shape(whole) != partition_expr_shape(running),
        "partition_expr_shape cannot tell a whole-partition SUM from a"
        + " running one",
    )
    var or_plan = LogicalPlan.filter(
        Expr.binary(BIN_OR, col("qty") > 1, col("qty") > 2), sales_scan()
    )
    var and_plan = LogicalPlan.filter(
        Expr.binary(BIN_AND, col("qty") > 1, col("qty") > 2), sales_scan()
    )
    assert_true(
        plan_shape(or_plan) != plan_shape(and_plan),
        "plan_shape cannot tell OR from AND",
    )
    assert_true(
        plan_shape(
            LogicalPlan.filter(
                Expr.unary(UN_IS_NULL, Expr.col_ref("qty")), sales_scan()
            )
        )
        != plan_shape(
            LogicalPlan.filter(
                Expr.unary(UN_IS_NOT_NULL, Expr.col_ref("qty")),
                sales_scan(),
            )
        ),
        "plan_shape cannot tell IS NULL from IS NOT NULL",
    )
    assert_equal(
        Int(FRAME_BOUND_UNBOUNDED_PRECEDING), Int(whole.frame.start_tag),
        "default_unordered starts at UNBOUNDED PRECEDING",
    )
    assert_equal(
        Int(FRAME_BOUND_UNBOUNDED_FOLLOWING), Int(whole.frame.end_tag),
        "default_unordered ends at UNBOUNDED FOLLOWING",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_pipeline_scan_filter_with_columns_group_by_sort_limit]()
    suite.test[test_is_in]()
    suite.test[test_agg_over_is_a_whole_partition_broadcast]()
    suite.test[test_sum_horizontal_skips_nulls]()
    suite.test[test_sort_null_order_cells]()
    suite.test[test_select_sum_keeps_the_sum]()
    suite.test[test_groupby_sort_false_is_byte_identical_to_group_by]()
    suite.test[test_groupby_default_sort_differs_by_the_sort_alone]()
    suite.test[test_the_comparison_sees_each_key_field]()
    suite^.run()
