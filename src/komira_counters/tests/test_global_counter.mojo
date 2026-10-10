# =============================================================================
# komira_counters/tests/test_global_counter.mojo -- the shared counter primitive
# =============================================================================
#
# What is pinned, one test each:
#   * the same NAME spelled at two separate sites is ONE counter;
#   * a different name is a different counter (no bleed between names);
#   * `reset` returns a counter to 0, and only that counter;
#   * a table's slots are independent, `reset` clears all of them, and a slot
#     out of range REFUSES rather than writing past the table;
#   * a negative slot computed at run time is refused by `read`,
#     `reset_slot` and `add`;
#   * `add` takes a negative delta;
#   * N workers each adding M sum to exactly N * M (no lost update).
#
# Every test uses a name of its own: the cells are process-global, so two tests
# sharing a name would read each other's counts.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.testing import TestSuite, assert_equal, assert_raises

from komira_counters.global_counter import GlobalCounter, GlobalCounterTable


# Two sites that spell the same name from two different functions. The type
# is spelled twice on purpose: the sharing must come from the NAME, not from
# one alias being reused.
def _bump_from_site_a(n: Int) raises:
    comptime C = GlobalCounter["komira_counters_test_shared_name"]
    C.add(n)


def _read_from_site_b() raises -> Int:
    comptime C = GlobalCounter["komira_counters_test_shared_name"]
    return C.read()


def test_same_name_at_two_sites_is_one_counter() raises:
    comptime C = GlobalCounter["komira_counters_test_shared_name"]
    C.reset()
    assert_equal(_read_from_site_b(), 0)
    _bump_from_site_a(5)
    _bump_from_site_a(2)
    assert_equal(_read_from_site_b(), 7)
    assert_equal(C.read(), 7)


def test_different_names_do_not_bleed() raises:
    comptime A = GlobalCounter["komira_counters_test_name_a"]
    comptime B = GlobalCounter["komira_counters_test_name_b"]
    A.reset()
    B.reset()
    A.add(3)
    assert_equal(A.read(), 3)
    assert_equal(B.read(), 0)
    B.incr()
    assert_equal(A.read(), 3)
    assert_equal(B.read(), 1)


def test_reset_clears_only_its_own_counter() raises:
    comptime A = GlobalCounter["komira_counters_test_reset_a"]
    comptime B = GlobalCounter["komira_counters_test_reset_b"]
    A.reset()
    B.reset()
    A.add(10)
    B.add(20)
    A.reset()
    assert_equal(A.read(), 0)
    assert_equal(B.read(), 20)
    # A reset counter counts again from zero.
    A.incr()
    assert_equal(A.read(), 1)


def test_negative_delta_and_try_forms() raises:
    comptime C = GlobalCounter["komira_counters_test_delta"]
    C.reset()
    C.add(10)
    C.add(-4)
    assert_equal(C.read(), 6)
    C.try_add(4)
    C.try_incr()
    assert_equal(C.read(), 11)


def test_table_slots_are_independent() raises:
    comptime T = GlobalCounterTable["komira_counters_test_table_slots", 4]
    T.reset()
    T.add(0, 1)
    T.add(2, 40)
    T.incr(2)
    T.try_add(3, 7)
    assert_equal(T.read(0), 1)
    assert_equal(T.read(1), 0)
    assert_equal(T.read(2), 41)
    assert_equal(T.read(3), 7)
    T.reset_slot(2)
    assert_equal(T.read(2), 0)
    assert_equal(T.read(3), 7)
    T.reset()
    for i in range(4):
        assert_equal(T.read(i), 0)


def test_table_refuses_a_slot_out_of_range() raises:
    comptime T = GlobalCounterTable["komira_counters_test_table_bounds", 2]
    T.reset()
    with assert_raises():
        T.add(2, 1)
    with assert_raises():
        T.add(-1, 1)
    with assert_raises():
        _ = T.read(2)
    with assert_raises():
        T.reset_slot(5)
    # The refused writes touched nothing, and a refused `try_add` is dropped.
    T.try_add(9, 1)
    assert_equal(T.read(0), 0)
    assert_equal(T.read(1), 0)


def test_table_refuses_a_negative_slot_known_only_at_run_time() raises:
    # The slot is computed at run time so the bound check cannot be folded
    # away: `read`, `reset_slot` and `add` must refuse a slot below 0, not
    # address the word before the table.
    comptime T = GlobalCounterTable["komira_counters_test_table_negative", 2]
    T.reset()
    var widths = List[Int]()
    widths.append(1)
    var neg = -len(widths)
    with assert_raises(contains="slot out of range"):
        _ = T.read(neg)
    with assert_raises(contains="slot out of range"):
        T.reset_slot(neg)
    with assert_raises(contains="slot out of range"):
        T.add(neg, 1)
    assert_equal(T.read(0), 0)
    assert_equal(T.read(1), 0)


comptime _WORKERS = 8
comptime _PER_WORKER = 50000
comptime _VoidPtr = UnsafePointer[NoneType, MutUntrackedOrigin]


def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin, for pthread's NULL args.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer and `None` is the all-zero (NULL) bit pattern. FFI NULL args only.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


def _entry_hammer(arg: _VoidPtr) -> _VoidPtr:
    """pthread start_routine: add to a counter and to a table, many times.

    Each iteration adds one to the plain counter and two to the table slot
    chosen by the iteration's parity, so both the cell and the slot arithmetic
    are under contention. `arg` is unused.

    # SAFETY: FFI-BOUNDARY entry point; touches only process-global counters
    # through the sealed `GlobalCounter` API and dereferences nothing.
    """
    comptime C = GlobalCounter["komira_counters_test_concurrent"]
    comptime T = GlobalCounterTable["komira_counters_test_concurrent_table", 2]
    for i in range(_PER_WORKER):
        C.try_incr()
        T.try_add(i % 2, 2)
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def test_concurrent_increments_sum_exactly() raises:
    """N real OS threads each add M times; the total is exactly N * M.

    A lost update (a plain load-then-store, or a non-atomic add) shows up as a
    total below N * M with high probability at this size; see the mutation run
    recorded in the commit that added this test.
    """
    comptime C = GlobalCounter["komira_counters_test_concurrent"]
    comptime T = GlobalCounterTable["komira_counters_test_concurrent_table", 2]
    C.reset()
    T.reset()

    var tids = List[Int64]()
    for _i in range(_WORKERS):
        tids.append(Int64(0))
    var started = 0
    var rc = Int32(0)
    for i in range(_WORKERS):
        rc = external_call["pthread_create", Int32](
            UnsafePointer(to=tids[i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_hammer,  # start_routine
            _null_ptr[NoneType, MutUntrackedOrigin](),  # arg = NULL
        )
        if rc != Int32(0):
            break
        started += 1
    # The barrier: join every thread that started before reading anything.
    for i in range(started):
        _ = external_call["pthread_join", Int32](
            tids[i], _null_ptr[UInt8, MutUntrackedOrigin]()
        )
    # A thread that never started must not read as a thread that did no work.
    if rc != Int32(0):
        raise Error("pthread_create failed: the concurrency test did not run")

    assert_equal(C.read(), _WORKERS * _PER_WORKER)
    # Half the iterations land in each slot, two per add.
    assert_equal(T.read(0), _WORKERS * (_PER_WORKER // 2) * 2)
    assert_equal(T.read(1), _WORKERS * (_PER_WORKER // 2) * 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
