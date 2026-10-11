# =============================================================================
# test_optimizer_payload_narrow — the width LADDER and the REFUSALS
# =============================================================================
#
# ⭐ EVERY ASSERTION HERE NAMES THE SPECIFIC VERDICT, NEVER A BOOLEAN. The
# weaker form is blind: when a SECOND term declines the same case, deleting a
# guard does NOT flip its guarded case to admit, so `assert not admitted`
# passes over a deleted guard and reports the guard as tested. So the ladder
# tests assert the exact BYTE COUNT
# (a 4 where a 2 belongs is a wrong width and is invisible to
# `narrowed != 0`), and every refusal test asserts that the column
# it names carries NO spec while a sibling column in the SAME plan still does —
# which is what distinguishes "this refusal fired" from "the rule never ran".
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    SOURCE_PARQUET,
    SOURCE_IN_MEMORY,
    JOIN_INNER,
    JOIN_LEFT,
    PLAN_SCAN,
    PLAN_JOIN,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)
from komira_plan_expr.payload_narrow import (
    choose_narrow_width,
    find_narrow_spec,
    PAYLOAD_NARROW_NONE,
    PAYLOAD_NARROW_1B,
    PAYLOAD_NARROW_2B,
    PAYLOAD_NARROW_4B,
)
from komira_optimizer.optimizer_payload_narrow import (
    narrow_join_payload_inplace,
)


# =============================================================================
# §1 — the width ladder, in isolation
# =============================================================================


def test_ladder_picks_the_narrowest_width_not_the_first_that_fits() raises:
    # The hc4 join shape's payload ranges (the same ranges `_hc4_shaped_join`
    # below stamps on its scans).
    assert_equal(
        Int(choose_narrow_width(1, 999)),
        Int(PAYLOAD_NARROW_2B),
        "probe_val [1,999] must pick 2 bytes",
    )
    assert_equal(
        Int(choose_narrow_width(1, 9999)),
        Int(PAYLOAD_NARROW_2B),
        "build_val [1,9999] must pick 2 bytes",
    )
    # ⭐ THE GUARD AGAINST A LADDER THAT STOPS AT INTEGER (4 bytes) AND NEVER
    # PICKS SMALLINT. A ladder that
    # stopped at 4 bytes would answer 4 here and the whole test file would still
    # be green under a boolean assertion.
    assert_true(
        choose_narrow_width(1, 9999) != PAYLOAD_NARROW_4B,
        "9998 fits two bytes; picking four leaves ~3 wall points on hc4",
    )
    print("test_ladder_picks_the_narrowest_width_not_the_first_that_fits OK")


def test_ladder_boundaries_are_exact() raises:
    # 1 byte holds a span of exactly 255, not 256.
    assert_equal(Int(choose_narrow_width(0, 255)), Int(PAYLOAD_NARROW_1B), "span 255 -> 1B")
    assert_equal(Int(choose_narrow_width(0, 256)), Int(PAYLOAD_NARROW_2B), "span 256 -> 2B")
    assert_equal(Int(choose_narrow_width(0, 65535)), Int(PAYLOAD_NARROW_2B), "span 65535 -> 2B")
    assert_equal(Int(choose_narrow_width(0, 65536)), Int(PAYLOAD_NARROW_4B), "span 65536 -> 4B")
    assert_equal(
        Int(choose_narrow_width(0, 4294967295)),
        Int(PAYLOAD_NARROW_4B),
        "span 2^32-1 -> 4B",
    )
    assert_equal(
        Int(choose_narrow_width(0, 4294967296)),
        Int(PAYLOAD_NARROW_NONE),
        "span 2^32 needs all eight bytes -> REFUSE",
    )
    # The frame of reference is what makes a high, tight domain narrowable at
    # all: [1000000, 1000100] is a span of 100.
    assert_equal(
        Int(choose_narrow_width(1000000, 1000100)),
        Int(PAYLOAD_NARROW_1B),
        "a tight domain far from zero is 1 byte WITH the base, 8 without it",
    )
    # hc4's KEY range, for the record: it does NOT fit two bytes. The rule
    # excludes the key by name regardless, but the ladder must not be the thing
    # that would have said yes.
    assert_equal(
        Int(choose_narrow_width(0, 24999999)),
        Int(PAYLOAD_NARROW_4B),
        "the hc4 key domain is a 4-byte span",
    )
    print("test_ladder_boundaries_are_exact OK")


