# =============================================================================
# test_string_share_byte_equiv — the string-share gate
#                                (`set_string_share_enabled`)
#                                byte-equivalence oracle
# =============================================================================
#
# ⭐ THE STRING-SHARE GATE IS DEFAULT **ON** (see
# `scan_copy_trace.string_share_enabled`).
# `set_string_share_enabled(False)` is the kill switch, and the
# `Column.from_string` COPY arm it selects is RETAINED deliberately — it is the
# rollback path AND the byte-equivalence ORACLE this file compares against.
# The default itself is pinned by `test_scan_copy_trace_direct`.
#
# `Column.from_string_shared` is the ZERO-COPY sibling of `Column.from_string`.
# `from_string` DEEP-COPIES both buffers of the incoming `StringArray` (its own
# docstring says "(copies data)"); the shared spelling Arc-shares them. The two
# must be indistinguishable in every observable a downstream consumer can read.
#
# The copy this deletes moves a whole column chunk's string payload a second
# time for no semantic reason. This file is the correctness half; the
# DRAM/wall half is an A/B, not a test.
#
# ---------------------------------------------------------------------------
# ⚠ WHAT EACH TEST IS THE FALSIFIER FOR, AND WHICH MUTATION KILLS IT
# ---------------------------------------------------------------------------
# A falsifier that some OTHER guard also catches is not a falsifier for this
# change. Each row below names a mutation of the PRODUCTION code and the ONE
# assertion here that goes RED under it.
#
#   M1  `from_string_shared`: emit `offset=arr.length` instead of `offset=0`
#         -> KILLED BY `test_shared_matches_the_copying_spelling_non_nullable`
#            ("logical offset must match the copying spelling").
#   M2  `from_string_shared`: drop the `offsets_shared.set_length(...)` mirror
#         -> KILLED BY `test_shared_truncates_an_over_allocated_offsets_buffer`
#            ("offsets handle must be TRUNCATED to (length + 1) * 4").
#            ⚠ NOT killed by any of the byte-equality tests: the production
#            producers `set_length` their buffers exactly, so the mirror is a
#            NO-OP for them. This test builds the case the production arms
#            cannot.
#   M3  `from_string_shared`: drop the `data_shared.set_length(...)` mirror
#         -> KILLED BY `test_shared_truncates_an_over_allocated_data_buffer`.
#   M4  `from_string_shared`: skip the validity `share()` (emit `None`)
#         -> KILLED BY `test_shared_matches_the_copying_spelling_nullable`
#            ("validity presence must match" / the per-bit comparison).
#   M5  `from_string_shared`: pass `null_count=0` instead of `arr.null_count`
#         -> KILLED BY `test_shared_matches_the_copying_spelling_nullable`
#            ("null_count must match the copying spelling").
#   M6  `from_string_shared`: drop the short-buffer `raise` on data
#         -> KILLED BY `test_shared_raises_on_a_short_data_buffer`.
#   M7  the column decode: make BOTH gated arms call `from_string` (i.e. the
#       lever never arms)
#         -> ⛔ NOT KILLED BY ANYTHING IN THIS FILE. Every test here drives
#            `Column.from_string_shared` and the counter PRIMITIVES DIRECTLY;
#            none of them reaches the column decode, so reverting both gated
#            returns leaves this whole file GREEN. The falsifier for the
#            DECODER WIRING drives a real PLAIN BYTE_ARRAY file through the
#            decoder with the gate off and then on; it moves with the column
#            decode. This file's job is the factory and the counter, not the
#            route.
#   M8  `scan_copy_trace.string_share_enabled` reads the latch the wrong way
#       round -> KILLED BY `test_gate_flips_in_process`.
#
# Hard-rule audit: no UnsafePointer in any test signature; no wildcard origins;
# no `take_pointee` field-swap; the file is well under the 1000-line cap.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from komira_parquet.scan_copy_trace import (
    reset_scan_copy_gates,
    incr_string_copy,
    incr_string_share,
    reset_scan_copy_counts,
    set_string_share_enabled,
    string_copy_count,
    string_share_count,
    string_share_enabled,
)
# UTF-8 value) so an offsets bug cannot hide behind a uniform stride, and NOT a
# multiple of any SIMD width.
# -----------------------------------------------------------------------------
def _ragged_values() -> List[String]:
    var v = List[String]()
    v.append(String("alpha"))
    v.append(String(""))
    v.append(String("bravo-charlie-delta"))
    v.append(String("e"))
    v.append(String("éèê"))  # multi-byte UTF-8
    v.append(String("foxtrot"))
    v.append(String("golf-hotel"))
    return v^


