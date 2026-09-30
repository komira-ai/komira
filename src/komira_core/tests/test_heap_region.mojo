# =============================================================================
# test_heap_region.mojo — unit test for komira_core.io.heap_region.HeapRegion
# =============================================================================
#
# Validates the `HeapRegion(MemoryRegion)` conformer:
#
# Coverage:
#   (a) Construct from `List[UInt8]([1, 2, 3, 4])`; verify `length()` == 4.
#   (b) `as_view()` returns a ByteView whose `len()` matches the source.
#   (c) ByteView contents match input bytes (via `read_u8_at`).
#   (d) `with_capacity(N)` factory produces an empty region (length 0)
#       with capacity reserved for growth.
#   (e) Empty region (no bytes appended) has length 0; view is empty.
#   (f) Move semantics: HeapRegion is Movable; transfer-construct works.
#   (g) Generic trait dispatch: a `[K: MemoryRegion]`-parametric function
#       elaborates against HeapRegion and dispatches through trait.
#
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.io.heap_region import HeapRegion
from komira_core.io.memory_region import MemoryRegion


# -----------------------------------------------------------------------------
# Test bodies
# -----------------------------------------------------------------------------


def test_construct_from_list_and_length() raises:
    """(a) Construct from a populated `List[UInt8]`; `length()` reflects
    the byte count exactly."""
    var bytes = List[UInt8]()
    bytes.append(UInt8(1))
    bytes.append(UInt8(2))
    bytes.append(UInt8(3))
    bytes.append(UInt8(4))
    var region = HeapRegion(bytes^)
    assert_equal(Int(region.length()), 4)


def test_as_view_len_matches_input() raises:
    """(b) `as_view()` returns a ByteView whose `len()` matches the
    underlying List length."""
    var bytes = List[UInt8]()
    for i in range(7):
        bytes.append(UInt8(i))
    var region = HeapRegion(bytes^)
    var view = region.as_view()
    assert_equal(view.len(), 7)


def test_as_view_contents_match() raises:
    """(c) ByteView contents match the input bytes via `read_u8_at`."""
    var bytes = List[UInt8]()
    bytes.append(UInt8(10))
    bytes.append(UInt8(20))
    bytes.append(UInt8(30))
    bytes.append(UInt8(40))
    bytes.append(UInt8(50))
    var region = HeapRegion(bytes^)
    var view = region.as_view()
    assert_equal(view.len(), 5)
    assert_equal(Int(view.read_u8_at(0)), 10)
    assert_equal(Int(view.read_u8_at(1)), 20)
    assert_equal(Int(view.read_u8_at(2)), 30)
    assert_equal(Int(view.read_u8_at(3)), 40)
    assert_equal(Int(view.read_u8_at(4)), 50)


def test_with_capacity_factory() raises:
    """(d) `with_capacity(N)` factory produces an empty region; caller
    can extend by accessing the inner List or by replacing the region
    later. Verifies `length() == 0` post-factory."""
    var region = HeapRegion.with_capacity(1024)
    assert_equal(Int(region.length()), 0)
    var view = region.as_view()
    assert_equal(view.len(), 0)


def test_empty_region() raises:
    """(e) Empty region (constructed from an empty List) has length 0
    and produces an empty view. Validates the boundary case where the
    underlying List has no bytes — `as_view()` must NOT crash and must
    return a view with `len() == 0`."""
    var bytes = List[UInt8]()
    var region = HeapRegion(bytes^)
    assert_equal(Int(region.length()), 0)
    var view = region.as_view()
    assert_equal(view.len(), 0)


def test_move_semantics() raises:
    """(f) HeapRegion is Movable; transfer-construct (`r2 = r1^`) leaves
    r2 owning the bytes; r2.length() returns the original count."""
    var bytes = List[UInt8]()
    for i in range(16):
        bytes.append(UInt8(i * 2))
    var r1 = HeapRegion(bytes^)
    var r2 = r1^
    assert_equal(Int(r2.length()), 16)
    var view = r2.as_view()
    assert_equal(view.len(), 16)
    # Verify the bytes are correct after the move.
    for i in range(16):
        assert_equal(Int(view.read_u8_at(i)), i * 2)


# -----------------------------------------------------------------------------
# (g) Generic trait dispatch — a `[K: MemoryRegion]`-parametric function
# elaborates against HeapRegion and dispatches through the trait surface.
# This is the load-bearing test: it proves the trait conformance holds
# end-to-end via the trait dispatch path.
# -----------------------------------------------------------------------------


def _generic_length[K: MemoryRegion](ref region: K) -> Int64:
    """Generic helper: trait dispatch on `length()`. Mirrors the
    hot-path pattern in `MmapAlignedBuffer[ALIGN, K].length()` /
    `region_length()`."""
    return region.length()


def _generic_view_len[K: MemoryRegion](ref region: K) -> Int:
    """Generic helper: trait dispatch on `as_view()`. Mirrors the
    hot-path pattern in `MmapAlignedBuffer[ALIGN, K].as_span()`."""
    return region.as_view().len()


def test_generic_trait_dispatch() raises:
    """(g) HeapRegion satisfies `MemoryRegion` and is invokable via a
    `[K: MemoryRegion]`-parametric helper. Proves the trait conformance
    is structurally correct and the dispatch path elaborates."""
    var bytes = List[UInt8]()
    bytes.append(UInt8(100))
    bytes.append(UInt8(101))
    bytes.append(UInt8(102))
    var region = HeapRegion(bytes^)
    assert_equal(Int(_generic_length[HeapRegion](region)), 3)
    assert_equal(_generic_view_len[HeapRegion](region), 3)


# -----------------------------------------------------------------------------
# main — sequence the test bodies; print PASS marker on completion.
# -----------------------------------------------------------------------------


def main() raises:
    print("test_heap_region: start")

    test_construct_from_list_and_length()
    print("  [a] construct_from_list_and_length -- PASS")

    test_as_view_len_matches_input()
    print("  [b] as_view_len_matches_input -- PASS")

    test_as_view_contents_match()
    print("  [c] as_view_contents_match -- PASS")

    test_with_capacity_factory()
    print("  [d] with_capacity_factory -- PASS")

    test_empty_region()
    print("  [e] empty_region -- PASS")

    test_move_semantics()
    print("  [f] move_semantics -- PASS")

    test_generic_trait_dispatch()
    print("  [g] generic_trait_dispatch -- PASS")

    print("test_heap_region: ALL PASS")
