# =============================================================================
# test_metric_point_and_attr_set.mojo
#   THE IN-PROCESS METRIC RECORD AND THE ATTRIBUTE-SET INTERNER.
# =============================================================================
#
# SCOPE. `MetricPoint` and `AttrSet` / `AttrSetRegistry`. The IN-PROCESS
# record only:
#
#   NOT here: the per-worker SERIES TABLE (`test_series_table.mojo`)
#   NOT here: the ring encoding of a metric record
#   NOT here: any at-rest storage format
#
# THE TWO PROPERTIES WORTH TESTING, because both are silent when wrong:
#
#   1. AN ATTRIBUTE SET IS A SET. `{a=1, b=2}` and `{b=2, a=1}` are the same
#      series. If they intern to different ids, a caller that happens to add
#      attributes in a different order silently creates a SECOND series
#      measuring the same thing, and every dashboard built on it is wrong in a
#      way no error surfaces.
#
#   2. A REFUSAL IS NEVER A WRONG ID. Truncation, digest collision and a full
#      table all return `ATTRSET_OVERFLOW_ID`, which is deliberately DISTINCT
#      from `EMPTY_ATTRSET_ID`. Conflating them would make an overflowed series
#      join the unattributed series -- the same class of corruption as a
#      `MetricsSet` lookup miss landing on a real metric.
#
# ⛔ ALL THREE REFUSAL ARMS ARE DRIVEN: truncated, digest collision and table
# full. A counter's zero-valued negative control passes over an arm that never
# runs; an arm no test enters is an arm whose refusal has never happened. Each
# arm has its own case below, and breaking each arm ALONE reds exactly ONE
# case — which is the proof that the arms are independent and that each case
# enters the arm it names:
#
#   arm          the break                        failing case
#   ----------   ------------------------------   -----------------------------
#   truncated    the guard DELETED                "a truncated set is REFUSED"
#   collision    INVERTED to `return id`          "the colliding set is REFUSED
#                (the silent MERGE)               -- never handed the first
#                                                 set's id"
#   table full   INVERTED to `return id`          "a FULL table REFUSES the new
#                (an id never stored)             set"
#
# The POD-size case reds the same way when a `_pad` field is widened.
#
# Encapsulation: POD values, all stack-local. No `UnsafePointer`.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_metrics.metric_point import (
    _METRIC_POINT_SIZE_GUARD,
    MetricPoint,
    METRIC_COUNTER,
    METRIC_UPDOWNCOUNTER,
    METRIC_GAUGE,
    METRIC_HISTOGRAM,
    METRIC_KIND_UNKNOWN,
    MFLAG_CUMULATIVE,
    MFLAG_MONOTONIC,
    MFLAG_VALUE_IS_DOUBLE,
    MFLAG_HAS_EXEMPLAR,
    counter_point,
    updown_counter_point,
    gauge_point,
)
from komira_metrics.attr_set import (
    _ATTR_KEY_VALUE_SIZE_GUARD,
    _ATTR_SET_SIZE_GUARD,
    _ATTR_SET_ENTRY_SIZE_GUARD,
    _ATTR_SET_REGISTRY_SIZE_GUARD,
    AttrKeyValue,
    AttrSet,
    AttrSetEntry,
    AttrSetRegistry,
    MAX_ATTRS_PER_SET,
    MAX_ATTRSETS,
    EMPTY_ATTRSET_ID,
    ATTRSET_OVERFLOW_ID,
)


# -----------------------------------------------------------------------------
# MetricPoint — the flag/value contract.
# -----------------------------------------------------------------------------


def test_a_default_point_has_an_UNKNOWN_kind_not_kind_zero() raises -> None:
    """`METRIC_COUNTER` is 0, so a zero-initialised point would otherwise claim
    to BE a counter. A discriminant whose default value is also a legal value
    gets routed as that legal value."""
    var p = MetricPoint()
    assert_equal(Int(p.kind), Int(METRIC_KIND_UNKNOWN), "unknown, not COUNTER")
    assert_true(Int(METRIC_COUNTER) == 0, "and COUNTER really is 0")


