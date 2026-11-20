"""When `push_predicates_down` moves a Filter below a UDF-carrying Project
(`optimizer_udf_opacity`).

The fixture is `Project[a, b, c](Scan a, b, c)` carrying a MAP UDF that reads
`a` and writes `b`: `a` and `c` pass through, `b` is the UDF's output under a
name the child also has. A predicate on a passthrough column moves below the
Project, which keeps its UDF; a predicate on `b`, or under a UDF that is not
a stateless, non-volatile MAP with declared outputs, stays above it.
"""

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from plan_expr.expr import Expr, BIN_ADD, BIN_GT
from plan_expr.scalar_value import ScalarValue
from plan_expr.udf_data import (
    UdfData,
    UDF_KIND_MAP,
    UDF_KIND_FILTER,
    UDF_KIND_AGG,
    UDF_PAR_STATELESS,
    UDF_PAR_SERIAL_ORDERED,
    UDF_PAR_MERGEABLE,
    UDF_PAR_PARTITION_LOCAL,
    UDF_STABILITY_IMMUTABLE,
    UDF_STABILITY_STABLE,
    UDF_STABILITY_VOLATILE,
)
from plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_SCAN,
    SOURCE_PARQUET,
)

from optimizer.optimizer_filter import push_predicates_down
from optimizer.optimizer_udf_opacity import (
    udf_modified_columns,
    udf_opacity_opaque_to_predicate_pushdown,
    udf_supports_input_passthrough,
    udf_project_passes_predicate,
)


# =============================================================================
# Fixtures
# =============================================================================


def _scan() raises -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("c", ArrowType.INT64, True))
    return LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, sb.build())


def _udf(
    kind: UInt8 = UDF_KIND_MAP,
    writes: String = "b",
    parallelism: UInt8 = UDF_PAR_STATELESS,
    stability: UInt8 = UDF_STABILITY_IMMUTABLE,
) -> UdfData:
    """A UDF reading `a` and writing `writes` (none when empty)."""
    var ic = List[Tuple[String, UInt8]]()
    ic.append(("a", UInt8(3)))
    var oc = List[Tuple[String, UInt8]]()
    if writes != "":
        oc.append((String(writes), UInt8(3)))
    return UdfData(
        kind=kind,
        name=String("margin"),
        input_columns=ic^,
        output_columns=oc^,
        operator_factory_id=UInt32(9311),
        call_site_salt=UInt32(4),
        stability=stability,
        parallelism_tag=parallelism,
        registered_handle_id=Optional(Int(8)),
    )


def _cols(*names: String) -> ExprArray:
    var e = ExprArray()
    for n in names:
        e.append(Expr.col_ref(n))
    return e^


def _udf_project(var udf: UdfData, var child: LogicalPlan) -> LogicalPlan:
    """Project[a, b, c] over `child` carrying `udf`."""
    return LogicalPlan.project_with_udf(
        _cols("a", "b", "c"), child^, OwnedPointer(udf^)
    )


def _gt(col: String, v: Int) -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(v))
    )


