# =============================================================================
# test_token_races — CancellationToken under real concurrency
# =============================================================================
#
# The token's API is poll-only: `new`, `never`, `clone`, `child`, `cancel`,
# `is_cancelled`, `reason`. It has no callbacks, waiters or deregistration,
# so the races that exist are between `cancel` and the other six. Each test
# below runs one race REPS times, every repetition on fresh tokens and fresh
# OS threads, so a destroy-and-recreate cycle is part of every run.
#
# HOW A RACE IS DRIVEN. Every repetition is one `fork_join_shared` wave on
# `_PthreadDispatch`, a test-only `ParallelDispatch` conformer that runs each
# shard on its own pthread and joins them all before returning (this package
# owns the trait and the driver but no pool; the real pool lives above it).
# Inside the wave, every chunk first arrives at a start latch (an atomic
# counter each chunk increments and then spins on until all N_THREADS have
# arrived), so the racing calls start together. Where a test needs "after
# every cancel returned", the chunks wait on a second counter. Orderings that
# a test asserts deterministically ("derived before the cancel") are made by
# the latch, not by timing; no test sleeps.
#
# WHAT IS PROBABILISTIC. Two properties can only fail if two threads hit a
# window of a few dozen instructions at once: "one transition" (two racing
# cancels must not both write the reason) and "the reason is published with
# the flag". The tests for them repeat REPS_RACE times; a pass is evidence,
# not proof, and the count is the strength of that evidence. Every other
# property here fails on every repetition when it is broken.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.testing import assert_false, assert_true

from komira_atomic_alias import AtomicI64
from komira_async_api.token import CancellationToken
from komira_async_api.fork_join_shared import fork_join_shared
from komira_async_api.parallel_dispatch import ParallelDispatch
from komira_async_api.shared_chunk_work import SharedChunkWork
from komira_async_api.worker_pool_traits import KeepAlive, Segment


comptime N_THREADS = 4
comptime REPS_RACE = 2000  # the two probabilistic races
comptime REPS_ORDERED = 300  # races whose failure is not timing-dependent
comptime OBSERVER_POLLS = 1000  # monotonicity polls after the first True
comptime DERIVE_DEPTH = 12  # tokens per deriving chunk; half before the latch

comptime MODE_CANCEL_ALL = 0
comptime MODE_OBSERVE = 1
comptime MODE_DERIVE = 2
comptime MODE_UPWARD = 3
comptime MODE_NEVER = 4


# -----------------------------------------------------------------------------
# _PthreadDispatch — one pthread per shard, joined before return.
# -----------------------------------------------------------------------------

comptime _Void = UnsafePointer[NoneType, MutUntrackedOrigin]