def test_int_and_double_share_one_field_and_the_flag_decides() raises -> None:
    var p = MetricPoint()
    p.set_int_value(Int64(-7))
    assert_false(p.value_is_double(), "int: flag clear")
    assert_equal(Int(p.as_int()), -7, "int round-trips, sign included")

    p.set_double_value(Float64(1.5))
    assert_true(p.value_is_double(), "double: flag set")
    assert_true(p.as_double() == Float64(1.5), "double round-trips")

    # ...and setting an int back CLEARS the flag. Without that, one reused
    # point reports an Int64 as a Float64 bit pattern.
    p.set_int_value(Int64(3))
    assert_false(p.value_is_double(), "flag cleared on the way back")
    assert_equal(Int(p.as_int()), 3, "int again")


def test_exemplar_needs_its_own_flag_because_span_id_zero_is_legal() raises -> None:
    """Absent-vs-empty, in the small. If "no exemplar" were encoded as
    `exemplar_span_id == 0`, a real span whose id is 0 would be invisible."""
    var p = MetricPoint()
    assert_false(p.has_exemplar(), "fresh point has none")
    assert_equal(Int(p.exemplar_span_id), 0, "and the field is 0")

    p.set_exemplar(UInt64(0))
    assert_true(
        p.has_exemplar(),
        "span id 0 IS an exemplar, and the flag is what says so",
    )


def test_the_kind_constructors_agree_with_their_flags() raises -> None:
    """A COUNTER that is not monotonic, or an UPDOWNCOUNTER that is, cannot be
    lowered to OTLP. The constructors are the one place that pairing is set."""
    var c = counter_point(
        UInt32(11), UInt32(22), EMPTY_ATTRSET_ID, Int64(5), UInt64(100), UInt64(200)
    )
    assert_equal(Int(c.kind), Int(METRIC_COUNTER), "counter kind")
    assert_true(c.is_monotonic(), "a COUNTER is monotonic")
    assert_false(c.is_cumulative(), "and DELTA by default")
    assert_equal(Int(c.as_int()), 5, "value")

    var u = updown_counter_point(
        UInt32(11), UInt32(22), EMPTY_ATTRSET_ID, Int64(-5), UInt64(100), UInt64(200)
    )
    assert_equal(Int(u.kind), Int(METRIC_UPDOWNCOUNTER), "updown kind")
    assert_false(u.is_monotonic(), "an UPDOWNCOUNTER is NOT monotonic")
    assert_equal(Int(u.as_int()), -5, "and may be negative")


def test_a_gauge_has_a_zero_width_window_not_a_window_to_the_epoch() raises -> None:
    """A gauge is instantaneous. Leaving `start_time` at 0 would make an
    exporter that subtracts the two report a window back to 1970."""
    var g = gauge_point(
        UInt32(1), UInt32(2), EMPTY_ATTRSET_ID, Int64(42), UInt64(999)
    )
    assert_equal(Int(g.kind), Int(METRIC_GAUGE), "gauge kind")
    assert_equal(
        Int(g.start_time_unix_ns), 999, "start == time, not 0"
    )
    assert_equal(Int(g.time_unix_ns), 999, "time")


# -----------------------------------------------------------------------------
# AttrSet — SET semantics. Property 1.
# -----------------------------------------------------------------------------


def test_attribute_order_does_not_change_the_identity() raises -> None:
    """THE MARQUEE PROPERTY. Two orderings of the same attributes are one
    series, or a caller silently forks its own metric."""
    var a = AttrSet()
    _ = a.add(UInt32(500), UInt32(1))
    _ = a.add(UInt32(100), UInt32(2))
    _ = a.add(UInt32(300), UInt32(3))

    var b = AttrSet()
    _ = b.add(UInt32(300), UInt32(3))
    _ = b.add(UInt32(500), UInt32(1))
    _ = b.add(UInt32(100), UInt32(2))

    a.canonicalize()
    b.canonicalize()
    assert_equal(
        Int(a.digest()), Int(b.digest()), "same set, same digest"
    )
    assert_true(a.equals(b), "and they compare equal pairwise")

    var reg = AttrSetRegistry()
    assert_equal(
        Int(reg.intern(a.copy())), Int(reg.intern(b.copy())), "and intern to ONE id"
    )
    assert_equal(reg.count(), 1, "having occupied ONE slot, not two")


