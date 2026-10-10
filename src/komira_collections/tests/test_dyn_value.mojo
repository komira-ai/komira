# =============================================================================
# Unit tests for DynValue[MAX_SIZE] type-erased inline storage
# =============================================================================
#
# Tests:
#   T1: create + get[T] reads back correct value
#   T2: move semantics (auto-synth __moveinit__)
#   T3: occupied DynValue drops cleanly (destroy fires, no crash)
#   T4: get[T] on a mutable DynValue writes through to stored value
#   T5: unoccupied DynValue drops cleanly (no destroy call)
#   T6: get[U] for a different U is refused (raises), holds[U] is False --
#       a same-size type, and a different instantiation of one generic struct
#       (mutant caught: the type check removed from holds)
#   T6b: two function types of equal size, whose reflect[T].name() is the
#       same string (`__MLIRType[<unprintable>]`): get of the other one is
#       refused (mutant caught: identity compared by reflect name, or by
#       reflect name + size, instead of the linkage-name tag)
#   T7: get[T] on an empty DynValue is refused with the "empty" message, and
#       is_occupied() is False; T1 asserts it True on an occupied value
#       (mutants caught: the empty branch removed, is_occupied() constant)
#   T8: the empty slot's destructor `_noop_destroy` leaves the bytes it is
#       given untouched. __deinit__ calls the destructor only when occupied,
#       so only a direct call reaches it (mutant caught: it writes a byte)
#
# Compile-time only, so no runtime test can observe them: get's return origin
# (`ref [self._storage]`), refusal of a mutable get on an immutable DynValue,
# and create's refusal of a T larger than MAX_SIZE, more aligned than the
# DynValue (e.g. SIMD[DType.float32, 8]), or with a non-trivial move
# constructor. The latter two were checked once by a planted program that
# failed to compile with each assert's message.
# =============================================================================

from std.memory import Pointer, alloc
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_collections.dyn_value import DynValue, _noop_destroy


# --- Test helpers ---

struct TwoInts(Movable):
    """Simple struct with two Int fields for typed-access testing."""
    var a: Int
    var b: Int

    def __init__(out self, a: Int, b: Int):
        self.a = a
        self.b = b


struct OtherTwoInts(Movable):
    """Same layout and size as TwoInts, different type."""
    var a: Int
    var b: Int

    def __init__(out self, a: Int, b: Int):
        self.a = a
        self.b = b


struct Boxed[W: Int](Movable):
    """One generic struct; Boxed[1] and Boxed[2] differ only by parameter."""
    var v: Int

    def __init__(out self, v: Int):
        self.v = v


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

def test_create_and_get() raises:
    """T1: create + get[T] reads back correct value."""
    var dv = DynValue[64].create[TwoInts](TwoInts(10, 20))
    assert_true(dv.is_occupied())
    ref val = dv.get[TwoInts]()
    if val.a != 10 or val.b != 20:
        raise Error(
            "T1 FAIL: expected (10, 20), got ("
            + String(val.a) + ", " + String(val.b) + ")"
        )
    print("    PASS test_create_and_get")


def test_move_semantics() raises:
    """T2: move semantics -- value survives auto-synth move."""
    var dv1 = DynValue[64].create[TwoInts](TwoInts(42, 99))
    var dv2 = dv1^  # auto-synth __moveinit__
    ref val = dv2.get[TwoInts]()
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


def test_get_write_through() raises:
    """T4: get[T] on a mutable DynValue writes through to the stored value."""
    var dv = DynValue[64].create[TwoInts](TwoInts(1, 2))
    dv.get[TwoInts]().a = 100
    ref slot = dv.get[TwoInts]()
    slot.b = 200
    ref val = dv.get[TwoInts]()
    if val.a != 100 or val.b != 200:
        raise Error(
            "T4 FAIL: expected (100, 200), got ("
            + String(val.a) + ", " + String(val.b) + ")"
        )
    print("    PASS test_get_write_through")


