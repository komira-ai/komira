# =============================================================================
# An as-of join's TOLERANCE VALUE and its PRE-SORT HINTS are plan identity.
# =============================================================================
#
# `LogicalPlan.structural_hash` is FNV-1a over the plan render
# (`plan_display._write_plan_node`), and it is the plan-compile cache key and
# the scalar-subquery dedup key. The as-of arm used to write only the tolerance
# TAG (`tolerance=INT64`), so `AsofTolerance.int64(5)` and
# `AsofTolerance.int64(500000)` hashed equal: in one engine context the second
# query would run the first one's compiled plan and match with the wrong
# window. The `*_sort_keys` / `*_sort_desc` hints were not rendered at all; a
# plan whose hint says "the input is already sorted, skip the sort" would share
# a compiled plan with one that must sort.
#
# The hint keys are QUOTED in the render: written raw, one key `k, ts` rendered
# like the two keys `k`, `ts`, and a left key spelling `k]/[F], right_sorted=[ts`
# rendered like a left hint `[k]` plus a right hint `[ts]`. The quoting
# escapes: under bare quotes the one key `k", "ts` rendered like `k`, `ts`.
#
# Each test is a pair that must hash differently, plus a control pair that
# must hash equal (the render stays deterministic, so caching still works).
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_ir.logical_plan import (
    AsofTolerance,
    LogicalPlan,
    SOURCE_PARQUET,
    ASOF_BACKWARD,
)


def _schema(ts: String, v: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(String("k"), ArrowType.INT64, False))
    b.add_field(Field(ts, ArrowType.INT64, False))
    b.add_field(Field(v, ArrowType.INT64, False))
    return b.build()


def _asof(
    tol: AsofTolerance,
    var left_sort_keys: List[String] = List[String](),
    var left_sort_desc: List[Bool] = List[Bool](),
    var right_sort_keys: List[String] = List[String](),
    var right_sort_desc: List[Bool] = List[Bool](),
) -> LogicalPlan:
    var keys: List[String] = ["k"]
    return LogicalPlan.asof_join(
        LogicalPlan.scan(String("trades.parquet"), SOURCE_PARQUET, _schema("ts", "px")),
        LogicalPlan.scan(String("quotes.parquet"), SOURCE_PARQUET, _schema("ts", "bid")),
        keys.copy(),
        keys.copy(),
        String("ts"),
        String("ts"),
        ASOF_BACKWARD,
        tol,
        left_sort_keys^,
        left_sort_desc^,
        right_sort_keys^,
        right_sort_desc^,
    )


def _differ(a: LogicalPlan, b: LogicalPlan, what: String) raises:
    assert_true(
        a.structural_hash() != b.structural_hash(),
        what + ": both rendered\n" + String(a),
    )


def test_the_issue_probe_int64_5_vs_500000() raises:
    _differ(
        _asof(AsofTolerance.int64(5)),
        _asof(AsofTolerance.int64(500000)),
        "tolerance int64(5) vs int64(500000)",
    )


def test_negative_tolerance_is_not_its_absolute_value() raises:
    _differ(
        _asof(AsofTolerance.int64(-5)),
        _asof(AsofTolerance.int64(5)),
        "tolerance int64(-5) vs int64(5)",
    )


def test_zero_tolerance_is_not_unbounded() raises:
    _differ(
        _asof(AsofTolerance.int64(0)),
        _asof(AsofTolerance.none()),
        "tolerance int64(0) vs none",
    )


def test_float_tolerances_differ_by_value() raises:
    _differ(
        _asof(AsofTolerance.float64(0.5)),
        _asof(AsofTolerance.float64(0.25)),
        "tolerance float64(0.5) vs float64(0.25)",
    )
    _differ(
        _asof(AsofTolerance.float64(-0.5)),
        _asof(AsofTolerance.float64(0.5)),
        "tolerance float64(-0.5) vs float64(0.5)",
    )


def test_int_and_float_tolerance_of_one_value_differ() raises:
    _differ(
        _asof(AsofTolerance.int64(5)),
        _asof(AsofTolerance.float64(5.0)),
        "tolerance int64(5) vs float64(5.0)",
    )


def test_a_pre_sort_hint_is_identity() raises:
    var lk: List[String] = ["k", "ts"]
    var ld: List[Bool] = [False, False]
    _differ(
        _asof(AsofTolerance.none(), lk^, ld^),
        _asof(AsofTolerance.none()),
        "left pre-sort hint vs none",
    )
    var rk: List[String] = ["k", "ts"]
    var rd: List[Bool] = [False, False]
    _differ(
        _asof(AsofTolerance.none(), List[String](), List[Bool](), rk^, rd^),
        _asof(AsofTolerance.none()),
        "right pre-sort hint vs none",
    )
    var ak: List[String] = ["k", "ts"]
    var ad: List[Bool] = [False, False]
    var bk: List[String] = ["k", "ts"]
    var bd: List[Bool] = [False, True]
    _differ(
        _asof(AsofTolerance.none(), ak^, ad^),
        _asof(AsofTolerance.none(), bk^, bd^),
        "pre-sort hint direction",
    )


def test_a_hint_key_cannot_split_into_two_keys() raises:
    var ak: List[String] = ["k, ts"]
    var ad: List[Bool] = [False, False]
    var bk: List[String] = ["k", "ts"]
    var bd: List[Bool] = [False, False]
    _differ(
        _asof(AsofTolerance.none(), ak^, ad^),
        _asof(AsofTolerance.none(), bk^, bd^),
        "hint keys [\"k, ts\"] (one key) vs [\"k\", \"ts\"]",
    )


def test_a_quote_in_a_hint_key_cannot_split_it() raises:
    # The quoting must ESCAPE: bare quotes around the key `k", "ts` write
    # `["k", "ts"]`, the render of the two keys `k`, `ts`.
    var ak: List[String] = ["k\", \"ts"]
    var ad: List[Bool] = [False, False]
    var bk: List[String] = ["k", "ts"]
    var bd: List[Bool] = [False, False]
    _differ(
        _asof(AsofTolerance.none(), ak^, ad^),
        _asof(AsofTolerance.none(), bk^, bd^),
        "hint keys ['k\", \"ts'] (one key) vs [\"k\", \"ts\"]",
    )


def test_a_left_hint_key_cannot_spell_a_right_hint() raises:
    var ak: List[String] = ["k]/[F], right_sorted=[ts"]
    var ad: List[Bool] = [False]
    var bk: List[String] = ["k"]
    var bd: List[Bool] = [False]
    var ck: List[String] = ["ts"]
    var cd: List[Bool] = [False]
    _differ(
        _asof(AsofTolerance.none(), ak^, ad^),
        _asof(AsofTolerance.none(), bk^, bd^, ck^, cd^),
        "a left hint key spelling `]/[F], right_sorted=[ts` vs a real right hint",
    )


def test_the_same_join_hashes_equal() raises:
    # Control: equal plans must keep one cache key.
    assert_equal(
        _asof(AsofTolerance.int64(5)).structural_hash(),
        _asof(AsofTolerance.int64(5)).structural_hash(),
    )
    assert_equal(
        _asof(AsofTolerance.float64(0.5)).structural_hash(),
        _asof(AsofTolerance.float64(0.5)).structural_hash(),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