def _null_void() -> _Void:
    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer and `None` is the all-zero NULL bit pattern (the same
    # idiom as `spawn_drop._ffi_null`).
    var none: Optional[_Void] = None
    return UnsafePointer(to=none).bitcast[_Void]()[]


@fieldwise_init
struct _ThreadJob[State: KeepAlive, T: Segment](Movable):
    """What one pthread runs: `seg.execute(state, task_id, task_id)`."""

    var state: UnsafePointer[Self.State, MutUntrackedOrigin]
    var seg: UnsafePointer[Self.T, MutUntrackedOrigin]
    var task_id: Int
    var failures: UnsafePointer[AtomicI64, MutUntrackedOrigin]


def _thread_entry[State: KeepAlive, T: Segment](arg: _Void) -> _Void:
    # FFI-BOUNDARY: pthread start routine. `arg` points at a `_ThreadJob`
    # in `run_with_state`'s `jobs` list, which neither moves nor drops until
    # every thread has been joined; the thread owns nothing it must free.
    # SAFETY: every pointer in the job targets a value on the
    # `run_with_state` frame (or the caller's State), alive until the join.
    var job = arg.bitcast[_ThreadJob[State, T]]()
    try:
        job[].seg[].execute[State](
            job[].state[], Int32(job[].task_id), Int64(job[].task_id)
        )
    except e:
        _ = e
        _ = job[].failures[].fetch_add(Int64(1))
    return _null_void()


struct _PthreadDispatch(ParallelDispatch, Movable, Deinitable):
    """Test-only dispatcher: `run_with_state` starts `n` pthreads, shard `i`
    runs `seg.execute(state, i, i)`, and all are joined before it returns.

    The segment is shared by pointer across the shards, as `LocalDispatcher`
    shares its `_seg_buf`. If `pthread_create` fails part-way, the shards
    already started can spin forever on a test's start latch; four threads
    failing to start is treated as an environment failure, not handled.
    """

    var n_threads: Int

    def __init__(out self, n_threads: Int):
        self.n_threads = n_threads

    def run_with_state[State: KeepAlive, T: Segment](
        mut self,
        mut state: State,
        var seg: T,
        n: Int,
        var cancel_token: CancellationToken,
        site_id: UInt32 = UInt32(0),
    ) raises -> T:
        _ = cancel_token^
        _ = site_id
        var failures = AtomicI64(Int64(0))
        # SAFETY: the three pointers target `state`, `seg` and `failures`,
        # all of which outlive the joins below; no thread outlives this call.
        var state_p = UnsafePointer(to=state).unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        var seg_p = UnsafePointer(to=seg).unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        var fail_p = UnsafePointer(to=failures).unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        # Both lists are fully sized before any pointer into them is taken.
        var jobs = List[_ThreadJob[State, T]](capacity=n)
        var tids = List[UInt64](capacity=n)
        for i in range(n):
            jobs.append(_ThreadJob[State, T](state_p, seg_p, i, fail_p))
            tids.append(UInt64(0))
        var started = 0
        for i in range(n):
            var arg = (
                UnsafePointer(to=jobs[i])
                .bitcast[NoneType]()
                .unsafe_origin_cast[MutUntrackedOrigin]()
            )
            var entry = _thread_entry[State, T]
            var rc = external_call["pthread_create", Int32](
                UnsafePointer(to=tids[i]).bitcast[UInt8](),
                _null_void().bitcast[UInt8](),
                entry,
                arg,
            )
            if rc != Int32(0):
                break
            started += 1
        for i in range(started):
            _ = external_call["pthread_join", Int32](tids[i], _null_void())
        state.__keep_alive()
        _ = jobs^
        if started != n:
            raise Error("_PthreadDispatch: pthread_create failed")
        if Int(failures.load()) != 0:
            raise Error("_PthreadDispatch: a shard raised")
        return seg^

    def worker_count(self) -> Int:
        return self.n_threads


# -----------------------------------------------------------------------------
# Shared race input / payload.
# -----------------------------------------------------------------------------


def _new_counter() -> OwnedPointer[AtomicI64]:
    var raw = alloc[AtomicI64](1)
    # SAFETY: `raw` is a fresh allocation this function owns until the
    # OwnedPointer takes it.
    raw[] = AtomicI64(Int64(0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


struct _RaceInput(Deinitable):
    """Read-only, shared by every chunk: chunk `c` cancels with `reasons[c]`.

    The reasons are long and of different lengths so that each is a separate
    heap buffer: a torn or doubly-written reason shows up as a string that is
    not exactly one of them."""

    var reasons: List[String]

    def __init__(out self):
        self.reasons = List[String]()
        for c in range(N_THREADS):
            var r = String("cancel-reason-of-chunk-") + String(c) + "-"
            for _ in range(48 + 13 * c):
                r += "r"
            self.reasons.append(r^)

    def is_candidate(self, r: String) -> Bool:
        for c in range(len(self.reasons)):
            if self.reasons[c] == r:
                return True
        return False


struct _RacePayload(Movable, Deinitable):
    """The one mutable payload every chunk aliases. Chunk `c` writes only
    `codes[c]` and `seen[c]`; the counters are atomics; `root` is only read
    (cloned / derived from), never cancelled through this field."""

    var root: CancellationToken
    var arrived: OwnedPointer[AtomicI64]
    var cancels_done: OwnedPointer[AtomicI64]
    var codes: List[Int]
    var seen: List[String]

    def __init__(out self, var root: CancellationToken):
        self.root = root^
        self.arrived = _new_counter()
        self.cancels_done = _new_counter()
        self.codes = List[Int](capacity=N_THREADS)
        self.seen = List[String](capacity=N_THREADS)
        for _ in range(N_THREADS):
            self.codes.append(0)
            self.seen.append(String(""))


def _wait_at_least(mut ctr: OwnedPointer[AtomicI64], target: Int):
    var spins = 0
    while Int(ctr[].load()) < target:
        spins += 1
        if spins % 256 == 0:
            _ = external_call["sched_yield", Int32]()


def _arrive_and_wait(mut ctr: OwnedPointer[AtomicI64], n: Int):
    _ = ctr[].fetch_add(Int64(1))
    _wait_at_least(ctr, n)


# -----------------------------------------------------------------------------
# Per-mode chunk bodies. Each returns 0 or a violation code that the driver
# turns into a message.
# -----------------------------------------------------------------------------


def _chunk_cancel(inp: _RaceInput, mut p: _RacePayload, c: Int) -> Int:
    """Cancel through a private clone; record the reason seen right after
    `cancel` returned."""
    var mine = p.root.clone()
    _arrive_and_wait(p.arrived, N_THREADS)
    mine.cancel(inp.reasons[c])
    var code = 0
    if not mine.is_cancelled():
        code = 1
    p.seen[c] = mine.reason()
    _ = p.cancels_done[].fetch_add(Int64(1))
    return code


def _chunk_observe(mut p: _RacePayload) -> Int:
    """Poll until cancelled; then the reason must be published and the token
    must stay cancelled."""
    var mine = p.root.clone()
    _arrive_and_wait(p.arrived, N_THREADS)
    var saw = False
    while True:
        # Read the counter BEFORE polling: if every canceller had returned
        # before this poll, the poll must see the cancel.
        var all_returned = Int(p.cancels_done[].load()) >= N_THREADS - 1
        if mine.is_cancelled():
            saw = True
            break
        if all_returned:
            break
    if not saw:
        return 2
    p.seen[0] = mine.reason()
    for _ in range(OBSERVER_POLLS):
        if not mine.is_cancelled():
            return 3
    return 0


def _derive_chain(
    inp: _RaceInput,
    mut p: _RacePayload,
    parent: CancellationToken,
    depth: Int,
) -> Int:
    """One token per frame: a child at even depth, a clone at odd depth. The
    first DERIVE_DEPTH / 2 frames are made before this chunk reaches the
    start latch (so strictly before the cancel), the rest race it. The
    deepest frame waits for the cancel to return, then derives a late child
    of the root; every frame checks its own token on the way out."""
    var tok: CancellationToken
    if depth % 2 == 0:
        tok = parent.child()
    else:
        tok = parent.clone()
    if depth == DERIVE_DEPTH // 2:
        _arrive_and_wait(p.arrived, N_THREADS)
    var code = 0
    if depth + 1 < DERIVE_DEPTH:
        code = _derive_chain(inp, p, tok, depth + 1)
    else:
        _wait_at_least(p.cancels_done, 1)
        var late = p.root.child()
        if not late.is_cancelled():
            code = 10
        elif late.reason() != inp.reasons[0]:
            code = 11
    if code == 0:
        if not tok.is_cancelled():
            code = 100 + depth
        elif tok.reason() != inp.reasons[0]:
            code = 200 + depth
    return code


def _chunk_upward(inp: _RaceInput, mut p: _RacePayload, c: Int) -> Int:
    """Every chunk cancels its OWN child of the root at once. The root and
    the siblings must not see it."""
    var mine = p.root.child()
    var grandchild = mine.child()
    _arrive_and_wait(p.arrived, N_THREADS)
    mine.cancel(inp.reasons[c])
    _ = p.cancels_done[].fetch_add(Int64(1))
    _wait_at_least(p.cancels_done, N_THREADS)
    if not mine.is_cancelled():
        return 1
    if p.root.is_cancelled():
        return 2
    if p.root.reason() != String(""):
        return 3
    if mine.reason() != inp.reasons[c]:
        return 4
    if grandchild.reason() != inp.reasons[c]:
        return 5
    return 0


def _chunk_never(inp: _RaceInput, mut p: _RacePayload, c: Int) -> Int:
    """Every chunk cancels a clone of a `never()` token at once."""
    var mine = p.root.clone()
    _arrive_and_wait(p.arrived, N_THREADS)
    mine.cancel(inp.reasons[c])
    if mine.is_cancelled():
        return 1
    if mine.reason() != String(""):
        return 2
    return 0


@fieldwise_init
struct _TokenRace(SharedChunkWork):
    """Chunk `c` of one race repetition; `mode` picks the race.

    DISPATCH-BOUNDARY SAFETY:
      * Disjointness: chunk `c` writes only `payload.codes[c]` and
        `payload.seen[c]` (MODE_OBSERVE: chunk 0 is the only writer of
        `seen[0]`; the cancellers there are chunks 1..N-1). The counters are
        atomics. `payload.root` is read by every chunk (`clone`/`child`),
        never written; the token's shared slots are the thing under test.
      * Liveness: the payload is MOVED onto the driver's State and `input`
        is borrowed with a concrete origin from the test's frame;
        `_PthreadDispatch.run_with_state` joins every thread before return.
      * No-realloc: `codes` and `seen` are pre-sized; chunks only setitem.
    """

    var mode: Int

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self,
        chunk_id: Int,
        n_chunks: Int,
        ref input: In,
        mut payload: P,
    ) raises:
        # SAFETY: every call site instantiates the driver with In=_RaceInput
        # and P=_RacePayload; the pointers do not escape this call.
        var inp = UnsafePointer(to=input).bitcast[_RaceInput]()
        var pp = UnsafePointer(to=payload).bitcast[_RacePayload]()
        _ = n_chunks
        var c = chunk_id
        var code = 0
        if self.mode == MODE_CANCEL_ALL:
            code = _chunk_cancel(inp[], pp[], c)
        elif self.mode == MODE_OBSERVE:
            if c == 0:
                code = _chunk_observe(pp[])
            else:
                code = _chunk_cancel(inp[], pp[], c)
        elif self.mode == MODE_DERIVE:
            if c == 0:
                code = _chunk_cancel(inp[], pp[], c)
            else:
                var base = pp[].root.clone()
                code = _derive_chain(inp[], pp[], base, 0)
        elif self.mode == MODE_UPWARD:
            code = _chunk_upward(inp[], pp[], c)
        else:
            code = _chunk_never(inp[], pp[], c)
        pp[].codes[c] = code


def _race(
    mode: Int, inp: _RaceInput, var root: CancellationToken
) raises -> _RacePayload:
    """One repetition: N_THREADS chunks on N_THREADS fresh pthreads."""
    var disp = _PthreadDispatch(N_THREADS)
    return fork_join_shared[
        _TokenRace,
        _RaceInput,
        _RacePayload,
        origin_of(inp),
        _PthreadDispatch,
        True,
        origin_of(disp),
    ](
        _TokenRace(mode),
        inp,
        _RacePayload(root^),
        N_THREADS,
        1,
        0,
        Optional[Pointer[_PthreadDispatch, origin_of(disp)]](
            Pointer(to=disp)
        ),
        CancellationToken.never(),
        UInt32(0),
    )


def _fail(test: String, rep: Int, chunk: Int, what: String) raises:
    raise Error(
        test + ": repetition " + String(rep) + ", chunk " + String(chunk)
        + ": " + what
    )


# -----------------------------------------------------------------------------
# The races.
# -----------------------------------------------------------------------------


def test_concurrent_cancel_is_one_transition() raises:
    """N_THREADS threads cancel clones of one token at once, each with its
    own reason. Exactly one cancel may set the reason: every thread, reading
    `reason()` right after its own `cancel` returned, must see the same
    string, that string must be the final reason, and it must be exactly one
    of the candidates (not torn). PROBABILISTIC: two cancels must overlap
    between the "not yet cancelled" check and the reason write; REPS_RACE
    repetitions."""
    var inp = _RaceInput()
    for rep in range(REPS_RACE):
        var p = _race(MODE_CANCEL_ALL, inp, CancellationToken.new())
        var final_reason = p.root.reason()
        if not p.root.is_cancelled():
            _fail("one transition", rep, -1, "root is not cancelled")
        if not inp.is_candidate(final_reason):
            _fail(
                "one transition", rep, -1,
                "final reason is no candidate (torn write): '"
                + final_reason + "'",
            )
        for c in range(N_THREADS):
            if p.codes[c] == 1:
                _fail("one transition", rep, c, "is_cancelled() False after own cancel returned")
            if p.seen[c] == String(""):
                _fail(
                    "one transition", rep, c,
                    "reason() empty after own cancel returned (flag "
                    + "published before the reason)",
                )
            if p.seen[c] != final_reason:
                _fail(
                    "one transition", rep, c,
                    "reason changed after cancel published: saw '"
                    + p.seen[c] + "', final '" + final_reason
                    + "' (two cancels both wrote the reason)",
                )


def test_observer_sees_published_reason_and_monotonic_flag() raises:
    """Chunk 0 polls a clone while chunks 1..N-1 cancel theirs. The first
    True from `is_cancelled()` must come with a published reason (non-empty,
    one candidate, equal to the final reason), and the token must then stay
    cancelled for OBSERVER_POLLS polls. If every canceller returned, the
    observer must have seen the cancel (deterministic). The reason checks
    are PROBABILISTIC (the observer must poll inside the publish window);
    REPS_RACE repetitions."""
    var inp = _RaceInput()
    for rep in range(REPS_RACE):
        var p = _race(MODE_OBSERVE, inp, CancellationToken.new())
        var final_reason = p.root.reason()
        for c in range(N_THREADS):
            var code = p.codes[c]
            if code == 1:
                _fail("observer", rep, c, "is_cancelled() False after own cancel returned")
            if code == 2:
                _fail("observer", rep, c, "every cancel returned but the observer never saw is_cancelled()")
            if code == 3:
                _fail("observer", rep, c, "is_cancelled() went True then False")
        if not inp.is_candidate(p.seen[0]):
            _fail(
                "observer", rep, 0,
                "reason read right after is_cancelled() was True is no "
                + "candidate (flag published before reason): '"
                + p.seen[0] + "'",
            )
        if p.seen[0] != final_reason:
            _fail(
                "observer", rep, 0,
                "observed reason '" + p.seen[0] + "' but final reason '"
                + final_reason + "'",
            )


def test_tokens_derived_around_cancel_all_observe_it() raises:
    """Chunk 0 cancels the root while chunks 1..N-1 build a chain of
    DERIVE_DEPTH children/clones of it: half made before the start latch
    (strictly before the cancel), half racing it, plus one child made after
    the cancel returned. Once the cancel returned, every one of them must be
    cancelled with the root's reason. Deterministic: a derived token that does
    not share its ancestors' slots fails on the pre-latch half every time."""
    var inp = _RaceInput()
    for rep in range(REPS_ORDERED):
        var p = _race(MODE_DERIVE, inp, CancellationToken.new())
        for c in range(N_THREADS):
            var code = p.codes[c]
            if code == 0:
                continue
            if code == 1:
                _fail("derive", rep, c, "canceller: is_cancelled() False after own cancel returned")
            if code == 10:
                _fail("derive", rep, c, "child made after the cancel returned is not cancelled")
            if code == 11:
                _fail("derive", rep, c, "child made after the cancel has the wrong reason")
            if code >= 200:
                _fail("derive", rep, c, "token at depth " + String(code - 200) + " has the wrong reason")
            if code >= 100:
                _fail(
                    "derive", rep, c,
                    "token at depth " + String(code - 100) + " (made "
                    + ("before" if code - 100 < DERIVE_DEPTH // 2 else "during")
                    + " the cancel) is not cancelled after it returned",
                )
            _fail("derive", rep, c, "unknown code " + String(code))


def test_concurrent_child_cancels_do_not_propagate_up() raises:
    """Every chunk cancels its own child of one root at once. After all
    returned: the root is not cancelled and has no reason, each child (and
    a grandchild made before the race) carries exactly its own reason, never a
    sibling's. Deterministic."""
    var inp = _RaceInput()
    for rep in range(REPS_ORDERED):
        var root = CancellationToken.new()
        var p = _race(MODE_UPWARD, inp, root^)
        for c in range(N_THREADS):
            var code = p.codes[c]
            if code == 1:
                _fail("upward", rep, c, "child not cancelled after own cancel returned")
            if code == 2:
                _fail("upward", rep, c, "a child's cancel cancelled the root")
            if code == 3:
                _fail("upward", rep, c, "a child's cancel set the root's reason")
            if code == 4:
                _fail("upward", rep, c, "child carries a sibling's or no reason")
            if code == 5:
                _fail("upward", rep, c, "grandchild carries a reason other than its parent's")
        assert_false(p.root.is_cancelled(), "upward: root cancelled after join")


def test_never_token_ignores_concurrent_cancels() raises:
    """Every chunk cancels a clone of `never()` at once; none may become
    cancelled or carry a reason. Deterministic."""
    var inp = _RaceInput()
    for rep in range(REPS_ORDERED):
        var p = _race(MODE_NEVER, inp, CancellationToken.never())
        for c in range(N_THREADS):
            if p.codes[c] == 1:
                _fail("never", rep, c, "a never() token became cancelled")
            if p.codes[c] == 2:
                _fail("never", rep, c, "a never() token carries a reason")
        assert_false(p.root.is_cancelled(), "never: root cancelled")
        assert_true(p.root.reason() == String(""), "never: root has a reason")


def main() raises:
    test_concurrent_cancel_is_one_transition()
    test_observer_sees_published_reason_and_monotonic_flag()
    test_tokens_derived_around_cancel_all_observe_it()
    test_concurrent_child_cancels_do_not_propagate_up()
    test_never_token_ignores_concurrent_cancels()