def test_a_duplicate_key_is_replaced_not_appended() raises -> None:
    """An attribute set is a MAP. `{a=1, a=2}` appended twice would hash
    differently depending on order even after sorting."""
    var a = AttrSet()
    _ = a.add(UInt32(7), UInt32(1))
    _ = a.add(UInt32(7), UInt32(2))
    assert_equal(a.count(), 1, "one pair, not two")
    assert_equal(Int(a.pairs[0].value_id), 2, "the later value won")


def test_a_different_value_is_a_different_series() raises -> None:
    """The negative control for the order test: interning must not collapse
    sets that genuinely differ."""
    var a = AttrSet()
    _ = a.add(UInt32(1), UInt32(10))
    var b = AttrSet()
    _ = b.add(UInt32(1), UInt32(11))

    var reg = AttrSetRegistry()
    var ia = reg.intern(a.copy())
    var ib = reg.intern(b.copy())
    assert_true(ia != ib, "different value => different series")
    assert_equal(reg.count(), 2, "two slots")


def test_the_empty_set_is_a_value_not_a_sentinel() raises -> None:
    """Most metrics carry no attributes. The empty set must intern cleanly,
    cost no slot, and be DISTINCT from the overflow id."""
    var reg = AttrSetRegistry()
    var e = AttrSet()
    assert_equal(
        Int(reg.intern(e.copy())), Int(EMPTY_ATTRSET_ID), "empty set interns to 0"
    )
    assert_equal(reg.count(), 0, "and occupies NO slot")
    assert_true(
        EMPTY_ATTRSET_ID != ATTRSET_OVERFLOW_ID,
        "empty and overflow are DIFFERENT ids",
    )
    var back = reg.lookup(EMPTY_ATTRSET_ID)
    assert_true(back.__bool__(), "and resolves back")
    assert_equal(back.value().count(), 0, "to a set of size 0")


# -----------------------------------------------------------------------------
# Refusals. Property 2 — a refusal is never a wrong id.
# -----------------------------------------------------------------------------


def test_a_truncated_set_is_REFUSED_not_interned() raises -> None:
    """Interning a set that already lost a pair would mint an id for a series
    silently missing a label -- every later reading attributed to the wrong
    thing. Refusing loses the point; interning corrupts the series."""
    var a = AttrSet()
    for i in range(MAX_ATTRS_PER_SET):
        assert_true(a.add(UInt32(i + 1), UInt32(i)), "fits")
    assert_false(a.truncated, "not truncated yet")

    assert_false(
        a.add(UInt32(9999), UInt32(0)), "the 9th pair does not fit"
    )
    assert_true(a.truncated, "and the set says so")

    var reg = AttrSetRegistry()
    assert_equal(
        Int(reg.intern(a.copy())),
        Int(ATTRSET_OVERFLOW_ID),
        "a truncated set is REFUSED",
    )
    assert_equal(reg.num_truncated_refused(), 1, "and the refusal is counted")
    assert_equal(reg.count(), 0, "nothing was interned")


def test_lookup_round_trips_an_interned_set() raises -> None:
    """What an exporter does at serialize time: id -> labels."""
    var a = AttrSet()
    _ = a.add(UInt32(42), UInt32(7))
    _ = a.add(UInt32(1), UInt32(9))

    var reg = AttrSetRegistry()
    var id = reg.intern(a.copy())
    assert_true(id != ATTRSET_OVERFLOW_ID, "interned")

    var back = reg.lookup(id)
    assert_true(back.__bool__(), "resolves")
    assert_equal(back.value().count(), 2, "two pairs")
    # Canonicalized: key 1 sorts before key 42.
    assert_equal(Int(back.value().pairs[0].key_id), 1, "sorted by key")
    assert_equal(Int(back.value().pairs[1].key_id), 42, "sorted by key")


def test_an_unknown_id_resolves_to_nothing() raises -> None:
    var reg = AttrSetRegistry()
    assert_false(
        reg.lookup(UInt32(123456)).__bool__(), "unknown id -> None"
    )
    assert_false(
        reg.lookup(ATTRSET_OVERFLOW_ID).__bool__(),
        "and the overflow id is never resolvable",
    )


def test_reinterning_the_same_set_is_idempotent() raises -> None:
    """The hot path: the same series is interned once per observation and must
    not consume a slot each time."""
    var reg = AttrSetRegistry()
    var first = UInt32(0)
    for i in range(50):
        var a = AttrSet()
        _ = a.add(UInt32(5), UInt32(6))
        var id = reg.intern(a.copy())
        if i == 0:
            first = id
        assert_equal(Int(id), Int(first), "same id every time")
    assert_equal(reg.count(), 1, "ONE slot after 50 interns")