def _validity_pattern() -> List[Bool]:
    var b = List[Bool]()
    b.append(True)
    b.append(False)
    b.append(True)
    b.append(True)
    b.append(False)
    b.append(True)
    b.append(False)
    return b^


def _assert_columns_byte_identical(
    imm shared: Column[HeapRegion],
    imm copied: Column[HeapRegion],
    imm what: String,
) raises:
    """Assert the SHARED column is indistinguishable from the COPIED one in
    every observable: header fields, both buffer BYTE LENGTHS, and every byte
    of both buffers."""
    assert_equal(
        shared.length(), copied.length(), what + ": logical element count"
    )
    assert_equal(
        shared._null_count,
        copied._null_count,
        what + ": null_count must match the copying spelling",
    )
    assert_equal(
        shared._offset,
        copied._offset,
        what + ": logical offset must match the copying spelling",
    )
    assert_true(
        shared.arrow_type == copied.arrow_type,
        what + ": arrow_type must match",
    )

    # --- data buffer: length, then every byte ---
    assert_equal(
        Int(shared._data.len()),
        Int(copied._data.len()),
        what + ": data handle must carry the SAME byte length as the copy",
    )
    for i in range(Int(copied._data.len())):
        assert_true(
            shared._data.get_typed[UInt8](i)
            == copied._data.get_typed[UInt8](i),
            what + ": data byte diverged at index " + String(i),
        )

    # --- offsets buffer: presence, length, then every byte ---
    assert_equal(
        shared._offsets.__bool__(),
        copied._offsets.__bool__(),
        what + ": offsets presence must match",
    )
    if copied._offsets:
        assert_equal(
            Int(shared._offsets.value().len()),
            Int(copied._offsets.value().len()),
            what
            + ": offsets handle must carry the SAME byte length as the copy",
        )
        for i in range(Int(copied._offsets.value().len())):
            assert_true(
                shared._offsets.value().get_typed[UInt8](i)
                == copied._offsets.value().get_typed[UInt8](i),
                what + ": offsets byte diverged at index " + String(i),
            )

    # --- validity: presence, length, then every BIT ---
    assert_equal(
        shared._validity.__bool__(),
        copied._validity.__bool__(),
        what + ": validity presence must match",
    )
    if copied._validity:
        assert_equal(
            shared._validity.value().length,
            copied._validity.value().length,
            what + ": validity bit length must match",
        )
        for i in range(copied._validity.value().length):
            assert_equal(
                shared._validity.value().test(i),
                copied._validity.value().test(i),
                what + ": validity BIT diverged at index " + String(i),
            )


# =============================================================================
# Part 1 — the shared spelling is byte-identical to the copying spelling.
# =============================================================================


def test_shared_matches_the_copying_spelling_non_nullable() raises:
    """The string concat's shape: no validity, ragged values."""
    var vals = _ragged_values()
    var copied = Column.from_string(StringArray.from_strings(vals))
    var shared = Column.from_string_shared(StringArray.from_strings(vals))
    _assert_columns_byte_identical(shared, copied, String("non-nullable"))
    # And the logical read-back agrees, not just the bytes.
    var sa = shared.share_as_string()
    for i in range(len(vals)):
        assert_equal(sa.get(i), vals[i], "value at index " + String(i))
    _ = shared^
    _ = copied^
    print("  OK non-nullable share is byte-identical to the copy")


def test_shared_matches_the_copying_spelling_nullable() raises:
    """The `_expand_with_nulls_string` shape: a validity bitmap is present, so
    the share must carry the bitmap AND `null_count` through unchanged."""
    var vals = _ragged_values()
    var valid = _validity_pattern()
    var copied = Column.from_string(
        StringArray.from_strings_with_validity(vals, valid)
    )
    var shared = Column.from_string_shared(
        StringArray.from_strings_with_validity(vals, valid)
    )
    assert_true(
        copied._validity.__bool__(),
        "PREMISE: the copying spelling must produce a validity bitmap, or this"
        " test asserts nothing about the validity share",
    )
    assert_true(
        copied._null_count > 0,
        "PREMISE: the fixture must contain nulls, or `null_count` cannot"
        " diverge and M5 is untested",
    )
    _assert_columns_byte_identical(shared, copied, String("nullable"))
    _ = shared^
    _ = copied^
    print("  OK nullable share is byte-identical to the copy")


