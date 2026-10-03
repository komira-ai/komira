# =============================================================================
# Tests for SharedAlignedBuffer[K] trait-bound elaboration
# =============================================================================
#
# Verifies SharedAlignedBuffer[K: MemoryRegion = HeapRegion] composes
# correctly with the standard container / wrapper shapes that holder structs
# parametric over the memory region rely on.
#
# Coverage:
#   * Optional[SharedAlignedBuffer[HeapRegion]] -- store & take
#   * Optional[SharedAlignedBuffer[MmapRegion]]  -- store & take
#   * Slab[SharedAlignedBuffer[HeapRegion]]      -- append, get, take_slot
#   * Slab[SharedAlignedBuffer[MmapRegion]]      -- append, get, take_slot
#   * struct Holder[K: MemoryRegion = HeapRegion]: var buf:
#       SharedAlignedBuffer[K] -- construct, move, drop
#
# The trait bounds on SharedAlignedBuffer are
#     (MmapAlignedBuffer, Movable, Deinitable)
# and Slab[T] requires `T: Deinitable`, Optional[T] requires
# Movable. This test confirms those bounds compose.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_buffer.memory_region import MemoryRegion
from komira_buffer.mmap_region import MmapRegion


# -----------------------------------------------------------------------------
# Helpers: construct SharedAlignedBuffer[HeapRegion] without depending on
# from_owned (which requires OwnedAlignedBuffer setup). We use the
# ArcPointer + offset/length ctor directly.
# -----------------------------------------------------------------------------

def _make_heap_shared(n: Int) -> SharedAlignedBuffer[HeapRegion]:
    """Build a SharedAlignedBuffer[HeapRegion] holding `n` zero bytes.

    Routes through OwnedAlignedBuffer + from_owned to exercise the
    canonical construction path.
    """
    var owned = OwnedAlignedBuffer(n)
    return SharedAlignedBuffer[HeapRegion].from_owned(owned^)


# -----------------------------------------------------------------------------
# Holder pattern: parametric struct field
# -----------------------------------------------------------------------------

struct Holder[K: MemoryRegion = HeapRegion](Movable, Deinitable):
    """Field-of-Struct pattern test. Mirrors the shape of holder structs
    (BufferHolder etc.) that are parametric over the memory region.
    """

    var buf: SharedAlignedBuffer[Self.K]

    def __init__(out self, var buf: SharedAlignedBuffer[Self.K]):
        self.buf = buf^


# =============================================================================
# Optional[SharedAlignedBuffer[HeapRegion]] -- store & take
# =============================================================================


def test_optional_heap_store_and_take() raises:
    """Optional[SharedAlignedBuffer[HeapRegion]] stores and pops cleanly.

    Verifies Optional's Movable trait bound is satisfied.
    """
    var opt = Optional[SharedAlignedBuffer[HeapRegion]](_make_heap_shared(128))
    assert_true(opt.__bool__())
    var taken = opt.take()
    # OAB(N).__init__ sets `_length == N`; SAB.from_owned propagates
    # `_length` -> SAB.
    assert_equal(taken.len(), 128)
    assert_true(not opt.__bool__())  # Optional is now None


def test_optional_heap_none_then_assign() raises:
    """Optional construction without a value, then assignment via
    `Optional(value^)`."""
    var opt = Optional[SharedAlignedBuffer[HeapRegion]]()
    assert_true(not opt.__bool__())
    opt = Optional[SharedAlignedBuffer[HeapRegion]](_make_heap_shared(64))
    assert_true(opt.__bool__())
    var taken = opt.take()
    # OAB(N).__init__ sets `_length == N`; SAB.from_owned propagates.
    assert_equal(taken.len(), 64)


# =============================================================================
# Optional[SharedAlignedBuffer[MmapRegion]] -- store & take
# =============================================================================
# We can't easily construct an MmapRegion at test time (needs a real
# file), but the elaboration question is about TYPE composition, not
# runtime use. We exercise Optional[SharedAlignedBuffer[MmapRegion]]
# default construction and bool-check to force the compiler to
# elaborate the type.


