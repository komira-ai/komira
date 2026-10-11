# =============================================================================
# The recorded optimizer decisions on LogicalPlan nodes: a join's
# `build_side` and `adaptive_allowed`, an aggregate's `mode`, a scan's
# `boundedness`.
# =============================================================================
#
# Each field must round-trip through every way the IR reproduces a node, and
# must enter plan identity, because the render IS `structural_hash`:
#
#   * the factory stores it (and its default is the documented one);
#   * `LogicalPlan.copy()` (the `*Data.copy()` arms) carries it;
#   * `_copy_plan` (the rebuild-through-factories deep copy most optimizer
#     rules reach) carries it;
#   * the render emits it when it is not the default, so two nodes differing
#     only in it hash differently, and a node holding the default renders
#     byte-for-byte as it did before the field existed;
#   * `validate_plan_integrity` refuses a value outside the space.
#
# Mutants each test was written to catch are named in its docstring.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_ALGO_AUTO,
    JOIN_BUILD_SIDE_LEFT,
    JOIN_BUILD_SIDE_RIGHT,
    JOIN_BUILD_SIDE_UNSET,
    AGG_MODE_SINGLE,
    AGG_MODE_PARTIAL,
    AGG_MODE_FINAL,
    AGG_MODE_UNSET,
    SCAN_BOUNDED,
    SCAN_UNBOUNDED,
)
from komira_plan_ir.plan_helpers import _copy_plan, validate_plan_integrity
from komira_plan_ir.plan_decisions import (
    EXCHANGE_KIND_GATHER,
    EXCHANGE_KIND_BROADCAST,
    EXCHANGE_KIND_HASH,
    EXCHANGE_KIND_RANGE,
    write_join_build_side,
    write_agg_mode,
    write_scan_boundedness,
    write_exchange_kind,
)


def _schema(a: String, b: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ArrowType.INT64, False))
    sb.add_field(Field(b, ArrowType.INT64, False))
    return sb.build()


def _scan(path: String, a: String, b: String) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(a, b))


def _join(build_side: UInt8, adaptive: Bool) -> LogicalPlan:
    var lo: List[String] = ["a"]
    var ro: List[String] = ["c"]
    return LogicalPlan.join(
        _scan("l.parquet", "a", "b"),
        _scan("r.parquet", "c", "d"),
        lo^, ro^, JOIN_INNER, JOIN_ALGO_AUTO, None, build_side, adaptive,
    )


def _agg(mode: UInt8) -> LogicalPlan:
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("b")), Optional[String]("s")))
    return LogicalPlan.aggregate(gb^, aggs^, _scan("t.parquet", "a", "b"), mode)


def _render(p: LogicalPlan) -> String:
    var s = String("")
    p.write_to(s)
    return s^


# =============================================================================
# Join build side and adaptive_allowed
# =============================================================================


def test_a_join_defaults_to_unset_build_side_and_not_adaptive() raises:
    """A join built without a decision states none. Catches a default of
    RIGHT (which would make a RAW plan claim a decision nobody made) and a
    default of `adaptive_allowed = True`."""
    var lo: List[String] = ["a"]
    var ro: List[String] = ["c"]
    var j = LogicalPlan.join(
        _scan("l.parquet", "a", "b"), _scan("r.parquet", "c", "d"),
        lo^, ro^, JOIN_INNER,
    )
    assert_equal(Int(j.join_data_ref().build_side), Int(JOIN_BUILD_SIDE_UNSET))
    assert_false(j.join_data_ref().adaptive_allowed)


def test_build_side_and_adaptive_survive_both_copies() raises:
    """Every (build_side, adaptive) pair comes back from `copy()` and from
    `_copy_plan`. Catches either copy path dropping a field (the copy would
    hand the build back to the right input)."""
    var sides: List[UInt8] = [
        JOIN_BUILD_SIDE_LEFT, JOIN_BUILD_SIDE_RIGHT, JOIN_BUILD_SIDE_UNSET
    ]
    var flags: List[Bool] = [False, True]
    for i in range(len(sides)):
        for k in range(len(flags)):
            var j = _join(sides[i], flags[k])
            var c = j.copy()
            assert_equal(Int(c.join_data_ref().build_side), Int(sides[i]))
            assert_equal(c.join_data_ref().adaptive_allowed, flags[k])
            var d = _copy_plan(j)
            assert_equal(Int(d.join_data_ref().build_side), Int(sides[i]))
            assert_equal(d.join_data_ref().adaptive_allowed, flags[k])
            assert_equal(c.structural_hash(), j.structural_hash())
            assert_equal(d.structural_hash(), j.structural_hash())


def test_build_side_does_not_change_the_output_schema() raises:
    """Child order alone fixes the output: left columns, then right. Catches a
    factory that orders the output by build side."""
    var j = _join(JOIN_BUILD_SIDE_LEFT, False)
    assert_equal(j.output_schema.num_columns(), 4)
    assert_equal(j.output_schema.field_name(0), "a")
    assert_equal(j.output_schema.field_name(1), "b")
    assert_equal(j.output_schema.field_name(2), "c")
    assert_equal(j.output_schema.field_name(3), "d")


