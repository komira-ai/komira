# =============================================================================
# test_plain_ba_raise_outlined — the PLAIN BYTE_ARRAY per-value refusals are
# byte-identical now that their sentences live in `@no_inline` helpers
# =============================================================================
#
# ★ WHAT THIS FILE IS THE FALSIFIER FOR. `plain.mojo`'s two BYTE_ARRAY walks
#   (`_decode_plain_ba_fused`, the default, and `_decode_plain_ba_two_pass`,
#   `set_plain_ba_fused_enabled(False)`) refuse a malformed page from INSIDE
#   `for i in range(num_values)`. A `raise Error(...)` spelled at the call
#   site, splicing three or four `String(Int)` itoas into a sentence, costs an
#   itoa per number, a `String::_add` per join, an sret slot, an atomic
#   String-refcount destructor and an opaque stack-trace call — per VALUE,
#   whether or not the branch is ever taken. The four sentences live in
#   `@no_inline` helpers; the PREDICATES stay at the call sites.
#
# ⛔ THE MOVE IS ONLY SAFE IF THE REFUSAL IS BYTE-IDENTICAL, AND "it still
#   raises" IS NOT THAT ASSERTION. `test_plain_ba_fused_byte_equiv` already
#   records why (its M3/M4 rows): a mutation that DELETES a bound still raises,
#   one value later, so a test that asserts only "raised" is green on a heap
#   overflow. Every assertion below therefore compares the caught message to a
#   sentence composed HERE, character for character.
#
# ⛔ AND THE EXPECTED TEXT IS SPELLED OUT IN THIS FILE, NOT IMPORTED. Reading
#   the sentence back from a message-builder in the code under test would make
#   the comparison agree with a broken helper. That is why the literals below
#   are duplicated from `plain.mojo` by hand and why a reword must red this
#   file.
#
# ---------------------------------------------------------------------------
# ⚠ WHAT EACH TEST IS THE FALSIFIER FOR, AND WHICH MUTATION KILLS IT
# ---------------------------------------------------------------------------
#   M1  `_raise_plain_ba_truncated_prefix`: reword, drop `String(pos)`, or
#       swap two interpolated numbers
#         -> KILLED BY `test_truncated_prefix_sentence_is_byte_identical`.
#   M2  `_raise_plain_ba_negative_length`: same class of edit
#         -> KILLED BY `test_negative_length_sentence_is_byte_identical`.
#   M3  `_raise_plain_ba_overruns_page`: reword, or pass `data_len` where the
#       call site passed `data_len - pos`
#         -> KILLED BY `test_two_pass_overrun_sentence_is_byte_identical`.
#   M4  `_raise_plain_ba_overruns_reserve`: reword, or pass `num_values - i`
#       for the later-prefix count instead of `num_values - 1 - i`
#         -> KILLED BY `test_fused_reserve_sentence_is_byte_identical`.
#   M5  ⭐ COLLAPSE the two arm-specific overrun helpers into one shared
#       sentence ("it is nearly the same message")
#         -> KILLED BY `test_the_two_overrun_sentences_stay_distinct`. The
#            bounds DIFFER — the two-pass arm proves `str_len <= data_len-pos`
#            and the fused arm the strictly stronger prefix-reserve bound — and
#            `test_plain_ba_fused_byte_equiv`'s M3 witness is asserted on the
#            fused wording. Merging them would silently disarm that witness.
#   M6  Point ONE arm's call site at the wrong shared helper, or re-inline one
#       of the two shared sentences so the arms drift
#         -> KILLED BY `test_both_arms_share_one_negative_length_sentence`.
#   M7  ⭐ Make a helper raise UNCONDITIONALLY (or hoist the call out of its
#       `if`), i.e. move the predicate as well as the sentence
#         -> KILLED BY `test_CONTROL_conforming_pages_do_not_refuse`. Without
#            this control every assertion above passes on a decoder that
#            refuses every page.
#
# ⚠ NO PARQUET FILE IS WRITTEN OR READ HERE. Every page below is hand-built
#   bytes.
#
# Hard-rule audit: no UnsafePointer in any signature (the raw pointer stays
# inside `_buf_from`); no wildcard origins; no address made from an integer.
# =============================================================================