def _count_udfs(plan: LogicalPlan) raises -> Int:
    var n = 1 if plan.has_udf() else 0
    if plan.tag == PLAN_FILTER:
        n += _count_udfs(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        n += _count_udfs(plan._project.value()[].child[])
    return n


def _assert_stays_above(out: LogicalPlan, why: String) raises:
    """`out` is the Filter, still directly over the UDF Project."""
    assert_equal(Int(out.tag), Int(PLAN_FILTER), why)
    ref below = out._filter.value()[].child[]
    assert_equal(Int(below.tag), Int(PLAN_PROJECT), why)
    assert_true(below.has_udf(), why + " (and the Project lost its UDF)")


def _assert_moved_below(out: LogicalPlan, why: String) raises:
    """`out` is the UDF Project, the same UDF, with the predicate under it: a
    Filter, or folded into the scan's filter."""
    assert_equal(Int(out.tag), Int(PLAN_PROJECT), why)
    assert_true(out.has_udf(), why + " (and the Project lost its UDF)")
    ref udf = out._project.value()[].udf.value()[]
    assert_equal(udf.name, String("margin"))
    assert_equal(udf.registered_handle_id.value(), 8)
    assert_equal(len(out._project.value()[].exprs), 3)
    ref below = out._project.value()[].child[]
    var has_pred = below.tag == PLAN_FILTER
    if below.tag == PLAN_SCAN and below._scan.value()[].filter:
        has_pred = True
    assert_true(has_pred, why + " (and the predicate is gone)")


# =============================================================================
# The column a predicate reads
# =============================================================================


def test_a_predicate_on_a_column_the_udf_rewrites_stays_above() raises:
    """`b > 3`: `b` is the UDF's output. The Project names it `ColRef(b)`,
    which by name alone looks like the child's `b` passing through. Catches:
    pushing by name, which would filter on the child's `b` instead."""
    var out = push_predicates_down(
        LogicalPlan.filter(_gt("b", 3), _udf_project(_udf(), _scan()))
    )
    _assert_stays_above(out, "a predicate on the UDF's output moved below it")


def test_a_predicate_on_a_passthrough_column_moves_below() raises:
    """`a > 3`: the UDF reads `a` and does not write it. Catches: the UDF
    Project being a full barrier, and a rebuild that drops its UDF."""
    var out = push_predicates_down(
        LogicalPlan.filter(_gt("a", 3), _udf_project(_udf(), _scan()))
    )
    _assert_moved_below(out, "a passthrough predicate did not move below")


def test_a_predicate_on_a_column_the_udf_does_not_read_moves_below() raises:
    """`c > 3`: the UDF neither reads nor writes `c`. Catches: requiring the
    column to be one the UDF reads, which blocks the safest case."""
    var out = push_predicates_down(
        LogicalPlan.filter(_gt("c", 3), _udf_project(_udf(), _scan()))
    )
    _assert_moved_below(out, "a predicate on an untouched column stayed above")


def test_a_predicate_reading_a_passthrough_and_a_rewritten_column_stays_above() raises:
    """`a + b > 3`: one column passes through, one is written. Catches:
    checking only the first column a predicate reads."""
    var pred = Expr.binary(
        BIN_GT,
        Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b")),
        Expr.literal(ScalarValue.from_int(3)),
    )
    var out = push_predicates_down(
        LogicalPlan.filter(pred^, _udf_project(_udf(), _scan()))
    )
    _assert_stays_above(out, "a predicate reading the UDF's output moved below")


def test_a_renamed_column_is_not_a_passthrough() raises:
    """Project[Alias(c, "a"), b] over Scan(a, b, c): above, `a` is the child's
    `c`. Catches: pushing `a > 3` raw, which would read the child's `a`."""
    var exprs = ExprArray()
    exprs.append(Expr.alias(Expr.col_ref("c"), "a"))
    exprs.append(Expr.col_ref("b"))
    var p = LogicalPlan.project_with_udf(exprs^, _scan(), OwnedPointer(_udf()))
    var out = push_predicates_down(LogicalPlan.filter(_gt("a", 3), p^))
    _assert_stays_above(out, "a predicate on a renamed column moved below")


def test_a_column_the_child_does_not_have_is_not_a_passthrough() raises:
    """Project[a, z] over Scan(a, b, c), UDF writes `b`: `z` is a placeholder
    the UDF output list does not name. Catches: pushing a predicate on a
    column the child cannot supply."""
    var p = LogicalPlan.project_with_udf(
        _cols("a", "z"), _scan(), OwnedPointer(_udf())
    )
    var out = push_predicates_down(LogicalPlan.filter(_gt("z", 1), p^))
    _assert_stays_above(out, "a predicate on a missing column moved below")


def test_a_column_the_project_does_not_output_stays_above() raises:
    """`q > 1` names no column of the Project. Catches: treating a column
    that is not found as passing through."""
    var out = push_predicates_down(
        LogicalPlan.filter(_gt("q", 1), _udf_project(_udf(), _scan()))
    )
    _assert_stays_above(out, "a predicate on an unknown column moved below")


# =============================================================================
# The UDF
# =============================================================================


def test_a_cse_introduced_udf_project_stays_a_barrier() raises:
    """A UDF Project flagged `is_cse_introduced`: its `_cse_*` columns exist
    only above it, and the UDF rebuild would drop the flag. Catches: the UDF
    rule bypassing the CSE barrier."""
    var p = LogicalPlan.project_with_udf(
        _cols("a", "b", "c"), _scan(), OwnedPointer(_udf()), True
    )
    var out = push_predicates_down(LogicalPlan.filter(_gt("a", 3), p^))
    _assert_stays_above(out, "a CSE-introduced UDF Project let a predicate through")
    assert_true(
        out._filter.value()[].child[]._project.value()[].is_cse_introduced,
        "the CSE flag was dropped",
    )


def test_a_udf_with_no_declared_output_columns_blocks_pushdown() raises:
    """A UDF with an empty output list: what it writes is unknown. Catches:
    an empty modified set read as "writes nothing"."""
    var out = push_predicates_down(
        LogicalPlan.filter(_gt("a", 3), _udf_project(_udf(writes=""), _scan()))
    )
    _assert_stays_above(out, "an undeclared UDF let a predicate through")


def test_a_stateful_udf_blocks_pushdown() raises:
    """SERIAL_ORDERED, MERGEABLE and PARTITION_LOCAL: a filter below changes
    the rows whose state the UDF carries. Catches: any one of the three let
    through."""
    var tags: List[UInt8] = [
        UDF_PAR_SERIAL_ORDERED, UDF_PAR_MERGEABLE, UDF_PAR_PARTITION_LOCAL
    ]
    for t in tags:
        var out = push_predicates_down(
            LogicalPlan.filter(
                _gt("a", 3), _udf_project(_udf(parallelism=t), _scan())
            )
        )
        _assert_stays_above(
            out, "a stateful UDF (tag " + String(t) + ") let a predicate through"
        )


def test_a_volatile_udf_blocks_pushdown_and_a_stable_one_does_not() raises:
    """VOLATILE stays above (section 10.9); STABLE is not volatile and moves
    below. Catches: the volatility check missing, or taking STABLE too."""
    var v = push_predicates_down(
        LogicalPlan.filter(
            _gt("a", 3),
            _udf_project(_udf(stability=UDF_STABILITY_VOLATILE), _scan()),
        )
    )
    _assert_stays_above(v, "a volatile UDF let a predicate through")
    var s = push_predicates_down(
        LogicalPlan.filter(
            _gt("a", 3),
            _udf_project(_udf(stability=UDF_STABILITY_STABLE), _scan()),
        )
    )
    _assert_moved_below(s, "a stable UDF blocked a passthrough predicate")


def test_a_predicate_reading_no_column_follows_the_udfs_opacity() raises:
    """`lit(false)` reads no column: it moves below a stateless UDF and stays
    above a volatile one. Catches: a predicate with no column passing every
    check vacuously, opaque UDF included."""
    var moved = push_predicates_down(
        LogicalPlan.filter(
            Expr.literal(ScalarValue.from_bool(False)),
            _udf_project(_udf(), _scan()),
        )
    )
    assert_equal(Int(moved.tag), Int(PLAN_PROJECT))
    assert_true(moved.has_udf(), "the Project lost its UDF")
    var kept = push_predicates_down(
        LogicalPlan.filter(
            Expr.literal(ScalarValue.from_bool(False)),
            _udf_project(_udf(stability=UDF_STABILITY_VOLATILE), _scan()),
        )
    )
    _assert_stays_above(kept, "a column-free predicate passed a volatile UDF")


def test_a_predicate_moves_below_two_stacked_udf_projects() raises:
    """Project[udf] over Project[udf] over Scan, `a > 3`: the pushed Filter
    meets the inner UDF Project and moves below it as well. Catches: the
    rebuilt Filter not re-entering pushdown, and either UDF dropped."""
    var inner = _udf_project(_udf(), _scan())
    var outer = _udf_project(_udf(), inner^)
    var out = push_predicates_down(LogicalPlan.filter(_gt("a", 3), outer^))
    assert_equal(_count_udfs(out), 2, "a UDF was dropped")
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))
    _assert_moved_below(
        out._project.value()[].child[], "the predicate stopped at the inner UDF"
    )


