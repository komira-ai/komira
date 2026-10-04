# =============================================================================
# test_arrow_offset_overflow.mojo — the Int32 variable-length offset ceiling.
# =============================================================================
#
# Arrow's `string` / `binary` types carry Int32 offsets, so a column's data
# buffer can address at most INT32_MAX == 2_147_483_647 bytes. A producer
# that accumulates its cumulative byte offset in a 64-bit `Int` and then
# narrows it with `Int32(offset)` silently wraps NEGATIVE past 2 GiB — and the
# array's ROW COUNT stays exactly correct, so a row-count check is blind to
# it.
#
# These tests are deliberately BEHAVIOURAL: they import only the public array
# constructors for the ceiling legs, never the guard's internals, so an
# absent guard fails them for the right reason (no error raised, garbage
# offsets).
#
# THE DISCRIMINATOR IS ONE BYTE. `test_from_strings_at_exactly_int32_max`
# builds a column of EXACTLY 2_147_483_647 data bytes and requires it to
# SUCCEED; `test_from_strings_one_byte_over_int32_max` appends a single 1-byte
# value to the same input and requires it to RAISE. A guard that is too eager
# fails the first; a guard that is absent or off-by-one fails the second. Both
# assert exact byte counts, not inequalities.
#
# Cost: these allocate ~2.1 GiB (over case) to ~4.3 GiB (at-boundary case, the
# input list plus the successfully-built column). That is why this file is
# sized `large`. There is no cheaper way to cross a 2 GiB ceiling honestly.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.string_array import StringArray
from komira_arrow.binary_array import BinaryArray
from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType
from komira_arrow.offset_overflow import (
    ARROW_INT32_OFFSET_MAX,
    clamp_offset_promote_at,
)


comptime INT32_MAX: Int = 2147483647
comptime MIB: Int = 1048576  # 2**20


def _one_mib() -> String:
    """A String of exactly 2**20 bytes, built by 20 doublings (no O(n) loop)."""
    var s = String("a")
    for _ in range(20):
        var t = s.copy()
        s += t
    return s^


def _one_mib_minus_one() -> String:
    """A String of exactly 2**20 - 1 bytes.

    Built as the sum 2**0 + 2**1 + ... + 2**19 == 2**20 - 1, so there is no
    String slicing and no per-byte append.
    """
    var out = String()
    var piece = String("a")
    for _ in range(20):
        out += piece
        var t = piece.copy()
        piece += t
    return out^


def _values_summing_to_int32_max() -> List[String]:
    """2047 x 2**20 + (2**20 - 1) == 2_147_483_647 bytes across 2048 values."""
    var chunk = _one_mib()
    var values = List[String](capacity=2049)
    for _ in range(2047):
        values.append(chunk.copy())
    values.append(_one_mib_minus_one())
    return values^


def test_from_strings_at_exactly_int32_max() raises:
    """EXACTLY INT32_MAX data bytes is legal and must round-trip.

    This is the "guard is not too eager" half of the discriminator. If the
    ceiling were implemented as `>=` instead of `>`, this test fails.
    """
    var values = _values_summing_to_int32_max()
    assert_equal(len(values), 2048, "input value count")

    var arr = StringArray.from_strings(values)
    assert_equal(len(arr), 2048, "row count")
    assert_equal(arr.data_length, INT32_MAX, "data_length == INT32_MAX exactly")
    # The LAST element must still be addressable: its offsets are
    # [2_146_435_072, 2_147_483_647], both of which fit in Int32.
    assert_equal(arr.get_length(2047), MIB - 1, "last element byte length")
    assert_equal(arr.get_length(0), MIB, "first element byte length")
    _ = arr^