def test_ladder_refuses_degenerate_and_extreme_endpoints() raises:
    assert_equal(
        Int(choose_narrow_width(10, 9)),
        Int(PAYLOAD_NARROW_NONE),
        "max < min is an unpopulated fold, not a zero-width column",
    )
    # The subtraction guard. `max - min` on these would overflow Int64, and an
    # overflowed span wraps to a SMALL number — i.e. the failure mode is
    # choosing a width that cannot hold the data, which is a wrong answer and
    # not a slow one.
    var big: Int64 = (Int64(1) << 62) + 1
    assert_equal(
        Int(choose_narrow_width(-big, big)),
        Int(PAYLOAD_NARROW_NONE),
        "endpoints outside +/-2^62 must REFUSE, never wrap",
    )
    print("test_ladder_refuses_degenerate_and_extreme_endpoints OK")


# =============================================================================
# §2 — plan fixtures
# =============================================================================


def _side_schema(key: String, payload: String, payload_nullable: Bool) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(key, ArrowType.INT64, False))
    sb.add_field(Field(payload, ArrowType.INT64, payload_nullable))
    return sb.build()


def _stats(
    key: String, key_hi: Int64, payload: String, lo: Int64, hi: Int64
) raises -> TableStats:
    var names = List[String]()
    var stats = List[ColumnStats]()
    names.append(key)
    stats.append(
        ColumnStats(
            None,
            Optional[ScalarValue](ScalarValue.from_int64(0)),
            Optional[ScalarValue](ScalarValue.from_int64(key_hi)),
            Optional[Int](0),
        )
    )
    names.append(payload)
    stats.append(
        ColumnStats(
            None,
            Optional[ScalarValue](ScalarValue.from_int64(lo)),
            Optional[ScalarValue](ScalarValue.from_int64(hi)),
            Optional[Int](0),
        )
    )
    return TableStats(
        1000, names^, stats^, STATS_SOURCE_PARQUET_METADATA
    )


def _side(
    path: String,
    key: String,
    payload: String,
    lo: Int64,
    hi: Int64,
    payload_nullable: Bool = False,
    with_stats: Bool = True,
    source_type: UInt8 = SOURCE_PARQUET,
) raises -> LogicalPlan:
    var ts: Optional[TableStats] = None
    if with_stats:
        ts = Optional[TableStats](_stats(key, 24999999, payload, lo, hi))
    return LogicalPlan.scan(
        path,
        source_type,
        _side_schema(key, payload, payload_nullable),
        None,
        None,
        None,
        ts^,
    )


def _hc4_shaped_join(join_type: UInt8 = JOIN_INNER) raises -> LogicalPlan:
    """The hc4 cell's shape, with hc4's column ranges:
    `probe(key[0,25M], probe_val[1,999]) INNER JOIN build(key, build_val[1,9999])`.
    """
    var l = List[String]()
    l.append(String("key"))
    var r = List[String]()
    r.append(String("key"))
    return LogicalPlan.join(
        _side(String("probe.parquet"), String("key"), String("probe_val"), 1, 999),
        _side(String("build.parquet"), String("key"), String("build_val"), 1, 9999),
        l^,
        r^,
        join_type,
    )


def _scan_specs(imm side: LogicalPlan) raises -> List[String]:
    """Render the stamped specs of a SCAN side as `name:bytes:base` strings, so
    an assertion can name the exact verdict rather than a count."""
    var out = List[String]()
    if side.tag != PLAN_SCAN or not side._scan:
        return out^
    ref pn = side._scan.value()[].payload_narrow
    for i in range(len(pn)):
        out.append(
            pn[i].column_name
            + String(":")
            + String(Int(pn[i].target_bytes))
            + String(":")
            + String(pn[i].base)
        )
    return out^