# =============================================================================
# The predicates on their own
# =============================================================================


def test_modified_columns_are_every_output_column() raises:
    """Exactly the output names; none for an empty output list."""
    var u = _udf()
    u.output_columns.append(("y", UInt8(3)))
    var m = udf_modified_columns(u)
    assert_equal(len(m), 2)
    assert_true("b" in m and "y" in m)
    assert_false("a" in m, "an input column read as modified")
    assert_equal(len(udf_modified_columns(_udf(writes=""))), 0)


def test_only_a_stateless_map_udf_is_transparent() raises:
    """A FILTER or AGG UDF is opaque, and passes no column through; a
    stateless MAP passes through every column it does not write."""
    assert_true(udf_opacity_opaque_to_predicate_pushdown(_udf(kind=UDF_KIND_FILTER)))
    assert_true(udf_opacity_opaque_to_predicate_pushdown(_udf(kind=UDF_KIND_AGG)))
    assert_false(udf_supports_input_passthrough(_udf(kind=UDF_KIND_AGG), "a"))
    assert_false(udf_opacity_opaque_to_predicate_pushdown(_udf()))
    assert_true(udf_supports_input_passthrough(_udf(), "a"))
    assert_true(udf_supports_input_passthrough(_udf(), "c"))
    assert_false(udf_supports_input_passthrough(_udf(), "b"))


