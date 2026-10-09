# =============================================================================
# test_plan_wire_agg_args.mojo: every aggregate function's ARGUMENTS on an
# AGGREGATE node, through the codec and through protoc's bytes.
# =============================================================================
#
# `_agg_expr_to_wire` / `_agg_expr_from_wire` carry an `AggExpr` (a function
# tag and four sparse argument slots) on `WireAggregateNode.agg_exprs`. Before
# this file, two members reached that path in a round trip: SUM(b) and CORR(b,
# a). COUNT reached it only in a test that asserts a refusal, so a decoder that
# dropped COUNT's input column (reading count(col) as count(*), which counts
# NULL rows too) left the package green, as did one that swapped the two
# arguments of a covar_*/regr_* member. The `Expr.agg_fn` member test goes
# through `WireAggFn`, a different message and a different decode function.
#
# A remapped function tag is caught elsewhere only when the two functions'
# output types differ: the decoder re-derives the AGGREGATE's output schema
# and refuses one that differs from the carried schema
# (PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED), so COUNT decoded as SUM is refused, and
# COUNT decoded as COUNT_DISTINCT (both non-null INT64) is not. The tests
# below compare the tag itself.
#
# What each test proves, and the defect it catches:
#
#   test_count_of_a_column_keeps_its_input
#       COUNT(x) decodes as COUNT with slot 0 = col(x) and slots 1-3 empty.
#       Red on: the decoder dropping slot 0 for COUNT; COUNT decoded as any
#       other function.
#   test_count_star_keeps_no_input
#       COUNT(*) decodes with all four slots empty. Red on: a decoder that
#       invents an argument for an argument-less COUNT.
#   test_every_agg_fn_keeps_its_func_and_arguments
#       one AGGREGATE node with COUNT(*) and every member of the AggFn
#       vocabulary, each with its own arguments (unary: one column; bivariate:
#       x in slot 0, y in slot 1). Red on: any member's tag remapped, any
#       member's argument dropped or replaced, slots 0 and 1 swapped. No
#       member here fills slots 2 or 3; those are carried and refused by
#       `test_the_two_unread_agg_slots_are_carried_and_refused`
#       (test_plan_wire_round_trip_ir.mojo).
#   test_every_agg_fn_bytes_are_frozen
#       the same plan, frozen as `tests/fixtures/golden/aggregate_every_fn.hex`
#       and held to protoc by `plan_wire_golden_fixtures` (BUCK): the `.txtpb`
#       names every function by its wire name, so each member's wire number is
#       pinned. This test decodes the committed bytes and protoc's canonical
#       bytes and asserts every slot of every member on both.
#
# Regolding: `test_every_agg_fn_bytes_are_frozen` prints a GOLDEN block for
# `aggregate_every_fn` on every run, as test_plan_wire_golden_bytes.mojo does;
# copy it into the `.hex`, then rewrite the `.txtpb` and `.canonical.hex` as
# BUCK says. A moved `.hex` is a wire change; read the diff before regolding.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import (
    AggExpr,
    AGG_COUNT,
    AGG_COUNT_IF,
    AGG_BOOL_AND,
    AGG_BOOL_OR,
    agg_is_bivariate,
)
from komira_plan_expr.expr import Expr, EXPR_COL_REF
from komira_plan_ir.logical_plan import LogicalPlan, ExprArray, AggExprArray
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SNAPSHOT_PINNED,
)
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.source_variant import SourceVariant, SOURCE_VARIANT_ORC

from komira_plan_wire import plan_to_bytes, plan_from_bytes
from komira_plan_wire.plan_wire_vocabulary import AGG_FN_WIRE_MEMBERS


comptime _FIXTURE_DIR: String = "src/komira_plan_wire/tests/fixtures/golden/"
comptime _GOLDEN_NAME: String = "aggregate_every_fn"
comptime _HEX_BYTES_PER_LINE: Int = 32


# =============================================================================
# The leaf
# =============================================================================