def test_zero_length_string_column_is_byte_equivalent() raises:
    """The `max(data_length, 1)` edge: `from_string` allocates a 1-byte data
    buffer for an EMPTY array and then `set_length(0)`s it. The share must land
    on the same zero byte length, not on the source's capacity."""
    var vals = List[String]()
    var copied = Column.from_string(StringArray.from_strings(vals))
    var shared = Column.from_string_shared(StringArray.from_strings(vals))
    assert_equal(shared.length(), 0, "empty column length")
    _assert_columns_byte_identical(shared, copied, String("zero-length"))
    _ = shared^
    _ = copied^
    print("  OK zero-length share is byte-identical to the copy")


# =============================================================================
# Part 2 — the `set_length` MIRROR. These are the only falsifiers for it.
# =============================================================================
#
# ⚠ The production producers (the string concat,
# `StringArray.from_strings*`) size their buffers EXACTLY, so `share()` inherits
# an already-exact length and the mirror is a no-op for them — deleting it
# leaves every byte-equality test above GREEN. These two tests build the case
# the production arms cannot: a buffer deliberately longer than the array's
# logical extent. The hazard is real for any future caller whose array is
# over-allocated or sliced, because `Column.content_hash` folds `_data.len()`
# raw bytes.
# -----------------------------------------------------------------------------


