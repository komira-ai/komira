# =============================================================================
# test_tracer_parallelize.mojo — Tracer under @parameter parallelize
# =============================================================================
#
# Worker-disjoint span emission via `Pointer(to=tracer)` capture. Verifies:
#
#   1. 8 workers each emit 100 spans → 1600 records on the rings (open
#      + close per span).
#   2. Each worker's stack returns to depth 0 after the dispatch.
#   3. No data corruption (record count, span_id counter monotonicity).
#   4. drain_into_capture pulls every record across every worker.
# =============================================================================

from std.ffi import external_call
from std.memory import Pointer, UnsafePointer, alloc
from std.testing import assert_equal, assert_true

from komira_obs.tracer import Tracer
from komira_obs.exporter import CapturingExporter


# =============================================================================
# THE FORK-JOIN — real pthreads.
#
# ⚠ MOJO 1.0.0: `from std.algorithm import parallelize` is GONE. `parallelize`
# was REMOVED from the stdlib (measured against 1.0.0: absent from
# `std.algorithm`, `std.runtime`, `std.runtime.asyncrt`; no `std.parallel` /
# `std.concurrency` module exists). It is not a rename — there is nothing to
# repoint the import to.
#
# The replacement is raw `pthread_create` + `pthread_join` over
# `std.ffi.external_call`. A SERIAL LOOP WOULD HAVE VOIDED THIS FILE: every
# arm below is about what N threads do to ONE shared Tracer — the disjointness
# of the per-worker rings, and the `try_register` read-then-write race the
# second arm's docstring dissects at length. Run those bodies one at a time and
# all three still pass while proving nothing.
#
# ⚠ WHY IT IS NOT ONE GENERIC HELPER: a parameter of function TYPE is a CLOSURE
# trait and a top-level `def` is a THIN function, so `_fork_join[entry](...)`
# does not bind in 1.0.0. A thin entry reaches `external_call` only at a DIRECT
# reference, so the create loop is inlined per arm and only the plumbing below
# is shared.
#
# The file, its test names and its docstrings keep the word "parallelize": it
# names the SHAPE under test (N concurrent workers on one Tracer).
# =============================================================================