def _schema() raises -> Schema:
    """A group key and one column per argument class: `x` for COUNT and the
    first bivariate slot, `y` for the numeric unary members and the second
    bivariate slot, `flag` for the three members that fold a BOOL."""
    var sb = SchemaBuilder()
    sb.add_field(Field("g", ArrowType.STRING, True))
    sb.add_field(Field("x", ArrowType.INT64, True))
    sb.add_field(Field("y", ArrowType.FLOAT64, True))
    sb.add_field(Field("flag", ArrowType.BOOL, True))
    return sb.build()


def _scan() raises -> LogicalPlan:
    var p = ScanParams()
    p.put_str(String("path"), String("/data/events.orc"))
    var binding = ScanBinding(
        kind_id=scan_kind_id(String("komira.orc")),
        kind_name=String("komira.orc"),
        name=String("events"),
        params=p^,
        schema=_schema(),
        fingerprint=UInt64(0xA66),
        structural_id=UInt64(0xA66F),
        gate=PushdownGate.conjunctive_comparison(),
        snapshot_policy=SNAPSHOT_PINNED,
        snapshot_token=UInt64(742),
    )
    return LogicalPlan.scan_from_source(
        SourceVariant(tag=SOURCE_VARIANT_ORC, binding=binding^), _schema()
    )


def _aggregate(var ax: AggExprArray) raises -> LogicalPlan:
    var gb = ExprArray()
    gb.append(Expr.col_ref("g"))
    return LogicalPlan.aggregate(gb^, ax^, _scan())


def _every_fn_plan() raises -> LogicalPlan:
    """COUNT(*) first, then every engine tag 0..AGG_FN_WIRE_MEMBERS-1 in
    order, each aliased `f<tag>` so the output columns are distinct.

    The argument per member is the shape that member reads
    (`_agg_arg_slots` in plan_wire_values.mojo): a bivariate member gets
    col(x) in slot 0 and col(y) in slot 1, two DIFFERENT columns so a swap is
    visible; COUNT_IF, BOOL_AND and BOOL_OR get the BOOL column; COUNT gets
    `x`; every other unary member gets `y`."""
    var ax = AggExprArray()
    var none_expr: Optional[Expr] = None
    ax.append(AggExpr(AGG_COUNT, none_expr^, Optional(String("count_star"))))
    for i in range(AGG_FN_WIRE_MEMBERS):
        var tag = UInt8(i)
        var name = Optional(String("f") + String(i))
        if agg_is_bivariate(tag):
            ax.append(
                AggExpr(
                    tag,
                    Optional(Expr.col_ref("x")),
                    Optional(Expr.col_ref("y")),
                    name^,
                )
            )
        elif tag == AGG_COUNT_IF or tag == AGG_BOOL_AND or tag == AGG_BOOL_OR:
            ax.append(AggExpr(tag, Optional(Expr.col_ref("flag")), name^))
        elif tag == AGG_COUNT:
            ax.append(AggExpr(tag, Optional(Expr.col_ref("x")), name^))
        else:
            ax.append(AggExpr(tag, Optional(Expr.col_ref("y")), name^))
    return _aggregate(ax^)


# =============================================================================
# Slot-by-slot comparison
# =============================================================================


def _slot(o: Optional[Expr]) -> String:
    """One argument slot as text: absent, or the expression's tag and render.
    An empty slot and a present one never print alike."""
    if not o:
        return String("<absent>")
    return String("tag ") + String(Int(o.value().tag)) + " " + String(o.value())


def _alias(o: Optional[String]) -> String:
    if not o:
        return String("<no alias>")
    return String("alias ") + o.value()


def _assert_agg_slots(
    what: String, want: LogicalPlan, got: LogicalPlan
) raises:
    """Every `AggExpr` of `got`'s AGGREGATE node equals `want`'s: function
    tag, each of the four slots (present or absent, and what it holds), and
    the alias. Read from the decoded `AggregateData`, not the plan render, so
    no rendering choice can hide a slot."""
    ref w = want.aggregate_data_ref()
    ref g = got.aggregate_data_ref()
    assert_equal(
        len(g.agg_exprs),
        len(w.agg_exprs),
        what + ": the decoded AGGREGATE holds a different number of aggregates",
    )
    for i in range(len(w.agg_exprs)):
        ref a = w.agg_exprs[i]
        ref b = g.agg_exprs[i]
        var at = what + ": aggregate " + String(i) + " (" + String(a) + ")"
        assert_equal(
            Int(b.func),
            Int(a.func),
            at + " decoded as a different function: " + String(b),
        )
        assert_equal(
            _slot(b.child), _slot(a.child), at + ": slot 0 did not survive"
        )
        assert_equal(
            _slot(b.child1), _slot(a.child1), at + ": slot 1 did not survive"
        )
        assert_equal(
            _slot(b.child2), _slot(a.child2), at + ": slot 2 did not survive"
        )
        assert_equal(
            _slot(b.child3), _slot(a.child3), at + ": slot 3 did not survive"
        )
        assert_equal(
            _alias(b.alias_name),
            _alias(a.alias_name),
            at + ": the alias did not survive",
        )


