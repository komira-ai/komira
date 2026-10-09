# =============================================================================
# test_payload_narrow_columns: each condition of the rule, one case each
# =============================================================================
#
# Every case changes exactly one input against a base case that narrows, and
# asserts the whole result rendered (`scan:name:bytes:base`), never a count or
# a boolean: a refusal is seen as the refused column missing while its sibling
# column, or the other side, is still there, so a case cannot pass because the
# rule did nothing. The base case is a join of two Parquet scans:
#   left  scan 0: key (INT64), pv (INT64, footer [1, 999]),  qv (INT64, [5, 9])
#   right scan 1: key (INT64), bv (INT64, footer [1, 9999])
# which narrows to `0:pv:2:1 0:qv:1:5 | 1:bv:2:1`.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.payload_narrow import PayloadNarrowSpec
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_FULL,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_CROSS,
)
from komira_plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)

from komira_lowering_rules.payload_narrow import derive_payload_narrow


# =============================================================================
# Fixtures
# =============================================================================


@fieldwise_init
struct Col(Copyable, Movable):
    """One column of a fixture scan: its declared field and its footer entry."""

    var name: String
    var arrow_type: ArrowType
    var nullable: Bool
    var in_footer: Bool
    var lo: Optional[ScalarValue]
    var hi: Optional[ScalarValue]


def _int(name: String, lo: Int64, hi: Int64) -> Col:
    return Col(
        name, ArrowType.INT64, False, True,
        Optional[ScalarValue](ScalarValue.from_int64(lo)),
        Optional[ScalarValue](ScalarValue.from_int64(hi)),
    )


def _key() -> Col:
    # The key's own range fits four bytes, so only the key exclusion keeps it
    # out of the result.
    return _int("key", 0, 24999999)


def _schema(cols: List[Col]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(cols)):
        sb.add_field(Field(cols[i].name, cols[i].arrow_type, cols[i].nullable))
    return sb.build()


def _footer(cols: List[Col]) -> TableStats:
    var names = List[String]()
    var stats = List[ColumnStats]()
    for i in range(len(cols)):
        if not cols[i].in_footer:
            continue
        names.append(cols[i].name)
        stats.append(ColumnStats(None, cols[i].lo.copy(), cols[i].hi.copy(), Optional[Int](0)))
    return TableStats(1000, names^, stats^, STATS_SOURCE_PARQUET_METADATA)


def _scan(cols: List[Col], plan_stats: Optional[TableStats] = None) -> LogicalPlan:
    """A Parquet scan of `cols`. `plan_stats` is what a producer recorded on
    the plan; the rule must never read it."""
    return LogicalPlan.scan(
        "t.parquet", SOURCE_PARQUET, _schema(cols), None, None, None, plan_stats.copy()
    )


def _left_cols() -> List[Col]:
    var c = List[Col]()
    c.append(_key())
    c.append(_int("pv", 1, 999))
    c.append(_int("qv", 5, 9))
    return c^


def _right_cols() -> List[Col]:
    var c = List[Col]()
    c.append(_key())
    c.append(_int("bv", 1, 9999))
    return c^


def _keys(name: String) -> List[String]:
    var k = List[String]()
    k.append(name)
    return k^


def _footers(left: List[Col], right: List[Col]) -> List[Optional[TableStats]]:
    var f = List[Optional[TableStats]]()
    f.append(Optional[TableStats](_footer(left)))
    f.append(Optional[TableStats](_footer(right)))
    return f^


def _render(specs: List[List[PayloadNarrowSpec]]) -> String:
    """`scan:name:bytes:base` per spec, scans separated by ` | `."""
    var out = String()
    for s in range(len(specs)):
        if s > 0:
            out += " | "
        for i in range(len(specs[s])):
            if i > 0:
                out += " "
            ref p = specs[s][i]
            out += String(s) + ":" + p.column_name + ":" + String(Int(p.target_bytes)) + ":" + String(p.base)
    return out^


