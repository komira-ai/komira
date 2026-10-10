# =============================================================================
# The pandas door's plans, read off protoc's bytes.
# =============================================================================
#
# Each fixture `fixtures/<stem>.txtpb` is a plan in the shape a pandas-shaped
# frontend emits. A `proto_encode` build action runs protoc over it and the
# bytes are staged as `wire/<stem>.hex`, so what this file decodes was written
# by the reference implementation; no encoder of this repository touched it.
#
# For every fixture, in this order:
#   1. `plan_wire_admit` (the structural gate: size, version, depth, node
#      count) accepts the bytes;
#   2. `plan_from_bytes` decodes them (it runs the structural gate again, the
#      output-schema check per node and the value gate);
#   3. `plan_wire_check_values` (the value gate) accepts the decoded plan;
#   4. the field the fixture exists for is asserted on the decoded plan by
#      name: `nulls_first`, `join_type`, the COUNT's input slot, the CSV
#      binding. A defect there fails with that field's message first;
#   5. the decoded plan equals the plan `door_plans` builds with
#      `komira_plan_ir`: the same render and `structural_hash`, the same output
#      schema field by field, and the same `plan_shape`.
#
# For the sort fixtures the plan render is a partial witness. It omits
# `nulls_first` when it equals the derived placement (`derived_nulls_first`:
# NULLS LAST in both directions), so it prints NULLS FIRST for
# `na_position="first"` and nothing for `"last"`. Step 4 and `plan_shape`
# read the field itself.
#
# Mutants run against this file (each planted, built red, reverted):
#   M1 the decoder's SORT arm flips each `nulls_first`;
#   M2 `join_type_from_wire` maps JOIN_LEFT to JOIN_INNER;
#   M3 the decoder drops a COUNT's input column, so count(col) reads as
#      count(*).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_pandas_door_e2e import (
    DOOR_CSV_FINGERPRINT,
    DOOR_CSV_KIND_ID,
    DOOR_CSV_PATH,
    DOOR_MTIME_NS,
    agg_shape,
    groupby_count_col_plan,
    groupby_size_plan,
    merge_plan,
    plan_shape,
    read_csv_plan,
    schema_shape,
    sort_values_plan,
    wire_bytes_from_hex,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.expr import Expr, EXPR_COL_REF
from komira_plan_ir.logical_plan import (
    JOIN_INNER,
    JOIN_LEFT,
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SCAN,
    PLAN_SORT,
    SOURCE_KIND_ROW,
)
from komira_plan_wire import (
    plan_from_bytes,
    plan_wire_admit,
    plan_wire_check_values,
    plan_wire_supported_versions,
)
from komira_scan_source.scan_binding import (
    SCAN_KIND_NAME_CSV,
    SCAN_ORIENTATION_ROW,
    SNAPSHOT_PINNED,
)
from komira_scan_source.source_variant import SOURCE_VARIANT_CSV


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


def _assert_sort_on_amount(
    stem: String, p: LogicalPlan, nulls_first: Bool
) raises:
    assert_equal(Int(p.tag), Int(PLAN_SORT), stem + ": the root is not a SORT")
    ref d = p.sort_data_ref()
    assert_equal(len(d.keys), 1, stem + ": the SORT has one key")
    assert_equal(d.keys[0], String("amount"), stem + ": sort key")
    assert_false(d.descending[0], stem + ": sort_values is ascending")
    assert_equal(len(d.nulls_first), 1, stem + ": one nulls_first per key")
    assert_equal(
        d.nulls_first[0], nulls_first,
        stem + ": nulls_first decoded as " + String(d.nulls_first[0])
        + ", the fixture says " + String(nulls_first),
    )
    assert_equal(
        Int(d.child[].tag), Int(PLAN_SCAN), stem + ": the SORT reads the scan"
    )


def test_sort_values_na_position_first() raises:
    """`na_position="first"`: `nulls_first` true, which the render prints as
    NULLS FIRST (it deviates from the derived NULLS LAST)."""
    var p = _admitted(String("sort_values_na_first"))
    _assert_sort_on_amount(String("sort_values_na_first"), p, True)
    _assert_same_plan(
        String("sort_values_na_first"), p, sort_values_plan(True)
    )