def test_from_strings_one_byte_over_int32_max() raises:
    """INT32_MAX + 1 data bytes must raise a NAMED error, not wrap silently.

    Without the guard this call returns an array whose `offsets[2048]` has
    wrapped to -2147483648, so `get_length(2048)` is garbage while `len(arr)`
    is a perfectly correct 2049. That is the silent-wrong-answer class this
    guard exists to kill.
    """
    var values = _values_summing_to_int32_max()
    values.append(String("z"))  # +1 byte -> 2_147_483_648
    assert_equal(len(values), 2049, "input value count")

    var raised = False
    var msg = String()
    try:
        var arr = StringArray.from_strings(values)
        _ = arr^
    except e:
        raised = True
        msg = String(e)

    assert_true(
        raised,
        "StringArray.from_strings MUST raise at INT32_MAX+1 data bytes; it"
        " returned an array with silently wrapped offsets instead",
    )
    assert_true(
        msg.find("ArrowOffsetOverflow") >= 0,
        "error must be the named ArrowOffsetOverflow class, got: " + msg,
    )
    assert_true(
        msg.find("StringArray.from_strings") >= 0,
        "error must name the producing site, got: " + msg,
    )
    assert_true(
        msg.find("2147483648") >= 0,
        "error must name the exact byte count that overflowed, got: " + msg,
    )
    assert_true(
        msg.find("2147483647") >= 0,
        "error must name the Int32 offset limit, got: " + msg,
    )
    assert_true(
        msg.find("-2147483648") >= 0,
        "error must name the wrapped value the narrowing would have produced,"
        " got: " + msg,
    )


def test_from_byte_lists_one_byte_over_int32_max() raises:
    """The raw-bytes constructor has the same ceiling and the same guard."""
    var chunk = List[UInt8](capacity=MIB)
    for _ in range(MIB):
        chunk.append(UInt8(65))

    var values = List[List[UInt8]](capacity=2049)
    for _ in range(2048):
        values.append(chunk.copy())
    # 2048 * 2**20 == 2_147_483_648 == INT32_MAX + 1.

    var raised = False
    var msg = String()
    try:
        var arr = StringArray.from_byte_lists(values)
        _ = arr^
    except e:
        raised = True
        msg = String(e)

    assert_true(
        raised, "from_byte_lists MUST raise at INT32_MAX+1 data bytes"
    )
    assert_true(
        msg.find("ArrowOffsetOverflow") >= 0,
        "error must be the named ArrowOffsetOverflow class, got: " + msg,
    )
    assert_true(
        msg.find("StringArray.from_byte_lists") >= 0,
        "error must name the producing site, got: " + msg,
    )


def test_binary_array_one_byte_over_int32_max() raises:
    """BinaryArray shares the Int32 offsets layout and must share the guard."""
    var chunk = List[UInt8](capacity=MIB)
    for _ in range(MIB):
        chunk.append(UInt8(66))

    var values = List[List[UInt8]](capacity=2049)
    for _ in range(2048):
        values.append(chunk.copy())

    var raised = False
    var msg = String()
    try:
        var arr = BinaryArray.from_bytes_list(values)
        _ = arr^
    except e:
        raised = True
        msg = String(e)

    assert_true(
        raised, "BinaryArray.from_bytes_list MUST raise at INT32_MAX+1 bytes"
    )
    assert_true(
        msg.find("ArrowOffsetOverflow") >= 0,
        "error must be the named ArrowOffsetOverflow class, got: " + msg,
    )
    assert_true(
        msg.find("BinaryArray.from_bytes_list") >= 0,
        "error must name the producing site, got: " + msg,
    )


def test_well_under_the_ceiling_is_untouched() raises:
    """A normal small column must not pay for or trip the guard."""
    var values: List[String] = ["alpha", "", "beta", "gamma"]
    var arr = StringArray.from_strings(values)
    assert_equal(len(arr), 4, "row count")
    assert_equal(arr.data_length, 14, "data_length")
    assert_equal(arr.get(0), "alpha", "element 0")
    assert_equal(arr.get(1), "", "element 1")
    assert_equal(arr.get(3), "gamma", "element 3")


# =============================================================================
# PRODUCER ATTRIBUTION + THE GROUPED-KEY PROMOTION
# =============================================================================
#
# THE SHAPE THESE COVER. A grouped string-key drain over ~18.3M distinct
# urls (`SELECT url, count(*) FROM hits GROUP BY url ORDER BY 2 DESC LIMIT
# 10` over ~100M rows) needs ~3.37 GB of key bytes. An Int32-offset build of
# that column refuses with:
#
#   ArrowOffsetOverflow: <unnamed column> at StringArray.from_strings needs
#   3374058173 data bytes for 18342019 values ...
#
# Two requirements follow from that one line.
#
#   (1) THE MESSAGE MUST NAME THE CONSTRUCTOR THE PRODUCER CALLED. A GROUPED
#       drain carries key validity, so it calls `from_strings_with_validity`;
#       if that constructor's ALL-VALID FAST PATH delegates to `from_strings`
#       and loses the identity on the way, readers searching for
#       `StringArray.from_strings` call sites cannot find the producer,
#       because the producer is not one of them.
#
#   (2) THE REFUSAL IS WRONG ON THE MERITS AT THIS SITE. 18,342,019 distinct
#       urls have no narrow-offset representation at all, so refusing denies an
#       answer that EXISTS at 64-bit offsets. The drain is free to widen its own
#       output tag; `RecordBatchBuilder.build` promotes the schema in lockstep.
#
# A caller may catch the raise and re-report it as a result line, with no
# stack trace; the message is then the only evidence there is, which is why
# it has to carry the identity.
# =============================================================================