def _round_trip(plan: LogicalPlan) raises -> LogicalPlan:
    var bytes = plan_to_bytes(plan)
    return plan_from_bytes(bytes^)


# =============================================================================
# COUNT(col) and COUNT(*)
# =============================================================================


def test_count_of_a_column_keeps_its_input() raises:
    """COUNT(x) counts the non-NULL values of x; COUNT(*) counts rows. The
    two differ on any group with a NULL x, so the decoded slot 0 is asserted
    by name and expression tag, independently of `_assert_agg_slots`."""
    var ax = AggExprArray()
    ax.append(
        AggExpr(AGG_COUNT, Optional(Expr.col_ref("x")), Optional(String("n_x")))
    )
    var plan = _aggregate(ax^)
    var back = _round_trip(plan)
    ref d = back.aggregate_data_ref()
    assert_equal(len(d.agg_exprs), 1, "COUNT(x): one aggregate expected")
    ref c = d.agg_exprs[0]
    assert_equal(
        Int(c.func),
        Int(AGG_COUNT),
        "COUNT(x) decoded as another function: " + String(c),
    )
    assert_true(
        Bool(c.child),
        "COUNT(x) decoded with NO input: the decoder dropped slot 0, so the"
        " plan now counts rows (NULLs included) instead of non-NULL x: "
        + String(c),
    )
    assert_equal(
        Int(c.child.value().tag),
        Int(EXPR_COL_REF),
        "COUNT(x): slot 0 is not a column reference: " + String(c),
    )
    assert_equal(
        c.child.value().col_ref_name(),
        String("x"),
        "COUNT(x): slot 0 names a different column: " + String(c),
    )
    assert_true(
        not c.child1 and not c.child2 and not c.child3,
        "COUNT(x): a slot COUNT does not read came back populated: "
        + String(c),
    )
    _assert_agg_slots(String("COUNT(x)"), plan, back)


def test_count_star_keeps_no_input() raises:
    var none_expr: Optional[Expr] = None
    var ax = AggExprArray()
    ax.append(AggExpr(AGG_COUNT, none_expr^, Optional(String("n"))))
    var plan = _aggregate(ax^)
    var back = _round_trip(plan)
    ref d = back.aggregate_data_ref()
    assert_equal(len(d.agg_exprs), 1, "COUNT(*): one aggregate expected")
    ref c = d.agg_exprs[0]
    assert_equal(
        Int(c.func),
        Int(AGG_COUNT),
        "COUNT(*) decoded as another function: " + String(c),
    )
    assert_true(
        not c.child and not c.child1 and not c.child2 and not c.child3,
        "COUNT(*) decoded WITH an argument; it now counts the non-NULL values"
        " of a column instead of rows: " + String(c),
    )
    _assert_agg_slots(String("COUNT(*)"), plan, back)


# =============================================================================
# Every member
# =============================================================================


def test_every_agg_fn_keeps_its_func_and_arguments() raises:
    var plan = _every_fn_plan()
    assert_equal(
        len(plan.aggregate_data_ref().agg_exprs),
        AGG_FN_WIRE_MEMBERS + 1,
        "the corpus is COUNT(*) plus one aggregate per AggFn member",
    )
    var back = _round_trip(plan)
    _assert_agg_slots(String("every AggFn, round trip"), plan, back)
    assert_equal(
        String(back),
        String(plan),
        "every AggFn: the decoded plan renders differently",
    )


# =============================================================================
# Every member, frozen
# =============================================================================


