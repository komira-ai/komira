# =============================================================================
# `SharedAlignedBuffer.share_range_as` — the WINDOW Arc-share.
#
# ⛔ DO NOT DELETE THIS FILE. IT IS THE ONLY PLACE `share_range_as` IS PINNED.
#
# `SharedAlignedBuffer.share_range_as` is a MEMORY-SAFETY primitive: it hands
# out an Arc share of a SUB-RANGE of a buffer. Nothing else asserts its window
# arithmetic, its nesting, its mmap-keepalive clone or its refusals. The list
# under "WHAT IT PINS" below is the file's justification; read it before
# proposing a deletion.
#
# WHY IT TESTS THE PRIMITIVE DIRECTLY RATHER THAN THROUGH A CALLER
#
# `share_range_as` has live callers: `Column.as_primitive`'s zero-copy arm
# (every call on a non-nullable column), and `make_selection_column`
# (`komira_core/arrow/selection_column.mojo`), which narrows a dict-base share
# with `base._data.share_range_as[HeapRegion](base._offset * vw,
# base._length * vw)` whenever a join probe slices its dictionary base. Testing
# the primitive directly keeps every assertion live however those callers are
# rewritten, replaced or gated.
#
# WHAT IT PINS, and why each one is here rather than assumed:
#
#   * WINDOW SEMANTICS — `len()` is the sub-range, and byte `j` of the share is
#     byte `byte_offset + j` of the source. This is the whole contract; a
#     share that returned the source's length with an offset on the side would
#     force every caller to prefix-copy downstream.
#   * NO BYTE COPY — asserted by MUTATING through the window and observing the
#     write in the SOURCE. A copy would pass every read-only assertion in this
#     file, so nothing else here can tell a share from a memcpy.
#     (⚠ The mutation is legitimate HERE and nowhere else: writing through an
#     Arrow buffer share is the mutate-through-alias hazard that
#     `Column.share_as_primitive`'s docstring makes its callers audit. This
#     test owns both handles and is proving aliasing on purpose.)
#   * COMPOSITION — a window of a window resolves against the inner window, so
#     `_offset` accumulates. Nesting is how a sliced Column's buffer reaches
#     the accessor in the first place.
#   * THE MISS-ONE-FIELD HAZARD — an mmap-erased buffer's `_mmap_keepalive`
#     cookie must be CLONED onto the window, or the window aliases page-cache
#     bytes that `munmap` on the owner's drop. This is not hypothetical: it is
#     the bug `test_sab_borrowed_view_mmap_keepalive.mojo` was written for,
#     where `from_borrowed_view` was the one derivation factory that missed it.
#     `share_range_as` is the NEXT such factory, so it gets the same guard.
#   * REFUSALS — an out-of-range window must RAISE, not clamp. A clamped share
#     aliases bytes the caller did not ask for, which is a memory-safety
#     question; and the checks must not be `debug_assert`s that fold out of the
#     bench builds where the arithmetic is hottest.
# =============================================================================

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.io.heap_region import HeapRegion
from komira_core.io.mmap_region import MmapRegion


comptime _N = 64


def _make_ramp(n: Int) raises -> SharedAlignedBuffer[HeapRegion]:
    """A heap-owned SAB of `n` bytes where byte `i` holds `i & 0xFF`.

    A RAMP, not zeros: every assertion below is about WHICH bytes the window
    exposes, and a zero-filled fixture cannot tell a correct window from a
    wrongly-based one.
    """
    var owned = OwnedAlignedBuffer(n)
    owned.set_length(Int64(n))
    var buf = SharedAlignedBuffer[HeapRegion].from_owned(owned^)
    for i in range(n):
        buf.set_typed[UInt8](i, UInt8(i & 0xFF))
    return buf^


def test_window_len_and_bytes() raises:
    """The window's `len()` IS the sub-range, and its bytes are the source's
    at `byte_offset + j` — not the source's from byte 0."""
    var src = _make_ramp(_N)
    var start = 16
    var length = 32
    var win = src.share_range_as[HeapRegion](start, length)

    assert_equal(win.len(), length, "window len() == byte_length")
    for j in range(length):
        assert_equal(
            Int(win.get_typed[UInt8](j)),
            (start + j) & 0xFF,
            "window byte j must be source byte (byte_offset + j)",
        )
    # The source is untouched by taking the window.
    assert_equal(src.len(), _N, "source len() unchanged by share_range_as")


def test_window_offset_is_rebased_into_the_region() raises:
    """`_offset` accumulates onto the source's, so the window really is a view
    INTO the same region and not a fresh allocation at offset 0."""
    var src = _make_ramp(_N)
    var start = 24
    var win = src.share_range_as[HeapRegion](start, 8)
    assert_equal(
        Int(win._offset),
        Int(src._offset) + start,
        "window _offset must be source _offset + byte_offset",
    )