comptime _PROMOTE_AT_BYTES: Int = 100
"""The lowered promotion trip point the promotion legs pass explicitly."""


def test_with_validity_all_valid_delegation_keeps_its_own_identity() raises:
    """The all-valid fast path must not report a call the caller never made.

    This is the literal falsifier for requirement (1). A
    `from_strings_with_validity` that delegates with
    `return StringArray.from_strings(values)` produces a message that says
    `at StringArray.from_strings` with NO mention of
    `from_strings_with_validity` anywhere in it -- so the final assertion below
    fails on a message that is otherwise perfectly well-formed. That is how a
    producer stays unidentifiable: the message is not malformed, it is
    CONFIDENTLY WRONG about which constructor ran.

    This leg costs the same ~2.1 GiB as its neighbours above, deliberately.
    `from_strings`' guard is `check_int32_offsets`, which trips at the HARD
    Arrow ceiling and has no configurable trip point -- and it must not,
    because a site that REFUSES has to refuse at the real limit and nowhere
    else. The trip point belongs to `should_promote_offsets`, which is what
    the promotion legs below pass explicitly.
    """
    var values = _values_summing_to_int32_max()
    values.append(String("z"))  # +1 byte -> 2_147_483_648
    # ALL-VALID, which is what routes this call through the delegation.
    var valid = List[Bool](capacity=len(values))
    for _ in range(len(values)):
        valid.append(True)

    var raised = False
    var msg = String()
    try:
        var arr = StringArray.from_strings_with_validity(values, valid)
        _ = arr^
    except e:
        raised = True
        msg = String(e)

    assert_true(
        raised,
        "from_strings_with_validity MUST raise at INT32_MAX+1 data bytes even"
        " on its all-valid fast path",
    )
    assert_true(
        msg.find("ArrowOffsetOverflow") >= 0,
        "error must be the named ArrowOffsetOverflow class, got: " + msg,
    )
    assert_true(
        msg.find("from_strings_with_validity") >= 0,
        "THE MESSAGE MUST NAME THE CONSTRUCTOR THE CALLER ACTUALLY INVOKED."
        " A message saying only `at StringArray.from_strings` sends"
        " readers searching for call sites that do not exist. Got: " + msg,
    )


def test_explicit_producer_identity_reaches_the_message() raises:
    """A caller that passes `producer=` is named in the overflow message.

    The generalisation of the leg above: the delegating constructor can only
    carry its OWN identity, which narrows ~60 candidate call sites to the
    handful that call the nullable constructor. A caller that states who it is
    narrows it to one.
    """
    var values = _values_summing_to_int32_max()
    values.append(String("z"))

    var raised = False
    var msg = String()
    try:
        var arr = StringArray.from_strings(
            values, "test_explicit_producer_identity (the caller)"
        )
        _ = arr^
    except e:
        raised = True
        msg = String(e)

    assert_true(raised, "must still raise at INT32_MAX+1 data bytes")
    assert_true(
        msg.find("test_explicit_producer_identity (the caller)") >= 0,
        "the caller's stated identity must appear in the message, got: " + msg,
    )
    assert_true(
        msg.find("StringArray.from_strings") >= 0,
        "the detecting SITE must still be named -- the producer identity is an"
        " ADDITION, not a replacement, got: " + msg,
    )


def test_unattributed_call_says_so_rather_than_looking_complete() raises:
    """An unconverted caller must produce a message that ADMITS it is blind.

    THE POINT OF THIS LEG. A message naming only a shared constructor reads
    as complete -- it has a site, a byte count, a limit and a remedy -- so a
    reader treats it as the whole story and goes looking for a bug that is not
    where the message says. Saying UNATTRIBUTED out loud is what stops that,
    and it is why the empty-producer branch prints a sentence instead of
    nothing.
    """
    var big = _values_summing_to_int32_max()
    big.append(String("z"))
    var msg = String()
    try:
        var a3 = StringArray.from_strings(big)
        _ = a3^
    except e:
        msg = String(e)
    assert_true(
        msg.find("UNATTRIBUTED") >= 0,
        "an unconverted call site must be reported as unattributed rather"
        " than as a complete diagnosis, got: " + msg,
    )