from std.memory import unsafe_memcpy
from std.testing import TestSuite, assert_equal, assert_true

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from komira_parquet import decode_plain_byte_array
from komira_parquet.scan_copy_trace import (
    reset_scan_copy_gates,
    set_plain_ba_fused_enabled,
)

# =============================================================================
# Helpers — hand-built pages, and one decode that returns the ERROR TEXT
# =============================================================================


def _u32_le(value: Int) -> List[UInt8]:
    """Little-endian 4-byte encoding, as a Parquet BYTE_ARRAY length prefix.
    `value` is written as the raw 32 bits, so a negative length round-trips —
    the decoder reads the prefix as a SIGNED Int32 straight from the page."""
    var out = List[UInt8]()
    out.append(UInt8(value & 0xFF))
    out.append(UInt8((value >> 8) & 0xFF))
    out.append(UInt8((value >> 16) & 0xFF))
    out.append(UInt8((value >> 24) & 0xFF))
    return out^


def _extend(mut dst: List[UInt8], src: List[UInt8]):
    for i in range(len(src)):
        dst.append(src[i])


def _buf_from(bytes: List[UInt8]) -> OwnedAlignedBuffer:
    """Copy `bytes` into a fresh aligned buffer, so the decoder under test
    receives a real heap allocation whose end is a real allocation end."""
    var n = len(bytes)
    var buf = OwnedAlignedBuffer(max(n, 1))
    if n > 0:
        var view = buf.view_range_mut(0, n)
        unsafe_memcpy(dest=view._unsafe_ptr(), src=bytes.unsafe_ptr(), count=n)
    buf.set_length(Int64(n))
    return buf^


def _decode_msg(
    page: List[UInt8], data_len: Int, num_values: Int, fused: Bool
) raises -> String:
    """Decode on the requested arm; return the error text, or "" if the page
    was accepted. Returning the TEXT rather than a Bool is the whole point of
    this file."""
    set_plain_ba_fused_enabled(fused)
    var buf = _buf_from(page)
    var view = buf.view_range_ro(0, data_len)
    var msg = String("")
    try:
        var arr = decode_plain_byte_array(view.into_span(), num_values)
        _ = arr^
    except e:
        msg = String(e)
    _ = buf^
    reset_scan_copy_gates()
    return msg^


# -----------------------------------------------------------------------------
# The four witness pages. Each reaches EXACTLY ONE refusal, and the comment
# says which check fires and with what arguments — so a page that starts
# tripping a different bound is visible as a changed expectation, not as a
# silently still-green "it raised".
# -----------------------------------------------------------------------------


def _page_truncated_prefix() -> List[UInt8]:
    """6 bytes, 2 declared values. Value 0 declares length 0 and consumes the
    first 4 bytes; value 1's prefix then starts at byte 4 with only 2 bytes
    left, so `pos + 4 > data_len` fires with i=1, pos=4, data_len=6."""
    var page = List[UInt8]()
    _extend(page, _u32_le(0))
    page.append(UInt8(0xAA))
    page.append(UInt8(0xBB))
    return page^


def _page_negative_length() -> List[UInt8]:
    """8 bytes, 1 declared value, whose prefix is -1 read as a signed Int32.
    `str_len < 0` fires with i=0, str_len=-1. ⭐ This page is accepted by the
    fused arm's up-front prefix-budget check (1 <= 8 >> 2), which is what makes
    it reach the SHARED per-value refusal on BOTH arms."""
    var page = List[UInt8]()
    _extend(page, _u32_le(-1))
    for _ in range(4):
        page.append(UInt8(0x41))
    return page^


