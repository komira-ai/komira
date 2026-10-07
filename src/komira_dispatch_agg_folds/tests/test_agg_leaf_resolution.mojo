# =============================================================================
# `agg_leaf_resolution`: the PROJECT an aggregate's parquet leaf carries, the
# binding every arm receives, the file-derived scan projection, and the two
# agreement checks (the raising one for a resident leaf, the fail-open one for
# the streaming route).
#
# No other test of this package reaches this module (the aggregate entry point
# that uses it moves in a later PR), so every arm is driven directly:
#
#   * `AggLeafProject`: deep copy, the sub-project by output name (kept,
#     dropped, order), and the one-op tail;
#   * `AggLeafBinding`: the plain binding, a binding with a project, and deep
#     copies of both;
#   * `leaf_scan_projection`: project and predicate columns, first-seen order,
#     no duplicates;
#   * `assert_leaf_schema_agrees`: agreement returns, and a count, name or
#     type disagreement raises with both name lists in the message;
#   * `agg_leaf_project_of`: a non-PROJECT, a PROJECT tag without its data, a
#     PROJECT whose output schema has the wrong width, and a good one;
#   * `leaf_project_agrees_with_resolution`: each of its five refusals and
#     its admit.
# =============================================================================

from std.collections import List, Optional
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_plan_expr.expr import BIN_ADD, BIN_GT, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    ExprArray, LogicalPlan, PLAN_PROJECT, SOURCE_PARQUET,
)
from komira_plan_ir.physical_plan import OP_PROJECT

from komira_dispatch_agg_folds.agg_leaf_resolution import (
    AggLeafBinding,
    AggLeafProject,
    agg_leaf_project_of,
    assert_leaf_schema_agrees,
    leaf_project_agrees_with_resolution,
    leaf_scan_projection,
)


# =============================================================================
# Fixtures
# =============================================================================


def _schema(imm names: List[String], imm types: List[ArrowType]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], types[i], True))
    return sb.build()


def _footer() -> Schema:
    """The parquet footer: a INT64, b INT64, s STRING."""
    var n: List[String] = [String("a"), String("b"), String("s")]
    var t: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64, ArrowType.STRING]
    return _schema(n, t)


def _plus(l: String, r: String) -> Expr:
    return Expr.binary(BIN_ADD, Expr.col_ref(l), Expr.col_ref(r))


def _project3() -> AggLeafProject:
    """[a+b AS __agg_in_0, a AS a, s AS __grp_key_0]."""
    var e = ExprArray()
    e.append(_plus("a", "b"))
    e.append(Expr.col_ref(String("a")))
    e.append(Expr.col_ref(String("s")))
    var names: List[String] = [
        String("__agg_in_0"), String("a"), String("__grp_key_0"),
    ]
    return AggLeafProject(e^, names^)


def _resolution3() -> Schema:
    var n: List[String] = [
        String("__agg_in_0"), String("a"), String("__grp_key_0"),
    ]
    var t: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64, ArrowType.STRING]
    return _schema(n, t)


def _raises_with(imm expected: Schema, imm actual: Schema, needle: String) raises:
    var raised = False
    try:
        assert_leaf_schema_agrees(expected, actual, String("site_x"))
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.find("site_x") >= 0, msg)
        assert_true(msg.find(needle) >= 0, msg)
    assert_true(raised, "a disagreement must raise")


# =============================================================================
# AggLeafProject
# =============================================================================


def test_project_copy_is_deep_and_equal() raises:
    """A copy carries the same names and one expression per name. Catches a
    copy that drops the expressions (an empty `e`)."""
    var p = _project3()
    var c = p.copy()
    assert_equal(len(c.exprs), 3)
    assert_equal(len(c.out_names), 3)
    for i in range(3):
        assert_equal(c.out_names[i], p.out_names[i])
    assert_true(c.exprs[0].is_binary())
    assert_equal(c.exprs[2].col_ref_name(), "s")


def test_subset_keeps_project_order_and_drops_unknown_names() raises:
    """`keep = [__grp_key_0, nope, __agg_in_0]` yields the two outputs it
    names in the PROJECT's order (__agg_in_0 first) and silently drops the
    name the project does not output. Catches a subset in `keep` order and a
    subset that keeps everything (`wanted` never cleared)."""
    var p = _project3()
    var keep: List[String] = [
        String("__grp_key_0"), String("nope"), String("__agg_in_0"),
    ]
    var s = p.subset_by_out_names(keep)
    assert_equal(len(s.out_names), 2)
    assert_equal(len(s.exprs), 2)
    assert_equal(s.out_names[0], "__agg_in_0")
    assert_equal(s.out_names[1], "__grp_key_0")
    assert_true(s.exprs[0].is_binary())
    assert_equal(s.exprs[1].col_ref_name(), "s")
    var none = p.subset_by_out_names(List[String]())
    assert_equal(len(none.out_names), 0)