def test_project_check_is_false_off_a_udf_project() raises:
    """A plain Project and a UDF Filter are not UDF Projects: False, so the
    caller never takes the UDF rebuild for them."""
    var plain = LogicalPlan.project(_cols("a", "b", "c"), _scan())
    assert_false(udf_project_passes_predicate(plain, _gt("a", 3)))
    var f = LogicalPlan.filter_with_udf(
        Expr.literal(ScalarValue.from_bool(True)),
        _scan(),
        OwnedPointer(_udf(kind=UDF_KIND_FILTER)),
    )
    assert_false(udf_project_passes_predicate(f, _gt("a", 3)))
    var p = _udf_project(_udf(), _scan())
    assert_true(udf_project_passes_predicate(p, _gt("a", 3)))


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_predicate_on_a_column_the_udf_rewrites_stays_above]()
    suite.test[test_a_predicate_on_a_passthrough_column_moves_below]()
    suite.test[test_a_predicate_on_a_column_the_udf_does_not_read_moves_below]()
    suite.test[test_a_predicate_reading_a_passthrough_and_a_rewritten_column_stays_above]()
    suite.test[test_a_renamed_column_is_not_a_passthrough]()
    suite.test[test_a_column_the_child_does_not_have_is_not_a_passthrough]()
    suite.test[test_a_column_the_project_does_not_output_stays_above]()
    suite.test[test_a_cse_introduced_udf_project_stays_a_barrier]()
    suite.test[test_a_udf_with_no_declared_output_columns_blocks_pushdown]()
    suite.test[test_a_stateful_udf_blocks_pushdown]()
    suite.test[test_a_volatile_udf_blocks_pushdown_and_a_stable_one_does_not]()
    suite.test[test_a_predicate_reading_no_column_follows_the_udfs_opacity]()
    suite.test[test_a_predicate_moves_below_two_stacked_udf_projects]()
    suite.test[test_modified_columns_are_every_output_column]()
    suite.test[test_only_a_stateless_map_udf_is_transparent]()
    suite.test[test_project_check_is_false_off_a_udf_project]()
    suite^.run()