def _page_two_pass_overrun() -> List[UInt8]:
    """8 bytes, 1 declared value declaring a 100-byte body. The two-pass arm's
    bound `str_len > data_len - pos` fires with i=0, str_len=100, and 4 bytes
    remaining after the prefix."""
    var page = List[UInt8]()
    _extend(page, _u32_le(100))
    for _ in range(4):
        page.append(UInt8(0x42))
    return page^


def _page_fused_reserve() -> List[UInt8]:
    """104 bytes, 2 declared values, value 0 declaring a 100-byte body — the
    capacity witness `test_plain_ba_fused_byte_equiv` documents. The fused
    arm reserves 4 bytes for value 1's prefix, so `str_len > data_len - pos -
    prefix_reserve` fires with i=0, str_len=100, 96 bytes remaining and 1 later
    prefix reserved. ⛔ The two-pass arm ACCEPTS value 0 here and raises a value
    later; that difference is the reason the two overrun sentences differ."""
    var page = List[UInt8]()
    _extend(page, _u32_le(100))
    for i in range(100):
        page.append(UInt8(i & 0xFF))
    return page^


# =============================================================================
# §1 — THE FOUR SENTENCES, BYTE FOR BYTE
# =============================================================================


def test_truncated_prefix_sentence_is_byte_identical() raises:
    """Falsifier for M1. The two-pass arm is the one that reaches this check
    with a page the fused arm's up-front prefix-budget refusal would take
    first, so the witness is decoded on that arm."""
    var page = _page_truncated_prefix()
    assert_equal(len(page), 6, "witness page must be exactly 6 bytes")
    var msg = _decode_msg(page, 6, 2, False)
    assert_equal(
        msg,
        String(
            "parquet: truncated PLAIN BYTE_ARRAY: length prefix for value 1"
            " starts at byte 4 but the page holds only 6 bytes"
        ),
        (
            "the outlined helper must reproduce the call site's sentence BYTE"
            " FOR BYTE, including every interpolated number and its position"
        ),
    )


def test_negative_length_sentence_is_byte_identical() raises:
    var msg = _decode_msg(_page_negative_length(), 8, 1, False)
    assert_equal(
        msg,
        String(
            "parquet: corrupt PLAIN BYTE_ARRAY: value 0 declares a negative"
            " length -1"
        ),
        "falsifier for M2 — byte-for-byte, on the two-pass arm",
    )


def test_two_pass_overrun_sentence_is_byte_identical() raises:
    var msg = _decode_msg(_page_two_pass_overrun(), 8, 1, False)
    assert_equal(
        msg,
        String(
            "parquet: corrupt PLAIN BYTE_ARRAY: value 0 declares length 100"
            " but only 4 bytes remain in the page"
        ),
        (
            "falsifier for M3 — `remaining` is `data_len - pos`, i.e. what is"
            " left AFTER this value's own 4-byte prefix, not `data_len`"
        ),
    )


def test_fused_reserve_sentence_is_byte_identical() raises:
    var page = _page_fused_reserve()
    assert_equal(len(page), 104, "witness page must be exactly 104 bytes")
    var msg = _decode_msg(page, 104, 2, True)
    assert_equal(
        msg,
        String(
            "parquet: corrupt PLAIN BYTE_ARRAY: value 0 declares length 100"
            " but only 96 bytes remain in the page once the 1 later length"
            " prefixes are reserved"
        ),
        (
            "falsifier for M4 — the reserve is 4 * (num_values - 1) = 4, so 96"
            " bytes remain and exactly 1 later prefix is reserved"
        ),
    )


# =============================================================================
# §2 — ONE SENTENCE, NOT TWO COPIES. The two shared refusals were byte-identical
# literals duplicated across the arms; they are one function each now, and this
# is the assertion that says so.
# =============================================================================