def test_build_side_and_adaptive_enter_plan_identity() raises:
    """LEFT, RIGHT and UNSET render differently and hash differently, and so
    do adaptive and not. Catches the render dropping either field: two plans
    that build on different sides would share a compiled plan."""
    var unset = _join(JOIN_BUILD_SIDE_UNSET, False)
    var left = _join(JOIN_BUILD_SIDE_LEFT, False)
    var right = _join(JOIN_BUILD_SIDE_RIGHT, False)
    var adaptive = _join(JOIN_BUILD_SIDE_UNSET, True)
    assert_true("build=left" in _render(left), _render(left))
    assert_true("build=right" in _render(right), _render(right))
    assert_true(", adaptive)" in _render(adaptive), _render(adaptive))
    var hashes: List[UInt64] = [
        unset.structural_hash(),
        left.structural_hash(),
        right.structural_hash(),
        adaptive.structural_hash(),
    ]
    for a in range(len(hashes)):
        for b in range(a + 1, len(hashes)):
            assert_true(hashes[a] != hashes[b], String(a) + " vs " + String(b))


def test_an_undecided_join_renders_as_before_the_fields_existed() raises:
    """The pre-field render, byte for byte. Catches an unconditional emission,
    which would move every cached plan's `structural_hash`."""
    var text = _render(_join(JOIN_BUILD_SIDE_UNSET, False))
    var first = String(text.split("\n")[0])
    assert_equal(first, "Join(type=INNER, on=[a=c])")


def test_integrity_refuses_a_build_side_outside_the_space() raises:
    """Catches `validate_plan_integrity` not checking the value."""
    var j = _join(JOIN_BUILD_SIDE_LEFT, False)
    assert_true(validate_plan_integrity(j))
    j._join.value()[].build_side = UInt8(7)
    assert_false(validate_plan_integrity(j))


# =============================================================================
# Aggregate mode
# =============================================================================


def test_an_aggregate_defaults_to_unset_mode() raises:
    """Catches a default of SINGLE: an unoptimized plan would then state a
    decision."""
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var a = LogicalPlan.aggregate(gb^, AggExprArray(), _scan("t.parquet", "a", "b"))
    assert_equal(Int(a.aggregate_data_ref().mode), Int(AGG_MODE_UNSET))


def test_every_mode_survives_both_copies_and_hashes_apart() raises:
    """SINGLE, PARTIAL, FINAL and UNSET each come back from `copy()` and
    `_copy_plan`, and the four hash pairwise apart. Catches a copy that drops
    the mode (a PARTIAL would execute as a SINGLE and emit values where its
    consumer expects states) and a render that omits it."""
    var modes: List[UInt8] = [
        AGG_MODE_SINGLE, AGG_MODE_PARTIAL, AGG_MODE_FINAL, AGG_MODE_UNSET
    ]
    var hashes = List[UInt64]()
    for i in range(len(modes)):
        var a = _agg(modes[i])
        assert_equal(Int(a.aggregate_data_ref().mode), Int(modes[i]))
        assert_equal(Int(a.copy().aggregate_data_ref().mode), Int(modes[i]))
        assert_equal(Int(_copy_plan(a).aggregate_data_ref().mode), Int(modes[i]))
        assert_equal(_copy_plan(a).structural_hash(), a.structural_hash())
        hashes.append(a.structural_hash())
    for a in range(len(hashes)):
        for b in range(a + 1, len(hashes)):
            assert_true(hashes[a] != hashes[b], String(a) + " vs " + String(b))
    assert_true("mode=partial" in _render(_agg(AGG_MODE_PARTIAL)))
    assert_true("mode=final" in _render(_agg(AGG_MODE_FINAL)))
    assert_true("mode=single" in _render(_agg(AGG_MODE_SINGLE)))
    assert_false("mode=" in _render(_agg(AGG_MODE_UNSET)))


def test_mode_does_not_change_the_aggregate_output_schema() raises:
    """The host derives a PARTIAL's state layout; the IR node's schema is the
    same for every mode. Catches a factory that rewrites the schema by mode."""
    var single = _agg(AGG_MODE_SINGLE)
    var partial = _agg(AGG_MODE_PARTIAL)
    assert_equal(
        single.output_schema.num_columns(), partial.output_schema.num_columns()
    )
    for i in range(single.output_schema.num_columns()):
        assert_equal(
            single.output_schema.field_name(i),
            partial.output_schema.field_name(i),
        )


def test_integrity_refuses_a_mode_outside_the_space() raises:
    var a = _agg(AGG_MODE_PARTIAL)
    assert_true(validate_plan_integrity(a))
    a._aggregate.value()[].mode = UInt8(3)
    assert_false(validate_plan_integrity(a))


# =============================================================================
# Scan boundedness
# =============================================================================


