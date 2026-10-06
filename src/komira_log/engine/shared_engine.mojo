# =============================================================================
# komira_log.engine.shared_engine — the per-core binary log engine (P2b).
# =============================================================================
#
# The forever-root-owned engine instance. ONE per
# process, owned by the forever-root (EngineContext / the long-lived
# service processes), sized to `num_workers`. It bundles everything the ambient log path
# touches:
#
#   * N per-worker SPSC `LogRecordRing`s (one per substrate worker) — produced
#     into by the owning core during work, drained by the SAME core when idle.
#     Stored in a `Slab[LogRecordRing]` (the `komira_trace` `Tracer._rings`
#     shape; `LogRecordRing` is Movable and is appended to the slab).
#   * The `SiteDictionary` — `site_id → fmt`, `module_id → module`, built by the
#     SAME comptime digests the emit path computes (keys match by construction).
#   * The `CalibrationAnchor` — drain-side raw-tick → wall-time conversion.
#     Held behind an `OwnedPointer[Atomic]`-free POD slot but mutated through a
#     `refresh_anchor()` call (~1 Hz) by a runtime task.
#   * The global relaxed-atomic level gate + the per-module `EnvFilter` (moved
#     here from the P1 `LogConfig` — the facade reads them the SAME way).
#   * The `LogSink` the drain writes decoded lines to (P3: stderr / single file
#     / per-core segments + rotation). The dev default is
#     stderr; production installs per-core segments via `set_sink`.
#   * The pthread TLS key for the ambient worker_id read.
#
# # Backpressure policy
#
# Per-ring-class, reusing the obs ring's BLOCK/DROP verbatim:
#   * Per-worker DATAPLANE rings [0, num_workers): `OVERFLOW_DROP` — a full ring
#     drops the record (counted in `_overflow_dropped`) rather than blocking a
#     query worker. Logging must never stall the dataplane.
#   * The non-worker FALLBACK ring [num_workers]: `OVERFLOW_BLOCK` — the
#     non-worker producer spins until a slot frees (non-worker logs are rare
#     + correctness > throughput there).
#   * WARN AND ERROR records are NEVER dropped — if a DROP ring rejects such a
#     push, the emit path escalates to a synchronous render+write via
#     `escalate_line` ("never drop WARN/ERROR ... escalate to a synchronous
#     slow-path"). It also triggers a sink flush for crash-tail safety.
#
#     ⚠ WARN IS IN THE GUARANTEE, NOT ONLY ERROR. An escalation gated
#     `level >= LEVEL_ERROR` would lose every dropped WARN. And it is not only
#     the FACADE that escalates: the typed `Logger` surface checks its push
#     result too. Both surfaces route through the same `admits` gate and the
#     same escalation, at the same level.
#
# # The ambient reach
#
# A bare `log.info(...)` from ANY thread resolves the engine via the
# process-global `LogManager` (an address in a C cell, set ONCE at init),
# reads its `worker_id` from TLS, and pushes the binary record into
# `engine.ring(wid)`. A non-worker thread (TLS unset → WORKER_ID_UNSET) routes
# to the synchronous-direct fallback (`emit_fallback_line`) so a log from the
# job supervisor heartbeat / an HTTP handler / a CLI tool with no runtime never crashes
# and is never silently dropped on an undrained ring.
#
# # Encapsulation
#
# Every field is either a `Slab` (the obs ring pattern), a plain owned
# struct/`List`-backed dictionary (the List is the owner, NEVER byte-slab-
# stored), a POD scalar, or an `OwnedPointer[Atomic]` (the non-Movable-payload
# pattern). NO `UnsafePointer` field, NO wildcard-origin field, NO heap-owning
# field inside a byte-slab. The `LogEventRecord`s on the rings are POD
# (see log_event_record.mojo).
# =============================================================================

from komira_atomic_alias import AtomicI64, AtomicU8
from std.builtin.swap import swap
from std.memory import alloc, UnsafePointer, OwnedPointer

from komira_core.collections import Slab

from komira_spsc_ring.spsc_ring import (
    DEFAULT_RING_CAPACITY,
    OVERFLOW_BLOCK,
    OVERFLOW_DROP,
)
from komira_clock import now_unix_ms


# ~1 Hz calibration re-anchor cadence. The drain's
# raw-tick→wall conversion drifts as the counter / NTP wall clock diverge; a
# re-anchor this often keeps the conversion accurate without measurable cost.
comptime _ANCHOR_REFRESH_MS: Int64 = Int64(1000)

# End-of-query final-flush budget for `drain_captured_spans`. Large
# enough to drain any realistic per-worker ring tail in one pass; the drain
# loop stops early on the first empty pop, so this is just an upper bound.
comptime _FINAL_FLUSH_BUDGET: Int = 1 << 30

# DEFAULT per-worker retained-span buffer ceiling.
#
# DERIVED, NOT PICKED: four ring-fulls. The retained buffer is a HANDOFF
# WINDOW between the drain and `take_span_lines`, not a store; if more than
# four ring-capacities' worth of completed spans have accumulated without a
# consumer taking them, there is no consumer, and the buffer is a leak rather
# than a queue. Bounding it converts "a process that enabled span capture and
# forgot to drain it grows without limit" into a counted, diagnosable gap
# (`spans_dropped_count`).
#
# ⚠ THE CEILING IS A FIELD, NOT THIS CONSTANT. `set_span_buf_max` overrides it
# per engine — both so a long-lived service can size its own retention and,
# bluntly, so the cap is TESTABLE: a policy that silently drops telemetry and
# is only reachable after 16,384 spans is a policy nothing will ever falsify.
comptime _SPAN_BUF_MAX: Int = 4 * DEFAULT_RING_CAPACITY

# DEFAULT per-worker retained-METRIC buffer ceiling.
#
# The same number for the same reason (four ring-fulls: a handoff window, not a
# store), and the bound matters MORE here than it does for spans. Spans are
# event-driven and stop when traffic stops; metrics are PERIODIC, so a process
# that enables capture and forgets to call `take_metric_points` leaks forever at
# a constant rate, with nothing to notice it. Overflow degrades to a counted
# drop (`metrics_dropped_count`); the drain never stalls.
comptime _METRIC_BUF_MAX: Int = 4 * DEFAULT_RING_CAPACITY

from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_INFO, LEVEL_ERROR
from komira_log.engine.output_sink import LogSink
from komira_log.engine.rotation import RotationPolicy
from komira_log.engine.log_event_record import (
    LogEventRecord,
    REC_LOG,
    REC_SPAN_OPEN,
    REC_SPAN_CLOSE,
    REC_METRIC,
)
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.site_dictionary import SiteDictionary
from komira_log.engine.calibration import (
    CalibrationAnchor,
    capture_anchor,
    read_raw_ticks,
)
from komira_log.engine.drain import decode_one, decode_one_to_view
from komira_log.engine.log_record_view import LogRecordView
from komira_log.engine.span_context import SpanContextSlot
from komira_log.engine.span_emit import build_span_open, build_span_close
from komira_log.engine.metric_emit import (
    decode_metric_point,
    metric_record_is_decodable,
)

from komira_metrics.metric_point import MetricPoint
from komira_log.engine.span_drain import (
    OpenSpanTable,
    UnifiedDrainResult,
    drain_unified,
)
from komira_log.engine.worker_id_tls import (
    create_worker_id_key,
    delete_worker_id_key,
    set_worker_id,
    current_worker_id,
    WORKER_ID_UNSET,
)


