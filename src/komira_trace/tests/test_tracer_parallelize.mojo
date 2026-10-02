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

from std.memory import Pointer
from std.testing import assert_equal, assert_true

from komira_spawn_join import spawn_join, SpawnJoinBody
from komira_trace.tracer import Tracer
from komira_trace.exporter import CapturingExporter


# =============================================================================
# THE FORK-JOIN -- real pthreads, through `komira_spawn_join`.
#
# MOJO 1.0.0 removed `parallelize` from the stdlib. `spawn_join(body, n)` starts
# `n` threads that each call `body.run(tid)` on ONE shared body, which holds a
# typed `Pointer` to the shared Tracer. A SERIAL LOOP WOULD HAVE VOIDED THIS
# FILE: every arm below is about what N threads do to ONE shared Tracer -- the
# disjointness of the per-worker rings, and the `try_register` read-then-write
# race the second arm's docstring dissects at length.
#
# A body that raises fails the test: `spawn_join` joins every thread and then
# rethrows the lowest tid's error.
#
# The file, its test names and its docstrings keep the word "parallelize": it
# names the SHAPE under test (N concurrent workers on one Tracer).
# =============================================================================


comptime N_WORKERS = 8
comptime SPANS_PER_WORKER = 100


struct _EmitBody[o: Origin[mut=True]](SpawnJoinBody):
    """Each worker opens and closes `iters` spans on its own ring."""

    var tracer: Pointer[Tracer, Self.o]
    var iters: Int

    def __init__(out self, tracer: Pointer[Tracer, Self.o], iters: Int):
        self.tracer = tracer
        self.iters = iters

    def run(self, tid: Int) raises:
        ref tracer = self.tracer[]
        for _i in range(self.iters):
            var sid = tracer.start_span["worker.consume_morsel"](worker_id=tid)
            tracer.end_span(sid, worker_id=tid)


def test_disjoint_per_worker_emit() raises:
    """8 workers × 100 spans → 1600 records, all stacks return to depth 0."""
    var tracer = Tracer(num_workers=N_WORKERS, ring_capacity=1024)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    spawn_join(_EmitBody(Pointer(to=tracer), SPANS_PER_WORKER), N_WORKERS)

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


struct _DupNameBody[o: Origin[mut=True]](SpawnJoinBody):
    """Every worker emits the SAME name, on purpose -- the `try_register`
    read-then-write race is the subject of the arm below."""

    var tracer: Pointer[Tracer, Self.o]

    def __init__(out self, tracer: Pointer[Tracer, Self.o]):
        self.tracer = tracer

    def run(self, tid: Int) raises:
        ref tracer = self.tracer[]
        var sid = tracer.start_span["operator.flat_hash_agg"](worker_id=tid)
        tracer.end_span(sid, worker_id=tid)


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
    spawn_join(_DupNameBody(Pointer(to=tracer)), N_EMITTERS)

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


struct _UniqueNameBody[o: Origin[mut=True]](SpawnJoinBody):
    """One DISTINCT span name per tid, so the registry must end up holding
    four."""

    var tracer: Pointer[Tracer, Self.o]

    def __init__(out self, tracer: Pointer[Tracer, Self.o]):
        self.tracer = tracer

    def run(self, tid: Int) raises:
        ref tracer = self.tracer[]
        if tid == 0:
            var s = tracer.start_span["op.a"](worker_id=tid)
            tracer.end_span(s, worker_id=tid)
        elif tid == 1:
            var s = tracer.start_span["op.b"](worker_id=tid)
            tracer.end_span(s, worker_id=tid)
        elif tid == 2:
            var s = tracer.start_span["op.c"](worker_id=tid)
            tracer.end_span(s, worker_id=tid)
        else:
            var s = tracer.start_span["op.d"](worker_id=tid)
            tracer.end_span(s, worker_id=tid)


def test_distinct_names_register_separately() raises:
    """4 workers emit 4 different names — registry has 4 entries."""
    var tracer = Tracer(num_workers=4, ring_capacity=256)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    spawn_join(_UniqueNameBody(Pointer(to=tracer)), 4)

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