def test_a_fresh_registry_has_refused_nothing() raises -> None:
    """The negative control for the counters: without it, a registry that
    refused everything would satisfy the refusal cases above."""
    var reg = AttrSetRegistry()
    assert_equal(reg.count(), 0, "nothing interned")
    assert_equal(reg.num_overflowed(), 0, "nothing overflowed")
    assert_equal(reg.num_digest_collisions(), 0, "no collisions")
    assert_equal(reg.num_truncated_refused(), 0, "nothing truncated")

    var a = AttrSet()
    _ = a.add(UInt32(1), UInt32(1))
    assert_true(
        reg.intern(a.copy()) != ATTRSET_OVERFLOW_ID,
        "and a well-formed set is ACCEPTED",
    )
    assert_equal(reg.num_overflowed(), 0, "still nothing refused")


# -----------------------------------------------------------------------------
# THE OTHER TWO REFUSAL ARMS.
#
# `intern` has three refusal arms. They are not interchangeable: each returns the same `ATTRSET_OVERFLOW_ID` but
# for a different reason, increments a DIFFERENT counter, and would corrupt a
# different thing if it were ever changed to accept instead of refuse.
# -----------------------------------------------------------------------------

# ⚠ MAGIC NUMBERS, AND WHERE THEY CAME FROM. These two single-pair attribute
# sets are DIFFERENT and their 32-bit FNV-1a digests are EQUAL. They were found
# by brute-force search over `AttrSet.digest()` (a random walk of the (key_id,
# value_id) space; the first collision appeared at ~28k samples, which is the
# birthday bound for a 32-bit digest). There is no way to reach this arm without
# a real collision -- the arm is entered only when a probe finds a slot whose id
# MATCHES and whose set does NOT.
#
# ⚠ IF `digest()` CHANGES THESE STOP COLLIDING, and this case would then intern
# both sets happily. That is why the first assertion below is on the FIXTURE's
# own precondition: the case goes RED naming the collision, rather than quietly
# testing nothing.
comptime _COLLIDE_A_KEY: UInt32 = UInt32(1558400949)
comptime _COLLIDE_A_VAL: UInt32 = UInt32(3195251657)
comptime _COLLIDE_B_KEY: UInt32 = UInt32(1268342204)
comptime _COLLIDE_B_VAL: UInt32 = UInt32(4214716298)


def test_a_digest_collision_is_REFUSED_never_MERGED() raises -> None:
    """`attr_set.mojo`'s collision arm. TWO DIFFERENT SETS, ONE DIGEST.

    This is the arm whose failure mode is worst and quietest. `name_registry`
    can accept a benign double-insert because its drain dedups by name_id; here
    accepting would make two DISTINCT series report as ONE, and no downstream
    consumer can undo a merge -- the counts are already summed."""
    var a = AttrSet()
    assert_true(a.add(_COLLIDE_A_KEY, _COLLIDE_A_VAL), "A fits")
    var b = AttrSet()
    assert_true(b.add(_COLLIDE_B_KEY, _COLLIDE_B_VAL), "B fits")

    # THE FIXTURE'S OWN PRECONDITION. Without this, a change to `digest()` would
    # turn this whole case into two ordinary inserts that assert nothing.
    assert_equal(
        Int(a.digest()),
        Int(b.digest()),
        "FIXTURE: these two sets must still DIGEST THE SAME -- if `digest()`"
        " changed, re-derive the colliding pair; this case cannot reach the"
        " collision arm without one",
    )
    assert_false(
        a.equals(b), "FIXTURE: and they must still be DIFFERENT sets"
    )

    var reg = AttrSetRegistry()
    var id_a = reg.intern(a.copy())
    assert_true(id_a != ATTRSET_OVERFLOW_ID, "the first set interns")
    assert_equal(reg.count(), 1, "and takes one slot")

    var id_b = reg.intern(b.copy())
    assert_equal(
        Int(id_b),
        Int(ATTRSET_OVERFLOW_ID),
        "the colliding set is REFUSED -- never handed the first set's id",
    )
    assert_true(id_b != id_a, "and above all is NOT merged into it")
    assert_equal(reg.num_digest_collisions(), 1, "and the collision is COUNTED")
    assert_equal(reg.count(), 1, "and consumed no slot")

    # The incumbent is untouched: the id still resolves to the set that minted
    # it, not to the intruder.
    var back = reg.lookup(id_a)
    assert_true(back.__bool__(), "the first set still resolves")
    assert_true(
        back.value().equals(a),
        "and resolves to the set that MINTED the id, not the intruder",
    )
    # The counters are not interchangeable: a collision is not an overflow and
    # not a truncation.
    assert_equal(reg.num_overflowed(), 0, "a collision is NOT an overflow")
    assert_equal(reg.num_truncated_refused(), 0, "and NOT a truncation")