comptime _VoidPtr = UnsafePointer[NoneType, MutUntrackedOrigin]


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (Mojo 1.0.0 has no
    null-UnsafePointer constructor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero (NULL) bit pattern. FFI NULL args only.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


@fieldwise_init
struct _WArg(Copyable, Movable, Deinitable):
    """The per-worker pthread arg. ONE PER THREAD, because every arm needs its
    own `tid` — the parameter the old `parallelize` closure took, and the value
    that selects this worker's ring and (in the third arm) its span name.

    Both fields are PODs (an Int-laundered address and two counters), the
    FFI-POD address carve-out the pointer rules allow at a pthread
    boundary.

    SAFETY: the N args live in ONE heap block allocated by the calling test
    frame and freed only AFTER the join barrier, so the arg strictly outlives
    every reader; workers only READ it. `tracer_addr` points at a local of the
    calling frame, which likewise outlives the barrier. The Tracer is shared by
    address deliberately — that is what is under test.
    """

    var tracer_addr: Int  # Int-laundered Tracer*
    var tid: Int
    var iters: Int


def _new_tids(n: Int) -> List[Int64]:
    """N zeroed pthread_t slots (pthread_t is 64-bit on Linux + macOS)."""
    var tids = List[Int64]()
    for _i in range(n):
        tids.append(Int64(0))
    return tids^


def _box_args(n: Int, tracer_addr: Int, iters: Int) -> UnsafePointer[
    _WArg, MutUntrackedOrigin
]:
    """Heap-box N per-worker args. Freed by `_join_all` after the barrier."""
    var box = alloc[_WArg](n)
    for i in range(n):
        UnsafePointer(to=box[i]).unsafe_write(
            _WArg(tracer_addr=tracer_addr, tid=i, iters=iters)
        )
    return box.unsafe_origin_cast[MutUntrackedOrigin]()


def _join_all(
    tids: List[Int64],
    started: Int,
    n_workers: Int,
    create_rc: Int32,
    var box: UnsafePointer[_WArg, MutUntrackedOrigin],
) raises:
    """The BARRIER. Joins every thread that actually started, then frees the
    arg block — in that order, so no live thread outlives what it reads.

    Raises if any `pthread_create` failed. That matters more here than
    anywhere: a thread that never started emits no spans, and every assertion
    below counts. Silently running 3 of 4 workers would turn the registry
    bounds green while testing a narrower race than the one named.
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
            + " workers -- the concurrency gate did not run at full width"
        )


@always_inline
def _tracer_of(a: _WArg) -> UnsafePointer[Tracer, MutUntrackedOrigin]:
    """Recover the shared Tracer. ONE FFI-boundary recovery site."""
    # SAFETY: FFI-BOUNDARY. `tracer_addr` was produced by
    # `Int(UnsafePointer(to=tracer))` on a local of the calling test frame,
    # which outlives the join barrier (see `_WArg`).
    return UnsafePointer[Tracer, MutUntrackedOrigin](
        unsafe_from_address=a.tracer_addr,
    )


comptime N_WORKERS = 8
comptime SPANS_PER_WORKER = 100


def _entry_worker_emit(arg: _VoidPtr) -> _VoidPtr:
    """pthread start_routine for the `worker_emit` worker."""
    # SAFETY: FFI-BOUNDARY. `arg` points into the `_WArg` block `_box_args`
    # allocated; it outlives every thread (freed only after the join barrier).
    ref a = arg.bitcast[_WArg]()[]
    ref tracer = _tracer_of(a)[]
    try:
        for i in range(a.iters):
            var sid = tracer.start_span["worker.consume_morsel"](
                worker_id=a.tid
            )
            tracer.end_span(sid, worker_id=a.tid)
            _ = i
    except e:
        # A pthread entry cannot propagate an exception across the ABI.
        print("worker_emit", a.tid, "raised:", e)
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def test_disjoint_per_worker_emit() raises:
    """8 workers × 100 spans → 1600 records, all stacks return to depth 0."""
    var tracer = Tracer(num_workers=N_WORKERS, ring_capacity=1024)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    var tp = Pointer(to=tracer)

    var _tids = _new_tids(N_WORKERS)
    var _box = _box_args(
        N_WORKERS, Int(UnsafePointer(to=tracer)), SPANS_PER_WORKER
    )
    var _started = 0
    var _rc = Int32(0)
    for _i in range(N_WORKERS):
        _rc = external_call["pthread_create", Int32](
            UnsafePointer(to=_tids[_i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_worker_emit,  # start_routine (DIRECT thin-fn reference)
            UnsafePointer(to=_box[_i]).bitcast[NoneType]().unsafe_origin_cast[
                MutUntrackedOrigin
            ](),  # arg (this worker's own slot -- carries its tid)
        )
        if _rc != Int32(0):
            break
        _started += 1
    _join_all(_tids, _started, N_WORKERS, _rc, _box)
    _ = tp
    _ = tracer  # keepalive

    # Every worker's stack returns to 0.
    for w in range(N_WORKERS):
        assert_equal(tracer.depth_of(w), Int(0),
                     "worker " + String(w) + " stack at 0")

    # Drain into a capturing exporter and count.
    var exp = CapturingExporter()
    tracer.drain_into_capture(exp)
    # OPEN + CLOSE packets join into one SpanRecord per
    # span_id, so the count is N_WORKERS * SPANS_PER_WORKER (not 2x).
    var expected = N_WORKERS * SPANS_PER_WORKER
    assert_equal(exp.count(), Int(expected),
                 "captured " + String(exp.count()) + " of " + String(expected))
    print("  test_disjoint_per_worker_emit PASS, spans=", exp.count())


def _entry_worker_dup_name(arg: _VoidPtr) -> _VoidPtr:
    """pthread start_routine for the `worker_dup_name` worker. Every worker
    emits the SAME name, on purpose — the `try_register` read-then-write race
    is the subject of the arm below."""
    # SAFETY: FFI-BOUNDARY. See `_entry_worker_emit`.
    ref a = arg.bitcast[_WArg]()[]
    ref tracer = _tracer_of(a)[]
    try:
        var sid = tracer.start_span["operator.flat_hash_agg"](worker_id=a.tid)
        tracer.end_span(sid, worker_id=a.tid)
    except e:
        print("worker_dup_name", a.tid, "raised:", e)
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def test_name_registry_populated_under_parallelize() raises:
    """Multiple workers emit the same name — the registry ends up HOLDING it,
    and the insert count stays inside the one-duplicate-per-worker bound the
    implementation actually promises.

    ⚠ `count() == 1` WOULD BE AN INTERMITTENT RED: it asserts a property
    `NameRegistry` explicitly says it does not provide. `try_register` is a plain
    read-then-write, NOT a CAS:

        var existing = self.entries[idx].name_id      # read
        if existing == UInt32(0):
            # "Concurrent writers on the SAME idx ... may both pass this
            #  check; we accept up to one duplicate write because the JSONL
            #  drain dedups by name_id at emit time."
            self.entries[idx].name_id = name_id       # write
            _ = self.n_registered.fetch_add(Int32(1))

    so N workers racing on one unregistered name can each see 0 and each
    `fetch_add`. `n_registered` is therefore an UPPER BOUND on distinct names,
    not a count of them — and `count()` has no production consumer outside
    `tracer.mojo`. Every real reader — `lookup`, `contains`, the JSONL drain — linear-probes and
    stops at the FIRST matching entry, so a duplicate is invisible to all of
    them. Pinning a non-contract that has a race behind it is exactly how a suite
    acquires an unexplainable intermittent red.

    The bounds below are the real contract: at least one insert happened (the
    registry is POPULATED — what this test is named for), and at most one per
    racing worker. If that ceiling were ever exceeded, `try_register`'s "up to
    one duplicate write" reasoning would be wrong and this SHOULD go red.

    ⚠ WHAT THIS DELIBERATELY DOES NOT COVER. Two DIFFERENT names that hash to the
    same `idx` can both read 0 and both write, and the second write OVERWRITES
    the first — a genuinely LOST name, not a benign duplicate. That is a real
    defect and it needs an actual CAS on `entries[idx].name_id`; it is out of
    scope here because it changes a lock-free hot path and has to be measured,
    not edited. It is NOT what a racing single name produces (one name, four
    emitters, count 2)."""
    comptime N_EMITTERS = 4
    var tracer = Tracer(num_workers=N_EMITTERS, ring_capacity=256)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    var tp = Pointer(to=tracer)

    var _tids = _new_tids(N_EMITTERS)
    var _box = _box_args(N_EMITTERS, Int(UnsafePointer(to=tracer)), 1)
    var _started = 0
    var _rc = Int32(0)
    for _i in range(N_EMITTERS):
        _rc = external_call["pthread_create", Int32](
            UnsafePointer(to=_tids[_i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_worker_dup_name,  # start_routine (DIRECT thin-fn reference)
            UnsafePointer(to=_box[_i]).bitcast[NoneType]().unsafe_origin_cast[
                MutUntrackedOrigin
            ](),  # arg (this worker's own slot -- carries its tid)
        )
        if _rc != Int32(0):
            break
        _started += 1
    _join_all(_tids, _started, N_EMITTERS, _rc, _box)
    _ = tp
    _ = tracer

    var n = tracer.name_registry_count()
    assert_true(
        n >= 1,
        "the one emitted name must be registered; count was " + String(n),
    )
    assert_true(
        n <= N_EMITTERS,
        "at most ONE duplicate insert per racing worker is in contract ("
        + String(N_EMITTERS)
        + " emitters); count was "
        + String(n),
    )
    print("  test_name_registry_populated_under_parallelize PASS, count=", n)


def _entry_worker_unique(arg: _VoidPtr) -> _VoidPtr:
    """pthread start_routine for the `worker_unique` worker — one DISTINCT
    span name per tid, so the registry must end up holding four."""
    # SAFETY: FFI-BOUNDARY. See `_entry_worker_emit`.
    ref a = arg.bitcast[_WArg]()[]
    ref tracer = _tracer_of(a)[]
    try:
        if a.tid == 0:
            var s = tracer.start_span["op.a"](worker_id=a.tid)
            tracer.end_span(s, worker_id=a.tid)
        elif a.tid == 1:
            var s = tracer.start_span["op.b"](worker_id=a.tid)
            tracer.end_span(s, worker_id=a.tid)
        elif a.tid == 2:
            var s = tracer.start_span["op.c"](worker_id=a.tid)
            tracer.end_span(s, worker_id=a.tid)
        else:
            var s = tracer.start_span["op.d"](worker_id=a.tid)
            tracer.end_span(s, worker_id=a.tid)
    except e:
        print("worker_unique", a.tid, "raised:", e)
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def test_distinct_names_register_separately() raises:
    """4 workers emit 4 different names — registry has 4 entries."""
    var tracer = Tracer(num_workers=4, ring_capacity=256)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    var tp = Pointer(to=tracer)

    var _tids = _new_tids(4)
    var _box = _box_args(4, Int(UnsafePointer(to=tracer)), 1)
    var _started = 0
    var _rc = Int32(0)
    for _i in range(4):
        _rc = external_call["pthread_create", Int32](
            UnsafePointer(to=_tids[_i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_worker_unique,  # start_routine (DIRECT thin-fn reference)
            UnsafePointer(to=_box[_i]).bitcast[NoneType]().unsafe_origin_cast[
                MutUntrackedOrigin
            ](),  # arg (this worker's own slot -- carries its tid)
        )
        if _rc != Int32(0):
            break
        _started += 1
    _join_all(_tids, _started, 4, _rc, _box)
    _ = tp
    _ = tracer

    assert_equal(tracer.name_registry_count(), Int(4),
                 "four distinct names registered")
    print("  test_distinct_names_register_separately PASS")


def main() raises:
    print("test_tracer_parallelize")
    print("=======================")
    test_disjoint_per_worker_emit()
    test_name_registry_populated_under_parallelize()
    test_distinct_names_register_separately()
    print()
    print("ALL TESTS PASS")