def _derive_join(
    left: List[Col],
    right: List[Col],
    join_type: UInt8 = JOIN_INNER,
    left_key: String = "key",
    right_key: String = "key",
) raises -> String:
    var plan = LogicalPlan.join(
        _scan(left), _scan(right), _keys(left_key), _keys(right_key), join_type
    )
    return _render(derive_payload_narrow(plan, _footers(left, right)))


comptime BASE = "0:pv:2:1 0:qv:1:5 | 1:bv:2:1"


def _eq(got: String, want: String) raises:
    assert_equal(got, want)


# =============================================================================
# The base case
# =============================================================================


def test_base_case_narrows_every_payload_column() raises:
    _eq(_derive_join(_left_cols(), _right_cols()), BASE)


# =============================================================================
# (a) never a join key of the side
# =============================================================================


def test_each_side_excludes_its_own_key() raises:
    # Left key `key`, right key `bv`. Right's `key` column is then a payload
    # column, and right's `bv` is excluded. Catches: the key exclusion removed
    # (left `key` would narrow to 0:key:4:0), or one side's keys used for the
    # other (right `key` would stay out, right `bv` would narrow).
    var got = _derive_join(_left_cols(), _right_cols(), right_key="bv")
    _eq(got, "0:pv:2:1 0:qv:1:5 | 1:key:4:0")


# =============================================================================
# (b) declared INT64, (c) non-nullable
# =============================================================================


def test_a_payload_not_declared_int64_is_refused() raises:
    # qv declared INT32, footer [5, 9]. Catches: the INT64 check removed.
    var left = _left_cols()
    left[2].arrow_type = ArrowType.INT32
    _eq(_derive_join(left, _right_cols()), "0:pv:2:1 | 1:bv:2:1")


def test_a_nullable_payload_is_refused() raises:
    # Catches: the nullability check removed.
    var left = _left_cols()
    left[1].nullable = True
    _eq(_derive_join(left, _right_cols()), "0:qv:1:5 | 1:bv:2:1")


# =============================================================================
# (d) the footer proves the bound
# =============================================================================


def test_footers_drive_the_rule_and_the_plan_statistics_do_not() raises:
    # Left: the plan's own statistics prove [5, 9] for qv but the footer entry
    # is None, so the left side narrows nothing. Right: the plan carries no
    # statistics and the footer narrows bv. Catches: the rule reading
    # `ScanData.table_stats` (left would narrow, right would not), or a None
    # footer read as an empty one.
    var left = _left_cols()
    var right = _right_cols()
    var plan = LogicalPlan.join(
        _scan(left, Optional[TableStats](_footer(left))),
        _scan(right),
        _keys("key"),
        _keys("key"),
        JOIN_INNER,
    )
    var footers = List[Optional[TableStats]]()
    footers.append(None)
    footers.append(Optional[TableStats](_footer(right)))
    _eq(_render(derive_payload_narrow(plan, footers)), " | 1:bv:2:1")


def test_a_column_absent_from_the_footer_is_refused() raises:
    # Catches: a missing footer column read as a bound (find_column < 0).
    var left = _left_cols()
    left[1].in_footer = False
    _eq(_derive_join(left, _right_cols()), "0:qv:1:5 | 1:bv:2:1")


def test_a_missing_min_or_a_missing_max_is_refused() raises:
    # Two cases, one per endpoint. Catches: either half of the presence check
    # removed (the value would be read out of an empty Optional).
    var no_min = _left_cols()
    no_min[1].lo = None
    _eq(_derive_join(no_min, _right_cols()), "0:qv:1:5 | 1:bv:2:1")
    var no_max = _left_cols()
    no_max[1].hi = None
    _eq(_derive_join(no_max, _right_cols()), "0:qv:1:5 | 1:bv:2:1")


def test_a_non_integer_min_or_max_is_refused() raises:
    # One case per endpoint, the other endpoint an integer. A float bound reads
    # as 0 through `int_val`, so each case is chosen to narrow if read that
    # way: min 1.0 read as 0 gives [0, 999]; max 999.0 read as 0, with min -5,
    # gives [-5, 0]. Catches: either half of the integer check removed.
    var float_min = _left_cols()
    float_min[1].lo = Optional[ScalarValue](ScalarValue.from_float(1.0))
    _eq(_derive_join(float_min, _right_cols()), "0:qv:1:5 | 1:bv:2:1")
    var float_max = _left_cols()
    float_max[1].lo = Optional[ScalarValue](ScalarValue.from_int64(-5))
    float_max[1].hi = Optional[ScalarValue](ScalarValue.from_float(999.0))
    _eq(_derive_join(float_max, _right_cols()), "0:qv:1:5 | 1:bv:2:1")