def test_optional_mmap_default_constructs() raises:
    """Optional[SharedAlignedBuffer[MmapRegion]]() default-constructs
    to None.

    This is a TYPE-ELABORATION test. The trait bounds on
    SharedAlignedBuffer[MmapRegion] must satisfy Optional[T]'s Movable
    constraint for this to even compile.
    """
    var opt = Optional[SharedAlignedBuffer[MmapRegion]]()
    assert_true(not opt.__bool__())


# =============================================================================
# Slab[SharedAlignedBuffer[HeapRegion]] -- append, get, take_slot
# =============================================================================


def test_slab_heap_append_and_len() raises:
    """Slab[SharedAlignedBuffer[HeapRegion]] accepts append; len reflects."""
    var slab = Slab[SharedAlignedBuffer[HeapRegion]]()
    slab.append(_make_heap_shared(32))
    slab.append(_make_heap_shared(64))
    slab.append(_make_heap_shared(128))
    assert_equal(slab.len(), 3)


def test_slab_heap_get_by_index() raises:
    """Slab[SharedAlignedBuffer[HeapRegion]].get(i) returns a ref to
    the stored buffer; observed length matches construction.
    """
    var slab = Slab[SharedAlignedBuffer[HeapRegion]]()
    slab.append(_make_heap_shared(32))
    slab.append(_make_heap_shared(128))
    # OAB(N).__init__ sets `_length == N`; SAB.from_owned propagates.
    assert_equal(slab.get(0).len(), 32)
    assert_equal(slab.get(1).len(), 128)


def test_slab_heap_take_slot_unchecked() raises:
    """Slab[SharedAlignedBuffer[HeapRegion]].take_slot_unchecked
    extracts the buffer; downstream len observation works."""
    var slab = Slab[SharedAlignedBuffer[HeapRegion]]()
    slab.append(_make_heap_shared(64))
    slab.append(_make_heap_shared(256))
    var taken = slab.take_slot_unchecked(1)
    slab.set_len_unchecked(1)  # mark slot 1 empty post-take
    # OAB(N).__init__ sets `_length == N`; SAB.from_owned propagates.
    assert_equal(taken.len(), 256)


# =============================================================================
# Slab[SharedAlignedBuffer[MmapRegion]] -- type elaboration only
# =============================================================================


def test_slab_mmap_default_constructs() raises:
    """Slab[SharedAlignedBuffer[MmapRegion]]() compiles and is empty.

    TYPE-ELABORATION test: confirms Slab[T]'s T: Deinitable
    bound is satisfied by SharedAlignedBuffer[MmapRegion].
    """
    var slab = Slab[SharedAlignedBuffer[MmapRegion]]()
    assert_equal(slab.len(), 0)


# =============================================================================
# Holder[K]: var buf field, construct + move + drop
# =============================================================================


def test_holder_heap_construct_and_move() raises:
    """Holder[HeapRegion] constructs from a SharedAlignedBuffer and
    moves cleanly. Verifies Holder.Movable holds when buf is moved."""
    var h = Holder[HeapRegion](_make_heap_shared(256))
    # OAB(N).__init__ sets `_length == N`; SAB.from_owned propagates.
    assert_equal(h.buf.len(), 256)
    # Move the holder
    var h2 = h^
    assert_equal(h2.buf.len(), 256)


def test_holder_default_k_is_heap_region() raises:
    """`Holder()` with default K-parameter is HeapRegion."""
    var h = Holder(_make_heap_shared(128))
    # OAB(N).__init__ sets `_length == N`; SAB.from_owned propagates.
    assert_equal(h.buf.len(), 128)


def test_holder_in_slab() raises:
    """Slab[Holder[HeapRegion]] composes -- two layers of parameterization."""
    var slab = Slab[Holder[HeapRegion]]()
    slab.append(Holder[HeapRegion](_make_heap_shared(64)))
    slab.append(Holder[HeapRegion](_make_heap_shared(128)))
    assert_equal(slab.len(), 2)
    # OAB(N).__init__ sets `_length == N`; SAB.from_owned propagates.
    assert_equal(slab.get(0).buf.len(), 64)
    assert_equal(slab.get(1).buf.len(), 128)


# =============================================================================
# Test driver
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