def test_sort_values_na_position_last() raises:
    """`na_position="last"`, pandas' default: `nulls_first` false. That is
    the derived placement, which the render omits; the field assert and
    `plan_shape` read it."""
    var p = _admitted(String("sort_values_na_last"))
    _assert_sort_on_amount(String("sort_values_na_last"), p, False)
    _assert_same_plan(
        String("sort_values_na_last"), p, sort_values_plan(False)
    )


def _assert_merge_on_cust_id(
    stem: String, p: LogicalPlan, join_type: UInt8
) raises:
    assert_equal(Int(p.tag), Int(PLAN_JOIN), stem + ": the root is not a JOIN")
    ref d = p.join_data_ref()
    assert_equal(
        Int(d.join_type), Int(join_type),
        stem + ": join_type decoded as " + String(Int(d.join_type))
        + ", the fixture says " + String(Int(join_type))
        + " (JOIN_INNER=" + String(Int(JOIN_INNER)) + ", JOIN_LEFT="
        + String(Int(JOIN_LEFT)) + ")",
    )
    assert_equal(len(d.left_on), 1, stem + ": one left key")
    assert_equal(d.left_on[0], String("cust_id"), stem + ": left key")
    assert_equal(len(d.right_on), 1, stem + ": one right key")
    assert_equal(d.right_on[0], String("cust_id"), stem + ": right key")
    assert_false(d.residual.__bool__(), stem + ": merge(on=) has no residual")
    assert_equal(
        p.output_schema.field_name(4), String("cust_id_right"),
        stem + ": the right side's colliding key is renamed",
    )


def test_merge_how_left() raises:
    var p = _admitted(String("merge_left"))
    _assert_merge_on_cust_id(String("merge_left"), p, JOIN_LEFT)
    _assert_same_plan(String("merge_left"), p, merge_plan(JOIN_LEFT))


def test_merge_how_inner() raises:
    var p = _admitted(String("merge_inner"))
    _assert_merge_on_cust_id(String("merge_inner"), p, JOIN_INNER)
    _assert_same_plan(String("merge_inner"), p, merge_plan(JOIN_INNER))


def _assert_grouped_count(
    stem: String, p: LogicalPlan, column: String, output: String
) raises:
    """`column` empty means `count(*)`: the COUNT's input slot is absent."""
    assert_equal(
        Int(p.tag), Int(PLAN_SORT),
        stem + ": groupby sorts its keys, so the root is a SORT",
    )
    ref s = p.sort_data_ref()
    assert_equal(s.keys[0], String("cust_id"), stem + ": the group-key sort")
    assert_true(s.nulls_first[0], stem + ": the group-key sort puts nulls first")
    ref agg = s.child[]
    assert_equal(
        Int(agg.tag), Int(PLAN_AGGREGATE), stem + ": an AGGREGATE under the SORT"
    )
    ref d = agg.aggregate_data_ref()
    assert_equal(len(d.agg_exprs), 1, stem + ": one aggregate")
    ref a = d.agg_exprs[0]
    assert_equal(Int(a.func), Int(AGG_COUNT), stem + ": the aggregate is COUNT")
    if column == "":
        assert_false(
            a.child.__bool__(),
            stem + ": count(*) decoded with an input column; a COUNT that reads"
            + " a column counts its non-null values, not rows",
        )
    else:
        assert_true(
            a.child.__bool__(),
            stem + ": count(" + column + ") decoded with NO input column, i.e."
            + " as count(*): it would count rows, nulls included",
        )
        ref c = a.child.value()
        assert_equal(Int(c.tag), Int(EXPR_COL_REF), stem + ": COUNT's input")
        assert_equal(c.col_ref_name(), column, stem + ": COUNT's input column")
    assert_true(a.alias_name.__bool__(), stem + ": the output is named")
    assert_equal(a.alias_name.value(), output, stem + ": the output name")


def test_groupby_size_is_count_star() raises:
    """`groupby("cust_id").size()`: rows per group."""
    var p = _admitted(String("groupby_size"))
    _assert_grouped_count(String("groupby_size"), p, String(""), String("size"))
    _assert_same_plan(String("groupby_size"), p, groupby_size_plan())