def test_grouped_key_drain_promotes_instead_of_refusing() raises:
    """`Column.from_strings_with_validity_promoting` widens past the ceiling.

    THIS IS THE ANSWER TO REQUIREMENT (2), and it is the helper the grouped
    drains in `radix_hash_agg_untyped` / `hash_agg_untyped` call. Driven
    through the `offset_promote_at` parameter so the SAME buffers, stores and
    tags a multi-GB drain runs are exercised over a hundred bytes.

    Its power is established by the control below: with the trip point
    lowered the promotion must fire, and with it at the production value the
    same input must stay narrow (the next test).
    """

    # 7 valid values x 20 bytes = 140 bytes > 100, plus one NULL contributing
    # zero -- so the NULL accounting is part of what trips the promotion.
    var twenty = String("abcdefghijklmnopqrst")
    var values = List[String]()
    var valid = List[Bool]()
    for i in range(8):
        if i == 3:
            values.append(String(""))
            valid.append(False)
        else:
            values.append(twenty.copy())
            valid.append(True)

    var col = Column.from_strings_with_validity_promoting(
        values, valid, offset_promote_at=_PROMOTE_AT_BYTES
    )
    assert_equal(
        col.arrow_type,
        ArrowType.LARGE_STRING,
        "140 payload bytes over a 100-byte trip point MUST promote; a `string`"
        " tag here means the promotion did not fire and the drain would still"
        " refuse at the hard ceiling",
    )
    assert_equal(col._length, 8, "row count survives the promotion")
    assert_equal(col._null_count, 1, "the NULL group is still a NULL group")
    _ = col^

    # CONTROL -- the NARROW constructor over the SAME input must NOT raise.
    # 140 bytes is nowhere near the hard Arrow ceiling, so if this fires the
    # trip point has leaked into `check_int32_offsets` and the promotion
    # assertion above is measuring the wrong thing.
    var raised = False
    try:
        var narrow = StringArray.from_strings_with_validity(values, valid)
        _ = narrow^
    except:
        raised = True
    assert_true(
        not raised,
        "CONTROL: the narrow constructor trips only at the HARD Arrow ceiling,"
        " which 140 bytes does not reach -- so it must NOT raise here.",
    )


def test_under_the_lowered_trip_point_stays_narrow() raises:
    """The promotion is CONDITIONAL -- a column that fits keeps `string`.

    The half that stops this from re-typing every string column in the tree.
    Same lowered trip point, a payload under it.
    """
    var values: List[String] = ["alpha", "beta", "gamma"]
    var valid: List[Bool] = [True, False, True]
    var col = Column.from_strings_with_validity_promoting(
        values, valid, offset_promote_at=_PROMOTE_AT_BYTES
    )
    assert_equal(
        col.arrow_type,
        ArrowType.STRING,
        "10 payload bytes is under the 100-byte trip point and MUST stay"
        " narrow -- an unconditional promotion would re-type every string"
        " column in the tree to buy nothing",
    )
    _ = col^


def test_promote_at_is_clamped_to_the_real_ceiling() raises:
    """The trip point can only be LOWERED, never raised past the real ceiling.

    `clamp_offset_promote_at` keeps an in-range value and maps zero, a
    negative value or anything above `ARROW_INT32_OFFSET_MAX` to the ceiling,
    so a misconfigured trip point cannot let a narrow column wrap.
    """
    assert_equal(clamp_offset_promote_at(_PROMOTE_AT_BYTES), _PROMOTE_AT_BYTES)
    assert_equal(clamp_offset_promote_at(1), 1)
    assert_equal(
        clamp_offset_promote_at(ARROW_INT32_OFFSET_MAX), ARROW_INT32_OFFSET_MAX
    )
    assert_equal(clamp_offset_promote_at(0), ARROW_INT32_OFFSET_MAX)
    assert_equal(clamp_offset_promote_at(-5), ARROW_INT32_OFFSET_MAX)
    assert_equal(
        clamp_offset_promote_at(ARROW_INT32_OFFSET_MAX + 1),
        ARROW_INT32_OFFSET_MAX,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