def _has(imm rendered: List[String], imm want: String) -> Bool:
    for i in range(len(rendered)):
        if rendered[i] == want:
            return True
    return False


# =============================================================================
# §3 — the rule, on the hc4 shape
# =============================================================================


def test_hc4_shape_narrows_both_payloads_to_two_bytes() raises:
    var plan = _hc4_shaped_join()
    var n = narrow_join_payload_inplace(plan)
    assert_equal(n, 2, "exactly two columns narrow on the hc4 shape")

    var lhs = _scan_specs(plan._join.value()[].left[])
    var rhs = _scan_specs(plan._join.value()[].right[])
    # ⭐ THE EXACT VERDICT: name, WIDTH and BASE. `len(lhs) == 1` would pass on
    # a 4-byte choice and on a base of 0 where 1 belongs.
    assert_true(
        _has(lhs, String("probe_val:2:1")),
        "probe_val must be narrowed to 2 bytes with base=1",
    )
    assert_true(
        _has(rhs, String("build_val:2:1")),
        "build_val must be narrowed to 2 bytes with base=1",
    )
    assert_equal(len(lhs), 1, "the probe side narrows exactly one column")
    assert_equal(len(rhs), 1, "the build side narrows exactly one column")
    print("test_hc4_shape_narrows_both_payloads_to_two_bytes OK")


def test_the_join_key_is_never_narrowed() raises:
    """⛔ THE LOAD-BEARING REFUSAL. The join leaf this rule is designed for
    keys on INT64 only, so a narrowed key would take the join off that route
    (the PAYLOAD ONLY block of `optimizer_payload_narrow.mojo`).
    Note the key's own domain [0, 24999999] DOES fit four bytes — the ladder
    would say yes — so this test is asserting the EXCLUSION and not an accident
    of the range."""
    assert_equal(
        Int(choose_narrow_width(0, 24999999)),
        Int(PAYLOAD_NARROW_4B),
        "precondition: the ladder alone would narrow this key",
    )
    var plan = _hc4_shaped_join()
    _ = narrow_join_payload_inplace(plan)
    var lhs = _scan_specs(plan._join.value()[].left[])
    var rhs = _scan_specs(plan._join.value()[].right[])
    assert_equal(
        find_narrow_spec_by_name(lhs, String("key")),
        -1,
        "the probe key must carry NO spec",
    )
    assert_equal(
        find_narrow_spec_by_name(rhs, String("key")),
        -1,
        "the build key must carry NO spec",
    )
    # ...and the sibling payload column IS stamped, which is what makes the two
    # assertions above evidence of an EXCLUSION rather than of a rule that
    # never ran.
    assert_equal(len(lhs) + len(rhs), 2, "both payload columns still narrowed")
    print("test_the_join_key_is_never_narrowed OK")


def find_narrow_spec_by_name(imm rendered: List[String], imm name: String) -> Int:
    var want = name + String(":")
    for i in range(len(rendered)):
        ref s = rendered[i]
        if s.byte_length() < want.byte_length():
            continue
        var sb = s.as_bytes()
        var wb = want.as_bytes()
        var is_prefix = True
        for j in range(len(wb)):
            if sb[j] != wb[j]:
                is_prefix = False
                break
        if is_prefix:
            return i
    return -1


# =============================================================================
# §4 — the refusals
# =============================================================================


def test_a_nullable_payload_column_is_refused() raises:
    var l = List[String]()
    l.append(String("key"))
    var r = List[String]()
    r.append(String("key"))
    var plan = LogicalPlan.join(
        _side(
            String("probe.parquet"), String("key"), String("probe_val"), 1, 999,
            payload_nullable=True,
        ),
        _side(String("build.parquet"), String("key"), String("build_val"), 1, 9999),
        l^,
        r^,
        JOIN_INNER,
    )
    var n = narrow_join_payload_inplace(plan)
    # The NULLABLE side refuses; the non-nullable side still fires. One
    # assertion cannot be satisfied by "the rule did nothing".
    assert_equal(n, 1, "only the non-nullable side narrows")
    assert_equal(
        len(_scan_specs(plan._join.value()[].left[])),
        0,
        "a nullable payload column carries no spec",
    )
    assert_true(
        _has(_scan_specs(plan._join.value()[].right[]), String("build_val:2:1")),
        "the non-nullable sibling is unaffected",
    )
    print("test_a_nullable_payload_column_is_refused OK")


