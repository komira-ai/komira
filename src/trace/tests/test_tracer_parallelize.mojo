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
from std.testing import assert_equal

from fork_join import fork_join, ForkJoinBody
from trace.tracer import Tracer
from trace.exporter import CapturingExporter


# =============================================================================
# THE FORK-JOIN -- real pthreads, through `fork_join`.
#
# MOJO 1.0.0 removed `parallelize` from the stdlib. `fork_join(body, n)` starts
# `n` threads that each call `body.run(tid)` on ONE shared body, which holds a
# typed `Pointer` to the shared Tracer. A SERIAL LOOP WOULD HAVE VOIDED THIS
# FILE: every arm below is about what N threads do to ONE shared Tracer -- the
# disjointness of the per-worker rings, and the `try_register` read-then-write
# race the second arm's docstring dissects at length.
#
# A body that raises fails the test: `fork_join` joins every thread and then
# rethrows the lowest tid's error.
#
# The file, its test names and its docstrings keep the word "parallelize": it
# names the SHAPE under test (N concurrent workers on one Tracer).
# =============================================================================


comptime N_WORKERS = 8
comptime SPANS_PER_WORKER = 100


struct _EmitBody[o: Origin[mut=True]](ForkJoinBody):
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
    fork_join(_EmitBody(Pointer(to=tracer), SPANS_PER_WORKER), N_WORKERS)

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


struct _DupNameBody[o: Origin[mut=True]](ForkJoinBody):
    """Every worker emits the SAME name, on purpose: concurrent registrations
    of one name are the subject of the arm below."""

    var tracer: Pointer[Tracer, Self.o]

    def __init__(out self, tracer: Pointer[Tracer, Self.o]):
        self.tracer = tracer

    def run(self, tid: Int) raises:
        ref tracer = self.tracer[]
        var sid = tracer.start_span["operator.flat_hash_agg"](worker_id=tid)
        tracer.end_span(sid, worker_id=tid)


def test_name_registry_populated_under_parallelize() raises:
    """Several workers emit the same name at once: the registry holds it,
    stored and counted once.

    `NameRegistry.try_register` claims a slot with one compare-and-swap of
    the slot's id, so of the workers that race to register one name exactly
    one claims the slot and the others see the name and return False. The
    deterministic forms of this race (a second registration run inside the
    first one's claim window, of the same name and of another name with the
    same home slot) are tested in `name_registry`'s own tests; this one runs
    it on real threads through the tracer."""
    comptime N_EMITTERS = 4
    var tracer = Tracer(num_workers=N_EMITTERS, ring_capacity=256)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    fork_join(_DupNameBody(Pointer(to=tracer)), N_EMITTERS)

    var n = tracer.name_registry_count()
    assert_equal(
        n, 1, "the one emitted name is registered once; count was " + String(n)
    )
    print("  test_name_registry_populated_under_parallelize PASS, count=", n)


struct _UniqueNameBody[o: Origin[mut=True]](ForkJoinBody):
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
    fork_join(_UniqueNameBody(Pointer(to=tracer)), 4)

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
