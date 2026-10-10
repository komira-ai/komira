# =============================================================================
# tracer.mojo — public Tracer API
# =============================================================================
#
# Public-API shape:
#
#   var tracer = Tracer(num_workers=N)            # production
#   var tracer = Tracer.testing(num_workers=N,    # test
#                               clock=mock_clock,
#                               ids=mock_ids)
#
#   # Hot-loop form (the in-pipeline API; the only form shipped):
#   var sid = tracer.start_span[name="engine.segment.execute"](
#       worker_id=wid, parent_id=parent
#   )
#   # ... work ...
#   tracer.end_span(span_id=sid, worker_id=wid)
#
# Per-worker state is a `Slab[WorkerContextSlot]` indexed by `tid`. There
# is no "with tracer.span(...)" block-scoped sugar: context-manager support
# inside a `@parameter parallelize` body is unverified, and explicit
# start/end is the canonical hot-path shape anyway.
#
# Comptime gating:
#
#   alias TRACES_ENABLED: Bool = True   # default
#
# Every public method on `Tracer` is wrapped in
# `@parameter if TRACES_ENABLED:`. When `TRACES_ENABLED == False`, the
# entire body comptime-elides, so the disabled build is `objdump`
# byte-identical to one with no tracing calls.
#
# Non-Movable: `Tracer` owns the per-worker context slab + ring buffers
# + name registry inline. The `OwnedPointer` indirection lives on the
# embedder side (EngineContext holds `Optional[OwnedPointer[Tracer]]`).
# =============================================================================

from std.collections import Dict

from komira_atomic_alias import AtomicU64

from komira_collections.slab import Slab

from komira_clock import now_ns as _platform_now_ns

from komira_trace.span_record import (
    SpanRecord,
    SpanLink,
    TRACE_ID_BYTES,
    DEFAULT_MAX_LINKS,
    SPAN_FLAG_ROOT,
    SPAN_FLAG_HAS_ERROR,
    SPAN_STATUS_OPEN,
    SPAN_STATUS_CLOSED,
)
from komira_trace.span_packet import (
    SpanPacket,
    PACKET_OPEN,
    PACKET_CLOSE,
)
from komira_trace.span_ring import SpanPacketRing
from komira_spsc_ring.spsc_ring import (
    OVERFLOW_BLOCK,
    OVERFLOW_DROP,
    DEFAULT_RING_CAPACITY,
)
from komira_name_registry import (
    MAX_REGISTERED_NAMES,
    NameRegistry,
    name_id as _literal_name_id,
)
from komira_trace.testing import MockClock, MockIdGenerator
from komira_trace.exporter import (
    CapturingExporter,
    JsonlFileExporter,
    format_span_jsonl,
)


# One bit per registry slot, so the per-worker "already registered" bitset
# covers every name the registry can hold.
comptime NAME_BITSET_WORDS: Int = (MAX_REGISTERED_NAMES + 63) // 64


# Comptime gate for the entire span emitter. Set to `False` to elide
# every public API call (the build is then byte-identical to a no-span
# baseline). Default is True.
comptime TRACES_ENABLED: Bool = True


# Context-stack depth per worker. Matches the spike (MAX_DEPTH=16).
comptime MAX_SPAN_DEPTH: Int = 16


# -----------------------------------------------------------------------------
# WorkerContextSlot — POD per-worker slot (mirrors spike B). Holds the
# in-flight span_id stack + a "names already registered by this worker"
# bitset to fast-path the lazy registration check.
# -----------------------------------------------------------------------------


