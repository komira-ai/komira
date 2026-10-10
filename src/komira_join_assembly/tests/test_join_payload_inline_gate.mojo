# komira_join_assembly/tests/test_join_payload_inline_gate.mojo -- the direct
# test of `join_payload_inline`: the two flags, the width gate, the type
# allow-list, the FIRE / DECLINE / PROBE / SERVE witnesses, the pay-subst
# witnesses and `join_pay_subst_alias`.
#
# Every function of the module is called here, with nothing but the module,
# `komira_arrow.ArrowType` and `JoinKeyAliasMap`: no join kernel, no writer, no
# environment variable. The counters and the flags are process-wide, so every
# test sets the state it reads first.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_join_assembly.join_key_cse import JoinKeyAliasMap
from komira_join_assembly.join_payload_inline import (
    JOIN_KN_WORDS,
    JOIN_KN_WORDS_PAY,
    JOIN_PAY_MAX_COLS,
    JOIN_PAY_MAX_ENTRY_BYTES,
    join_pay_subst_alias,
    join_pay_subst_configure,
    join_pay_subst_elided_count,
    join_pay_subst_enabled,
    join_pay_subst_fallback_count,
    join_pay_subst_kept_count,
    join_pay_subst_note_elided,
    join_pay_subst_note_fallback,
    join_pay_subst_note_kept,
    join_pay_subst_reset_config,
    join_payload_entry_bytes,
    join_payload_inline_admits,
    join_payload_inline_configure,
    join_payload_inline_declined_count,
    join_payload_inline_enabled,
    join_payload_inline_fired_count,
    join_payload_inline_note_served,
    join_payload_inline_probed_count,
    join_payload_inline_record_build,
    join_payload_inline_record_probe,
    join_payload_inline_reset_config,
    join_payload_inline_served_count,
    join_payload_type_admits,
    reset_join_pay_subst_counters,
    reset_join_payload_inline_counters,
)


def _map(var aliases: List[Int]) -> JoinKeyAliasMap:
    return JoinKeyAliasMap(_proven=aliases^)


def _junk() -> List[Int32]:
    """An `out_alias` that already holds entries: every exit must replace or
    clear them."""
    var v = List[Int32]()
    v.append(Int32(7))
    v.append(Int32(7))
    v.append(Int32(7))
    return v^


# -----------------------------------------------------------------------------
# The flags
# -----------------------------------------------------------------------------


def test_unconfigured_flags_read_off() raises:
    join_payload_inline_reset_config()
    join_pay_subst_reset_config()
    # Twice: an unconfigured read must not latch a value either way.
    assert_false(join_payload_inline_enabled(), "payload-inline default")
    assert_false(join_payload_inline_enabled(), "payload-inline second read")
    assert_false(join_pay_subst_enabled(), "pay-subst default")
    assert_false(join_pay_subst_enabled(), "pay-subst second read")
    # An unconfigured process never arms, even on an admissible shape.
    reset_join_payload_inline_counters()
    assert_false(join_payload_inline_admits(1, ArrowType.INT64, False))
    assert_equal(join_payload_inline_declined_count(), 1)


def test_configure_sets_each_flag_alone() raises:
    join_payload_inline_reset_config()
    join_pay_subst_reset_config()
    join_payload_inline_configure(True)
    assert_true(join_payload_inline_enabled(), "payload-inline on")
    assert_false(join_pay_subst_enabled(), "pay-subst untouched")
    join_payload_inline_configure(False)
    assert_false(join_payload_inline_enabled(), "payload-inline off")
    join_payload_inline_configure(True)
    join_payload_inline_reset_config()
    assert_false(join_payload_inline_enabled(), "payload-inline reset")

    join_pay_subst_configure(True)
    assert_true(join_pay_subst_enabled(), "pay-subst on")
    assert_false(join_payload_inline_enabled(), "payload-inline untouched")
    join_pay_subst_configure(False)
    assert_false(join_pay_subst_enabled(), "pay-subst off")
    join_pay_subst_configure(True)
    join_pay_subst_reset_config()
    assert_false(join_pay_subst_enabled(), "pay-subst reset")


# -----------------------------------------------------------------------------
# The width gate and the type allow-list
# -----------------------------------------------------------------------------