def test_a_scan_is_bounded_unless_stated() raises:
    """RAW reads an unstated boundedness as BOUNDED. Catches a default of
    UNBOUNDED, which would make every plan a streaming plan."""
    var s = _scan("t.parquet", "a", "b")
    assert_equal(Int(s.scan_data_ref().boundedness), Int(SCAN_BOUNDED))
    var text = _render(s)
    var first = String(text.split("\n")[0])
    assert_false("boundedness" in first, first)


def test_unbounded_survives_both_copies_and_enters_identity() raises:
    """An UNBOUNDED scan comes back from `copy()`, `_copy_plan` and
    `scan_from_source`, renders `boundedness=unbounded`, and neither its hash
    nor its `ScanData.fingerprint` equals the bounded scan's. Catches a copy
    that drops the mark (a streaming source read as if it ended) and a render
    or fingerprint that cannot tell the two reads apart."""
    var bounded = _scan("t.parquet", "a", "b")
    var src = bounded.scan_data_ref().source.copy()
    var unbounded = LogicalPlan.scan_from_source(
        src^, _schema("a", "b"), boundedness=SCAN_UNBOUNDED
    )
    assert_equal(Int(unbounded.scan_data_ref().boundedness), Int(SCAN_UNBOUNDED))
    assert_equal(Int(unbounded.copy().scan_data_ref().boundedness), Int(SCAN_UNBOUNDED))
    assert_equal(Int(_copy_plan(unbounded).scan_data_ref().boundedness), Int(SCAN_UNBOUNDED))
    assert_true("boundedness=unbounded" in _render(unbounded), _render(unbounded))
    assert_true(unbounded.structural_hash() != bounded.structural_hash())
    assert_true(
        unbounded.scan_data_ref().fingerprint()
        != bounded.scan_data_ref().fingerprint()
    )
    assert_equal(_copy_plan(unbounded).structural_hash(), unbounded.structural_hash())


def test_scan_from_source_refuses_a_boundedness_outside_the_space() raises:
    """Catches the factory storing any byte."""
    var src = _scan("t.parquet", "a", "b").scan_data_ref().source.copy()
    var raised = False
    try:
        _ = LogicalPlan.scan_from_source(src^, _schema("a", "b"), boundedness=UInt8(2))
    except e:
        raised = True
        assert_true("boundedness 2" in String(e), String(e))
    assert_true(raised, "boundedness 2 was accepted")


def test_integrity_refuses_a_boundedness_outside_the_space() raises:
    var s = _scan("t.parquet", "a", "b")
    assert_true(validate_plan_integrity(s))
    s._scan.value()[].boundedness = UInt8(9)
    assert_false(validate_plan_integrity(s))


def _side_text(v: UInt8) -> String:
    var s = String("")
    write_join_build_side(s, v)
    return s^


def _mode_text(v: UInt8) -> String:
    var s = String("")
    write_agg_mode(s, v)
    return s^


def _bound_text(v: UInt8) -> String:
    var s = String("")
    write_scan_boundedness(s, v)
    return s^


def _kind_text(v: UInt8) -> String:
    var s = String("")
    write_exchange_kind(s, v)
    return s^


def test_every_writer_names_every_value_and_shows_an_unnamed_one() raises:
    """Each decision writer names every constant of its space (including
    UNSET) and writes `<space>#<n>` for a value no constant names, so a
    corrupt value is visible in a render instead of aliasing a neighbour.
    Catches an arm dropped (its value would print as `#<n>`) and a fallback
    that names a real value."""
    assert_equal(_side_text(JOIN_BUILD_SIDE_LEFT), "left")
    assert_equal(_side_text(JOIN_BUILD_SIDE_RIGHT), "right")
    assert_equal(_side_text(JOIN_BUILD_SIDE_UNSET), "unset")
    assert_equal(_side_text(UInt8(7)), "build_side#7")
    assert_equal(_mode_text(AGG_MODE_SINGLE), "single")
    assert_equal(_mode_text(AGG_MODE_PARTIAL), "partial")
    assert_equal(_mode_text(AGG_MODE_FINAL), "final")
    assert_equal(_mode_text(AGG_MODE_UNSET), "unset")
    assert_equal(_mode_text(UInt8(9)), "agg_mode#9")
    assert_equal(_bound_text(SCAN_BOUNDED), "bounded")
    assert_equal(_bound_text(SCAN_UNBOUNDED), "unbounded")
    assert_equal(_bound_text(UInt8(5)), "boundedness#5")
    assert_equal(_kind_text(EXCHANGE_KIND_GATHER), "GATHER")
    assert_equal(_kind_text(EXCHANGE_KIND_BROADCAST), "BROADCAST")
    assert_equal(_kind_text(EXCHANGE_KIND_HASH), "HASH")
    assert_equal(_kind_text(EXCHANGE_KIND_RANGE), "RANGE")
    assert_equal(_kind_text(UInt8(9)), "exchange_kind#9")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