def _string_array_with_slack(
    data_slack: Int, offsets_slack: Int
) raises -> StringArray[HeapRegion]:
    """A 3-element StringArray whose buffers are deliberately allocated LONGER
    than the header claims, with the slack filled with a recognisable pattern
    that must NOT reach the Column."""
    comptime n = 3
    var payload = String("aa") + String("bbbb") + String("c")  # 2 + 4 + 1 = 7
    var data_len = payload.byte_length()

    var db = OwnedAlignedBuffer(data_len + data_slack)
    db.set_length(Int64(data_len + data_slack))
    var pb = payload.as_bytes()
    for i in range(data_len):
        db.set_typed[UInt8](i, pb[i])
    for i in range(data_slack):
        db.set_typed[UInt8](data_len + i, UInt8(0xA5))

    var off_bytes = (n + 1) * 4
    var ob = OwnedAlignedBuffer(off_bytes + offsets_slack)
    ob.set_length(Int64(off_bytes + offsets_slack))
    ob.set_typed[Int32](0, Int32(0))
    ob.set_typed[Int32](1, Int32(2))
    ob.set_typed[Int32](2, Int32(6))
    ob.set_typed[Int32](3, Int32(7))
    for i in range(offsets_slack // 4):
        ob.set_typed[Int32](n + 1 + i, Int32(0x5A5A5A5A))

    return StringArray[HeapRegion](
        offsets=ob^,
        data=db^,
        validity=None,
        length=n,
        data_length=data_len,
        null_count=0,
    )


def test_shared_truncates_an_over_allocated_data_buffer() raises:
    """M3. The shared handle must expose exactly `data_length` bytes."""
    var arr = _string_array_with_slack(64, 0)
    assert_true(
        Int(arr.data.len()) > arr.data_length,
        "PREMISE: the source data buffer must be LONGER than `data_length`,"
        " or this test asserts nothing",
    )
    var expect = arr.data_length
    var col = Column.from_string_shared(arr^)
    assert_equal(
        Int(col._data.len()),
        expect,
        "from_string_shared must TRUNCATE the shared data handle to"
        " `data_length` — the source buffer's extra bytes must not reach the"
        " Column, or content_hash diverges from the copying spelling",
    )
    _ = col^
    print("  OK over-allocated data buffer is truncated by the share")


def test_shared_truncates_an_over_allocated_offsets_buffer() raises:
    """M2. The shared handle must expose exactly `(length + 1) * 4` bytes."""
    var arr = _string_array_with_slack(0, 32)
    var expect_off = (arr.length + 1) * 4
    assert_true(
        Int(arr.offsets.len()) > expect_off,
        "PREMISE: the source offsets buffer must be LONGER than"
        " (length + 1) * 4, or this test asserts nothing",
    )
    var col = Column.from_string_shared(arr^)
    assert_true(
        col._offsets.__bool__(), "the shared column must carry offsets"
    )
    assert_equal(
        Int(col._offsets.value().len()),
        expect_off,
        "from_string_shared must TRUNCATE the shared offsets handle to"
        " (length + 1) * 4",
    )
    _ = col^
    print("  OK over-allocated offsets buffer is truncated by the share")


def test_shared_raises_on_a_short_data_buffer() raises:
    """M6. A `data_length` larger than the buffer is the case `from_string`'s
    `view_range_ro` would have rejected; the share must REFUSE, not alias
    out-of-range bytes."""
    comptime n = 2
    var db = OwnedAlignedBuffer(4)
    db.set_length(Int64(4))
    var ob = OwnedAlignedBuffer((n + 1) * 4)
    ob.set_length(Int64((n + 1) * 4))
    ob.set_typed[Int32](0, Int32(0))
    ob.set_typed[Int32](1, Int32(2))
    ob.set_typed[Int32](2, Int32(999))
    var arr = StringArray[HeapRegion](
        offsets=ob^,
        data=db^,
        validity=None,
        length=n,
        data_length=999,  # LIES: the buffer holds 4 bytes
        null_count=0,
    )
    var raised = False
    try:
        var col = Column.from_string_shared(arr^)
        _ = col^
    except:
        raised = True
    assert_true(
        raised,
        "from_string_shared must RAISE when `data_length` exceeds the data"
        " buffer — aliasing out-of-range bytes is worse than the copy it"
        " replaces",
    )
    print("  OK short data buffer is refused")


# =============================================================================
# Part 3 — the PAIRED counter is the observable.
# =============================================================================


def test_counters_are_paired_and_exclusive() raises:
    """M7. `string-share + string-COPY` is the number of BYTE_ARRAY fallback
    chunks that reached the gated arm, so a lever that never arms is RED here
    rather than measuring a perfect null that is indistinguishable from an arm
    that was never reached.

    This test drives the counters directly (the gated arm's own increments live
    behind a decode route that needs a mixed PLAIN + RLE_DICTIONARY
    fixture); what it pins is the PAIRING invariant the A/B reads."""
    reset_scan_copy_counts()
    assert_equal(string_share_count(), 0, "reset must zero string-share")
    assert_equal(string_copy_count(), 0, "reset must zero string-COPY")

    incr_string_copy()
    incr_string_copy()
    assert_equal(string_copy_count(), 2, "the OFF arm must count COPIES")
    assert_equal(
        string_share_count(),
        0,
        "the OFF arm must NOT increment string-share — a non-zero share count"
        " with the gate off means the arms are mis-wired",
    )

    incr_string_share()
    assert_equal(
        string_share_count(),
        1,
        "the ON arm must increment string-share, not string-COPY",
    )
    assert_equal(
        string_copy_count(), 2, "the ON arm must not also count a COPY"
    )

    # Cumulative, not per-scan: the A/B reads the LAST dump line as the total.
    incr_string_share()
    incr_string_copy()
    assert_equal(string_share_count(), 2, "counters must be CUMULATIVE")
    assert_equal(string_copy_count(), 3, "counters must be CUMULATIVE")
    reset_scan_copy_counts()
    print("  OK paired counters are exclusive and cumulative")


def test_gate_flips_in_process() raises:
    """The byte-equivalence oracle has to flip the arm twice in ONE process,
    through the setter.

    ⚠ It ends by RESETTING the latch rather than leaving it stored OFF. An OFF
    latch is not the default, and leaving one behind would hand any later
    test in this process a silently disarmed gate."""
    set_string_share_enabled(True)
    assert_true(
        string_share_enabled(), "the setter must be able to force the gate ON"
    )
    set_string_share_enabled(False)
    assert_false(
        string_share_enabled(),
        "the setter must be able to force the gate OFF",
    )
    reset_scan_copy_gates()
    assert_true(string_share_enabled(), "the reset must restore the default ON")
    print("  OK the setter flips the latch in-process")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