def _hex_nibble(v: UInt8) -> String:
    comptime DIGITS = String("0123456789abcdef")
    return String(DIGITS[byte=Int(v)])


def _to_hex_lines(bytes: List[UInt8]) -> String:
    """The `.hex` rendering test_plan_wire_golden_bytes.mojo writes: lowercase,
    32 bytes per line, each line ending in a line break."""
    var out = String("")
    for i in range(len(bytes)):
        out += _hex_nibble(bytes[i] >> 4)
        out += _hex_nibble(bytes[i] & 0xF)
        if (i % _HEX_BYTES_PER_LINE) == (_HEX_BYTES_PER_LINE - 1):
            out += "\n"
    if len(bytes) % _HEX_BYTES_PER_LINE != 0:
        out += "\n"
    return out^


def _hex_value(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + UInt8(10)
    raise Error(
        "plan_wire agg golden: a `.hex` fixture holds a byte that is not a"
        " lowercase hex digit: " + String(Int(c))
    )


def _from_hex(text: String) raises -> List[UInt8]:
    var nibbles = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord(" ")) or c == UInt8(ord("\n")):
            continue
        nibbles.append(_hex_value(c))
    if len(nibbles) % 2 != 0:
        raise Error("plan_wire agg golden: odd number of hex digits")
    var out = List[UInt8]()
    for i in range(0, len(nibbles), 2):
        out.append((nibbles[i] << 4) | nibbles[i + 1])
    return out^


def _read_fixture(name: String) raises -> List[UInt8]:
    """`tests/fixtures/golden/<name>.hex`, staged at its repository path
    under the test's working directory (BUCK `test_data`)."""
    var path = _FIXTURE_DIR + name + ".hex"
    var text = String("")
    try:
        with open(path, "r") as f:
            text = f.read()
    except:
        raise Error(
            "plan_wire agg golden: fixture `" + path + "` is missing; the"
            " GOLDEN block printed above is the `.hex` content"
        )
    return _from_hex(text)


def test_every_agg_fn_bytes_are_frozen() raises:
    """Freeze, then read back the committed bytes and protoc's.

    The `.hex` is this encoder's output, compared byte for byte. The
    `.canonical.hex` is protoc's encoding of the `.txtpb` protoc decoded from
    the `.hex` (`plan_wire_golden_fixtures`, `golden_aggregate_every_fn_canonical`):
    it omits every field at its default (`has_child1: false` and the like), so
    it is the form a non-Mojo producer writes, and the decoder must find each
    argument in it too."""
    var plan = _every_fn_plan()
    var bytes = plan_to_bytes(plan)
    print("GOLDEN-BEGIN " + _GOLDEN_NAME)
    print(_to_hex_lines(bytes), end="")
    print("GOLDEN-END " + _GOLDEN_NAME)

    var want = _read_fixture(_GOLDEN_NAME)
    assert_equal(
        len(bytes),
        len(want),
        "aggregate_every_fn: the encoder's bytes changed length; that is a"
        " wire change",
    )
    for i in range(len(want)):
        assert_equal(
            Int(bytes[i]),
            Int(want[i]),
            "aggregate_every_fn: the encoder's bytes diverge from the frozen"
            " fixture at offset " + String(i),
        )

    var frozen = plan_from_bytes(want^)
    _assert_agg_slots(String("every AggFn, frozen .hex"), plan, frozen)
    assert_equal(String(frozen), String(plan), "frozen .hex: render differs")

    var canonical = _read_fixture(_GOLDEN_NAME + ".canonical")
    assert_true(
        len(canonical) < len(bytes),
        "aggregate_every_fn.canonical.hex is not shorter than the `.hex`, so"
        " it is not protoc's encoding (protoc omits default scalars that this"
        " encoder writes)",
    )
    var foreign = plan_from_bytes(canonical^)
    _assert_agg_slots(String("every AggFn, protoc's bytes"), plan, foreign)
    assert_equal(
        String(foreign), String(plan), "protoc's bytes: render differs"
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_count_of_a_column_keeps_its_input]()
    suite.test[test_count_star_keeps_no_input]()
    suite.test[test_every_agg_fn_keeps_its_func_and_arguments]()
    suite.test[test_every_agg_fn_bytes_are_frozen]()
    suite^.run()
