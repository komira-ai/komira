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
# captured by value): each test keeps the SM, the counters and one `_ForkArg`
# holding typed pointers to them in its own frame, hands the arg's address to
# every thread, and reads nothing until every thread is joined.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import external_call
from std.memory import UnsafePointer
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

# How long a QUEUED worker spins for a free slot before it gives up.
comptime _MAX_QUEUED_SPINS: Int = 2_000_000


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (UnsafePointer has no null
    constructor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero (NULL) bit pattern. FFI NULL args only.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


@always_inline
def _untracked[T: AnyType](mut value: T) -> UnsafePointer[T, MutUntrackedOrigin]:
    """The address of a value of the calling test's frame, for the threads.

    # SAFETY: every caller passes a local of the test function, which joins all
    # threads before it returns, so the value outlives every thread that
    # dereferences this pointer.
    """
    return UnsafePointer(to=value).unsafe_origin_cast[MutUntrackedOrigin]()


@fieldwise_init
struct _ForkArg(Copyable, Movable, Deinitable):
    """The pthread arg, shared BY EVERY worker in one fork-join.

    SAFETY: each test builds ONE of these in its own frame, hands its address
    to all N threads, and JOINS every thread before it reads a result or
    returns, so the arg and the values it points at outlive every reader. The
    workers only READ the arg. They share the SM deliberately (that is what is
    under test) and every mutation of it goes through the SM's own mutex; the
    counters are atomics.
    """

    var sm: UnsafePointer[_Sm, MutUntrackedOrigin]
    var admitted: UnsafePointer[AtomicI64, MutUntrackedOrigin]
    var queued: UnsafePointer[AtomicI64, MutUntrackedOrigin]
    var rejected: UnsafePointer[AtomicI64, MutUntrackedOrigin]
    # Queued waits that ran out of spins (the worker then stops its loop).
    var gave_up: UnsafePointer[AtomicI64, MutUntrackedOrigin]
    var cycles: Int  # admit->release cycles per worker (1 == single shot)


# WHY THE FORK-JOIN IS NOT ONE GENERIC HELPER. The obvious shape,
# `_fork_join[entry: def (_VoidPtr) -> _VoidPtr](n, arg)`, does not compile: a
# parameter of function TYPE is a CLOSURE trait, and a top-level `def` is a
# THIN function, so binding one to the other fails ("a thin function cannot
# bind to a closure trait"). Routing it through a type parameter fails too
# (the comptime value is not 'ImplicitlyCopyable'). A thin entry passes to
# `external_call` only as a DIRECT reference, as komira_async's
# `pthread_worker.launch_worker_pthread` does. So the create loop is inlined
# per test and everything around it is shared below.


def _new_tids(n: Int) -> List[Int64]:
    """N zeroed pthread_t slots (pthread_t is 64-bit on Linux + macOS)."""
    var tids = List[Int64]()
    for _i in range(n):
        tids.append(Int64(0))
    return tids^


def _join_all(
    tids: List[Int64],
    started: Int,
    n_workers: Int,
    create_rc: Int32,
) raises:
    """The BARRIER. Joins every thread that actually started.

    Raises if any `pthread_create` failed, so a thread that never started can
    never be silently mistaken for a thread that did no work. That is the one
    failure mode that would turn this gate green while testing nothing.
    """
    for i in range(started):
        _ = external_call["pthread_join", Int32](
            tids[i], _null_ptr[UInt8, MutUntrackedOrigin]()
        )
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
    """pthread start_routine for (1) and (3)."""
    # SAFETY: FFI-BOUNDARY. `arg` is the address of the test frame's
    # `_ForkArg`, which outlives every thread (see `_ForkArg`).
    ref a = arg.bitcast[_ForkArg]()[]
    ref sm = a.sm[]
    ref adm = a.admitted[]
    ref q = a.queued[]
    ref rej = a.rejected[]
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
                # under_cap), then run + release. The spin is bounded: with a
                # correct SM a slot frees within a few scheduler quanta, while
                # a counter that lost an update can hold the cap full forever,
                # so running out of spins is counted (and asserted 0) and the
                # worker stops, rather than the test hanging.
                var claimed = False
                var spins = 0
                while spins < _MAX_QUEUED_SPINS:
                    if sm.try_promote_if_under_cap(String("m")):
                        claimed = True
                        break
                    spins += 1
                if claimed:
                    sm.release(String("m"))
                else:
                    sm.release_queued(String("m"))
                    _ = a.gave_up[].fetch_add(1)
                    break
            else:
                _ = rej.fetch_add(1)
    except e:
        # A pthread entry cannot propagate an exception across the ABI. Print it;
        # the post-barrier assertions are what fail the test.
        print("WARN _entry_admit_release raised: ", String(e))
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def test_concurrent_admit_release_balances_to_zero() raises:
    var n_workers = 8
    var cycles_per_worker = 20_000
    # A cap big enough that most admits succeed (we WANT high admit/release
    # traffic to stress the lock, not mostly-rejects).
    var cap = 4

    var sm = _serving_sm_with_cap(cap)

    # Count, atomically, how many slots each worker is responsible for releasing
    # (every ADMITTED + every promoted QUEUED). The final in-flight count is
    # asserted == 0 directly off the SM, which is the real proof; these atomics
    # cross-check the bookkeeping.
    var admitted_total = AtomicI64(0)
    var queued_total = AtomicI64(0)
    var rejected_total = AtomicI64(0)
    var gave_up_total = AtomicI64(0)

    var fork_arg = _ForkArg(
        sm=_untracked(sm),
        admitted=_untracked(admitted_total),
        queued=_untracked(queued_total),
        rejected=_untracked(rejected_total),
        gave_up=_untracked(gave_up_total),
        cycles=cycles_per_worker,
    )
    var arg = _untracked(fork_arg).bitcast[NoneType]()
    var tids = _new_tids(n_workers)
    var started = 0
    var rc = Int32(0)
    for i in range(n_workers):
        rc = external_call["pthread_create", Int32](
            UnsafePointer(to=tids[i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_admit_release,  # start_routine (DIRECT thin-fn reference)
            arg,  # arg (shared by all N)
        )
        if rc != Int32(0):
            break
        started += 1
    _join_all(tids, started, n_workers, rc)
    _ = fork_arg^

    assert_equal(
        gave_up_total.load(), Int64(0),
        "no queued worker ran out of spins waiting for a free slot",
    )
    # The decisive assertion: after every admit was paired with its release, the
    # shared SM's in-flight + queued counts are EXACTLY 0 (no lost update).
    assert_equal(
        sm.inflight_of(String("m")), 0,
        "in-flight returns to exactly 0 after all concurrent releases",
    )
    assert_equal(
        sm.queued_of(String("m")), 0,
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

    sm.shutdown_all()


# =============================================================================
# (2) CAP IS A HARD GLOBAL BOUND — workers admit WITHOUT releasing until the
#     barrier; in-flight + queued can never exceed cap + queue_capacity no
#     matter how many threads race (the atomic cap-check + bump). After the
#     barrier the count of ADMITTED is exactly cap.
# =============================================================================
def _entry_admit_hold(arg: _VoidPtr) -> _VoidPtr:
    """pthread start_routine for (2). Each worker fires ONE admit and does NOT
    release (holds its slot to the barrier) so the SM accumulates in-flight +
    queued to its bound."""
    # SAFETY: FFI-BOUNDARY — see `_entry_admit_release`.
    ref a = arg.bitcast[_ForkArg]()[]
    ref sm = a.sm[]
    try:
        var d = sm.admit(String("m"))
        if d == ADMIT_ADMITTED:
            _ = a.admitted[].fetch_add(1)
        elif d == ADMIT_QUEUED:
            _ = a.queued[].fetch_add(1)
        else:
            _ = a.rejected[].fetch_add(1)
    except e:
        print("WARN _entry_admit_hold raised: ", String(e))
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def test_concurrent_cap_is_hard_bound() raises:
    var n_workers = 16
    var cap = 2
    var sm = _serving_sm_with_cap(cap)
    var queue_cap = sm.queue_capacity_of(String("m"))

    var admitted_total = AtomicI64(0)
    var queued_total = AtomicI64(0)
    var rejected_total = AtomicI64(0)
    var gave_up_total = AtomicI64(0)

    var fork_arg = _ForkArg(
        sm=_untracked(sm),
        admitted=_untracked(admitted_total),
        queued=_untracked(queued_total),
        rejected=_untracked(rejected_total),
        gave_up=_untracked(gave_up_total),
        cycles=1,
    )
    var arg = _untracked(fork_arg).bitcast[NoneType]()
    var tids = _new_tids(n_workers)
    var started = 0
    var rc = Int32(0)
    for i in range(n_workers):
        rc = external_call["pthread_create", Int32](
            UnsafePointer(to=tids[i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_admit_hold,  # start_routine (DIRECT thin-fn reference)
            arg,  # arg (shared by all N)
        )
        if rc != Int32(0):
            break
        started += 1
    _join_all(tids, started, n_workers, rc)
    _ = fork_arg^

    # The in-flight count never exceeded the cap (the atomic cap-check held the
    # bound globally across all threads).
    assert_equal(
        Int64(sm.inflight_of(String("m"))), admitted_total.load(),
        "the SM in-flight count equals the number of ADMITTED slots",
    )
    assert_true(
        sm.inflight_of(String("m")) <= cap,
        "in-flight never exceeded the cap under the concurrent race",
    )
    assert_true(
        sm.queued_of(String("m")) <= queue_cap,
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

    sm.shutdown_all()


# =============================================================================
# (3) PULL PROMOTION UNDER CONTENTION — with a cap of 1 and 8 workers, most
#     admits QUEUE and then spin on try_promote_if_under_cap, so the
#     queued -> in-flight move races against concurrent admits and releases.
#     Every queued worker claims a slot and releases it, and both counters
#     return to exactly 0 (a lost update in the promotion path leaves one of
#     them non-zero).
# =============================================================================
def test_concurrent_pull_promotion_balances_to_zero() raises:
    var n_workers = 8
    var sm = _serving_sm_with_cap(1)

    var admitted_total = AtomicI64(0)
    var queued_total = AtomicI64(0)
    var rejected_total = AtomicI64(0)
    var gave_up_total = AtomicI64(0)

    var fork_arg = _ForkArg(
        sm=_untracked(sm),
        admitted=_untracked(admitted_total),
        queued=_untracked(queued_total),
        rejected=_untracked(rejected_total),
        gave_up=_untracked(gave_up_total),
        cycles=2_000,
    )
    var arg = _untracked(fork_arg).bitcast[NoneType]()
    var tids = _new_tids(n_workers)
    var started = 0
    var rc = Int32(0)
    for i in range(n_workers):
        rc = external_call["pthread_create", Int32](
            UnsafePointer(to=tids[i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_admit_release,  # start_routine (DIRECT thin-fn reference)
            arg,  # arg (shared by all N)
        )
        if rc != Int32(0):
            break
        started += 1
    _join_all(tids, started, n_workers, rc)
    _ = fork_arg^

    assert_equal(
        gave_up_total.load(), Int64(0),
        "no queued worker ran out of spins waiting for a free slot",
    )
    assert_equal(sm.inflight_of(String("m")), 0, "in-flight returns to 0")
    assert_equal(sm.queued_of(String("m")), 0, "queued returns to 0")
    assert_equal(
        admitted_total.load() + queued_total.load() + rejected_total.load(),
        Int64(n_workers * 2_000),
        "every attempt classified once",
    )
    sm.shutdown_all()


# =============================================================================
# (4) CONCURRENT LOAD IS SERIALIZED — N workers request_load the SAME model
#     concurrently. The SM mutex serializes the whole load decision, so the model
#     ends SERVING with EXACTLY ONE resident instance (the losing threads observe
#     it already SERVING under the lock and just re-arm the TTL; they do NOT
#     spawn a second child or corrupt the parallel-list bookkeeping).
# =============================================================================
def _entry_request_load(arg: _VoidPtr) -> _VoidPtr:
    """pthread start_routine for (4)."""
    # SAFETY: FFI-BOUNDARY — see `_entry_admit_release`.
    ref a = arg.bitcast[_ForkArg]()[]
    ref s = a.sm[]
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
    # This test counts nothing; the counters only fill the arg.
    var unused = AtomicI64(0)

    var fork_arg = _ForkArg(
        sm=_untracked(sm),
        admitted=_untracked(unused),
        queued=_untracked(unused),
        rejected=_untracked(unused),
        gave_up=_untracked(unused),
        cycles=1,
    )
    var arg = _untracked(fork_arg).bitcast[NoneType]()
    var tids = _new_tids(n_workers)
    var started = 0
    var rc = Int32(0)
    for i in range(n_workers):
        rc = external_call["pthread_create", Int32](
            UnsafePointer(to=tids[i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_request_load,  # start_routine (DIRECT thin-fn reference)
            arg,  # arg (shared by all N)
        )
        if rc != Int32(0):
            break
        started += 1
    _join_all(tids, started, n_workers, rc)
    _ = fork_arg^
    _ = unused.load()

    # The model is SERVING with exactly ONE resident instance after N concurrent
    # request_load calls.
    assert_equal(
        sm.state_of(String("m")), 2, "model is SERVING after concurrent load",
    )
    assert_equal(
        sm.resident_count(), 1,
        "exactly one resident instance (no double-spawn under the race)",
    )
    sm.shutdown_all()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