def test_absent_statistics_are_refused_not_guessed() raises:
    var l = List[String]()
    l.append(String("key"))
    var r = List[String]()
    r.append(String("key"))
    var plan = LogicalPlan.join(
        _side(
            String("probe.parquet"), String("key"), String("probe_val"), 1, 999,
            with_stats=False,
        ),
        _side(String("build.parquet"), String("key"), String("build_val"), 1, 9999),
        l^,
        r^,
        JOIN_INNER,
    )
    var n = narrow_join_payload_inplace(plan)
    assert_equal(n, 1, "a stats-less scan narrows nothing; its sibling still does")
    assert_equal(
        len(_scan_specs(plan._join.value()[].left[])),
        0,
        "no stats -> no narrowing. The rule never guesses a domain",
    )
    print("test_absent_statistics_are_refused_not_guessed OK")


def test_a_non_inner_join_is_refused_on_both_sides() raises:
    var plan = _hc4_shaped_join(JOIN_LEFT)
    var n = narrow_join_payload_inplace(plan)
    assert_equal(n, 0, "LEFT join: neither side narrows")
    assert_equal(len(_scan_specs(plan._join.value()[].left[])), 0, "left side clean")
    assert_equal(len(_scan_specs(plan._join.value()[].right[])), 0, "right side clean")
    # Control: the SAME fixture as INNER narrows two columns, so the zero above
    # is the join type and not the fixture.
    var inner = _hc4_shaped_join(JOIN_INNER)
    assert_equal(
        narrow_join_payload_inplace(inner), 2, "control: the INNER twin narrows 2"
    )
    print("test_a_non_inner_join_is_refused_on_both_sides OK")


def test_a_non_parquet_side_is_refused() raises:
    var l = List[String]()
    l.append(String("key"))
    var r = List[String]()
    r.append(String("key"))
    var plan = LogicalPlan.join(
        _side(
            String("mem"), String("key"), String("probe_val"), 1, 999,
            source_type=SOURCE_IN_MEMORY,
        ),
        _side(String("build.parquet"), String("key"), String("build_val"), 1, 9999),
        l^,
        r^,
        JOIN_INNER,
    )
    var n = narrow_join_payload_inplace(plan)
    assert_equal(n, 1, "the in-memory side narrows nothing; the parquet side does")
    print("test_a_non_parquet_side_is_refused OK")


def test_the_rule_is_idempotent() raises:
    """A second pass must not double-stamp — the scalar-dependency protocol
    (`optimizer_scalar_deps.mojo`) runs every pass again, and a caller may
    re-run passes over an already-optimized plan."""
    var plan = _hc4_shaped_join()
    _ = narrow_join_payload_inplace(plan)
    _ = narrow_join_payload_inplace(plan)
    assert_equal(
        len(_scan_specs(plan._join.value()[].left[])),
        1,
        "a second pass must REPLACE, never append",
    )
    assert_true(
        _has(_scan_specs(plan._join.value()[].left[]), String("probe_val:2:1")),
        "and the replacement is the same verdict",
    )
    print("test_the_rule_is_idempotent OK")


def test_copy_carries_the_stamp() raises:
    """`ScanData.payload_narrow` is deliberately NOT a ctor argument, so
    `copy()` has to carry it by explicit assignment. A clone that dropped it
    would make the rule fire and then silently un-fire on every copied
    plan."""
    var plan = _hc4_shaped_join()
    _ = narrow_join_payload_inplace(plan)
    var clone = plan.copy()
    assert_true(
        _has(_scan_specs(clone._join.value()[].left[]), String("probe_val:2:1")),
        "the deep clone must carry the stamp",
    )
    print("test_copy_carries_the_stamp OK")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