struct SharedEngine(Movable):
    """The forever-root-owned per-core binary log engine.

    Owns N per-worker SPSC rings + the decoder dictionary + the calibration
    anchor + the level gate + the stderr sink + the TLS key. Lives for the
    process (created once at init, torn down once at exit after all ambient
    readers are quiescent). Reached ambiently via `GlobalEngineHandle`.
    """

    var _num_workers: Int
    # N+1 rings: [0, num_workers) per-worker; [num_workers] is the MPSC fallback
    # backstop ring (kept for design symmetry; the fallback emit path is
    # synchronous-direct, see emit_fallback_line).
    var _rings: Slab[LogRecordRing]
    # Per-worker span context (the span-id stack + per-worker id/trace
    # allocation). Disjoint per worker, touched only by its owning core — the
    # SAME SPSC discipline the per-core rings rely on (the obs Tracer
    # `_ctx_slab` shape). POD slots in a Slab, so no stale-pointer hazard.
    var _span_ctx: Slab[SpanContextSlot]
    # Drain-side OPEN/CLOSE correlator for the unified span drain. Lives on the
    # engine because OPEN and CLOSE for one span can drain in DIFFERENT batches
    # (different idle windows) — the table holds pending OPENs across batches.
    # Drain-thread-only (the worker that owns the ring also drains it), so no
    # synchronization is needed.
    var _open_spans: OpenSpanTable
    var _dict: SiteDictionary
    # Calibration anchor behind a stable heap slot so the ~1 Hz refresh task can
    # mutate it through the ambient handle without moving the engine. POD anchor;
    # OwnedPointer keeps the address stable + the engine Movable.
    var _anchor: OwnedPointer[CalibrationAnchor]
    # The relaxed-atomic global level gate (moved from P1 LogConfig). One relaxed
    # load + branch on the hot path. Non-Movable Atomic → OwnedPointer wrap.
    var _global_level: OwnedPointer[AtomicU8]
    var _filter: EnvFilter
    var _sink: LogSink
    var _tls_key: UInt64
    var _enabled: Bool
    # Retained span collector. When `_capture_spans` is on, the
    # worker-loop drain (`drain_worker`) routes a completed SPAN line into the
    # per-worker `_span_buf[wid]` retained buffer INSTEAD of the output sink,
    # so the post-query `drain_traces_to_jsonl` reads the lines the continuous
    # idle-loop drain accumulated (the rings are already empty by then — the
    # idle loop wins the race). Default OFF so a pure logging engine (control-
    # plane ambient, no EngineContext / no trace consumer) retains nothing →
    # no unbounded growth. The owning trace-drain consumer (EngineContext)
    # flips it on via `set_capture_spans`. The buffer is per-worker, sized to
    # the ring count (N workers + 1 fallback), matching the `for w in
    # range(n+1)` drain loop. `List[String]` (owned) — no pointer.
    var _capture_spans: Bool
    var _span_buf: List[List[String]]
    # the ceiling on ONE worker's retained buffer. See `_SPAN_BUF_MAX`.
    var _span_buf_max: Int
    # the METRIC return channel. The same per-worker, drain-thread-only,
    # take-to-hand-off shape established for spans, with ONE difference that
    # is the whole reason it is a separate field rather than a reuse: the
    # payload is `MetricPoint` (POD), NOT a rendered String. A metric's egress
    # form is POD all the way to the exporter; rendering at the drain is the
    # dead end the data-model design rules out. The channel is shared, the
    # payload type is not.
    #
    # Separate gate from `_capture_spans` on purpose: a service that wants
    # traces does not thereby want metrics retained in-process, and a single
    # gate would make one an unavoidable side effect of the other. Default OFF —
    # a pure logging engine retains nothing and grows nothing.
    #
    # `List[List[MetricPoint]]` is heap-owned by the Lists and lives on a
    # normal struct field, never inside a byte-backed slab. `MetricPoint` itself
    # is scalars only. No pointer, no wildcard origin.
    var _capture_metrics: Bool
    var _metric_buf: List[List[MetricPoint]]
    var _metric_buf_max: Int
    # Wall-clock ms of the last calibration re-anchor. The ~1 Hz refresh task
    # (the worker-0 idle hook) calls
    # `maybe_refresh_anchor`, which re-anchors only when ≥ _ANCHOR_REFRESH_MS
    # has elapsed — so the drain's raw-tick→wall conversion stays accurate over
    # long runs without paying a per-idle-hook re-capture.
    var _last_anchor_ms: Int64

    # -------------------------------------------------------------------------
    # SINK-ERROR EVIDENCE. Three sites swallow a sink error --
    # `drain_worker`, `emit_fallback_line`, `escalate_line`. Swallowing is the
    # right POLICY (a logger must never wedge a worker loop on a transient sink
    # error) but it must not be silent, and `LogSink` keeps no counter of its
    # own. These two are those counters.
    #
    # ⚠ THE TWO ARE DIFFERENT FACTS AND MUST NOT BE SUMMED. A refused WRITE is
    # a LOST LINE. A refused FLUSH means the line DID land and is merely not
    # durable yet -- which matters only for `escalate_line`'s crash-tail
    # promise, and reading it as a loss would overstate the damage.
    #
    # SAFETY: `Atomic` is non-Movable and `SharedEngine` is Movable, so the
    # payload is heap-owned through `OwnedPointer` -- the pattern
    # `_global_level` already uses. Atomic rather than a plain `Int64` because
    # the drain thread and arbitrary non-worker threads both increment.
    var _sink_dropped: OwnedPointer[AtomicI64]
    var _sink_flush_failures: OwnedPointer[AtomicI64]

    def __init__(out self, num_workers: Int, var filter: EnvFilter) raises:
        if num_workers <= 0:
            raise Error("SharedEngine: num_workers must be > 0")
        self._num_workers = num_workers

        # N per-worker rings + 1 fallback ring slot.
        var n_rings = num_workers + 1
        self._rings = Slab[LogRecordRing].create_with_capacity(n_rings)
        for w in range(n_rings):
            # Per-ring-class backpressure: the per-worker
            # DATAPLANE rings DROP (never stall query work); the [num_workers]
            # non-worker FALLBACK ring BLOCKs (non-worker logs are rare +
            # correctness > throughput). ERROR records bypass DROP via the
            # facade's `escalate_line` slow-path (never-dropped).
            var policy = OVERFLOW_DROP if w < num_workers else OVERFLOW_BLOCK
            self._rings.append(
                LogRecordRing(
                    capacity=DEFAULT_RING_CAPACITY, overflow_policy=policy
                )
            )

        # Per-worker span context (N slots; the fallback slot does not run
        # spans — a non-worker thread has no per-core ring to drain, so spans
        # are a worker-thread-only surface in P4a). Sized to num_workers.
        self._span_ctx = Slab[SpanContextSlot].create_prefilled(num_workers)
        self._open_spans = OpenSpanTable()

        self._dict = SiteDictionary()

        var raw_anchor = alloc[CalibrationAnchor](1)
        raw_anchor.unsafe_write(capture_anchor())
        self._anchor = OwnedPointer[CalibrationAnchor](
            unsafe_from_raw_pointer=raw_anchor
        )

        var raw_lvl = alloc[AtomicU8](1)
        raw_lvl[] = AtomicU8(filter.global_level)
        self._global_level = OwnedPointer[AtomicU8](
            unsafe_from_raw_pointer=raw_lvl
        )

        self._filter = filter^
        # Dev default: stderr. Production installs per-core segments via
        # `set_sink_per_core_segments` (P3) at EngineContext init.
        self._sink = LogSink.stderr()
        self._tls_key = create_worker_id_key()
        self._enabled = True
        # Retained span collector, off by default (no retention for a
        # pure logging engine). One buffer per ring (N workers + 1 fallback).
        self._capture_spans = False
        self._span_buf = List[List[String]]()
        for _ in range(n_rings):
            self._span_buf.append(List[String]())
        self._span_buf_max = _SPAN_BUF_MAX
        # the metric return channel, off by default, one buffer per ring.
        self._capture_metrics = False
        self._metric_buf = List[List[MetricPoint]]()
        for _ in range(n_rings):
            self._metric_buf.append(List[MetricPoint]())
        self._metric_buf_max = _METRIC_BUF_MAX
        self._last_anchor_ms = now_unix_ms()

        var raw_drop = alloc[AtomicI64](1)
        raw_drop[] = AtomicI64(Int64(0))
        self._sink_dropped = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw_drop
        )
        var raw_flush = alloc[AtomicI64](1)
        raw_flush[] = AtomicI64(Int64(0))
        self._sink_flush_failures = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw_flush
        )

    # There is no process-static handle to clear: the ambient global is the
    # immortal LogManager engine (never destroyed), and a per-context engine is
    # owned by its EngineContext. The compiler-synthesized destructor drops the
    # heap-owning fields (Slabs / OwnedPointers / Lists) in declaration order.
    #
    # ★ THE DESTRUCTOR BODY EXISTS FOR ONE FIELD, AND ONE ONLY: `_tls_key`. The
    # body below adds NO field teardown, and the compiler still drops every
    # field, in declaration order, after this body returns.

    def __deinit__(deinit self):
        """Give the pthread TLS key back. Cannot raise (destructors are noexcept).

        ★ WHY A DESTRUCTOR IS THE ONLY PLACE THIS CAN LIVE. `__init__` takes a
        key out of a PROCESS-WIDE pool of `PTHREAD_KEYS_MAX` (512 on macOS,
        1024 on glibc), and an engine that never returned it would cap the
        number of engines a process can ever build. An embedder that builds one
        `EngineContext` (and so one `SharedEngine`) PER CALL would then hit
        `pthread_key_create` EAGAIN after a few hundred calls. Falsifier:
        `tests/test_shared_engine_tls_key_reclaimed.mojo`.

        ⚠ THE ORDERING THIS DEPENDS ON, AND WHY IT HOLDS BY CONSTRUCTION.
        Deleting the key is only safe once every thread that BOUND a worker id
        into it is gone. `EngineContext` declares `_runtime`
        (`PerCoreAsyncRuntime`, whose own `__del__` signals shutdown and
        `pthread_join`s every worker) BEFORE `_log_engine`, and Mojo drops
        fields IN DECLARATION ORDER (see `komira_async`'s runtime).
        So every worker is joined before this body runs. It is a property of the
        FIELD ORDER, not of a convention a caller must remember — but it is the
        reason `_log_engine` must stay declared after `_runtime`.

        ⚠ AND WHY THERE IS NOTHING TO FREE FOR THE THREADS THAT HELD A VALUE.
        `pthread_key_delete` does NOT run per-thread destructors; POSIX leaves
        that to the application. `set_worker_id` stores `worker_id + 1` as the
        void* — an INTEGER the pthread layer never dereferences (the key is
        created with a NULL destructor for exactly that reason), so there is no
        heap object anywhere in this mechanism to leak.
        """
        # rc is deliberately dropped: EINVAL on an already-deleted key is the
        # only failure mode and there is no recovery from inside a destructor.
        # Same shape as `_runtime_teardown_join`'s ignored `pthread_join` rc.
        _ = delete_worker_id_key(self._tls_key)

    # -------------------------------------------------------------------------
    # Gate accessors (read by the facade — same shape P1's LogConfig exposed).
    # -------------------------------------------------------------------------

    @always_inline
    def enabled(self) -> Bool:
        return self._enabled

    def set_enabled(mut self, on: Bool):
        self._enabled = on

    @always_inline
    def capture_spans(self) -> Bool:
        return self._capture_spans

    def set_capture_spans(mut self, on: Bool):
        """Toggle the retained span collector. When ON, EVERY drain on
        this engine routes a completed SPAN line into the per-worker retained
        buffer (read back by `take_span_lines`); LOG records are unaffected
        (`drain_worker` always sinks them, the twins always return them). The
        trace-drain consumer (EngineContext) sets this ON; ambient logging-only
        engines leave it OFF so they retain nothing. Turning it OFF does NOT
        discard already-buffered lines (a final drain can still recover them).

        ⚠ WHAT "OFF" MEANS IS NOT THE SAME ON EVERY DRAIN, AND THAT
        ASYMMETRY IS DELIBERATE. `drain_worker` has a sink, so OFF means "write
        the span there". `drain_worker_to_lines` / `drain_worker_to_records`
        have no sink — their whole contract is that they return rather than
        write — so OFF means the completed span is DROPPED, and counted into
        `spans_dropped_count()`. A process that wants traces off those two
        drains must turn this ON; a process that leaves it OFF now finds out
        how many spans that cost it. The alternative — having a returning drain
        write span JSON into the log sink of the deployed indexing path —
        injects trace data into a production log index and was rejected."""
        self._capture_spans = on

    def take_span_lines(mut self, worker_id: Int) -> List[String]:
        """Move out and clear the retained span buffer for `worker_id`.
        The post-query trace drain calls this after a final ring flush to read
        the lines the continuous idle-loop drain accumulated. Leaves an empty
        buffer behind so the next query starts fresh.

        ★ THIS IS THE SPAN RETURN CHANNEL FOR EVERY DRAIN, not just the
        sink-writing one. `drain_worker_to_lines` returns `List[String]` and
        `drain_worker_to_records` returns `List[LogRecordView]`; a completed
        span is neither, so neither may throw it away. They retain it HERE, so
        a consumer reads spans the same way whichever drain produced them and
        no drain signature had to change. A fourth record kind (REC_METRIC)
        gets its own `_metric_buf` / `take_metric_points` pair in exactly this
        shape rather than inventing a third mechanism."""
        var out = List[String]()
        swap(out, self._span_buf[worker_id])
        return out^

    @always_inline
    def span_buf_len(self, worker_id: Int) -> Int:
        """How many completed spans are retained for `worker_id` and not yet
        taken. Read by the retention-cap test and usable as a backlog gauge."""
        return len(self._span_buf[worker_id])

    @always_inline
    def span_buf_max(self) -> Int:
        return self._span_buf_max

    def set_span_buf_max(mut self, n: Int):
        """Override the per-worker retained-span ceiling (`_SPAN_BUF_MAX`).
        Spans completed while a worker's buffer is at the ceiling are counted
        into `spans_dropped_count()` and discarded — retention degrades, the
        drain never stalls and the process never grows without bound."""
        self._span_buf_max = n

    # -------------------------------------------------------------------------
    # the METRIC return channel. Deliberately the same five-call surface as
    # the span one above (`capture_*` / `set_capture_*` / `take_*` / `*_buf_len`
    # / `*_buf_max` + setter), so a reader who knows one knows the other.
    # -------------------------------------------------------------------------

    @always_inline
    def capture_metrics(self) -> Bool:
        return self._capture_metrics

    def set_capture_metrics(mut self, on: Bool):
        """Toggle the retained metric collector. When ON, every drain on this
        engine decodes a REC_METRIC into `_metric_buf[worker_id]`, read back by
        `take_metric_points`.

        ⚠ WHAT "OFF" MEANS IS THE SAME ON ALL THREE DRAINS, AND THAT IS THE ONE
        PLACE METRICS DIVERGE FROM SPANS. For spans, OFF means `drain_worker`
        writes to its SINK — a span's egress form is a rendered line, so a text
        sink is a legal destination for it. A `MetricPoint` is POD, and
        rendering it into the log sink is both a dead end
        and, on the deployed indexing drain, metric rows injected into a
        production LOG index. So there is NO sink fallback for a metric on any
        drain: OFF means the point is dropped, and counted into
        `metrics_dropped_count()`. A process that wants metrics turns this ON;
        one that leaves it OFF finds out what that cost."""
        self._capture_metrics = on

    def take_metric_points(mut self, worker_id: Int) -> List[MetricPoint]:
        """Move out and clear the retained metric buffer for `worker_id`.

        ★ THE METRIC RETURN CHANNEL FOR EVERY DRAIN ON THIS ENGINE — the exact
        shape `take_span_lines` established for spans, and reused rather than
        re-decided. `drain_worker` returns `Int`, `drain_worker_to_lines`
        returns log text and `drain_worker_to_records` returns log views; a
        metric point is none of those three, so it leaves out of band or not at
        all. No drain signature changed to add it.

        Leaves an empty buffer behind so the next sweep interval starts fresh."""
        var out = List[MetricPoint]()
        swap(out, self._metric_buf[worker_id])
        return out^

    @always_inline
    def metric_buf_len(self, worker_id: Int) -> Int:
        """How many decoded points are retained for `worker_id` and not yet
        taken. Read by the retention-cap test and usable as a backlog gauge."""
        return len(self._metric_buf[worker_id])

    @always_inline
    def metric_buf_max(self) -> Int:
        return self._metric_buf_max

    def set_metric_buf_max(mut self, n: Int):
        """Override the per-worker retained-metric ceiling (`_METRIC_BUF_MAX`).
        Points decoded while a worker's buffer is at the ceiling are counted
        into `metrics_dropped_count()` and discarded. Overridable for the same
        two reasons the span ceiling is: a service can size its own retention,
        and a drop policy only reachable after 16,384 points is one nothing will
        ever falsify."""
        self._metric_buf_max = n

    @always_inline
    def global_level(self) -> UInt8:
        """Relaxed load of the global threshold (the cheap first gate)."""
        return self._global_level[].load()

    def set_global_level(mut self, level: UInt8):
        AtomicU8.store(
            UnsafePointer(to=self._global_level[]).unsafe_bitcast[
                Scalar[DType.uint8]
            ](), level
        )

    @always_inline
    def effective_level(self, module: StaticString) -> UInt8:
        """Per-module effective threshold (longest-prefix EnvFilter override).
        `@always_inline` so a call through the ambient `MutExternalOrigin`
        resolve pointer (the facade hot path) inlines the empty-rules
        short-circuit instead of a non-inlinable indirect call."""
        return self._filter.effective_level(module)

    # -------------------------------------------------------------------------
    # THE LEVEL GATE — ONE decision, not two sequential vetoes.
    # -------------------------------------------------------------------------

    @always_inline
    def admits(self, level: UInt8, module: StaticString) -> Bool:
        """Is a record at `level` from `module` admitted? THE gate.

        ⛔ DO NOT SPELL THIS AS TWO SEQUENTIAL VETOES:

            if level < e.global_level():          return   # (2)
            if level < e.effective_level(module): return   # (3)

        The first one RETURNS, so a per-module rule could only ever RAISE a
        module's threshold. That makes `env_filter.mojo`'s advertised semantics
        unreachable — its own header documents

            --log-level=info,komira_pg=debug
                -> global default = INFO; module "komira_pg" = DEBUG

        and `EnvFilter.effective_level` implements exactly that, resolving
        longest-prefix to a SINGLE effective level. A two-gate sequence throws
        that answer away: the INFO global rejects the DEBUG record before the
        rule admitting it is ever read, and "turn DEBUG on for one module"
        cannot be expressed.

        THE CONTRACT, in one sentence: **the effective threshold for
        (level, module) is the longest-prefix per-module rule if one matches,
        and the runtime global level otherwise.** A matching rule governs
        whether it raises the bar or lowers it.

        ⚠ THE PERF PROPERTY IS PRESERVED, AND IT IS WHY THE SHAPE IS NOT
        SIMPLY `level >= effective_level(module)`. The common case is NO
        per-module overrides, and on that path this is a `List` length read,
        one relaxed atomic load and one compare — no more than the two-veto
        sequence, and no `String(module)` allocation. The longest-prefix walk
        (which does allocate) runs only when rules actually exist.
        `@always_inline` so the ambient facade's call through its untracked
        engine pointer still inlines the empty-rules short-circuit instead of an
        indirect call.

        ⚠ ONE DELIBERATE TIE-BREAK. `EnvFilter.effective_level` returns the
        filter's own parsed global when no rule matches, which is
        indistinguishable from a rule that RESTATES that global. So after a
        runtime `set_global_level`, a module whose rule merely repeats the
        parsed default follows the knob rather than the rule. Both readings
        are defensible and they differ only for a rule that changes nothing;
        the knob winning is the one that keeps `set_global_level` meaning
        "the default for every module without an opinion of its own".
        """
        var g = self._global_level[].load()
        if self._filter.num_rules() == 0:
            # No overrides: the runtime global IS the effective level. One
            # compare, no allocation — the hot path.
            return level >= g
        var m = self._filter.effective_level(module)
        if m == self._filter.global_level:
            # No rule matched `module` (the walk fell back to the filter's own
            # default), so the runtime knob governs.
            return level >= g
        # A rule matched. It is more specific than the global and wins —
        # ABOVE it (`x=warn` under a debug default) or BELOW it
        # (`x=debug` under an info default), which is the half the two-veto
        # sequence could not express.
        return level >= m

    @always_inline
    def num_workers(self) -> Int:
        return self._num_workers

    @always_inline
    def tls_key(self) -> UInt64:
        return self._tls_key

    # -------------------------------------------------------------------------
    # TLS worker_id binding (the worker thread calls this once at startup).
    # -------------------------------------------------------------------------

    def bind_worker_thread(self, worker_id: UInt16):
        """Bind the calling thread's `worker_id` into pthread TLS. Call ONCE
        when a worker thread starts (the pthread entry). After this, a bare
        `log.*` on this thread routes to `ring(worker_id)`."""
        set_worker_id(self._tls_key, worker_id)

    @always_inline
    def current_worker_id(self) -> UInt16:
        """Ambient TLS read — which ring the calling thread pushes into.
        WORKER_ID_UNSET (0xFFFF) on a non-worker thread (TLS unset)."""
        return current_worker_id(self._tls_key)

    # -------------------------------------------------------------------------
    # Ring access. `ring(wid)` returns a `ref` into the owned Slab — NO pointer
    # crosses the API (the encapsulation rule). The facade emits into it; the
    # worker drains it.
    # -------------------------------------------------------------------------

    @always_inline
    def ring(mut self, worker_id: Int) -> ref [self._rings] LogRecordRing:
        # SAFETY: returns a ref tied to the engine's own `_rings` Slab origin
        # (NOT `self`) — the OwnedPointer/Slab interior-ref discipline.
        # `worker_id` is clamped to a valid slot by the caller's gate.
        return self._rings.get_mut_interior(worker_id)

    @always_inline
    def fallback_ring_idx(self) -> Int:
        """The backstop ring slot index (the MPSC fallback, last slot)."""
        return self._num_workers

    # -------------------------------------------------------------------------
    # Calibration. The drain reads the anchor; the ~1 Hz refresh task replaces
    # it (re-reads the raw counter + the wall clock together).
    # -------------------------------------------------------------------------

    @always_inline
    def anchor(self) -> CalibrationAnchor:
        return self._anchor[]

    def refresh_anchor(mut self):
        """Re-capture the (tick0, wall0, tick_hz) anchor unconditionally. Called
        ~1 Hz by a runtime task so the raw-tick→wall conversion stays accurate
        as the process runs (counter drift / NTP wall adjustments)."""
        self._anchor[] = capture_anchor()
        self._last_anchor_ms = now_unix_ms()

    def maybe_refresh_anchor(mut self) -> Bool:
        """The ~1 Hz calibration-refresh task hook. Re-anchors
        ONLY when ≥ `_ANCHOR_REFRESH_MS` has elapsed since the last anchor;
        otherwise a cheap no-op. Called from the worker-0 idle hook (a nominated
        worker, per the tier-3 backstop) so the long-run tick→wall conversion
        stays accurate without paying a re-capture on every idle window.
        Returns True iff it actually re-anchored."""
        var now = now_unix_ms()
        if now - self._last_anchor_ms >= _ANCHOR_REFRESH_MS:
            self._anchor[] = capture_anchor()
            self._last_anchor_ms = now
            return True
        return False

    @always_inline
    def last_anchor_ms(self) -> Int64:
        return self._last_anchor_ms

    # -------------------------------------------------------------------------
    # Dictionary registration. A decodable site registers its (fmt, module) so
    # the drain can reconstruct the human line. The facade registers each site
    # at emit time (idempotent), keyed by the SAME comptime digest.
    # -------------------------------------------------------------------------

    @always_inline
    def register_site[fmt: StringLiteral, module: StringLiteral](mut self):
        self._dict.register[fmt, module]()

    @always_inline
    def register_site_dynamic(
        mut self,
        site_id: UInt32,
        fmt: StaticString,
        module_id: UInt32,
        module: StaticString,
    ):
        """RUNTIME-keyed site registration — the erased emit path's reach into
        the SAME dictionary the comptime path uses. See
        `SiteDictionary.register_dynamic`."""
        self._dict.register_dynamic(site_id, fmt, module_id, module)

    # -------------------------------------------------------------------------
    # The unified SPAN surface (P4a). A span rides the SAME per-core ring as a
    # log record, discriminated by `LogEventRecord.kind`. `start_span` allocates
    # a span_id, pushes it on the per-worker span-id stack (for parent
    # correlation), and emits a SPAN_OPEN record carrying (parent_id, trace_id);
    # `end_span` pops the stack and emits a SPAN_CLOSE record. The drain pairs
    # OPEN↔CLOSE by span_id and renders an OTLP-shaped span JSON.
    #
    # This generalizes `komira_trace.Tracer.start_span/end_span` onto the
    # SharedEngine: same comptime span-name digest (registered into the SAME
    # SiteDictionary as log fmts), same per-worker `Slab[SpanContextSlot]`
    # span-id stack, same OPEN/CLOSE-pair drain. The span name is registered
    # into the dict (so the drain resolves site_id → name) exactly as a log
    # fmt is.
    # -------------------------------------------------------------------------

    def start_span[
        name: StringLiteral, module: StringLiteral = "komira"
    ](mut self, worker_id: Int) -> UInt64:
        """Open a span on `ring(worker_id)`. Returns the new span_id (0 if the
        engine is disabled). The span name is comptime-registered into the
        decoder dictionary; the parent is the worker's current innermost span
        (stack top); a fresh trace_id is minted for a root span."""
        if not self._enabled:
            return UInt64(0)
        # Register the span name so the drain resolves site_id → name (same
        # idempotent dict the log fmts use; the digest matches by construction).
        self._dict.register[name, module]()

        ref slot = self._span_ctx.get_mut_interior(worker_id)
        var parent_id = slot.current_parent()
        var span_id = slot.alloc_span_id(worker_id)
        # Push BEFORE reading trace_id so a root open mints the trace first.
        slot.open(worker_id, span_id)
        var trace_lo = slot.trace_lo
        var trace_hi = slot.trace_hi

        var start_tick = read_raw_ticks()
        var rec = build_span_open[name, module](
            span_id, parent_id, trace_lo, trace_hi, LEVEL_INFO, start_tick
        )
        ref ring = self._rings.get_mut_interior(worker_id)
        _ = ring.try_push(rec)
        return span_id

    def end_span(mut self, span_id: UInt64, worker_id: Int):
        """Close `span_id` on `ring(worker_id)`. Pops the per-worker stack and
        emits a SPAN_CLOSE record carrying the end tick. The drain joins it to
        the matching OPEN by span_id."""
        if not self._enabled:
            return
        ref slot = self._span_ctx.get_mut_interior(worker_id)
        slot.close()
        var end_tick = read_raw_ticks()
        var rec = build_span_close(span_id, end_tick)
        ref ring = self._rings.get_mut_interior(worker_id)
        _ = ring.try_push(rec)

    @always_inline
    def current_span(self, worker_id: Int) -> UInt64:
        """The innermost in-flight span_id for `worker_id` (0 if none)."""
        return self._span_ctx[worker_id].current_parent()

    @always_inline
    def span_depth(self, worker_id: Int) -> Int:
        return self._span_ctx[worker_id].depth_of()

    def pending_span_count(self) -> Int:
        """Drain-side: spans whose OPEN landed but whose CLOSE has not yet been
        drained (pending across batches). 0 means every observed span completed.
        """
        return self._open_spans.pending_count()

    def unknown_kind_dropped_count(mut self) -> Int64:
        """Drain-side: records REFUSED across every ring this engine owns
        because no drain arm recognised their `kind`. Summed over the dataplane
        rings AND the non-worker fallback ring — `_num_workers + 1` slots, the
        same span `__init__` constructs.

        NON-ZERO MEANS A PRODUCER IS AHEAD OF THE DRAINS. The records were
        dropped, not rendered; the alternative was writing `"<unknown site N>"`
        rows into whatever the drain feeds, which on `drain_worker_to_records`
        is a production log index.
        """
        var total = Int64(0)
        for w in range(self._num_workers + 1):
            total += self._rings.get_mut_interior(w).unknown_kind_dropped_count()
        return total

    def overflow_dropped_count(mut self) -> Int64:
        """Records LOST because a ring was full when the producer pushed.

        Summed over the dataplane rings AND the non-worker fallback ring.
        The dataplane rings are `OVERFLOW_DROP` by policy — a full ring must
        never stall query work — so this is the price of that policy, and it is
        the ONLY record of it.

        ⚠ THESE RECORDS NEVER REACHED A DRAIN AT ALL. They are not the
        unknown-kind refusals above (which a drain saw and rejected); they were
        discarded at PUSH time, so no drain, sink or index ever observed them.
        Until this accessor existed the count was read by four TEST files and
        ZERO production sites -- a counted drop nobody could see, which is a
        silent drop with extra steps.
        """
        var total = Int64(0)
        for w in range(self._num_workers + 1):
            total += self._rings.get_mut_interior(w).overflow_dropped_count()
        return total

    def spans_dropped_count(mut self) -> Int64:
        """SPAN records this engine's drains consumed without producing a span.
        Summed over every ring, the same span the two counters above use.

        ⚠ THIS IS A TRACE-DATA-LOSS GAUGE, AND ITS ZERO IS THE ONLY EVIDENCE
        THAT TRACING IS INTACT. Three ways it moves, all of them policy:
          * a completed span reached `drain_worker_to_lines` /
            `drain_worker_to_records` while `_capture_spans` was OFF — those
            drains have no sink to fall back to, so there is nowhere to put it;
          * a worker's retained buffer was at `span_buf_max` — nobody is
            calling `take_span_lines`;
          * a SPAN record reached one of the bare free-fn drains
            (`drain_to_lines` / `drain_to_views`), which have no open-span
            table to pair it into.
        A CLOSE whose OPEN is still pending is NOT counted here — that one is
        `pending_span_count()`.
        """
        var total = Int64(0)
        for w in range(self._num_workers + 1):
            total += self._rings.get_mut_interior(w).span_record_dropped_count()
        return total

    def metrics_dropped_count(mut self) -> Int64:
        """REC_METRIC records this engine's drains consumed without producing a
        `MetricPoint`. Summed over every ring, the same span the three
        counters above use.

        ⚠ A METRICS PIPELINE THAT DROPS SILENTLY IS WORSE THAN ONE THAT IS OFF:
        the dashboard still draws and the missing points read as real values.
        This number is the only thing that distinguishes them from outside the
        process. Four ways it moves, all policy:
          * `_capture_metrics` was OFF — no drain has a destination for a POD
            point, and unlike a span there is no sink to fall back to;
          * a worker's retained buffer was at `metric_buf_max` — nobody is
            calling `take_metric_points`;
          * the record was NOT DECODABLE — the arena-spilled histogram payload
            (the ring codec is scalar-only; `HistogramPoint` has no ring
            encoding yet) or a truncated header. Refused, never half-decoded;
          * the record reached one of the bare free-fn drains
            (`drain_to_lines` / `drain_to_views`), whose return types are log
            text and log views.
        """
        var total = Int64(0)
        for w in range(self._num_workers + 1):
            total += self._rings.get_mut_interior(
                w
            ).metric_record_dropped_count()
        return total

    # -------------------------------------------------------------------------
    # SINK-ERROR EVIDENCE. The counters behind the three `except:` blocks.
    # -------------------------------------------------------------------------

    def sink_dropped_line_count(self) -> Int64:
        """Rendered lines this engine FAILED TO WRITE and swallowed.

        ⚠ NON-ZERO MEANS LOG LINES ARE GONE. Not delayed, not buffered --
        rendered, handed to the sink, refused, and discarded. Three sites feed
        it, and they are not interchangeable:
          * `drain_worker` -- a fully decoded record whose sink write raised.
            The ring did its job; the disk did not.
          * `emit_fallback_line` -- an unbound-thread log (an HTTP handler, the
            job supervisor heartbeat, a CLI tool, a log-mirroring thread). This is the
            path every log from a thread with no worker_id takes.
          * `escalate_line` -- an ERROR or WARN the ring already rejected once.
            A non-zero count here means the never-drop guarantee did not hold,
            which is the single most important thing this number can tell you.

        The swallow itself is deliberate and stays: a logger that raises into a
        worker loop turns a full disk into a query failure. What was wrong was
        that it was SILENT -- and the comment at the drain site asserted the
        opposite, naming "the sink's own counters", which do not exist.
        """
        return self._sink_dropped[].load()

    def sink_flush_failure_count(self) -> Int64:
        """Sink flushes that failed. NOT a lost line -- a line that landed but
        may not survive a crash.

        `escalate_line` flushes because an ERROR usually precedes a crash, so
        the line must be durable before the process dies. If that flush fails
        the write still happened, so counting it as a drop would overstate the
        loss; counting it as nothing would erase the only signal that the
        crash-tail promise was not kept. It is its own number for that reason.
        """
        return self._sink_flush_failures[].load()

    @always_inline
    def _note_sink_dropped(mut self):
        _ = self._sink_dropped[].fetch_add(Int64(1))

    @always_inline
    def _note_sink_flush_failure(mut self):
        _ = self._sink_flush_failures[].fetch_add(Int64(1))

    # -------------------------------------------------------------------------
    # Introspection used by the level-gate and site-registration tests. Both
    # are reads of state that is otherwise only observable by its effects.
    # -------------------------------------------------------------------------

    @always_inline
    def filter_rule_count(self) -> Int:
        """Per-module override rules parsed from the log-level directive. Zero is the hot
        common case and the one `admits` is optimised for."""
        return self._filter.num_rules()

    def site_dict_len(self) -> Int:
        """Entries in the shared site dictionary.

        Exposed because the dictionary is mutated on the emit path and its
        growth is otherwise invisible until a drain decodes something. The
        ordering invariant in `test_log_sink_error_evidence.mojo` reads it.
        """
        return len(self._dict.sites)

    def drain_worker_unified(
        mut self, worker_id: Int
    ) -> UnifiedDrainResult:
        """Drain `ring(worker_id)` fully, routing each record by kind: REC_LOG →
        a decoded text line; SPAN_OPEN/SPAN_CLOSE → an OTLP span (paired across
        batches via the engine's `_open_spans` table). Returns both output
        streams (log_lines + span_lines). The worker that owns the ring is the
        only drainer, so the open-span table needs no lock.

        This is the UNIFIED drain — logs and spans on one ring → one drain →
        two outputs. The log-only `drain_worker` / `drain_worker_to_lines` stay
        for the pure-log path; this is the trace-aware twin."""
        var anchor = self._anchor[]
        return drain_unified(
            self._rings.get_mut_interior(worker_id),
            worker_id,
            self._dict,
            anchor,
            self._open_spans,
        )

    def drain_captured_spans(mut self, worker_id: Int) -> List[String]:
        """The post-query trace-drain entry. First do a FINAL flush of
        any SPAN records still on `ring(worker_id)` into the retained buffer
        (the continuous idle-loop `drain_worker` has been filling it mid-query,
        but a tail of records may remain if the query ended between idle
        windows), then move out and return the accumulated `span_lines` for that
        worker. Reads the buffer the worker loop filled — NOT the (already
        empty) live ring — so it is robust to the idle-loop winning the drain
        race. Used by `EngineContext.drain_traces_to_jsonl`.

        Requires `_capture_spans` ON (the trace consumer set it via
        `set_capture_spans`); with capture off this returns whatever was already
        buffered (empty for a logging-only engine)."""
        # FINAL flush: drain any remaining records. With capture on, completed
        # SPAN lines land in `_span_buf[worker_id]` (LOG records go to the sink,
        # unchanged). `drain_worker` breaks as soon as `try_pop` is empty, so a
        # very large budget just means "drain the whole tail" — this is the
        # end-of-query reconcile, not the bounded idle hook.
        _ = self.drain_worker(worker_id, _FINAL_FLUSH_BUDGET)
        return self.take_span_lines(worker_id)

    # -------------------------------------------------------------------------
    # The per-core drain (the worker loop calls this when idle). Decodes every
    # record on `ring(worker_id)` and writes the rendered line to the sink.
    # Bounded by `max_records` so it can NEVER starve query work (the drain
    # budget). Returns the number of records drained.
    # -------------------------------------------------------------------------

    def drain_worker(mut self, worker_id: Int, max_records: Int) -> Int:
        """Drain up to `max_records` from `ring(worker_id)`, decode each, and
        write the line to the sink. Returns the count drained. Caller (the
        worker loop) gates on `ring(worker_id).is_empty()` first so this only
        runs when there is work — keeping the idle-path cost near zero."""
        var n = 0
        var anchor = self._anchor[]
        while n < max_records:
            ref r = self._rings.get_mut_interior(worker_id)
            var rec_opt = r.try_pop()
            if not rec_opt:
                break
            var rec = rec_opt.value().copy()
            # Route by kind: SPAN records feed the OTLP open-span table (and a
            # completed span is written to the sink as its JSON line); LOG
            # records render as text. A mixed (logs+spans) ring drains cleanly
            # through this one production path — the unification at the sink.
            if rec.kind == REC_SPAN_OPEN:
                self._open_spans.ingest_open(rec, worker_id, self._dict, anchor)
                n += 1
                continue
            elif rec.kind == REC_SPAN_CLOSE:
                var span_line = self._open_spans.ingest_close(rec, anchor)
                if span_line:
                    # When the retained collector is on, the completed
                    # OTLP span line goes ONLY to the per-worker buffer (the
                    # JSONL file becomes the span destination; stderr stays
                    # clean). When off, it writes to the sink as before. The
                    # OTLP formatting is `ingest_close`'s output — byte-identical
                    # to the `drain_worker_unified` path, so a span captured here
                    # matches what the post-query drain expects.
                    if self._capture_spans:
                        # bounded. Retention degrades to a counted drop
                        # rather than growing without limit; see
                        # `_SPAN_BUF_MAX` and `spans_dropped_count`.
                        if len(self._span_buf[worker_id]) < self._span_buf_max:
                            self._span_buf[worker_id].append(span_line.value())
                        else:
                            r.note_span_record_dropped()
                    else:
                        # Same contract as the log-line write below: swallow,
                        # but COUNT. A completed span lost to a sink error is
                        # a hole in a trace, and it was invisible.
                        try:
                            self._sink.write_line_core(
                                worker_id, span_line.value()
                            )
                        except:
                            self._note_sink_dropped()
                n += 1
                continue
            elif rec.kind == REC_METRIC:
                # the METRIC arm. Decoded into the per-worker retained
                # buffer, read back by `take_metric_points`; the same channel,
                # gate and bound built for spans, with a POD payload instead
                # of a rendered line.
                #
                # ⚠ THERE IS NO SINK FALLBACK ON ANY OF THE THREE DRAINS, and
                # that is not an omission. A span whose capture is off can be
                # written to the text sink because a span's egress form IS text.
                # A `MetricPoint` is POD to the exporter; rendering it here is
                # a dead end, and on the deployed
                # indexing drain it would write metric rows into a production
                # LOG index. So capture-off, buffer-full and not-decodable all
                # take the same exit: dropped, and COUNTED.
                if (
                    metric_record_is_decodable(rec)
                    and self._capture_metrics
                    and (
                        len(self._metric_buf[worker_id]) < self._metric_buf_max
                    )
                ):
                    self._metric_buf[worker_id].append(
                        decode_metric_point(rec, anchor)
                    )
                else:
                    r.note_metric_record_dropped()
                n += 1
                continue
            if rec.kind != REC_LOG:
                # THE CLOSED DEFAULT. Without this arm the `else` below would be
                # OPEN: any kind that was not a SPAN would fall into the log
                # decode, which walks `rec.n_args` over bytes that are not an
                # arg table and renders `"<unknown site N>"`. Counted and
                # refused instead.
                r.note_unknown_kind()
                n += 1
                continue
            var line = decode_one(rec, r, self._dict, anchor)
            # A logger must never wedge the worker loop on a transient sink
            # error (full disk, rename race) — swallow + continue.
            #
            # ⚠ THE SWALLOW IS THE POLICY; SILENCE WOULD BE THE BUG. `LogSink`
            # has no counter of any kind — it declares `_kind`, `_lock`,
            # `_file`, `_segments`, `_n_segments` and nothing else — so a fully
            # decoded record would vanish with no trace.
            # `sink_dropped_line_count` is that counter, and a non-zero value
            # means log lines are gone.
            try:
                self._sink.write_line_core(worker_id, line)
            except:
                self._note_sink_dropped()
            n += 1
        # If the ring fully drained, reclaim the spill arena.
        if self._rings.get_mut_interior(worker_id).is_empty():
            self._rings.get_mut_interior(worker_id).reset_arena()
        return n

    def drain_worker_to_lines(
        mut self, worker_id: Int, max_records: Int
    ) -> List[String]:
        """Like `drain_worker`, but RETURNS the decoded lines instead of writing
        them to the sink. Used by tests (assert byte-identical render through the
        engine path) and any embedder that wants the lines (a custom sink). The
        worker loop uses `drain_worker` (→ sink); this is the inspectable twin."""
        var lines = List[String]()
        var anchor = self._anchor[]
        var n = 0
        while n < max_records:
            ref r = self._rings.get_mut_interior(worker_id)
            var rec_opt = r.try_pop()
            if not rec_opt:
                break
            var rec = rec_opt.value().copy()
            # Route SPAN records to the OTLP table so a mixed ring doesn't emit
            # garbage text. They do not appear in the RETURNED lines (this is
            # the log-only inspect path); the completed span leaves through
            # `_span_buf` / `take_span_lines` instead. The single-call
            # trace-aware twin is `drain_worker_unified`.
            if rec.kind == REC_SPAN_OPEN:
                self._open_spans.ingest_open(rec, worker_id, self._dict, anchor)
                n += 1
                continue
            elif rec.kind == REC_SPAN_CLOSE:
                # ⛔ NEVER `_ = ingest_close(...)`. `ingest_close` RETURNS the
                # completed OTLP span line; discarding it would correlate and
                # render the span and then destroy it, one statement after the
                # work was done. The text drain (`drain_worker`) keeps it, and so
                # must this one.
                #
                # It cannot be RETURNED, because this fn returns `List[String]`
                # of decoded LOG text and a caller asking for log lines must
                # not receive span JSON interleaved into them. So it goes to
                # the same per-worker side channel the text drain uses —
                # `_span_buf` / `take_span_lines` — which is the ONE span
                # return channel for every drain on this engine.
                var span_line = self._open_spans.ingest_close(rec, anchor)
                if span_line:
                    if self._capture_spans and (
                        len(self._span_buf[worker_id]) < self._span_buf_max
                    ):
                        self._span_buf[worker_id].append(span_line.value())
                    else:
                        # Capture OFF, or the buffer is full. Unlike
                        # `drain_worker` there is NO sink on this path to fall
                        # back to, so the span is lost — but it is lost
                        # COUNTED. A silent loss and a process that emits no
                        # spans are indistinguishable from outside; these two
                        # are not.
                        r.note_span_record_dropped()
                n += 1
                continue
            elif rec.kind == REC_METRIC:
                # the METRIC arm. Decoded into the per-worker retained
                # buffer, read back by `take_metric_points`; the same channel,
                # gate and bound built for spans, with a POD payload instead
                # of a rendered line.
                #
                # ⚠ THERE IS NO SINK FALLBACK ON ANY OF THE THREE DRAINS, and
                # that is not an omission. A span whose capture is off can be
                # written to the text sink because a span's egress form IS text.
                # A `MetricPoint` is POD to the exporter; rendering it here is
                # a dead end, and on the deployed
                # indexing drain it would write metric rows into a production
                # LOG index. So capture-off, buffer-full and not-decodable all
                # take the same exit: dropped, and COUNTED.
                if (
                    metric_record_is_decodable(rec)
                    and self._capture_metrics
                    and (
                        len(self._metric_buf[worker_id]) < self._metric_buf_max
                    )
                ):
                    self._metric_buf[worker_id].append(
                        decode_metric_point(rec, anchor)
                    )
                else:
                    r.note_metric_record_dropped()
                n += 1
                continue
            if rec.kind != REC_LOG:
                # THE CLOSED DEFAULT. Without this arm the `else` below would be
                # OPEN: any kind that was not a SPAN would fall into the log
                # decode, which walks `rec.n_args` over bytes that are not an
                # arg table and renders `"<unknown site N>"`. Counted and
                # refused instead.
                r.note_unknown_kind()
                n += 1
                continue
            lines.append(decode_one(rec, r, self._dict, anchor))
            n += 1
        if self._rings.get_mut_interior(worker_id).is_empty():
            self._rings.get_mut_interior(worker_id).reset_arena()
        return lines^

    def drain_worker_to_records(
        mut self, worker_id: Int, max_records: Int
    ) -> List[LogRecordView]:
        """The POD-RETURNING transpose seam. Like
        `drain_worker_to_lines`, but RETURNS a `List[LogRecordView]` (the OWNED,
        search-free handoff value) instead of rendered text. Drains up to
        `max_records` LOG records from `ring(worker_id)`, decoding each into an
        owned view (scalars + interpolated message + decoded arg key/value pairs).

        LAYERING: this is the ONLY indexing-facing API on the engine — it
        returns POD-owned values, NOT a `RecordBatch`. The transpose-to-RecordBatch
        + SearchSink publish lives OFF the engine, in the search-side consumer
        (`komira_log_index`). `komira_log` stays import-clean (no Arrow,
        search or S3 dependency).

        SPAN HANDLING: SPAN records are routed to the
        OTLP open-span table and NOT emitted as log views — spans get their OWN
        index. A mixed ring drains cleanly; only REC_LOG records become
        `LogRecordView`s. "Routed to the table" is not where the span's life
        ends: `ingest_close`'s completed span line lands in
        `_span_buf[worker_id]`, readable via `take_span_lines` — the same
        channel `drain_worker` uses.

        Arena-copy guard: `decode_one_to_view` materializes the arg-blob
        into OWNED bytes and builds owned Strings BEFORE returning, so the views
        hold ZERO reference into the ring arena and remain valid after the
        `reset_arena` below. NO `UnsafePointer` crosses this boundary.

        NOT WIRED INTO THE HOT DRAIN. The worker loop uses `drain_worker` (→ text
        sink). This twin is for the off-core native-indexing consumer and for
        cost benches / e2e tests — it is a SEAM, not the production hot path.
        """
        var views = List[LogRecordView]()
        var anchor = self._anchor[]
        var n = 0
        while n < max_records:
            ref r = self._rings.get_mut_interior(worker_id)
            var rec_opt = r.try_pop()
            if not rec_opt:
                break
            var rec = rec_opt.value().copy()
            if rec.kind == REC_SPAN_OPEN:
                self._open_spans.ingest_open(rec, worker_id, self._dict, anchor)
                n += 1
                continue
            elif rec.kind == REC_SPAN_CLOSE:
                # ⛔ see `drain_worker_to_lines`. THIS is the indexing drain
                # (`komira_log_index`'s `ServiceLogSink.pump`), so it is the arm
                # on which "spans are silently destroyed" would actually ship. A span is not a `LogRecordView`
                # and must not become one — spans get their own index — so it
                # goes to the per-worker side channel, same as every other
                # drain here.
                var span_line = self._open_spans.ingest_close(rec, anchor)
                if span_line:
                    if self._capture_spans and (
                        len(self._span_buf[worker_id]) < self._span_buf_max
                    ):
                        self._span_buf[worker_id].append(span_line.value())
                    else:
                        r.note_span_record_dropped()
                n += 1
                continue
            elif rec.kind == REC_METRIC:
                # the METRIC arm. Decoded into the per-worker retained
                # buffer, read back by `take_metric_points`; the same channel,
                # gate and bound built for spans, with a POD payload instead
                # of a rendered line.
                #
                # ⚠ THERE IS NO SINK FALLBACK ON ANY OF THE THREE DRAINS, and
                # that is not an omission. A span whose capture is off can be
                # written to the text sink because a span's egress form IS text.
                # A `MetricPoint` is POD to the exporter; rendering it here is
                # a dead end, and on the deployed
                # indexing drain it would write metric rows into a production
                # LOG index. So capture-off, buffer-full and not-decodable all
                # take the same exit: dropped, and COUNTED.
                if (
                    metric_record_is_decodable(rec)
                    and self._capture_metrics
                    and (
                        len(self._metric_buf[worker_id]) < self._metric_buf_max
                    )
                ):
                    self._metric_buf[worker_id].append(
                        decode_metric_point(rec, anchor)
                    )
                else:
                    r.note_metric_record_dropped()
                n += 1
                continue
            if rec.kind != REC_LOG:
                # THE CLOSED DEFAULT. Without this arm the `else` below would be
                # OPEN: any kind that was not a SPAN would fall into the log
                # decode, which walks `rec.n_args` over bytes that are not an
                # arg table and renders `"<unknown site N>"`. Counted and
                # refused instead.
                r.note_unknown_kind()
                n += 1
                continue
            views.append(decode_one_to_view(rec, r, self._dict, anchor))
            n += 1
        if self._rings.get_mut_interior(worker_id).is_empty():
            self._rings.get_mut_interior(worker_id).reset_arena()
        return views^

    @always_inline
    def worker_ring_nonempty(self, worker_id: Int) -> Bool:
        """Cheap check for the worker-loop idle hook (no drain unless there is
        work). Reads the ring's head/tail; SPSC-safe from the owning core."""
        return not self._rings[worker_id].is_empty()

    # -------------------------------------------------------------------------
    # The non-worker-thread fallback. A log from a thread with no `worker_id`
    # (TLS unset) cannot use a per-core SPSC ring (no owning core ever drains
    # it). It renders + writes the line synchronously under the sink lock — the
    # P1 behavior, confined to the cold off-thread path. Never crashes, never
    # silently dropped.
    # -------------------------------------------------------------------------

    def emit_fallback_line(mut self, line: String):
        """Synchronous-direct write for a non-worker-thread log. The line is
        already rendered (the facade renders it on the caller for the fallback
        path only). Routes to the fallback segment (the last slot) in per-core
        mode; STDERR/FILE ignore the index. Thread-safe via the sink's lock /
        the single append fd.

        ⚠ THIS IS THE PATH EVERY UNBOUND-THREAD LOG TAKES — an HTTP handler,
        the job supervisor heartbeat, a CLI tool with no runtime, and a log-mirroring
        thread's own write. A transient sink error is still swallowed (the
        logger must never wedge its caller) but it is now COUNTED:
        `sink_dropped_line_count`. Uncounted, it would be the widest silent-loss
        channel in the engine."""
        try:
            self._sink.write_line_core(self._num_workers, line)
        except:
            self._note_sink_dropped()

    def escalate_line(mut self, line: String):
        """ERROR-never-dropped slow-path. When a DROP ring
        rejects an ERROR push, the facade renders the line on the caller and
        calls this — a synchronous render+write that is NEVER dropped, plus a
        sink flush for crash-tail safety (an ERROR usually precedes a crash, so
        the line must be durable before the process dies).

        ⛔ "NEVER DROPPED" IS A GUARANTEE, SO ITS FAILURE MODE CANNOT BE
        SILENT. This body was one `try: write; flush; except: pass` — the last
        line of defence for a record the ring already rejected, failing with
        no trace, under a docstring promising it never fails. The write and
        the flush are now SEPARATE, because they fail differently and the
        difference is the whole point:
          * the WRITE failing means the line is GONE — the guarantee did not
            hold, and `sink_dropped_line_count` is the only evidence of it;
          * the FLUSH failing means the line LANDED but may not survive the
            crash it was probably announcing — `sink_flush_failure_count`.
        Summing them would report a durability hiccup as a lost ERROR.

        A failed write returns early: there is nothing to flush, and flushing
        anyway would charge a second failure for one lost line."""
        try:
            self._sink.write_line_core(self.current_worker_id_or_fallback(), line)
        except:
            self._note_sink_dropped()
            return
        try:
            self._sink.flush_all()
        except:
            self._note_sink_flush_failure()

    @always_inline
    def current_worker_id_or_fallback(self) -> Int:
        """The calling thread's worker_id as an Int, or the fallback slot index
        (`num_workers`) for a non-worker thread (TLS unset)."""
        var wid = current_worker_id(self._tls_key)
        if wid == WORKER_ID_UNSET:
            return self._num_workers
        return Int(wid)

    # -------------------------------------------------------------------------
    # Sink configuration (P3). The dev default is stderr; production installs a
    # file or per-core-segment sink at init (before workers spawn). Per-segment
    # rotation is carried in the `RotationPolicy`.
    # -------------------------------------------------------------------------

    def set_sink_stderr(mut self):
        self._sink = LogSink.stderr()

    def set_sink_single_file(
        mut self, base_path: String, policy: RotationPolicy
    ) raises:
        """Install a single rotating file `{base_path}.log` (all cores funnel
        through one append fd)."""
        self._sink = LogSink.single_file(base_path, policy)

    def set_sink_per_core_segments(
        mut self, base_path: String, policy: RotationPolicy
    ) raises:
        """Install per-core segments `{base_path}.core{N}.log` (the share-
        nothing production default — one fd per core, no shared lock). Sized to
        this engine's `num_workers`."""
        self._sink = LogSink.per_core_segments(
            base_path, self._num_workers, policy
        )

    def flush_sink(mut self):
        """Fsync every live segment (teardown / explicit flush).

        Counted in `sink_flush_failure_count` for the same reason
        `escalate_line`'s flush is: a teardown flush that failed means the
        tail of the log may not be on disk, and that was silent."""
        try:
            self._sink.flush_all()
        except:
            self._note_sink_flush_failure()

    @always_inline
    def sink_kind(self) -> UInt8:
        return self._sink.kind()

    @always_inline
    def segment_bytes(self, core: Int) -> Int:
        return self._sink.segment_bytes(core)

    @always_inline
    def segment_archive_count(self, core: Int) -> Int:
        return self._sink.segment_archive_count(core)
