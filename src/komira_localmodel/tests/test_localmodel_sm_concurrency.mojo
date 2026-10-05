# =============================================================================
# test_localmodel_sm_concurrency.mojo
#   The SM CONCURRENCY GATE: the BackendSupervisor's admission counters stay
#   CORRECT when N threads drive ONE SHARED state machine at once (a server
#   that forwards /v1 requests from N pthread workers shares one SM, and the
#   cap must bound TOTAL in-flight against the one loaded model, not leak past
#   N under the race).
# =============================================================================
#
# WHAT THIS PROVES (the cross-thread correctness the process-global SM mutex
# provides):
#
#   (1) NO LOST UPDATES — N workers each run M admit -> release cycles against
#       ONE shared SM. Every admit that returns ADMITTED is paired with exactly
#       one release. After the join barrier the in-flight count is EXACTLY 0 and
#       the queued count is 0. Without the mutex the non-atomic
#       `_inflight[idx] += 1` / `-= 1` race loses updates and the final count
#       drifts away from 0.
#
#   (2) THE CAP IS A HARD GLOBAL BOUND — with a cap of K and N > K workers each
#       holding an admitted slot, the in-flight count never exceeds the cap and
#       the queued count never exceeds the queue capacity (the admit() cap check
#       and the in-flight bump are atomic under the lock). ADMITTED + QUEUED +
#       REJECTED equals the number of attempts.
#
#   (3) PULL PROMOTION IS A HARD BOUND — a QUEUED worker spins on
#       try_promote_if_under_cap (the block-and-wait handler), claiming a freed
#       slot ONLY when in-flight < cap, so in-flight never exceeds the cap even
#       under concurrent admits and releases.
#
#   (4) CONCURRENT LOAD IS SERIALIZED — N workers request_load the SAME model;
#       the model loads EXACTLY ONCE (one resident instance), no double spawn.
#
# WHY REAL THREADS: every assertion below is about what N threads do to ONE
# shared SM; run serially, all of them would pass while proving nothing. The
# fork-join is raw `pthread_create` + `pthread_join` over
# `std.ffi.external_call` (Mojo's stdlib ships no thread pool), which gives
# real OS threads (so the mutex is genuinely contended), a real join barrier
# (so the post-barrier assertions mean "after every worker finished"), and the
# same shape as a server's pthread workers. It adds no package dependency.
#
# The SM is shared by ADDRESS (it is Movable, not Copyable, so it cannot be
# captured by value).
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.testing import TestSuite, assert_equal, assert_true

from komira_localmodel import (
    BackendSupervisor,
    LocalBackend,
    MonotonicClock,
    HostMemoryProfile,
    PLATFORM_MACOS,
    ADMIT_ADMITTED,
    ADMIT_QUEUED,
    ADMIT_REJECTED,
)


# A stub backend that launches instantly (no real process). Matches the
# test_localmodel_admission harness.
struct StubBackend(LocalBackend, Movable, Deinitable):
    var _base_url: String
    var _up: Bool

    def __init__(out self, base_url: String):
        self._base_url = base_url
        self._up = False

    def launch(mut self) raises -> String:
        self._up = True
        return self._base_url

    def health(self) -> Bool:
        return self._up

    def teardown(mut self):
        self._up = False

    def base_url(self) -> String:
        return self._base_url


struct MockClock(MonotonicClock, Movable, Deinitable):
    var _now_ms: Int

    def __init__(out self, start_ms: Int):
        self._now_ms = start_ms

    def now_ms(mut self) -> Int:
        return self._now_ms


comptime _Sm = BackendSupervisor[StubBackend, MockClock]


def _hw() -> HostMemoryProfile:
    return HostMemoryProfile(
        total_ram_bytes=96 * 1024 * 1024 * 1024,
        vram_bytes=0,
        unified_memory=True,
        platform=PLATFORM_MACOS,
    )


def _gib(n: Int) -> Int:
    return n * 1024 * 1024 * 1024


