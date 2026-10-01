# =============================================================================
# testing.mojo — first-class test infrastructure
# =============================================================================
#
# Mandatory test-isolation contract:
#
#   1. No process-global singletons. Every Tracer is constructed by the
#      embedder (or by the test body).
#   2. `MockClock` / `MockIdGenerator` are first-class types, not
#      optional debug helpers; the package's own unit tests use them.
#   3. `obs_test_scope()`-shaped helper sets up a fresh Tracer +
#      CapturingExporter + MockClock, tears down on exit.
#
# `MockClock` and `MockIdGenerator` are non-Movable so they can be held
# by `Tracer` via `OwnedPointer[Self]`. The constructor injection model
# matches the production `ClockSource` / `IdGenerator` traits used by
# the real Tracer.
# =============================================================================

from komira_atomic_alias import AtomicU64
from std.memory import OwnedPointer

from komira_obs.span_record import (
    SpanRecord,
    TRACE_ID_BYTES,
)


# -----------------------------------------------------------------------------
# MockClock — deterministic timestamp source. `tick(ns)` advances; `now()`
# returns the current value.
# -----------------------------------------------------------------------------


struct MockClock(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Deterministic clock for span timing assertions.

    Replaces `perf_counter_ns()` via constructor injection on `Tracer`.
    Tests advance time with `tick(ns)`; `now()` returns the current ns.
    """

    var _now_ns: UInt64

    def __init__(out self, start_ns: UInt64 = UInt64(0)):
        self._now_ns = start_ns

    @always_inline
    def now(self) -> UInt64:
        return self._now_ns

    @always_inline
    def tick(mut self, ns: UInt64):
        self._now_ns += ns

    def set(mut self, ns: UInt64):
        self._now_ns = ns


# -----------------------------------------------------------------------------
# MockIdGenerator — deterministic id factory. Seeded counter; returns
# monotonically-increasing trace_ids and span_ids.
# -----------------------------------------------------------------------------


struct MockIdGenerator(Deinitable):
    """Deterministic ID generator for trace_id / span_id.

    Replaces the random/UUID-shaped real generator via constructor
    injection. Backed by two Atomic counters so concurrent worker
    callers stay disjoint.
    """

    var _trace_seed: AtomicU64
    var _span_seed: AtomicU64

    def __init__(
        out self, trace_start: UInt64 = UInt64(1), span_start: UInt64 = UInt64(1)
    ):
        self._trace_seed = AtomicU64(trace_start)
        self._span_seed = AtomicU64(span_start)

    def next_trace_id(mut self) -> Array[UInt8, TRACE_ID_BYTES]:
        var id_lo = self._trace_seed.fetch_add(UInt64(1))
        var out = Array[UInt8, TRACE_ID_BYTES](fill=UInt8(0))
        # Encode `id_lo` into the low 8 bytes (little-endian); high 8
        # bytes left zero (deterministic; tests assert against this).
        var v = id_lo
        for i in range(8):
            out[i] = UInt8(Int(v) & 0xFF)
            v = v >> 8
        return out^

    def next_span_id(mut self) -> UInt64:
        return self._span_seed.fetch_add(UInt64(1))

    @always_inline
    def peek_trace(self) -> UInt64:
        return self._span_seed.load()  # for diagnostics only