def test_a_FULL_table_REFUSES_rather_than_reusing_a_slot() raises -> None:
    """`attr_set.mojo`'s table-full arm. The arm reached only by walking every one of the
    `MAX_ATTRSETS` probes without finding a free slot or a matching id.

    ⛔ THIS IS FAIL-CLOSED, NOT THE CARDINALITY CEILING. Collapse-on-overflow
    and the reserved OTel overflow attribute are a separate layer; what is
    pinned here is that
    a full table LOSES the new series rather than SILENTLY REUSING a slot, which
    would re-attribute an existing series' readings to a different set of
    labels."""
    var reg = AttrSetRegistry()
    for i in range(MAX_ATTRSETS):
        var s = AttrSet()
        assert_true(s.add(UInt32(i + 1), UInt32(i)), "pair fits")
        assert_true(
            reg.intern(s.copy()) != ATTRSET_OVERFLOW_ID,
            "every set interns while the table still has a free slot",
        )
    assert_equal(
        reg.count(), MAX_ATTRSETS, "EVERY slot is occupied -- the table is full"
    )
    assert_equal(
        reg.num_digest_collisions(),
        0,
        "FIXTURE: the 4096 fill sets must all digest DISTINCTLY, or the table"
        " never actually filled and the overflow arm below is unreachable",
    )
    assert_equal(reg.num_overflowed(), 0, "and NOTHING has overflowed yet")

    var extra = AttrSet()
    assert_true(
        extra.add(UInt32(MAX_ATTRSETS + 1), UInt32(MAX_ATTRSETS)), "pair fits"
    )
    var id = reg.intern(extra.copy())
    assert_equal(
        Int(id), Int(ATTRSET_OVERFLOW_ID), "a FULL table REFUSES the new set"
    )
    assert_true(
        Int(id) != Int(EMPTY_ATTRSET_ID),
        "and the refusal id is NOT the empty-set id -- conflating them would"
        " make every overflowed series join the UNATTRIBUTED series",
    )
    assert_equal(reg.num_overflowed(), 1, "and the overflow is COUNTED")
    assert_equal(reg.count(), MAX_ATTRSETS, "no slot was evicted or reused")
    assert_false(
        reg.lookup(id).__bool__(), "the overflow id resolves to nothing"
    )
    assert_equal(reg.num_digest_collisions(), 0, "an overflow is NOT a collision")
    assert_equal(reg.num_truncated_refused(), 0, "and NOT a truncation")

    # THE INCUMBENTS SURVIVED. Re-interning the FIRST set inserted must still
    # find it by probe and return its original id -- a full table that had
    # quietly evicted someone would refuse this too.
    var first = AttrSet()
    assert_true(first.add(UInt32(1), UInt32(0)), "pair fits")
    assert_true(
        reg.intern(first.copy()) != ATTRSET_OVERFLOW_ID,
        "the FIRST set interned is still resolvable in the full table -- the"
        " refusal above lost the NEW series, not an existing one",
    )
    assert_equal(reg.count(), MAX_ATTRSETS, "and re-finding it took no slot")


# -----------------------------------------------------------------------------
# POD SIZE. The convention `span_record.mojo` / `span_packet.mojo` follow, and
# the arithmetic this package's header states out loud.
# -----------------------------------------------------------------------------