def test_groupby_count_of_a_column() raises:
    """`groupby("cust_id").agg(n=("amount", "count"))`: non-null `amount`
    values per group."""
    var p = _admitted(String("groupby_count_col"))
    _assert_grouped_count(
        String("groupby_count_col"), p, String("amount"), String("n")
    )
    _assert_same_plan(String("groupby_count_col"), p, groupby_count_col_plan())


def test_read_csv_scan() raises:
    """`read_csv(path)`: the `komira.csv` binding. Its fingerprint in the
    fixture is the literal `komira_plan_ir`'s CSV arm test derived
    independently, so equality with the Mojo-built plan also holds
    `CsvSource`'s fold to that literal."""
    var p = _admitted(String("read_csv"))
    assert_equal(Int(p.tag), Int(PLAN_SCAN), "read_csv: the root is a SCAN")
    ref d = p.scan_data_ref()
    assert_equal(
        Int(d.source_kind), Int(SOURCE_KIND_ROW),
        "read_csv: the wire leaves source_kind UNSET and the decoded scan takes"
        + " ROW from the CSV kind's declared orientation",
    )
    assert_equal(
        Int(d.source.tag), Int(SOURCE_VARIANT_CSV),
        "read_csv: the source decodes as the CSV arm",
    )
    assert_true(d.source.is_binding_backed(), "read_csv: binding-backed")
    ref b = d.source.binding_ref()
    assert_equal(b.kind_name, String(SCAN_KIND_NAME_CSV), "read_csv: kind name")
    assert_equal(Int(b.kind_id), Int(DOOR_CSV_KIND_ID), "read_csv: kind id")
    assert_equal(b.name, String(DOOR_CSV_PATH), "read_csv: binding name")
    assert_equal(
        b.fingerprint, DOOR_CSV_FINGERPRINT, "read_csv: binding fingerprint"
    )
    assert_equal(
        Int(b.orientation), Int(SCAN_ORIENTATION_ROW),
        "read_csv: the CSV kind is a ROW source",
    )
    assert_equal(
        Int(b.snapshot_policy), Int(SNAPSHOT_PINNED),
        "read_csv: the file mtime pins the snapshot",
    )
    assert_equal(b.snapshot_token, DOOR_MTIME_NS, "read_csv: snapshot token")
    assert_equal(
        b.params.num_params(), 4,
        "read_csv: three dialect parameters plus the path",
    )
    _assert_same_plan(String("read_csv"), p, read_csv_plan())


def test_the_comparison_sees_each_key_field() raises:
    """The comparison of step 5 is not blind to the fields the mutants move:
    the Mojo-built plans that differ only in `nulls_first`, `join_type` or the
    COUNT's input have different shapes. (The render tells the two sorts
    apart too, by NULLS FIRST; it omits `nulls_first` only at the derived
    placement.)"""
    assert_true(
        plan_shape(sort_values_plan(True)) != plan_shape(sort_values_plan(False)),
        "plan_shape cannot tell na_position first from last",
    )
    assert_true(
        plan_shape(merge_plan(JOIN_LEFT)) != plan_shape(merge_plan(JOIN_INNER)),
        "plan_shape cannot tell a LEFT merge from an INNER one",
    )
    # The two groupby plans also differ in their output name, so the COUNT's
    # input is compared on its own, under one name.
    assert_true(
        agg_shape(AggExpr(AGG_COUNT, None, Optional(String("n"))))
        != agg_shape(
            AggExpr(
                AGG_COUNT,
                Optional(Expr.col_ref("amount")),
                Optional(String("n")),
            )
        ),
        "agg_shape cannot tell count(*) from count(col)",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_sort_values_na_position_first]()
    suite.test[test_sort_values_na_position_last]()
    suite.test[test_merge_how_left]()
    suite.test[test_merge_how_inner]()
    suite.test[test_groupby_size_is_count_star]()
    suite.test[test_groupby_count_of_a_column]()
    suite.test[test_read_csv_scan]()
    suite.test[test_the_comparison_sees_each_key_field]()
    suite^.run()