struct WorkerContextSlot(Copyable, Movable, Deinitable):
    # MOJO-1.0.0: `ImplicitlyCopyable` DROPPED, `Copyable` kept. 1.0.0 makes
    # `InlineArray` non-implicitly-copyable, and a struct owning one cannot
    # synthesise an implicit copy ctor -- there is no manual override (a
    # hand-written `__copyinit__` is not consulted). Copies of this POD
    # record are now spelled `.copy()`; that is the SAME memcpy an implicit copy emitted
    # implicitly, so codegen and cost are unchanged.
    """Per-worker mock span-id stack + registration bitset.

    POD by construction — mirrors the SpanRecord shape.
    """

    var depth: UInt32
    var stack: Array[UInt64, MAX_SPAN_DEPTH]
    # Per-worker "names this worker has registered" bitset — fast-paths
    # the registry CAS on subsequent emits. NAME_BITSET_WORDS = 4.
    var names_registered: Array[UInt64, NAME_BITSET_WORDS]
    # Cacheline pad (192-byte slot reaches 128-byte alignment when
    # combined with above; explicit 32-byte tail prevents false sharing).
    var _pad: Array[UInt8, 32]

    def __init__(out self):
        self.depth = UInt32(0)
        self.stack = Array[UInt64, MAX_SPAN_DEPTH](fill=UInt64(0))
        self.names_registered = Array[UInt64, NAME_BITSET_WORDS](
            fill=UInt64(0)
        )
        self._pad = Array[UInt8, 32](fill=UInt8(0))

    @always_inline
    def check_and_set_name(mut self, name_id: UInt32) -> Bool:
        """Test-and-set the bit for `name_id`. Returns True if the bit
        was newly claimed (the bit was previously 0).

        IMPORTANT — bit-7 collisions:
            The bit position is `name_id & 0xFF`, so two distinct
            `name_id`s sharing the same low 8 bits map to the same bit.
            A True return therefore means "this worker has not yet
            claimed THIS specific bit", NOT "this worker has not yet
            registered THIS specific name". Callers that need
            collision-safe registration must do an additional
            `_name_registry.contains(name_id)` check on a False return
            and fall through to `try_register` if the registry doesn't
            yet hold the name. See `start_span` for the canonical use.

            Witness: `d1.finalize` (name_id=769941714) and
            `d1.insert_batch` (name_id=2407699666) both have
            `name_id & 0xFF == 210`. Bucketing by the low byte alone would
            silently skip registering the second-emitted name, producing
            `__id_<n>` placeholders in JSONL output.
        """
        # Mod-256 bucketing matches the registry's open-addressing
        # capacity. Thus bit position == name_id & 255.
        var bit = Int(name_id) & 0xFF
        var word = bit >> 6
        var mask = UInt64(1) << UInt64(bit & 63)
        var prev = self.names_registered[word]
        if (prev & mask) != UInt64(0):
            return False  # bit already claimed (possibly by a different name_id)
        self.names_registered[word] = prev | mask
        return True


# -----------------------------------------------------------------------------
# Tracer — the public-API facade.
# -----------------------------------------------------------------------------