def test_window_is_a_share_not_a_copy() raises:
    """THE ZERO-COPY ASSERTION. Write through the window; read it in the
    SOURCE. A memcpy passes every other assertion in this file."""
    var src = _make_ramp(_N)
    var start = 40
    var win = src.share_range_as[HeapRegion](start, 8)

    assert_equal(
        Int(src.get_typed[UInt8](start)), start & 0xFF, "precondition"
    )
    win.set_typed[UInt8](0, UInt8(0xAB))
    assert_equal(
        Int(src.get_typed[UInt8](start)),
        0xAB,
        (
            "a write through the window must be visible in the SOURCE —"
            " share_range_as must ALIAS, never copy"
        ),
    )


def test_window_of_a_window_composes() raises:
    """Nesting resolves against the INNER window, so the offsets add."""
    var src = _make_ramp(_N)
    var outer = src.share_range_as[HeapRegion](16, 32)
    var inner = outer.share_range_as[HeapRegion](8, 4)

    assert_equal(inner.len(), 4, "nested window len()")
    assert_equal(
        Int(inner._offset),
        Int(src._offset) + 16 + 8,
        "nested window _offset accumulates through both hops",
    )
    for j in range(4):
        assert_equal(
            Int(inner.get_typed[UInt8](j)),
            (16 + 8 + j) & 0xFF,
            "nested window byte j == source byte (16 + 8 + j)",
        )


def test_zero_length_window_is_legal() raises:
    """An empty window is a legal request (an empty Column window produces
    one) and must not be confused with an out-of-range one."""
    var src = _make_ramp(_N)
    var win = src.share_range_as[HeapRegion](_N, 0)
    assert_equal(win.len(), 0, "zero-length window at the very end is legal")


def test_window_preserves_mmap_keepalive() raises:
    """MISS-ONE-FIELD. A window of an mmap-erased buffer must CLONE the
    keepalive cookie, or it aliases page-cache bytes that munmap on the
    owner's drop (the `from_borrowed_view` SIGSEGV, one factory over)."""
    var region = MmapRegion()
    var region_arc = ArcPointer[MmapRegion](region^)
    var owner = SharedAlignedBuffer.borrow_mmap_erased(region_arc^, 0, 0)
    assert_true(
        owner.has_mmap_keepalive(),
        "POSITIVE CONTROL: the fixture owner must carry a cookie, else a"
        " False below would be a fixture bug rather than a lost clone",
    )

    var win = owner.share_range_as[HeapRegion](0, 0)
    assert_true(
        win.has_mmap_keepalive(),
        "the WINDOW must inherit the mmap keepalive Arc",
    )
    assert_true(
        owner.has_mmap_keepalive(),
        "owner must retain its own ref (Arc clone, not a move)",
    )


def test_heap_window_does_not_invent_a_keepalive() raises:
    """The negative control for the case above: a heap-owned source must NOT
    spuriously gain a cookie, or the assertion there would pass for every
    buffer and prove nothing."""
    var src = _make_ramp(_N)
    assert_false(src.has_mmap_keepalive(), "heap fixture carries no cookie")
    var win = src.share_range_as[HeapRegion](8, 8)
    assert_false(
        win.has_mmap_keepalive(),
        "a heap-backed window must not report an mmap keepalive",
    )


def test_refuses_out_of_range_window() raises:
    """A window past the end must RAISE, not clamp."""
    var src = _make_ramp(_N)
    var raised = False
    try:
        var _w = src.share_range_as[HeapRegion](_N - 4, 8)
    except:
        raised = True
    assert_true(
        raised,
        "byte_offset + byte_length > len() must raise, not silently clamp"
        " (a clamped share aliases bytes the caller did not ask for)",
    )


def test_refuses_negative_range() raises:
    """Both negative arms, separately — one check covering both would pass
    while the other arm was missing."""
    var src = _make_ramp(_N)

    var raised_off = False
    try:
        var _a = src.share_range_as[HeapRegion](-1, 4)
    except:
        raised_off = True
    assert_true(raised_off, "negative byte_offset must raise")

    var raised_len = False
    try:
        var _b = src.share_range_as[HeapRegion](4, -1)
    except:
        raised_len = True
    assert_true(raised_len, "negative byte_length must raise")


def test_full_range_window_is_the_whole_buffer() raises:
    """The identity case: a window over the entire buffer reads like the
    source. Pins that the bounds check is `<=`, not `<`."""
    var src = _make_ramp(_N)
    var win = src.share_range_as[HeapRegion](0, _N)
    assert_equal(win.len(), _N, "full-range window len()")
    for j in range(_N):
        assert_equal(
            Int(win.get_typed[UInt8](j)), j & 0xFF, "full-range window byte"
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_window_len_and_bytes]()
    suite.test[test_window_offset_is_rebased_into_the_region]()
    suite.test[test_window_is_a_share_not_a_copy]()
    suite.test[test_window_of_a_window_composes]()
    suite.test[test_zero_length_window_is_legal]()
    suite.test[test_window_preserves_mmap_keepalive]()
    suite.test[test_heap_window_does_not_invent_a_keepalive]()
    suite.test[test_refuses_out_of_range_window]()
    suite.test[test_refuses_negative_range]()
    suite.test[test_full_range_window_is_the_whole_buffer]()
    suite^.run()