def test_to_ops_is_one_project_op() raises:
    """The tail is ONE `OP_PROJECT` carrying every expression and name.
    Catches the leaf predicates added as filter ops here."""
    var ops = _project3().to_ops()
    assert_equal(len(ops), 1)
    assert_equal(ops[0].tag, OP_PROJECT)
    assert_equal(len(ops[0].project_exprs.value()), 3)
    assert_equal(ops[0].project_names.value()[2], "__grp_key_0")


# =============================================================================
# AggLeafBinding
# =============================================================================


def test_plain_binding_has_no_project_and_an_empty_tail() raises:
    """The no-PROJECT binding: both schemas are the footer, no project, no
    scan projection, an empty op tail, and a copy that stays that way.
    Catches `has_project` returning True for a None project."""
    var b = AggLeafBinding.plain(_footer())
    assert_false(b.has_project())
    assert_equal(len(b.leaf_ops()), 0)
    assert_equal(b.resolution_schema.num_columns(), 3)
    assert_equal(b.scan_schema.field_name(2), "s")
    assert_false(b.scan_projection.__bool__())
    var c = b.copy()
    assert_false(c.has_project())
    assert_false(c.scan_projection.__bool__())
    assert_equal(c.scan_schema.num_columns(), 3)


def test_binding_with_project_copies_both_optionals() raises:
    """A binding with a project and a scan projection: one project op in the
    tail, and a deep copy that still has both. Catches a copy that keeps
    only the schemas."""
    var proj: List[String] = [String("a"), String("b"), String("s")]
    var b = AggLeafBinding(
        _footer(),
        _resolution3(),
        Optional[AggLeafProject](_project3()),
        Optional[List[String]](proj^),
    )
    assert_true(b.has_project())
    assert_equal(len(b.leaf_ops()), 1)
    var c = b.copy()
    assert_true(c.has_project())
    assert_equal(len(c.project.value().out_names), 3)
    assert_true(c.scan_projection.__bool__())
    assert_equal(c.scan_projection.value()[1], "b")
    assert_equal(c.resolution_schema.field_name(0), "__agg_in_0")


# =============================================================================
# leaf_scan_projection
# =============================================================================


def test_scan_projection_is_file_columns_first_seen_without_duplicates() raises:
    """Project [a+b, a, s] and predicates [b > 3, c > 0]: the projection is
    [a, b, s, c] — the predicate-only column `c` is included (a filter column
    missing from the decode is a wrong surviving set), and `a` and `b`
    appear once. Catches the predicates ignored and the dedup removed."""
    var p = _project3()
    var preds = Slab[Expr]()
    preds.append(
        Expr.binary(
            BIN_GT, Expr.col_ref(String("b")), Expr.literal(ScalarValue.from_int(3))
        )
    )
    preds.append(
        Expr.binary(
            BIN_GT, Expr.col_ref(String("c")), Expr.literal(ScalarValue.from_int(0))
        )
    )
    var out = leaf_scan_projection(p.exprs, preds)
    assert_equal(len(out), 4)
    assert_equal(out[0], "a")
    assert_equal(out[1], "b")
    assert_equal(out[2], "s")
    assert_equal(out[3], "c")


# =============================================================================
# assert_leaf_schema_agrees
# =============================================================================