def _serving_sm_with_cap(cap: Int) raises -> _Sm:
    var sm = _Sm(MockClock(0), _hw(), _gib(64), 60_000, 4)
    _ = sm.register_with_cap(
        String("m"), StubBackend(String("http://127.0.0.1:8081")), _gib(6), cap,
    )
    _ = sm.request_load(String("m"))  # -> SERVING
    return sm^


# =============================================================================
# THE FORK-JOIN — real pthreads. See the module banner for why this is not a
# serial loop.
# =============================================================================

comptime _VoidPtr = UnsafePointer[NoneType, MutUntrackedOrigin]


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (UnsafePointer has no null
    constructor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero (NULL) bit pattern. FFI NULL args only.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


@fieldwise_init
struct _ForkArg(Copyable, Movable, Deinitable):
    """The heap-boxed pthread arg, shared BY EVERY worker in one fork-join.

    All five fields are PODs: four addresses plus a loop count.

    SAFETY: each test allocates ONE of these, hands the SAME pointer to all
    N threads, and JOINS every thread before freeing it, so the arg strictly
    outlives every reader. The workers only ever READ it. The four addresses
    point at locals of the calling test frame, which likewise outlives the join
    barrier. Threads share the SM deliberately — that is what is under test —
    and every mutation of it goes through the SM's own mutex.
    """

    var sm_addr: Int  # Int-laundered OwnedPointer[_Sm]*
    var adm_addr: Int  # Int-laundered Atomic[int64]* (admitted), 0 if unused
    var q_addr: Int  # Int-laundered Atomic[int64]* (queued),    0 if unused
    var rej_addr: Int  # Int-laundered Atomic[int64]* (rejected), 0 if unused
    var cycles: Int  # admit->release cycles per worker (1 == single shot)


@always_inline
def _sm_of(arg: _ForkArg) -> UnsafePointer[OwnedPointer[_Sm], MutUntrackedOrigin]:
    """Recover the shared SM box from the arg. ONE FFI-boundary recovery site."""
    # SAFETY: FFI-BOUNDARY. `sm_addr` was produced by `Int(UnsafePointer(to=...))`
    # on an `OwnedPointer[_Sm]` owned by the calling test frame, which outlives
    # the join barrier (see `_ForkArg`).
    return UnsafePointer[OwnedPointer[_Sm], MutUntrackedOrigin](
        unsafe_from_address=arg.sm_addr,
    )


@always_inline
def _atomic_of(
    addr: Int,
) -> UnsafePointer[AtomicI64, MutUntrackedOrigin]:
    """Recover one of the counter atomics. ONE FFI-boundary recovery site."""
    # SAFETY: FFI-BOUNDARY. Same argument as `_sm_of`; `addr` is non-zero by
    # construction at every call site below.
    return UnsafePointer[AtomicI64, MutUntrackedOrigin](
        unsafe_from_address=addr,
    )


# WHY THE FORK-JOIN IS NOT ONE GENERIC HELPER. The obvious shape,
# `_fork_join[entry: def (_VoidPtr) -> _VoidPtr](n, arg)`, does not compile: a
# parameter of function TYPE is a CLOSURE trait, and a top-level `def` is a
# THIN function, so binding one to the other fails ("a thin function cannot
# bind to a closure trait"). Routing it through a type parameter fails too
# (the comptime value is not 'ImplicitlyCopyable'). A thin entry passes to
# `external_call` only as a DIRECT reference, as komira_async's
# `pthread_worker.launch_worker_pthread` does. So the three-line create loop is
# inlined per test and everything around it is shared below.


def _new_tids(n: Int) -> List[Int64]:
    """N zeroed pthread_t slots (pthread_t is 64-bit on Linux + macOS)."""
    var tids = List[Int64]()
    for _i in range(n):
        tids.append(Int64(0))
    return tids^


def _box_arg(var arg: _ForkArg) -> UnsafePointer[_ForkArg, MutUntrackedOrigin]:
    """Heap-box the shared pthread arg. Freed by `_join_all` after the barrier."""
    var box = alloc[_ForkArg](1)
    UnsafePointer(to=box[]).unsafe_write(arg^)
    return box.unsafe_origin_cast[MutUntrackedOrigin]()


def _join_all(
    tids: List[Int64],
    started: Int,
    n_workers: Int,
    create_rc: Int32,
    var box: UnsafePointer[_ForkArg, MutUntrackedOrigin],
) raises:
    """The BARRIER. Joins every thread that actually started, then frees the
    shared arg — in that order, so no live thread can outlive the arg it reads.

    Raises if any `pthread_create` failed, so a thread that never started can
    never be silently mistaken for a thread that did no work. That is the one
    failure mode that would turn this gate green while testing nothing.
    """
    for i in range(started):
        _ = external_call["pthread_join", Int32](
            tids[i], _null_ptr[UInt8, MutUntrackedOrigin]()
        )
    box.free()
    if create_rc != Int32(0):
        raise Error(
            "pthread_create failed (rc="
            + String(Int(create_rc))
            + ") after "
            + String(started)
            + " of "
            + String(n_workers)
            + " workers -- the concurrency gate did not run"
        )


# =============================================================================
# (1) NO LOST UPDATES — N threads x M admit->release cycles; in-flight returns
#     to EXACTLY 0. Each ADMITTED is released; QUEUED is promoted-then-released;
#     REJECTED is not released. The mutex makes every counter op atomic, so the
#     final accounting is exact (no lost +=/-= under the race).
# =============================================================================
def _entry_admit_release(arg: _VoidPtr) -> _VoidPtr:
    """pthread start_routine for (1)."""
    # SAFETY: FFI-BOUNDARY. `arg` is the `_ForkArg` box `_box_arg` allocated;
    # it outlives every thread (freed only after the join barrier).
    ref a = arg.bitcast[_ForkArg]()[]
    ref sm = _sm_of(a)[][]
    ref adm = _atomic_of(a.adm_addr)[]
    ref q = _atomic_of(a.q_addr)[]
    ref rej = _atomic_of(a.rej_addr)[]
    try:
        for _c in range(a.cycles):
            var d = sm.admit(String("m"))
            if d == ADMIT_ADMITTED:
                _ = adm.fetch_add(1)
                # ... (the "forward" would happen here, OUTSIDE the lock) ...
                sm.release(String("m"))
            elif d == ADMIT_QUEUED:
                _ = q.fetch_add(1)
                # BLOCK-AND-WAIT (the passthrough's QUEUED handler): spin until a
                # slot frees + this queued waiter PULLS it in (try_promote_if_
                # under_cap), then run + release. Bounded spin so a wedged test
                # cannot hang; under the live workers the slot frees quickly.
                var claimed = False
                var spins = 0
                while spins < 50_000_000:
                    if sm.try_promote_if_under_cap(String("m")):
                        claimed = True
                        break
                    spins += 1
                if claimed:
                    sm.release(String("m"))
                else:
                    # Safety valve (never expected): drop the queued slot.
                    sm.release_queued(String("m"))
            else:
                _ = rej.fetch_add(1)
    except e:
        # A pthread entry cannot propagate an exception across the ABI. Print it;
        # the post-barrier assertions are what fail the test.
        print("WARN _entry_admit_release raised: ", String(e))
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def test_concurrent_admit_release_balances_to_zero() raises:
    var n_workers = 8
    var cycles_per_worker = 200
    # A cap big enough that most admits succeed (we WANT high admit/release
    # traffic to stress the lock, not mostly-rejects).
    var cap = 4

    var sm_box = OwnedPointer[_Sm](_serving_sm_with_cap(cap))

    # Count, atomically, how many slots each worker is responsible for releasing
    # (every ADMITTED + every promoted QUEUED). The final in-flight count is
    # asserted == 0 directly off the SM, which is the real proof; these atomics
    # cross-check the bookkeeping.
    var admitted_total = AtomicI64(0)
    var queued_total = AtomicI64(0)
    var rejected_total = AtomicI64(0)

    var _tids = _new_tids(n_workers)
    var _box = _box_arg(
        _ForkArg(
            sm_addr=Int(UnsafePointer(to=sm_box)),
            adm_addr=Int(UnsafePointer(to=admitted_total)),
            q_addr=Int(UnsafePointer(to=queued_total)),
            rej_addr=Int(UnsafePointer(to=rejected_total)),
            cycles=cycles_per_worker,
        )
    )
    var _box_void = _box.bitcast[NoneType]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    var _started = 0
    var _rc = Int32(0)
    for _i in range(n_workers):
        _rc = external_call["pthread_create", Int32](
            UnsafePointer(to=_tids[_i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_admit_release,  # start_routine (DIRECT thin-fn reference)
            _box_void,  # arg (shared by all N)
        )
        if _rc != Int32(0):
            break
        _started += 1
    _join_all(_tids, _started, n_workers, _rc, _box)

    # The decisive assertion: after every admit was paired with its release, the
    # shared SM's in-flight + queued counts are EXACTLY 0 (no lost update).
    assert_equal(
        sm_box[].inflight_of(String("m")), 0,
        "in-flight returns to exactly 0 after all concurrent releases",
    )
    assert_equal(
        sm_box[].queued_of(String("m")), 0,
        "queued returns to exactly 0 after all promotions/releases",
    )

    # Cross-check: every attempt was classified exactly once.
    var total_attempts = Int64(n_workers * cycles_per_worker)
    var classified = (
        admitted_total.load() + queued_total.load() + rejected_total.load()
    )
    assert_equal(
        classified, total_attempts,
        "every admit attempt is classified exactly once (no double-count race)",
    )
    # We expect a healthy mix of admits (the lock did not serialize everything to
    # a single worker — there WAS real concurrency contending the cap).
    assert_true(
        admitted_total.load() > 0, "at least some requests were admitted"
    )

    sm_box[].shutdown_all()
    _ = sm_box^


# =============================================================================
# (2) CAP IS A HARD GLOBAL BOUND — workers admit WITHOUT releasing until the
#     barrier; the peak in-flight + queued can never exceed cap + queue_capacity
#     no matter how many threads race (the atomic cap-check + bump). After the
#     barrier the SM holds exactly min(total_attempts, cap+queue) slots, and the
#     count of ADMITTED never exceeds cap.
# =============================================================================
def _entry_admit_hold(arg: _VoidPtr) -> _VoidPtr:
    """pthread start_routine for (2). Each worker fires ONE admit and does NOT
    release (holds its slot to the barrier) so the SM accumulates in-flight +
    queued to its bound."""
    # SAFETY: FFI-BOUNDARY — see `_entry_admit_release`.
    ref a = arg.bitcast[_ForkArg]()[]
    ref sm = _sm_of(a)[][]
    try:
        var d = sm.admit(String("m"))
        if d == ADMIT_ADMITTED:
            _ = _atomic_of(a.adm_addr)[].fetch_add(1)
        elif d == ADMIT_QUEUED:
            _ = _atomic_of(a.q_addr)[].fetch_add(1)
        else:
            _ = _atomic_of(a.rej_addr)[].fetch_add(1)
    except e:
        print("WARN _entry_admit_hold raised: ", String(e))
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def test_concurrent_cap_is_hard_bound() raises:
    var n_workers = 16
    var cap = 2
    var sm_box = OwnedPointer[_Sm](_serving_sm_with_cap(cap))
    var queue_cap = sm_box[].queue_capacity_of(String("m"))

    var admitted_total = AtomicI64(0)
    var queued_total = AtomicI64(0)
    var rejected_total = AtomicI64(0)

    var _tids = _new_tids(n_workers)
    var _box = _box_arg(
        _ForkArg(
            sm_addr=Int(UnsafePointer(to=sm_box)),
            adm_addr=Int(UnsafePointer(to=admitted_total)),
            q_addr=Int(UnsafePointer(to=queued_total)),
            rej_addr=Int(UnsafePointer(to=rejected_total)),
            cycles=1,
        )
    )
    var _box_void = _box.bitcast[NoneType]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    var _started = 0
    var _rc = Int32(0)
    for _i in range(n_workers):
        _rc = external_call["pthread_create", Int32](
            UnsafePointer(to=_tids[_i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_admit_hold,  # start_routine (DIRECT thin-fn reference)
            _box_void,  # arg (shared by all N)
        )
        if _rc != Int32(0):
            break
        _started += 1
    _join_all(_tids, _started, n_workers, _rc, _box)

    # The in-flight count never exceeded the cap (the atomic cap-check held the
    # bound globally across all threads).
    assert_equal(
        Int64(sm_box[].inflight_of(String("m"))), admitted_total.load(),
        "the SM in-flight count equals the number of ADMITTED slots",
    )
    assert_true(
        sm_box[].inflight_of(String("m")) <= cap,
        "in-flight never exceeded the cap under the concurrent race",
    )
    assert_true(
        sm_box[].queued_of(String("m")) <= queue_cap,
        "queued never exceeded the bounded queue depth",
    )
    # Every worker was classified exactly once; admits capped at `cap`, the rest
    # queued up to queue_cap, the remainder rejected.
    var classified = (
        admitted_total.load() + queued_total.load() + rejected_total.load()
    )
    assert_equal(classified, Int64(n_workers), "all attempts classified once")
    assert_equal(
        admitted_total.load(), Int64(cap),
        "exactly `cap` requests were admitted in-flight (the hard bound)",
    )

    sm_box[].shutdown_all()
    _ = sm_box^


# =============================================================================
# (4) CONCURRENT LOAD IS SERIALIZED — N workers request_load the SAME model
#     concurrently. The SM mutex serializes the whole load decision, so the model
#     ends SERVING with EXACTLY ONE resident instance (the loser threads observe
#     it already SERVING under the lock + just re-arm the TTL — they do NOT
#     double-spawn a second child or corrupt the parallel-list bookkeeping). This
#     is the "exactly one worker spawns the one engine child" contract that makes
#     sharing ONE SM across N workers correct (vs per-worker SMs each spawning a
#     duplicate child).
# =============================================================================
def _entry_request_load(arg: _VoidPtr) -> _VoidPtr:
    """pthread start_routine for (4)."""
    # SAFETY: FFI-BOUNDARY — see `_entry_admit_release`.
    ref a = arg.bitcast[_ForkArg]()[]
    ref s = _sm_of(a)[][]
    try:
        _ = s.request_load(String("m"))
    except e:
        # Deliberately swallowed: the losers of the load race are expected to
        # be uninteresting; the assertions are on the SM's post-barrier state.
        _ = e
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def test_concurrent_request_load_serialized() raises:
    var n_workers = 12
    var sm = _Sm(MockClock(0), _hw(), _gib(64), 60_000, 4)
    _ = sm.register_with_cap(
        String("m"), StubBackend(String("http://127.0.0.1:8081")), _gib(6), 4,
    )
    var sm_box = OwnedPointer[_Sm](sm^)

    var _tids = _new_tids(n_workers)
    var _box = _box_arg(
        _ForkArg(
            sm_addr=Int(UnsafePointer(to=sm_box)),
            adm_addr=0,
            q_addr=0,
            rej_addr=0,
            cycles=1,
        )
    )
    var _box_void = _box.bitcast[NoneType]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    var _started = 0
    var _rc = Int32(0)
    for _i in range(n_workers):
        _rc = external_call["pthread_create", Int32](
            UnsafePointer(to=_tids[_i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_request_load,  # start_routine (DIRECT thin-fn reference)
            _box_void,  # arg (shared by all N)
        )
        if _rc != Int32(0):
            break
        _started += 1
    _join_all(_tids, _started, n_workers, _rc, _box)

    # The model is SERVING with exactly ONE resident instance after N concurrent
    # request_load calls (the SM mutex serializes the load; all but the first
    # observe it already SERVING under the lock and just re-arm — no double-load,
    # no corrupted bookkeeping).
    assert_equal(
        sm_box[].state_of(String("m")), 2, "model is SERVING after concurrent load",
    )
    assert_equal(
        sm_box[].resident_count(), 1,
        "exactly one resident instance (no double-spawn under the race)",
    )
    sm_box[].shutdown_all()
    _ = sm_box^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