def test_both_arms_share_one_negative_length_sentence() raises:
    """Falsifier for M6. The negative-length page is accepted by the fused
    arm's up-front budget check, so BOTH walks reach the shared helper and the
    two texts must be the same bytes — not merely the same shape."""
    var two_pass = _decode_msg(_page_negative_length(), 8, 1, False)
    var fused = _decode_msg(_page_negative_length(), 8, 1, True)
    assert_true(
        two_pass.byte_length() > 0, "the two-pass arm must refuse this page"
    )
    assert_true(fused.byte_length() > 0, "the fused arm must refuse it too")
    assert_equal(
        two_pass,
        fused,
        (
            "both walks call ONE `@no_inline` helper for this refusal, so the"
            " arms cannot drift apart in wording — which is also what makes"
            " their byte-equivalence claim checkable rather than a coincidence"
            " of two hand-copied literals"
        ),
    )


def test_the_two_overrun_sentences_stay_distinct() raises:
    """⭐ Falsifier for M5 — the assertion that keeps a well-meaning
    de-duplication from disarming a live witness.

    The two arms prove DIFFERENT bounds, so their refusals say different
    things. `test_plain_ba_fused_byte_equiv`'s M3 row asserts the fused arm
    names the reserve, precisely because a fused walk carrying the weaker
    two-pass bound would overflow its exact-capacity buffer BEFORE raising."""
    var two_pass = _decode_msg(_page_two_pass_overrun(), 8, 1, False)
    var fused = _decode_msg(_page_fused_reserve(), 104, 2, True)
    assert_true(
        "later length prefixes are reserved" in fused,
        (
            "the fused arm's overrun refusal must name the prefix reserve;"
            " got: "
            + fused
        ),
    )
    assert_true(
        not ("later length prefixes are reserved" in two_pass),
        (
            "the two-pass arm proves only `str_len <= data_len - pos` and must"
            " NOT claim the stronger bound; got: "
            + two_pass
        ),
    )
    assert_true(
        two_pass != fused,
        "the two overrun sentences must not be collapsed into one helper",
    )


# =============================================================================
# §3 — THE CONTROL. A helper that raised unconditionally, or a call hoisted out
# of its `if`, would pass every assertion above.
# =============================================================================


def test_CONTROL_conforming_pages_do_not_refuse() raises:
    """Falsifier for M7. Two conforming pages — one with a zero-length value,
    one multi-value — must decode on BOTH arms with no error text at all."""
    var empty = List[UInt8]()
    _extend(empty, _u32_le(0))

    var three = List[UInt8]()
    _extend(three, _u32_le(2))
    three.append(UInt8(0x41))
    three.append(UInt8(0x42))
    _extend(three, _u32_le(0))
    _extend(three, _u32_le(3))
    three.append(UInt8(0x43))
    three.append(UInt8(0x44))
    three.append(UInt8(0x45))
    assert_equal(len(three), 17, "the multi-value control page is 17 bytes")

    assert_equal(
        _decode_msg(empty, 4, 1, False),
        String(""),
        "a single zero-length value must decode on the two-pass arm",
    )
    assert_equal(
        _decode_msg(empty, 4, 1, True),
        String(""),
        "a single zero-length value must decode on the fused arm",
    )
    assert_equal(
        _decode_msg(three, 17, 3, False),
        String(""),
        "a conforming 3-value page must decode on the two-pass arm",
    )
    assert_equal(
        _decode_msg(three, 17, 3, True),
        String(""),
        "a conforming 3-value page must decode on the fused arm",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_truncated_prefix_sentence_is_byte_identical]()
    suite.test[test_negative_length_sentence_is_byte_identical]()
    suite.test[test_two_pass_overrun_sentence_is_byte_identical]()
    suite.test[test_fused_reserve_sentence_is_byte_identical]()
    suite.test[test_both_arms_share_one_negative_length_sentence]()
    suite.test[test_the_two_overrun_sentences_stay_distinct]()
    suite.test[test_CONTROL_conforming_pages_do_not_refuse]()
    suite^.run()