def test_agreeing_schemas_return() raises:
    """Same names and types, different nullability: no raise (nullability is
    deliberately not compared). Catches nullability added to the compare."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("__agg_in_0"), ArrowType.INT64, False))
    sb.add_field(Field(String("a"), ArrowType.INT64, False))
    sb.add_field(Field(String("__grp_key_0"), ArrowType.STRING, False))
    assert_leaf_schema_agrees(_resolution3(), sb.build(), String("site_x"))


def test_disagreeing_count_raises_with_both_lists() raises:
    """Three inferred columns against two emitted: raises, and the message
    lists both, comma-separated. Catches the count check removed (the name
    loop would then read past the shorter schema)."""
    var n: List[String] = [String("__agg_in_0"), String("a")]
    var t: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64]
    _raises_with(
        _resolution3(),
        _schema(n, t),
        "inferred [__agg_in_0, a, __grp_key_0] vs emitted [__agg_in_0, a]",
    )


def test_disagreeing_name_raises() raises:
    """Same width, the second name differs: raises. Catches the name compare
    removed."""
    var n: List[String] = [String("__agg_in_0"), String("b"), String("__grp_key_0")]
    var t: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64, ArrowType.STRING]
    _raises_with(_resolution3(), _schema(n, t), "vs emitted [__agg_in_0, b,")


def test_disagreeing_type_raises() raises:
    """Same names, the first type differs (FLOAT64 for INT64): raises. Catches
    the type compare removed, the case the docstring calls a silent wrong
    answer."""
    var n: List[String] = [String("__agg_in_0"), String("a"), String("__grp_key_0")]
    var t: List[ArrowType] = [ArrowType.FLOAT64, ArrowType.INT64, ArrowType.STRING]
    _raises_with(_resolution3(), _schema(n, t), "refused rather than folded")


# =============================================================================
# agg_leaf_project_of
# =============================================================================


def _scan_plan() -> LogicalPlan:
    return LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, _footer())


def test_a_non_project_child_is_none() raises:
    """A SCAN is not a PROJECT: None. Catches the tag test removed."""
    assert_false(agg_leaf_project_of(_scan_plan()).__bool__())


def test_a_project_tag_without_its_data_is_none() raises:
    """A node tagged PROJECT whose project data is absent: None, not a crash.
    Catches the second operand of the guard removed."""
    var bare = LogicalPlan(PLAN_PROJECT, _resolution3())
    assert_false(agg_leaf_project_of(bare).__bool__())


def test_a_project_lifts_exprs_and_output_names() raises:
    """A real PROJECT [a+b AS x, s]: its expressions, and its names read off
    the node's output schema. Catches names taken from the expressions
    instead of the output schema (the alias would be lost)."""
    var e = ExprArray()
    e.append(Expr.alias(_plus("a", "b"), String("x")))
    e.append(Expr.col_ref(String("s")))
    var plan = LogicalPlan.project(e^, _scan_plan())
    var got = agg_leaf_project_of(plan)
    assert_true(got.__bool__())
    assert_equal(len(got.value().exprs), 2)
    assert_equal(got.value().out_names[0], "x")
    assert_equal(got.value().out_names[1], "s")


def test_a_project_whose_schema_has_the_wrong_width_is_none() raises:
    """A PROJECT of two expressions whose output schema says three fields:
    None (decline rather than guess). Catches the width check removed."""
    var e = ExprArray()
    e.append(Expr.col_ref(String("a")))
    e.append(Expr.col_ref(String("s")))
    var plan = LogicalPlan.project(e^, _scan_plan())
    plan.output_schema = _resolution3()
    assert_false(agg_leaf_project_of(plan).__bool__())


# =============================================================================
# leaf_project_agrees_with_resolution
# =============================================================================


def test_streaming_gate_admits_an_agreeing_project() raises:
    """The project inferred against the footer gives exactly the resolution
    schema: True. Catches a gate that always declines."""
    assert_true(
        leaf_project_agrees_with_resolution(_project3(), _resolution3(), _footer())
    )


def test_streaming_gate_declines_a_width_mismatch() raises:
    """The resolution schema has two columns for three expressions: False.
    Catches the first width check removed."""
    var n: List[String] = [String("__agg_in_0"), String("a")]
    var t: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64]
    assert_false(
        leaf_project_agrees_with_resolution(_project3(), _schema(n, t), _footer())
    )


def test_streaming_gate_declines_names_out_of_step_with_exprs() raises:
    """A project of three expressions but two names: False. Catches the
    second width check removed (the name loop would read past the names)."""
    var p = _project3()
    var e = ExprArray()
    for i in range(len(p.exprs)):
        e.append(p.exprs[i].copy())
    var names: List[String] = [String("__agg_in_0"), String("a")]
    var short = AggLeafProject(e^, names^)
    assert_false(
        leaf_project_agrees_with_resolution(short, _resolution3(), _footer())
    )


def test_streaming_gate_declines_a_renamed_output() raises:
    """The resolution schema's third name differs from the project's: False.
    Catches the name compare removed."""
    var n: List[String] = [String("__agg_in_0"), String("a"), String("other")]
    var t: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64, ArrowType.STRING]
    assert_false(
        leaf_project_agrees_with_resolution(_project3(), _schema(n, t), _footer())
    )


def test_streaming_gate_declines_a_column_absent_from_the_footer() raises:
    """The footer lacks `b`, so inferring `a+b` raises inside the gate, which
    reports a disagreement (False) instead of propagating. Catches the
    `except` arm turned into a re-raise."""
    var n: List[String] = [String("a"), String("s")]
    var t: List[ArrowType] = [ArrowType.INT64, ArrowType.STRING]
    assert_false(
        leaf_project_agrees_with_resolution(_project3(), _resolution3(), _schema(n, t))
    )


def test_streaming_gate_declines_a_widened_column() raises:
    """The footer's `a` is INT32 while the plan resolved `a` as INT64: the
    inferred type differs at index 1, False. Catches the type compare
    removed."""
    var n: List[String] = [String("a"), String("b"), String("s")]
    var t: List[ArrowType] = [ArrowType.INT64, ArrowType.INT32, ArrowType.STRING]
    var e = ExprArray()
    e.append(Expr.col_ref(String("a")))
    e.append(Expr.col_ref(String("b")))
    var names: List[String] = [String("a"), String("b")]
    var p = AggLeafProject(e^, names^)
    var rn: List[String] = [String("a"), String("b")]
    var rt: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64]
    assert_false(
        leaf_project_agrees_with_resolution(p, _schema(rn, rt), _schema(n, t))
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