# =============================================================================
# (e) the width ladder, through the rule
# =============================================================================


def test_the_width_and_the_base_come_from_the_footer_bounds() raises:
    # Spans 255 (1 byte), 256 (2), 65536 (4) and 2^32 (none), with negative,
    # zero and positive bases. Catches: a width that is not the narrowest, a
    # base that is not the min, and a span needing eight bytes narrowed (the
    # PAYLOAD_NARROW_NONE check removed would emit a 0-byte spec).
    var left = List[Col]()
    left.append(_key())
    left.append(_int("a", -10, 245))
    left.append(_int("b", 0, 256))
    left.append(_int("c", 7, 65543))
    left.append(_int("d", 0, 4294967296))
    _eq(
        _derive_join(left, _right_cols()),
        "0:a:1:-10 0:b:2:0 0:c:4:7 | 1:bv:2:1",
    )


# =============================================================================
# The join: INNER, no residual, one key per side
# =============================================================================


def test_every_join_type_but_inner_is_refused() raises:
    # Catches: the join-type check removed or widened.
    var types = List[UInt8]()
    types.append(JOIN_LEFT)
    types.append(JOIN_RIGHT)
    types.append(JOIN_FULL)
    types.append(JOIN_SEMI)
    types.append(JOIN_ANTI)
    types.append(JOIN_CROSS)
    for i in range(len(types)):
        _eq(_derive_join(_left_cols(), _right_cols(), types[i]), " | ")


def test_a_residual_is_refused() raises:
    # Catches: the residual check removed.
    var residual = Optional[OwnedPointer[Expr]](
        OwnedPointer(Expr.binary(BIN_GT, Expr.col_ref("pv"), Expr.col_ref("bv")))
    )
    var plan = LogicalPlan.join(
        _scan(_left_cols()), _scan(_right_cols()), _keys("key"), _keys("key"),
        JOIN_INNER, residual=residual^,
    )
    var got = derive_payload_narrow(plan, _footers(_left_cols(), _right_cols()))
    _eq(_render(got), " | ")


def _derive_keys(var left_on: List[String], var right_on: List[String]) raises -> String:
    var plan = LogicalPlan.join(
        _scan(_left_cols()), _scan(_right_cols()), left_on^, right_on^, JOIN_INNER
    )
    return _render(derive_payload_narrow(plan, _footers(_left_cols(), _right_cols())))


def test_anything_but_one_key_per_side_is_refused() raises:
    # Two keys on the left only, two on the right only, two on both, none.
    # Catches: either side's key count check removed, or `== 1` widened.
    var two = List[String]()
    two.append("key")
    two.append("pv")
    var two_r = List[String]()
    two_r.append("key")
    two_r.append("bv")
    _eq(_derive_keys(two.copy(), _keys("key")), " | ")
    _eq(_derive_keys(_keys("key"), two_r.copy()), " | ")
    _eq(_derive_keys(two^, two_r^), " | ")
    _eq(_derive_keys(List[String](), List[String]()), " | ")
    # The control: one key each.
    _eq(_derive_keys(_keys("key"), _keys("key")), BASE)


def test_the_result_does_not_depend_on_a_previous_call() raises:
    # Pure: the same arguments give the same result, and the plan is unchanged
    # (it is read through an immutable reference, so a second call sees the
    # same plan).
    var left = _left_cols()
    var right = _right_cols()
    var plan = LogicalPlan.join(_scan(left), _scan(right), _keys("key"), _keys("key"), JOIN_INNER)
    var first = _render(derive_payload_narrow(plan, _footers(left, right)))
    var second = _render(derive_payload_narrow(plan, _footers(left, right)))
    _eq(first, BASE)
    assert_true(first == second)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