struct Tracer(Deinitable):
    """Per-embedder tracer; owns the per-worker slabs + ring buffers +
    name registry.

    Non-Movable. Embedders construct via:

        var tracer = Tracer(num_workers=N)            # production
        var tracer = Tracer.testing(num_workers=N,     # test
                                    clock=mock_clock,
                                    ids=mock_ids)

    Lifetime: EngineContext should hold `Optional[OwnedPointer[Tracer]]`.
    Workers reach `tracer.start_span(...)` / `end_span(...)` via
    `Pointer(to=tracer)` capture (Repro 7 pattern).
    """

    var num_workers: Int

    # Per-worker context slots — the TLS-or-equivalent mechanism.
    # Disjoint per-worker writes; no atomics on the hot path.
    var _ctx_slab: Slab[WorkerContextSlot]

    # Per-worker SPSC rings — drain reads through these. They
    # carry 32-byte `SpanPacket`s instead of 192-byte `SpanRecord`s on
    # the hot path; the producer writes one OPEN packet per `start_span`
    # and one CLOSE packet per `end_span`, and the drain (single-thread)
    # joins matching pairs by `span_id` to reconstruct the JSONL record.
    # 6x smaller per-slot copy, for a <100ns/op span.
    var _rings: Slab[SpanPacketRing]

    # Process-shared name registry (`name_registry.mojo`).
    var _name_registry: NameRegistry

    # Test-injectable clock + id source. MockClock is Movable so
    # Optional is fine; MockIdGenerator owns Atomic so we hold it via
    # OwnedPointer (Optional requires Movable).
    var _mock_clock: Optional[MockClock]
    var _has_mock_ids: Bool
    var _mock_ids_seed_trace: UInt64  # snapshot for production fallback
    var _mock_ids_seed_span: UInt64

    # Production id generator — atomic counters when no mock is
    # injected. Also drives the testing path (the seed values above
    # are loaded into these counters at testing() construction).
    var _trace_counter: AtomicU64
    var _span_counter: AtomicU64
    # Backpressure policy snapshot at construction.
    var _overflow_policy: UInt8

    def __init__(
        out self,
        num_workers: Int,
        ring_capacity: Int = DEFAULT_RING_CAPACITY,
        overflow_policy: UInt8 = OVERFLOW_BLOCK,
    ) raises:
        if num_workers <= 0:
            raise Error("Tracer: num_workers must be > 0")
        self.num_workers = num_workers
        self._ctx_slab = Slab[WorkerContextSlot].create_prefilled(num_workers)
        self._rings = Slab[SpanPacketRing].create_with_capacity(num_workers)
        for _w in range(num_workers):
            self._rings.append(SpanPacketRing(ring_capacity, overflow_policy))
        self._name_registry = NameRegistry()
        self._mock_clock = Optional[MockClock]()
        self._has_mock_ids = False
        self._mock_ids_seed_trace = UInt64(0)
        self._mock_ids_seed_span = UInt64(0)
        self._trace_counter = AtomicU64(UInt64(1))
        self._span_counter = AtomicU64(UInt64(1))
        self._overflow_policy = overflow_policy

    def install_mock_clock(mut self, var clock: MockClock):
        """Test helper. Replace the production timestamp source with a
        deterministic mock. Must be called before any worker emits.
        """
        self._mock_clock = Optional[MockClock](clock^)

    def install_mock_ids(
        mut self, trace_seed: UInt64, span_seed: UInt64
    ):
        """Test helper. Replace the production id counters with seeded
        deterministic values. Implemented as a counter reset rather
        than holding a separate MockIdGenerator (which would need
        OwnedPointer indirection because it owns Atomic fields).
        """
        self._has_mock_ids = True
        self._mock_ids_seed_trace = trace_seed
        self._mock_ids_seed_span = span_seed
        # Reset the production counters to the seed values so the
        # deterministic test path uses them directly. SAFETY: the
        # counters are private and we own `mut self` here.
        self._trace_counter = AtomicU64(trace_seed)
        self._span_counter = AtomicU64(span_seed)

    # -------------------------------------------------------------------------
    # Hot-path API (per-worker)
    # -------------------------------------------------------------------------

    @always_inline
    def _now_ns(self) -> UInt64:
        if self._mock_clock:
            return self._mock_clock.value().now()
        # Platform-specific user-space monotonic clock — see
        # `komira_clock`. Not `perf_counter_ns()` (a syscall,
        # ~25-50ns each on M-series): a libSystem / vDSO call
        # (~5-15ns).
        return _platform_now_ns()

    def _next_span_id(mut self) -> UInt64:
        # `install_mock_ids` resets the same Atomic counter to a
        # deterministic seed, so this single path covers both
        # production and test flows.
        return self._span_counter.fetch_add(UInt64(1))

    def _next_trace_id(mut self) -> Array[UInt8, TRACE_ID_BYTES]:
        # Low 8 bytes from atomic counter; high 8 bytes 0 (the
        # analyzer treats trace_id as opaque). A random source could
        # replace the counter for non-test paths.
        var v = self._trace_counter.fetch_add(UInt64(1))
        var out = Array[UInt8, TRACE_ID_BYTES](fill=UInt8(0))
        for i in range(8):
            out[i] = UInt8(Int(v) & 0xFF)
            v = v >> 8
        return out^

    def start_span[name: StringLiteral](
        mut self,
        worker_id: Int,
        parent_id: UInt64 = UInt64(0),
    ) -> UInt64:
        """Open a span. Returns the new span_id.

        `name` is comptime — the FNV-1a digest is a literal at the call
        site. First emit per-worker also CAS-inserts into the registry.

        Returns 0 if `TRACES_ENABLED` is false (the call comptime-elides
        to a no-op).

        Writes a 32-byte `SpanPacket` (kind=OPEN) to the
        per-worker ring instead of a 192-byte `SpanRecord`. The drain
        joins OPEN+CLOSE pairs by `span_id` at JSONL render time.
        """
        comptime if not TRACES_ENABLED:
            return UInt64(0)

        comptime name_id = _literal_name_id[name]()

        # Lazy registration: first emit per (worker, name) inserts into
        # the process registry. The bitset check is a single load+mask.
        # On bitset-hit we MUST disambiguate a low-8-bit collision (see
        # WorkerContextSlot.check_and_set_name): a `False` return from
        # check_and_set_name only means "this worker has already claimed
        # the bit for SOME name with the same `& 0xFF`", not "this
        # worker has already registered THIS name". A cheap registry
        # `contains` probe (allocation-free, O(1) under 50% load) covers
        # the collision case. `try_register` is a no-op when the entry
        # already holds this exact name_id, so the worst case on a
        # bitset-hit + registry-miss is one safe extra CAS-insert.
        ref slot = self._ctx_slab.get_mut_interior(worker_id)
        if slot.check_and_set_name(name_id):
            _ = self._name_registry.try_register[name]()
        elif not self._name_registry.contains(name_id):
            # Bitset says "claimed" but the registry doesn't hold
            # THIS name — a different name with the same `& 0xFF`
            # got there first. Force the registration through.
            _ = self._name_registry.try_register[name]()

        # Allocate ids + low-32 trace_id witness for the packet.
        var span_id = self._next_span_id()
        var trace_lo = UInt32(self._trace_counter.fetch_add(UInt64(1)) & UInt64(0xFFFFFFFF))
        var flags16 = UInt16(0)
        if parent_id == UInt64(0):
            flags16 = flags16 | UInt16(1)  # SPAN_FLAG_ROOT mirror in low byte

        # Push onto the per-worker stack.
        var d = Int(slot.depth)
        if d < MAX_SPAN_DEPTH:
            slot.stack[d] = span_id
            slot.depth = UInt32(d + 1)

        # Publish a compact OPEN packet (32-byte slot copy). try_push
        # handles overflow per policy.
        var packet = SpanPacket.open(
            span_id,
            parent_id,
            name_id,
            self._now_ns(),
            UInt16(worker_id),
            flags16,
            trace_lo,
        )
        ref ring = self._rings.get_mut_interior(worker_id)
        _ = ring.try_push(packet)

        return span_id

    def end_span(mut self, span_id: UInt64, worker_id: Int):
        """Close a span. Emits a CLOSE packet carrying `end_ns`.

        Writes a 32-byte `SpanPacket` (kind=CLOSE). The drain joins
        OPEN+CLOSE pairs by `span_id` at JSONL render time.
        """
        comptime if not TRACES_ENABLED:
            return

        ref slot = self._ctx_slab.get_mut_interior(worker_id)
        var d = Int(slot.depth)
        if d > 0:
            slot.depth = UInt32(d - 1)

        var packet = SpanPacket.close(
            span_id,
            self._now_ns(),
            UInt16(worker_id),
        )
        ref ring = self._rings.get_mut_interior(worker_id)
        _ = ring.try_push(packet)

    @always_inline
    def current_span(self, worker_id: Int) -> UInt64:
        """Return the innermost in-flight span_id for this worker."""
        ref slot = self._ctx_slab.get_mut_interior(worker_id)
        var d = Int(slot.depth)
        if d == 0:
            return UInt64(0)
        return slot.stack[d - 1]

    @always_inline
    def depth_of(self, worker_id: Int) -> Int:
        ref slot = self._ctx_slab.get_mut_interior(worker_id)
        return Int(slot.depth)

    # -------------------------------------------------------------------------
    # Drain / capture API (called from a single drain thread)
    # -------------------------------------------------------------------------

    def _join_packets_to_records(mut self) -> List[SpanRecord]:
        """Drain every per-worker ring of packets and join OPEN+CLOSE
        pairs by span_id into reconstructed SpanRecords.

        Off the hot path, but it runs on every drain (`drain_into_jsonl`
        in production), so it is O(packets): the OPEN pass records each
        span_id's record index in a `Dict`, and each CLOSE is one lookup.

        Returns one `SpanRecord` per OPEN packet observed; if a matching
        CLOSE was observed in the same drain, `end_ns` is set, otherwise
        it stays 0 (still-open span at drain time). A CLOSE whose OPEN is
        not in this drain matches nothing and is dropped (no record).
        """
        var records = List[SpanRecord]()
        # First pass: collect all packets across all workers.
        var packets = List[SpanPacket]()
        for w in range(self.num_workers):
            ref ring = self._rings.get_mut_interior(w)
            while True:
                var maybe = ring.try_pop()
                if not maybe:
                    break
                packets.append(maybe.value().copy())

        # Index OPEN packets first; then walk CLOSE packets and patch
        # end_ns into the matching SpanRecord.
        # PERF-CRITICAL: the CLOSE pass is one Dict lookup per packet. It
        # was a linear scan over `records` per CLOSE, O(n^2) per drain:
        # 10,000 spans cost 5e7 comparisons, which is what the drain
        # throughput test measured. Do not reintroduce a scan.
        # `index` keeps the FIRST record per span_id (the old scan's
        # first-match rule); span ids come from one atomic counter, so a
        # duplicate needs `install_mock_ids` to re-seed mid-window.
        var index = Dict[UInt64, Int]()
        for i in range(len(packets)):
            var p = packets[i].copy()
            if p.kind == PACKET_OPEN:
                var rec = SpanRecord()
                # Reconstruct the trace_id witness — low 4 bytes from
                # the packet, high 12 bytes left zero (analyzer-window
                # uniqueness is sufficient).
                var v = p.trace_id_lo
                for j in range(4):
                    rec.trace_id[j] = UInt8(Int(v) & 0xFF)
                    v = v >> 8
                rec.span_id = p.span_id
                rec.parent_id = p.parent_id
                rec.name_id = p.name_id
                rec.start_ns = p.ts_ns
                rec.end_ns = UInt64(0)
                rec.worker_id = UInt32(p.worker_id)
                rec.flags = UInt32(p.flags)
                rec.status = SPAN_STATUS_OPEN
                if p.span_id not in index:
                    index[p.span_id] = len(records)
                records.append(rec^)

        for i in range(len(packets)):
            ref p = packets[i]
            if p.kind == PACKET_CLOSE:
                var hit = index.get(p.span_id)
                if hit:
                    var j = hit.value()
                    records[j].end_ns = p.ts_ns
                    records[j].status = SPAN_STATUS_CLOSED

        return records^

    def drain_into_capture(mut self, mut exporter: CapturingExporter):
        """Drain every per-worker ring into a CapturingExporter (test
        helper). Drains until all rings are empty.
        """
        var records = self._join_packets_to_records()
        for i in range(len(records)):
            exporter.capture(records[i])

    def drain_into_jsonl(mut self, mut exporter: JsonlFileExporter) raises:
        """Drain every per-worker ring into a JsonlFileExporter."""
        exporter.flush_name_registry(self._name_registry)
        var records = self._join_packets_to_records()
        for i in range(len(records)):
            exporter.flush_record(records[i], self._name_registry)

    @always_inline
    def name_registry_count(self) -> Int:
        return self._name_registry.count()

    @always_inline
    def ring_size(self, worker_id: Int) -> Int64:
        ref ring = self._rings.get_mut_interior(worker_id)
        return ring.approximate_size()