def test_unoccupied_drops_cleanly() raises:
    """T5: default-constructed (unoccupied) DynValue drops without crash."""
    var dv = DynValue[64]()
    # Should not crash -- _noop_destroy is the default.
    _ = dv^
    print("    PASS test_unoccupied_drops_cleanly")


def test_wrong_type_is_refused() raises:
    """T6: get[U] raises and holds[U] is False for every U other than T."""
    var dv = DynValue[64].create[TwoInts](TwoInts(1, 2))
    assert_true(dv.holds[TwoInts]())
    assert_false(dv.holds[Int]())
    assert_false(dv.holds[OtherTwoInts]())  # same size, different type
    with assert_raises(contains="asked for"):
        _ = dv.get[Int]()
    with assert_raises(contains="asked for"):
        _ = dv.get[OtherTwoInts]()
    # The value is untouched by the refused reads.
    assert_equal(dv.get[TwoInts]().b, 2)

    var boxed = DynValue[64].create[Boxed[1]](Boxed[1](5))
    assert_true(boxed.holds[Boxed[1]]())
    assert_false(boxed.holds[Boxed[2]]())  # same base name and size
    with assert_raises(contains="asked for"):
        _ = boxed.get[Boxed[2]]()
    assert_equal(boxed.get[Boxed[1]]().v, 5)
    print("    PASS test_wrong_type_is_refused")


def _twice(x: Int64) -> Int64:
    return x * 2


def _shout(s: String) -> String:
    return s + "!"


def test_function_types_with_one_reflect_name() raises:
    """T6b: two fn types that reflect[T].name() renders identically.

    Both are 8-byte thin function pointers and both reflect names read
    `std.builtin._stubs.__MLIRType[<unprintable>]`, so a name or name+size
    check would hand back `_twice` typed as `def(String) -> String`.
    """
    comptime IntFn = def(Int64) thin -> Int64
    comptime StrFn = def(String) thin -> String
    assert_equal(
        String(reflect[IntFn].name()),
        String(reflect[StrFn].name()),
        "precondition: the reflect names collide",
    )
    var dv = DynValue[16].create[IntFn](_twice)
    assert_true(dv.holds[IntFn]())
    assert_false(dv.holds[StrFn]())
    with assert_raises(contains="asked for"):
        _ = dv.get[StrFn]()
    var f = dv.get[IntFn]()
    assert_equal(f(Int64(21)), Int64(42))
    var g = DynValue[16].create[StrFn](_shout)
    assert_false(g.holds[IntFn]())
    assert_equal(g.get[StrFn]()("hi"), "hi!")
    print("    PASS test_function_types_with_one_reflect_name")


def test_empty_is_refused() raises:
    """T7: get[T] on an unoccupied DynValue raises; holds[T] is False."""
    var dv = DynValue[64]()
    assert_false(dv.is_occupied())
    assert_false(dv.holds[TwoInts]())
    with assert_raises(contains="empty"):
        _ = dv.get[TwoInts]()
    print("    PASS test_empty_is_refused")


def test_noop_destroy_touches_nothing() raises:
    """T8: _noop_destroy leaves every byte of its argument as it was."""
    # SAFETY: a 16-byte heap buffer this test owns and frees below. `alloc`
    # already returns the origin the destructor slot's signature names, so
    # the pointer reaches `_noop_destroy` with no origin cast.
    var buf = alloc[UInt8](16)
    for i in range(16):
        (buf + i).init_pointee_copy(UInt8(0xAB))
    _noop_destroy(buf)
    var bytes = List[UInt8](capacity=16)
    for i in range(16):
        bytes.append(buf[i])
    buf.free()
    for i in range(16):
        assert_equal(bytes[i], UInt8(0xAB))
    print("    PASS test_noop_destroy_touches_nothing")


def main() raises:
    print("Running DynValue tests...")
    test_create_and_get()
    test_move_semantics()
    test_destroy_fires_on_drop()
    test_get_write_through()
    test_unoccupied_drops_cleanly()
    test_wrong_type_is_refused()
    test_function_types_with_one_reflect_name()
    test_empty_is_refused()
    test_noop_destroy_touches_nothing()
    print("All DynValue tests passed (9/9)")