def test_entry_widths_and_constants() raises:
    assert_equal(JOIN_KN_WORDS, 2)
    assert_equal(JOIN_KN_WORDS_PAY, 4)
    assert_equal(JOIN_PAY_MAX_COLS, 1)
    assert_equal(JOIN_PAY_MAX_ENTRY_BYTES, 32)
    assert_equal(join_payload_entry_bytes(False), 16)
    assert_equal(join_payload_entry_bytes(True), 32)
    # The wide entry is a power of two that divides a 64-byte line.
    assert_equal(64 % join_payload_entry_bytes(True), 0)
    assert_true(join_payload_entry_bytes(True) <= JOIN_PAY_MAX_ENTRY_BYTES)


def test_type_allow_list_is_exact() raises:
    """Every type id 0..63: exactly the eight 8-byte value types admit."""
    var admitted = 0
    for i in range(64):
        var t = ArrowType(i)
        var want = (
            t == ArrowType.INT64
            or t == ArrowType.UINT64
            or t == ArrowType.FLOAT64
            or t == ArrowType.TIMESTAMP
            or t == ArrowType.TIMESTAMP_S
            or t == ArrowType.TIMESTAMP_MS
            or t == ArrowType.TIMESTAMP_US
            or t == ArrowType.TIMESTAMP_NS
        )
        assert_equal(join_payload_type_admits(t), want, String("type id ", i))
        if want:
            admitted += 1
    assert_equal(admitted, 8)
    # The shapes the header names as refused.
    assert_false(join_payload_type_admits(ArrowType.STRING))
    assert_false(join_payload_type_admits(ArrowType.BINARY))
    assert_false(join_payload_type_admits(ArrowType.LARGE_STRING))
    assert_false(join_payload_type_admits(ArrowType.DICTIONARY))
    assert_false(join_payload_type_admits(ArrowType.DECIMAL128))
    assert_false(join_payload_type_admits(ArrowType.DATE64))


def test_admits_and_each_refusal_is_counted() raises:
    join_payload_inline_configure(True)
    reset_join_payload_inline_counters()
    assert_true(join_payload_inline_admits(1, ArrowType.INT64, False))
    assert_true(join_payload_inline_admits(1, ArrowType.TIMESTAMP_NS, False))
    assert_equal(join_payload_inline_declined_count(), 0, "admits count nothing")

    assert_false(join_payload_inline_admits(0, ArrowType.INT64, False), "k=0")
    assert_equal(join_payload_inline_declined_count(), 1)
    assert_false(join_payload_inline_admits(2, ArrowType.INT64, False), "k=2")
    assert_equal(join_payload_inline_declined_count(), 2)
    assert_false(join_payload_inline_admits(1, ArrowType.STRING, False))
    assert_equal(join_payload_inline_declined_count(), 3)
    assert_false(join_payload_inline_admits(1, ArrowType.DICTIONARY, False))
    assert_equal(join_payload_inline_declined_count(), 4)
    assert_false(join_payload_inline_admits(1, ArrowType.INT64, True), "null")
    assert_equal(join_payload_inline_declined_count(), 5)

    join_payload_inline_configure(False)
    assert_false(join_payload_inline_admits(1, ArrowType.INT64, False), "off")
    assert_equal(join_payload_inline_declined_count(), 6)
    # Declines touch no other witness.
    assert_equal(join_payload_inline_fired_count(), 0)
    assert_equal(join_payload_inline_probed_count(), 0)
    assert_equal(join_payload_inline_served_count(), 0)
    join_payload_inline_reset_config()


# -----------------------------------------------------------------------------
# The witnesses
# -----------------------------------------------------------------------------


def test_fire_probe_serve_witnesses_and_reset() raises:
    reset_join_payload_inline_counters()
    join_payload_inline_record_build(100, 1)
    assert_equal(join_payload_inline_fired_count(), 1)
    assert_equal(join_payload_inline_probed_count(), 0)
    assert_equal(join_payload_inline_served_count(), 0)
    assert_equal(join_payload_inline_declined_count(), 0)

    join_payload_inline_record_probe()
    join_payload_inline_record_probe()
    assert_equal(join_payload_inline_probed_count(), 2)
    assert_equal(join_payload_inline_fired_count(), 1)

    # Served counts COLUMNS, batched per assemble.
    join_payload_inline_note_served(3)
    join_payload_inline_note_served(2)
    assert_equal(join_payload_inline_served_count(), 5)

    _ = join_payload_inline_admits(0, ArrowType.INT64, False)
    assert_true(join_payload_inline_declined_count() > 0)

    # The pay-subst witnesses are separate and survive this reset.
    reset_join_pay_subst_counters()
    join_pay_subst_note_kept()
    reset_join_payload_inline_counters()
    assert_equal(join_payload_inline_fired_count(), 0)
    assert_equal(join_payload_inline_declined_count(), 0)
    assert_equal(join_payload_inline_probed_count(), 0)
    assert_equal(join_payload_inline_served_count(), 0)
    assert_equal(join_pay_subst_kept_count(), 1)


