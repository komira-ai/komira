# =============================================================================
# Regression: CopyableSharedAlignedBuffer.__init__(*, copy:) must preserve the
# type-erased mmap keepalive Arc cookie.
# =============================================================================
#
# THE HAZARD:
#   If `CopyableSharedAlignedBuffer.__init__(*, copy:)` built the clone via
#   `SharedAlignedBuffer.__init_unchecked(...)`, which HARDCODES
#   `_mmap_keepalive = None`, then copying a CopyableSAB whose inner buffer is
#   an mmap-borrowed buffer (empty-HeapRegion placeholder `_region` + the real
#   munmap-keepalive Arc held in `_mmap_keepalive`, as produced by
#   `SharedAlignedBuffer.borrow_mmap_erased`) would DROP the keepalive Arc on
#   the copy. The copy's cached `_ptr` would then alias mmap'd pages that can
#   be munmap'd (on the last *other* keepalive ref dropping) while the copy is
#   still live -> write-after-free / garbage read.
#
# THE CONTRACT:
#   The copy ctor clones the `_mmap_keepalive` Arc (refcount++) when the
#   source has one, mirroring the `_region` Arc clone it already performs.
#
# THE ASSERTION:
#   After `__init__(*, copy:)`, the copy must report `has_mmap_keepalive() ==
#   True`.
#
# A heap-owned buffer never reaches this copy ctor with a non-None keepalive;
# the hazard is any mmap-borrowed CopyableSAB copy (e.g. variadic-pack copy
# forwarding of a zero-copy mmap column).
# =============================================================================

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.copyable_shared_aligned_buffer import (
    CopyableSharedAlignedBuffer,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.mmap_region import MmapRegion


def _make_mmap_borrowed_sab() raises -> SharedAlignedBuffer[HeapRegion]:
    """Build a SAB[HeapRegion] whose bytes are an mmap borrow via the
    type-erased keepalive cookie (`borrow_mmap_erased`).

    We use an EMPTY MmapRegion (default ctor: `_len == 0`, `__del__` is a
    no-op munmap-skip). That is sufficient to exercise the keepalive-Arc
    plumbing: the buffer reports `has_mmap_keepalive() == True` regardless of
    the mapping's byte length, and no real mmap syscall is needed for the
    refcount-preservation invariant under test.
    """
    var region = MmapRegion()  # empty; munmap is a no-op at drop (_len == 0)
    var region_arc = ArcPointer[MmapRegion](region^)
    # offset=0, length=0 — the keepalive arm is what matters, not the byte span.
    return SharedAlignedBuffer.borrow_mmap_erased(region_arc^, 0, 0)


def test_source_sab_has_mmap_keepalive() raises:
    """Pre-condition: the source buffer reports a live mmap keepalive."""
    var sab = _make_mmap_borrowed_sab()
    assert_true(
        sab.has_mmap_keepalive(),
        "source mmap-borrowed SAB must report has_mmap_keepalive()==True",
    )


def test_copyable_wrapper_reports_keepalive() raises:
    """The CopyableSAB wrapper delegates has_mmap_keepalive() to the inner buf."""
    var wrapped = CopyableSharedAlignedBuffer[HeapRegion](
        _make_mmap_borrowed_sab()
    )
    assert_true(
        wrapped.has_mmap_keepalive(),
        "wrapped mmap-borrowed CopyableSAB must report keepalive present",
    )


def test_copy_ctor_preserves_mmap_keepalive() raises:
    """THE REGRESSION GUARD: copying a CopyableSAB whose inner buffer is
    mmap-borrowed must PRESERVE the mmap keepalive Arc on the copy.

    A copy ctor routed through `__init_unchecked`, which hardcodes
    `_mmap_keepalive = None`, fails this assertion (`has_mmap_keepalive()`
    is False on the copy). Cloning the keepalive Arc makes it True.
    """
    var src = CopyableSharedAlignedBuffer[HeapRegion](_make_mmap_borrowed_sab())
    assert_true(src.has_mmap_keepalive(), "src keepalive present pre-copy")

    var dst = CopyableSharedAlignedBuffer[HeapRegion](copy=src)
    assert_true(
        dst.has_mmap_keepalive(),
        (
            "COPY must preserve the mmap keepalive Arc (regression: copy ctor"
            " dropped it via __init_unchecked's hardcoded None)"
        ),
    )
    # Source must STILL hold its own keepalive ref (clone is +1, not a move).
    assert_true(
        src.has_mmap_keepalive(),
        "source must retain its keepalive after the copy (Arc clone, not move)",
    )


def test_copy_ctor_no_keepalive_stays_none() raises:
    """A heap-owned (non-mmap) CopyableSAB copy must NOT spuriously gain a
    keepalive — the fix is gated on the source having one."""
    var heap = SharedAlignedBuffer[HeapRegion].heap_owned(64)
    var src = CopyableSharedAlignedBuffer[HeapRegion](heap^)
    assert_false(
        src.has_mmap_keepalive(),
        "heap-owned source has no mmap keepalive",
    )
    var dst = CopyableSharedAlignedBuffer[HeapRegion](copy=src)
    assert_false(
        dst.has_mmap_keepalive(),
        "heap-owned copy must stay keepalive-free (no spurious Arc)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
