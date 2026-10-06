# =============================================================================
# Regression: SharedAlignedBuffer.from_borrowed_view(owner, off, len) must
# preserve the type-erased mmap keepalive Arc cookie.
# =============================================================================
#
# THE BUG
#   `borrow_mmap_erased` produces a `SAB[HeapRegion]` whose `_region` is an
#   EMPTY HeapRegion PLACEHOLDER (owns nothing) and whose SOLE lifetime anchor
#   is the `_mmap_keepalive: ArcPointer[MmapRegion]` cookie. Slicing such a
#   buffer with `from_borrowed_view(owner, offset, length)` cloned `_region`
#   (the placeholder — pinning nothing) and routed through `_field_init` ->
#   `__init_unchecked`, which HARDCODES `_mmap_keepalive = None`. The slice
#   therefore aliased mmap'd page-cache bytes with NOTHING pinning the mapping:
#   when the owner dropped, its last keepalive ref fired `munmap(2)` and every
#   slice's cached `_ptr` dangled into an unmapped address range.
#
#   This is the SAME "MISS-ONE-FIELD" hazard `share()` / `share_as()` /
#   `CopyableSharedAlignedBuffer.__init__(*, copy:)` each document and each
#   already handle (see test_copyable_sab_mmap_keepalive_copy.mojo);
#   `from_borrowed_view` must handle it the same way.
#
# WHY IT IS LIVE
#   `LocalFs.read_at` returns a `borrow_mmap_erased` buffer, so a spill read
#   (`FileSystemSpillStorage.read_chunk`) yields an mmap-erased buffer, and
#   `THSPLCDecoder.decode_zerocopy` slices it into per-column buffers with
#   exactly this factory and then drops the owner (`_ = bytes^`). Without the
#   cookie clone, the first read of any spill-restored column is a SIGSEGV
#   with no exception text.
#
# THE ASSERTION
#   A slice of an mmap-erased buffer must report `has_mmap_keepalive() == True`
#   (without the clone: False), and taking the slice must NOT move the owner's cookie
#   (Arc clone, +1, not a transfer). A heap-owned owner must NOT spuriously
#   gain one.
# =============================================================================

from std.memory import ArcPointer
from std.testing import TestSuite, assert_true, assert_false, assert_equal

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_buffer.mmap_region import MmapRegion


def _make_mmap_borrowed_sab() raises -> SharedAlignedBuffer[HeapRegion]:
    """A SAB[HeapRegion] whose bytes are an mmap borrow via the type-erased
    keepalive cookie.

    An EMPTY MmapRegion (default ctor: `_len == 0`, `__del__` munmap-skips) is
    sufficient: the invariant under test is Arc-cookie PROPAGATION, not the
    byte span, and this keeps the test hermetic (no file, no $TEST_TMPDIR, no
    syscall) so it is safe to run repeatedly and in parallel.
    """
    var region = MmapRegion()
    var region_arc = ArcPointer[MmapRegion](region^)
    return SharedAlignedBuffer.borrow_mmap_erased(region_arc^, 0, 0)


def test_owner_has_mmap_keepalive() raises:
    """POSITIVE CONTROL: the arrangement really does produce a keepalive-
    carrying owner. Without this, a False on the slice below would be
    indistinguishable from a fixture that never had a cookie to lose."""
    var owner = _make_mmap_borrowed_sab()
    assert_true(
        owner.has_mmap_keepalive(),
        "fixture owner must report has_mmap_keepalive()==True",
    )


def test_borrowed_view_preserves_mmap_keepalive() raises:
    """THE REGRESSION GUARD: a `from_borrowed_view(owner, off, len)` slice of
    an mmap-erased buffer must carry the keepalive Arc.

    Without the clone this is False -- `_field_init` -> `__init_unchecked` sets
    `_mmap_keepalive = None`, so the slice would pin nothing and dangle the
    moment the owner's last ref dropped (munmap)."""
    var owner = _make_mmap_borrowed_sab()
    var slice = SharedAlignedBuffer[HeapRegion].from_borrowed_view(
        owner, Int64(0), Int64(0)
    )
    assert_true(
        slice.has_mmap_keepalive(),
        (
            "BORROWED SLICE must inherit the mmap keepalive Arc -- otherwise it"
            " aliases page-cache bytes that munmap on the owner's drop"
            " (SIGSEGV in THSPLCDecoder.decode_zerocopy)"
        ),
    )
    # Clone, not move: the owner must retain its own ref.
    assert_true(
        owner.has_mmap_keepalive(),
        "owner must retain its keepalive after the slice (Arc clone, not move)",
    )


def test_borrowed_view_chain_preserves_mmap_keepalive() raises:
    """A slice OF A SLICE must also carry it -- the decode path nests borrows
    (chunk -> column buffer -> Bitmap.buffer)."""
    var owner = _make_mmap_borrowed_sab()
    var s1 = SharedAlignedBuffer[HeapRegion].from_borrowed_view(
        owner, Int64(0), Int64(0)
    )
    var s2 = SharedAlignedBuffer[HeapRegion].from_borrowed_view(
        s1, Int64(0), Int64(0)
    )
    assert_true(
        s2.has_mmap_keepalive(),
        "a slice of a slice must still pin the mapping",
    )


def test_heap_owned_borrowed_view_gains_no_keepalive() raises:
    """NEGATIVE CONTROL: the fix is gated on the owner HAVING a cookie -- a
    heap-owned owner's slice must not spuriously acquire one (which would leak
    an Arc and mask a genuinely un-pinned borrow)."""
    var heap = SharedAlignedBuffer[HeapRegion].heap_owned(64)
    assert_false(
        heap.has_mmap_keepalive(), "heap-owned owner has no mmap keepalive"
    )
    var slice = SharedAlignedBuffer[HeapRegion].from_borrowed_view(
        heap, Int64(0), Int64(32)
    )
    assert_false(
        slice.has_mmap_keepalive(),
        "heap-owned slice must stay keepalive-free (no spurious Arc)",
    )
    assert_equal(Int(slice.length()), 32, "heap-owned slice length preserved")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