def test_pay_subst_witnesses_and_reset() raises:
    reset_join_pay_subst_counters()
    join_pay_subst_note_elided()
    join_pay_subst_note_kept()
    join_pay_subst_note_kept()
    join_pay_subst_note_fallback()
    join_pay_subst_note_fallback()
    join_pay_subst_note_fallback()
    assert_equal(join_pay_subst_elided_count(), 1)
    assert_equal(join_pay_subst_kept_count(), 2)
    assert_equal(join_pay_subst_fallback_count(), 3)

    # The payload-inline witnesses are separate and survive this reset.
    reset_join_payload_inline_counters()
    join_payload_inline_record_probe()
    reset_join_pay_subst_counters()
    assert_equal(join_pay_subst_elided_count(), 0)
    assert_equal(join_pay_subst_kept_count(), 0)
    assert_equal(join_pay_subst_fallback_count(), 0)
    assert_equal(join_payload_inline_probed_count(), 1)


# -----------------------------------------------------------------------------
# join_pay_subst_alias
# -----------------------------------------------------------------------------


def test_alias_admits_and_fills_the_vector() raises:
    # Payload at build column 1; build column 0 aliases probe column 2, the
    # last column of a 3-column probe batch.
    var got = _junk()
    assert_true(join_pay_subst_alias(1, 2, 3, _map([2, -1]), got))
    assert_equal(len(got), 2)
    assert_equal(got[0], Int32(2))
    assert_equal(got[1], Int32(-1))

    # Payload at build column 0; the map's own entry there is ignored.
    got = _junk()
    assert_true(join_pay_subst_alias(0, 3, 2, _map([5, 0, 1]), got))
    assert_equal(len(got), 3)
    assert_equal(got[0], Int32(-1))
    assert_equal(got[1], Int32(0))
    assert_equal(got[2], Int32(1))

    # A single build column that is the payload needs no alias at all, and a
    # map longer than the build batch is fine.
    got = _junk()
    assert_true(join_pay_subst_alias(0, 1, 1, _map([-1, 9]), got))
    assert_equal(len(got), 1)
    assert_equal(got[0], Int32(-1))


def _refused(
    tag: String,
    pay_col: Int,
    build_ncols: Int,
    probe_ncols: Int,
    var aliases: List[Int],
) raises:
    var got = _junk()
    assert_false(
        join_pay_subst_alias(
            pay_col, build_ncols, probe_ncols, _map(aliases^), got
        ),
        tag,
    )
    assert_equal(len(got), 0, String(tag, ": out_alias must be empty"))


def test_alias_refusals_leave_the_vector_empty() raises:
    _refused("no payload", -1, 2, 3, [2, 1])
    _refused("payload past the build batch", 2, 2, 3, [2, 1, 0])
    _refused("empty build batch", 0, 0, 3, [])
    # The build side is the payload alone, so only the probe-width check
    # can refuse it.
    _refused("empty probe batch", 0, 1, 0, [-1])
    # The column past the map's end is the payload, so only the length check
    # can refuse it (`alias_of` past the end would read -1 and refuse anyway).
    _refused("map shorter than the build batch", 2, 3, 3, [0, 1])
    # A non-payload column with no alias.
    _refused("unaliased column", 1, 2, 3, [-1, -1])
    # An alias that names a column the probe batch does not have: exactly
    # probe_ncols is out of range.
    _refused("alias == probe_ncols", 1, 2, 3, [3, -1])
    # The refusal comes AFTER an entry was appended (the payload at column 0),
    # so the vector has to be cleared, not just left unfilled.
    _refused("refused after an append", 0, 3, 2, [-1, 1, 2])
    _refused("unaliased after an append", 0, 2, 2, [-1, -1])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
