# =============================================================================
# komira_log.engine.span_context — per-worker span-id stack + id allocation.
# =============================================================================
#
# The per-worker context the unified span surface needs. One POD slot per worker,
# touched ONLY by its owning core — so the span-id stack push/pop + the id
# allocation are disjoint-per-worker with no atomics on the hot path (the SAME
# SPSC property the per-core log ring relies on).
#
# Each slot owns:
#   * a span-id STACK (for parent correlation) — `start_span` pushes the new
#     span_id; `end_span` pops; the parent of a new span is the stack top.
#     Capped at MAX_SPAN_DEPTH (mirrors obs MAX_DEPTH=16).
#   * a per-worker monotonic span-id COUNTER. To keep span_ids globally unique
#     WITHOUT a cross-thread atomic, each worker's counter is seeded into a
#     disjoint high-bit lane: `span_id = (worker_id << 48) | local_counter`.
#     The drain treats span_id as opaque; uniqueness across workers is by
#     construction (different high lane), and a single worker's window of
#     <2^48 spans is unreachable in practice.
#   * a per-worker trace_id witness (the low 8 bytes carry per-root uniqueness,
#     as the obs tracer does). A NEW trace_id is minted for each ROOT span (depth 0
#     at open); nested spans inherit the current trace_id so a whole call tree
#     shares one trace. The high 8 bytes are 0 in P4a (analyzer-opaque).
#
# Encapsulation: every field is a scalar or a fixed `InlineArray` — POD
# by construction, exactly the obs `WorkerContextSlot` shape. Lives in a
# `Slab[SpanContextSlot]` on the engine (the obs ring pattern); NO heap-owning
# inner field, NO `UnsafePointer`, NO wildcard origin.
# =============================================================================


# Per-worker span-id stack depth cap: the tracer's own constant, imported so
# the two stacks cannot disagree.
from komira_trace.tracer import MAX_SPAN_DEPTH

# The worker-id is laundered into the top 16 bits of a span_id so per-worker
# monotonic counters stay globally unique without a shared atomic.
comptime _SPAN_ID_WORKER_SHIFT: UInt64 = UInt64(48)


struct SpanContextSlot(
    Copyable, Movable, Deinitable
):
    # `Copyable` but not `ImplicitlyCopyable`: `InlineArray` is not
    # implicitly copyable, and a struct owning one cannot synthesise an
    # implicit copy ctor (a hand-written `__copyinit__` is not consulted).
    # Copies of this POD record are spelled `.copy()`, a plain memcpy.
    """Per-worker span-id stack + id/trace allocation state — POD.

    Disjoint per worker; the owning core is the only reader/writer, so the
    push/pop + counter bump need no synchronization (SPSC by construction).
    """

    # In-flight span-id stack (parent correlation). `depth` is the live count.
    var depth: UInt32
    var stack: Array[UInt64, MAX_SPAN_DEPTH]
    # Per-worker monotonic local span counter (low lane of the span_id).
    var span_counter: UInt64
    # The trace_id witness for the CURRENT root tree (low 8 bytes carry the
    # per-root uniqueness; high 8 bytes 0 in P4a).
    var trace_lo: UInt64
    var trace_hi: UInt64
    # Per-worker trace-counter — minted into a fresh trace_lo per root span.
    var trace_counter: UInt64
    # Cacheline tail to keep adjacent slots off the same line (false-sharing).
    var _pad: Array[UInt8, 32]

    def __init__(out self):
        self.depth = UInt32(0)
        self.stack = Array[UInt64, MAX_SPAN_DEPTH](fill=UInt64(0))
        self.span_counter = UInt64(0)
        self.trace_lo = UInt64(0)
        self.trace_hi = UInt64(0)
        self.trace_counter = UInt64(0)
        self._pad = Array[UInt8, 32](fill=UInt8(0))

    @always_inline
    def current_parent(self) -> UInt64:
        """The innermost in-flight span_id (the parent of a span opened now),
        or 0 when no span is open (the new span will be a root)."""
        var d = Int(self.depth)
        if d == 0:
            return UInt64(0)
        return self.stack[d - 1]

    @always_inline
    def alloc_span_id(mut self, worker_id: Int) -> UInt64:
        """Mint a new globally-unique span_id from this worker's lane."""
        self.span_counter += UInt64(1)
        var lane = UInt64(worker_id) << _SPAN_ID_WORKER_SHIFT
        return lane | self.span_counter

    def open(mut self, worker_id: Int, span_id: UInt64):
        """Push a newly-opened span. If this is a ROOT (no parent in flight),
        mint a fresh trace_id for the new tree; nested spans inherit the
        current trace_id (set when the root opened)."""
        if self.depth == UInt32(0):
            # Root span — mint a fresh trace for the whole subtree.
            self.trace_counter += UInt64(1)
            var lane = UInt64(worker_id) << _SPAN_ID_WORKER_SHIFT
            self.trace_lo = lane | self.trace_counter
            self.trace_hi = UInt64(0)
        var d = Int(self.depth)
        if d < MAX_SPAN_DEPTH:
            self.stack[d] = span_id
            self.depth = UInt32(d + 1)

    def close(mut self):
        """Pop the innermost span."""
        var d = Int(self.depth)
        if d > 0:
            self.depth = UInt32(d - 1)

    @always_inline
    def depth_of(self) -> Int:
        return Int(self.depth)
