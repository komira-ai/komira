# =============================================================================
# Unit tests for DynValue[MAX_SIZE] type-erased inline storage
# =============================================================================
#
# Tests:
#   T1: create + as_ref reads back correct value
#   T2: move semantics (auto-synth __moveinit__)
#   T3: occupied DynValue drops cleanly (destroy fires, no crash)
#   T4: as_mut writes through to stored value
#   T5: unoccupied DynValue drops cleanly (no destroy call)
# =============================================================================

from std.memory import Pointer

from komira_core.collections.dyn_value import DynValue


# --- Test helpers ---

struct TwoInts(Movable):
    """Simple struct with two Int fields for typed-access testing."""
    var a: Int
    var b: Int

    def __init__(out self, a: Int, b: Int):
        self.a = a
        self.b = b


# ★ THE ORIGIN IS A STRUCT PARAMETER, NOT A WILDCARD.
# A wildcard-origin pointer field (`UnsafePointer[Int, MutExternalOrigin]`)
# is banned on any struct built and destroyed repeatedly in one process run,
# which is exactly a drop-observer fixture: tcmalloc byte reuse across
# destroy-recreate cycles reinterprets stale bytes under the new struct. The
# counter is an `Int` the test frame owns, and `counter_origin` binds the
# borrow to that frame.
#
# ⚠ WHY A POINTER-OVER-ONE-COUNTER WORKS HERE AND NOT FOR A SLAB FIXTURE.
# A `DynValue` holds exactly ONE `DropObserver`, so exactly one borrow of the
# counter exists at a time and the exclusivity checker is satisfied -- which is
# why the SAFE `Pointer` is usable here and no raw pointer survives in this file.
#
# A slab fixture puts N values over ONE counter, and none of the obvious
# spellings works there:
#   * `Pointer[Int, co]`       -> exclusivity error; `Slab[TrackedValue[co]]` and
#                                 the appended value both embed a `co` mutable
#                                 borrow, so `append` aliases one cell twice.
#   * `UnsafePointer[Int, co]` -> the SAME error. The checker keys on the ORIGIN,
#                                 not on the pointer type.
#   * construct-then-`append(v^)` (two-step, to split the arguments) -> same.
#   * `ArcPointer[Int]`        -> compiles and passes, and is WRONG: a
#                                 heap-owning inner field on a `Movable` element
#                                 of a byte-backed `Slab` is the stale-bytes trap
#                                 itself, a defect that passes its tests until
#                                 ASAP-drop timing changes.
# Do not "unify" the two fixtures: they differ because their aliasing differs.
#
# Do NOT reach for `MutUntrackedOrigin` to silence the deprecation warning on
# the old spelling: same untracked origin, new name.
#
# ⚠ The struct never owns a heap allocation; its only field is a borrowed
# counter. The name says what the type does.

struct DropObserver[counter_origin: Origin[mut=True]](Movable):
    """Writes a sentinel to a borrowed counter on drop, so a test can observe
    that `DynValue` really invoked `_destroy` rather than abandoning the value.
    """
    # SAFETY:
    #   (a) WHY parametric rather than wildcard: the concrete counter is not
    #       known at struct-definition site, so the origin is a struct
    #       PARAMETER bound at construction to the test frame that owns the
    #       `Int`. Concrete, not wildcard -- the wildcard ban does not apply.
    #   (b) NON-NULL for the struct's whole life: set in `__init__` from a
    #       `ref` parameter (never null-constructible), never reassigned.
    #   (c) BORROWED, never owning: nothing here allocates or frees. The owner
    #       is the `Int` local in the test body, which outlives this value.
    #   (d) TEARDOWN retires nothing, because no heap is held through the
    #       field: `__del__` writes through a borrow the origin keeps live.
    var _counter: Pointer[Int, Self.counter_origin]

    def __init__(out self, ref [Self.counter_origin] counter: Int):
        self._counter = Pointer(to=counter)

    def __deinit__(deinit self):
        # Write sentinel on drop so caller can observe destruction.
        self._counter[] = 42


# --- Tests ---

def test_create_and_as_ref() raises:
    """T1: create + as_ref reads back correct value."""
    var dv = DynValue[64].create[TwoInts](TwoInts(10, 20))
    ref val = dv._as_ptr[TwoInts]()[]
    if val.a != 10 or val.b != 20:
        raise Error(
            "T1 FAIL: expected (10, 20), got ("
            + String(val.a) + ", " + String(val.b) + ")"
        )
    print("    PASS test_create_and_as_ref")


def test_move_semantics() raises:
    """T2: move semantics -- value survives auto-synth move."""
    var dv1 = DynValue[64].create[TwoInts](TwoInts(42, 99))
    var dv2 = dv1^  # auto-synth __moveinit__
    ref val = dv2._as_ptr[TwoInts]()[]
    if val.a != 42 or val.b != 99:
        raise Error(
            "T2 FAIL: expected (42, 99), got ("
            + String(val.a) + ", " + String(val.b) + ")"
        )
    print("    PASS test_move_semantics")


def _drop_observer_in_dyn_value[co: Origin[mut=True]](ref [co] counter: Int) raises:
    """Helper: hold a DropObserver in a DynValue, then force the drop.

    The borrow's origin is `co`, the caller's frame -- so the compiler keeps
    `counter` alive across this call instead of being handed an untracked
    pointer and told not to reason about it.
    """
    var dv = DynValue[64].create[DropObserver[co]](DropObserver[co](counter))
    # Force drop by moving into discard.
    _ = dv^


def test_destroy_fires_on_drop() raises:
    """T3: destroy callback fires on drop -- DropObserver writes sentinel."""
    var counter = 0
    _drop_observer_in_dyn_value(counter)

    # DropObserver.__del__ should have written 42 to the counter.
    if counter != 42:
        raise Error(
            "T3 FAIL: expected counter=42 after drop, got " + String(counter)
        )
    print("    PASS test_destroy_fires_on_drop")


def test_as_mut_write_through() raises:
    """T4: as_mut provides writable access to the stored value."""
    var dv = DynValue[64].create[TwoInts](TwoInts(1, 2))
    var ptr = dv._as_ptr[TwoInts]()
    ptr[].a = 100
    ptr[].b = 200
    ref val = dv._as_ptr[TwoInts]()[]
    if val.a != 100 or val.b != 200:
        raise Error(
            "T4 FAIL: expected (100, 200), got ("
            + String(val.a) + ", " + String(val.b) + ")"
        )
    print("    PASS test_as_mut_write_through")


def test_unoccupied_drops_cleanly() raises:
    """T5: default-constructed (unoccupied) DynValue drops without crash."""
    var dv = DynValue[64]()
    # Should not crash -- _noop_destroy is the default.
    _ = dv^
    print("    PASS test_unoccupied_drops_cleanly")


def main() raises:
    print("Running DynValue tests...")
    test_create_and_as_ref()
    test_move_semantics()
    test_destroy_fires_on_drop()
    test_as_mut_write_through()
    test_unoccupied_drops_cleanly()
    print("All DynValue tests passed (5/5)")
