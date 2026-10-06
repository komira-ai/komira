# =============================================================================
# MockMorselSource tests -- Rev 4 trait pattern (§7.5 Phase 0 deliverable)
# =============================================================================
#
# Verifies MorselSourceImpl trait + @parameter generics produce distinct
# monomorphizations per concrete source type. Two mock structs implement
# the trait; a generic driver `drive_source[S: MorselSourceImpl]` is
# instantiated twice, proving compile-time monomorphization.
#
# Phase 1d.4.1: trait `next_morsel` now takes `self` (immutable borrow).
# Mutable counters live in a heap `_Counters` slab behind an
# UnsafePointer -- the same pattern ParquetMorselSource uses. The mock
# source remains Movable (UnsafePointer fields move trivially); the
# slab is freed in __del__.
# =============================================================================

from std.memory import alloc, UnsafePointer
from komira_atomic_alias import AtomicI64

from komira_core.arrow.schema import Schema
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_source import MorselSourceImpl, SourceCapabilities


# -----------------------------------------------------------------------------
# Shared mutable-state slabs (Atomic is non-Movable, so it lives on the heap
# reached through an UnsafePointer).
# -----------------------------------------------------------------------------


struct _MockCounters:
    """Heap slab holding the Atomic emitted-counter for MockMorselSource."""

    var emitted: AtomicI64


struct _ConstCounters:
    """Heap slab holding the Atomic call-counter for ConstantMorselSource."""

    var calls: AtomicI64


# -----------------------------------------------------------------------------
# Two concrete mock sources -- both implement MorselSourceImpl. The generic
# driver below is monomorphized once per (S) pairing.
# -----------------------------------------------------------------------------


struct MockMorselSource(MorselSourceImpl):
    """Emits `num_morsels` empty morsels, then signals EOF with `None`.

    The observable counter lives on a heap slab so `next_morsel(self, ...)`
    (immutable borrow) can advance it via Atomic fetch_add.
    """

    var num_morsels: Int
    var _counters: UnsafePointer[_MockCounters, MutUntrackedOrigin]

    def __init__(out self, num_morsels: Int):
        self.num_morsels = num_morsels
        # SAFETY: alloc returns uninitialized storage. Atomic is non-Movable,
        # so we construct the field in place through the pointer.
        self._counters = alloc[_MockCounters](1)
        self._counters[].emitted = AtomicI64(0)

    def __deinit__(deinit self):
        if Int(self._counters) != 0:
            self._counters.free()

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        # Claim next morsel id via atomic fetch_add. Immutable-borrow safe.
        var e = Int(self._counters[].emitted.fetch_add(Int64(1)))
        if e >= self.num_morsels:
            return None
        return Morsel.empty(morsel_id=e, partition_id=worker_id)

    def output_schema(self) -> Schema:
        return Schema()

    def partition_hint(self) -> Int:
        return 1

    def row_count_hint(self) -> Int:
        return self.num_morsels

    def capabilities(self) -> SourceCapabilities:
        return SourceCapabilities()


struct ConstantMorselSource(MorselSourceImpl):
    """Always emits an empty Morsel; partition_hint reports `parts`.

    Exists solely as a second MorselSourceImpl so we can verify that
    `drive_source[S]` produces a distinct monomorphization per S.
    """

    var parts: Int
    var _counters: UnsafePointer[_ConstCounters, MutUntrackedOrigin]

    def __init__(out self, parts: Int):
        self.parts = parts
        self._counters = alloc[_ConstCounters](1)
        self._counters[].calls = AtomicI64(0)

    def __deinit__(deinit self):
        if Int(self._counters) != 0:
            self._counters.free()

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        var c = Int(self._counters[].calls.fetch_add(Int64(1))) + 1
        return Morsel.empty(morsel_id=c, partition_id=worker_id)

    def output_schema(self) -> Schema:
        return Schema()

    def partition_hint(self) -> Int:
        return self.parts

    def row_count_hint(self) -> Int:
        return 0

    def capabilities(self) -> SourceCapabilities:
        return SourceCapabilities()


# -----------------------------------------------------------------------------
# Generic driver: parameterized on any MorselSourceImpl. Mojo will monomorphize
# this once per concrete S used at a call site. Two distinct S -> two distinct
# compiled instances -- that's the v0.4 dispatch model in one function.
# -----------------------------------------------------------------------------


def drive_source[S: MorselSourceImpl](var source: S, n_pulls: Int) raises -> Int:
    """Pulls `n_pulls` morsels through a source and returns partition_hint().

    Returning a cheap S-derived value keeps the monomorphized code visible
    to the linker (defeats dead-code elimination in release builds).
    """
    var src = source^
    for _ in range(n_pulls):
        var m = src.next_morsel(0)
        _ = m^  # discard Optional[Morsel] (None on EOF, Some(morsel) otherwise)
    return src.partition_hint()


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_mock_pulls() raises:
    var src = MockMorselSource(3)
    # drive_source[MockMorselSource] -- monomorphization #1
    var ph = drive_source(src^, 4)
    if ph != 1:
        raise "expected partition_hint() == 1, got " + String(ph)
    print("test_mock_pulls OK")


def test_constant_source_distinct_monomorphization() raises:
    var src = ConstantMorselSource(7)
    # drive_source[ConstantMorselSource] -- monomorphization #2.
    # Compiling this instantiation alongside #1 proves the trait dispatches
    # are resolved at compile time, not through a runtime table.
    var ph = drive_source(src^, 3)
    if ph != 7:
        raise "expected partition_hint() == 7, got " + String(ph)
    print("test_constant_source_distinct_monomorphization OK")


def test_mock_capabilities_default() raises:
    var src = MockMorselSource(2)
    var caps = src.capabilities()
    if caps.supports_projection:
        raise "mock should not advertise supports_projection"
    if caps.supports_as_source:
        raise "mock should not advertise supports_as_source"
    print("test_mock_capabilities_default OK")


def main() raises:
    test_mock_pulls()
    test_constant_source_distinct_monomorphization()
    test_mock_capabilities_default()
    print("All MockMorselSource (Rev 4 trait) tests PASS")