def test_the_PODs_are_the_SIZE_their_own_headers_claim() raises -> None:
    """attr_set.mojo's header sizes the interner at 320 KiB and derives it from
    these three numbers. A byte count in a comment that nothing executes is a
    number that drifts.

    ⛔ `size_of[T]()` does NOT fail to elaborate on a non-POD type —
    `size_of[String]()` elaborates (the probe and its positive control are
    recorded beside `_METRIC_POINT_SIZE_GUARD` in `metric_point.mojo`). Nothing
    in this package catches a POD-dropping swap by TYPE; what catches one is the
    size changing, which is what these assertions read."""
    assert_equal(size_of[AttrKeyValue](), 8, "AttrKeyValue: 4 + 4 = 8 B")
    assert_equal(
        size_of[AttrSet](),
        72,
        "AttrSet: 8 pairs x 8 B + n(1) + pad(3) + truncated(1) + pad = 72 B",
    )
    assert_equal(
        size_of[AttrSetEntry](),
        80,
        "AttrSetEntry: id(4) + occupied(1) + pad(3) + set(72) = 80 B",
    )
    # The header's headline figure, stated as the arithmetic rather than as a
    # remembered number: 4096 x 80 B = 327680 B = 320 KiB.
    assert_equal(
        MAX_ATTRSETS * size_of[AttrSetEntry](),
        327680,
        "the interner's slot array is 320 KiB per registry -- far more than a"
        " table storing only a hash, because each slot holds the whole set",
    )
    assert_true(
        size_of[AttrSetRegistry]() >= 327680,
        "and the registry is at least its slot array (plus four counters)",
    )
    # MetricPoint's own claim: the 4-byte ids pack ahead of the two single-byte
    # discriminants, leaving NO interior padding before the 8-byte timestamps.
    assert_equal(
        size_of[MetricPoint](),
        48,
        "MetricPoint: 4+4+4+1+1+2 pad = 16, then 4 x 8 B = 48 B with no"
        " interior padding -- the layout claim in its own docstring",
    )


def test_the_size_guard_constants_are_the_bytes_the_headers_claim() raises -> None:
    """THE FIVE `comptime _*_SIZE_GUARD` DECLARATIONS ARE READ HERE, AND
    NOWHERE ELSE.

    Before this case they were declared in `metric_point.mojo` /
    `attr_set.mojo` and read by NOTHING — five aliases whose only stated purpose
    was a POD check `size_of` does not perform (see the docstring above). A
    constant no test reads pins nothing: deleting one, or letting a field-type
    swap move the number it holds, was silent.

    Each assertion below names the GUARD, not `size_of`, so the failure message
    points at the declaration that went stale rather than at a fact about the
    type. The pair with `test_the_PODs_are_the_SIZE_their_own_headers_claim` is
    deliberate: that case pins the TYPE's layout, this one pins that the shipped
    constant still agrees with it."""
    assert_equal(
        _ATTR_KEY_VALUE_SIZE_GUARD,
        8,
        "_ATTR_KEY_VALUE_SIZE_GUARD is 8 B -- the guard beside AttrKeyValue",
    )
    assert_equal(
        _ATTR_SET_SIZE_GUARD,
        72,
        "_ATTR_SET_SIZE_GUARD is 72 B -- the guard beside AttrSet",
    )
    assert_equal(
        _ATTR_SET_ENTRY_SIZE_GUARD,
        80,
        "_ATTR_SET_ENTRY_SIZE_GUARD is 80 B -- the 80 the file header's 320 KiB"
        " figure is derived FROM",
    )
    assert_true(
        _ATTR_SET_REGISTRY_SIZE_GUARD >= 327680,
        "_ATTR_SET_REGISTRY_SIZE_GUARD is at least the 320 KiB slot array",
    )
    assert_equal(
        _METRIC_POINT_SIZE_GUARD,
        48,
        "_METRIC_POINT_SIZE_GUARD is 48 B -- the guard beside MetricPoint",
    )
    # And the guards are the SAME numbers as the types, not a second set of
    # remembered ones: a guard that drifted from its own struct would satisfy
    # every assertion above and still be a lie.
    assert_equal(
        _METRIC_POINT_SIZE_GUARD,
        size_of[MetricPoint](),
        "the guard IS size_of[MetricPoint](), not a number beside it",
    )
    assert_equal(
        _ATTR_SET_ENTRY_SIZE_GUARD,
        size_of[AttrSetEntry](),
        "the guard IS size_of[AttrSetEntry](), not a number beside it",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
