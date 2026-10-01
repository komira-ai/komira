# =============================================================================
# komira_log.engine.metric_sink — `RingMetricSink`, THE PRODUCTION
#   `MetricPointSink` CONFORMER: the joint between the metric sweep (which
#   produces points) and the ring codec (which carries them).
# =============================================================================
#
# The sweep produces `MetricPoint`s, `metric_emit.mojo` turns one into a
# `REC_METRIC`, the ring consumers decode it, and `SharedEngine` has a
# `take_metric_points` return channel. Without a production `MetricPointSink`
# conformer none of that is joined. `komira_obs` may not know about
# `REC_METRIC` (see `metric_sweep.mojo`'s "WHAT THIS FILE IS NOT"), so the
# conformer lives here.
#
# The seam is one-way: `komira_log` depends on `komira_obs`, and
# `metric_emit.mojo` beside this file already imports `MetricPoint`. So this
# file adds NO dep edge — it is the one place the two are allowed to meet.
#
# ─── ⭐ TWO SIGNALS, NOT ONE BOOL — THE WHOLE REASON THIS FILE IS NOT FIVE LINES
#
# `metric_emit.mojo`'s header states the trap in full; this is its resolution.
#
#   `MetricPointSink.try_accept` returns Bool, and **False means BACKPRESSURE**.
#   `MetricSweep._drain` does NOT advance its cursor on a False — the point is
#   re-offered on the next tick, which is what turns a full transport into
#   export LATENCY instead of loss.
#
#   `build_metric_record` returns `Optional`, and **its None is a REFUSAL**: a
#   point that will never encode, on this tick or any other.
#
# Mapping that None onto False LIVELOCKS the export. The sweep re-offers a point
# that can never be accepted, forever; the cursor never advances; the generation
# never finishes; `tick` never collects again, so EVERY OTHER SERIES in the
# process stops exporting too. It is not a dropped point, it is a stuck pipeline
# that reports no error.
#
# So the low-level push does NOT return a Bool. `emit_metric_record` returns a
# THREE-VALUED outcome:
#
#   METRIC_EMIT_PUSHED       the record is on the ring
#   METRIC_EMIT_RING_FULL    BACKPRESSURE — retry is correct, the only False
#   METRIC_EMIT_UNENCODABLE  REFUSAL — retry is a livelock, drop and count
#
# and the collapse onto the trait's Bool happens EXACTLY ONCE, in
# `RingMetricSink.try_accept`, where it is visible next to the counter that
# records what was dropped. A refusal nothing counts is indistinguishable from a
# code path that never ran — the same argument `MetricSweep.num_unreducible` and
# `MetricsSet.dropped_registrations` are built on.
#
# ⚠ AND THE HISTOGRAM ARM IS THE ONE THAT WOULD ACTUALLY FIRE. The scalar
# refusal is unreachable THROUGH THE SWEEP — `SeriesTable.add` refuses
# any kind that is not COUNTER/UPDOWNCOUNTER, and the sweep's emit loop
# normalises everything else into `counter_point`, so no swept `MetricPoint`
# carries a kind `build_metric_record` rejects. `try_accept_histogram` is
# different: the ring codec is SCALAR-only (there is no arena codec), so EVERY
# `HistogramPoint` the sweep produces is unencodable, by construction. A
# conformer that returned False there would livelock on the first histogram
# series any service ever records. That is why the falsifier drives the
# histogram arm and not the scalar one.
#
# ─── WHY THIS RESOLVES THE ENGINE INSTEAD OF HOLDING ONE ─────────────────────
#
# `LogManager._resolve()`, exactly as `komira_log/facade.mojo` does for every
# ambient `log.*` call. The engine is the process-global IMMORTAL one (moved to
# the heap and `unsafe_leak()`-leaked at install, never moved, never freed), so
# the resolve cannot dangle and the produced pointer is a TRANSIENT LOCAL,
# null-checked before any deref — never a stored wildcard-origin FIELD, which
# would be the stale-pointer hazard across destroy and recreate. A `Pointer(to=engine)` FIELD would be the
# banned "borrowed pointer on a long-lived struct" instead, and would also be
# WRONG: `ServiceLogSink.install()` donates its engine INTO the global, so after
# install the only engine whose ring(0) `pump()` drains IS the global one.
#
# ⛔ AND "NO ENGINE INSTALLED" IS A REFUSAL, NOT BACKPRESSURE. An engine is
# installed once, at boot, before the serve loop runs. A sweep tick that finds
# none will find none on the next tick too, so re-offering is the same livelock
# by a different door. Dropped and counted (`refused_no_engine`).
#
# ─── ⭐ EVERY ARM OF THE COLLAPSE NEEDS ITS OWN FALSIFIER ───────────────────
#
# Three independent signals, each with a case that goes red when that arm alone
# is broken:
#
#   what is broken                         what must go red
#   -----------------------------------   ---------------------------------
#   `try_accept_histogram` returns False   the sweep's own refusal counter
#   (the refusal->backpressure collapse,   stays 0, the generation never
#   i.e. THE LIVELOCK)                     completes and the point is
#                                          re-offered forever.
#
#   the RING_FULL arm returns True         "a full ring takes nothing": points
#   (the "just return True everywhere"     reported delivered that were written
#   sink that the first case alone         nowhere.
#   would pass)
#
#   the UNENCODABLE arm returns False      the unit-level mapping: an
#   (`build_metric_record`'s None mapped   unencodable point must return TRUE,
#   onto backpressure)                     "do not offer me this again".
#
# ⚠ NOTE WHAT THE FIRST TWO PROVE TOGETHER: neither degenerate sink passes both
# cases. "Always True" survives the first and dies on the second; "False on a
# refusal" survives the second and dies on the first. A single case in either
# direction would be satisfiable by a constant.
#
# Encapsulation: ZERO `UnsafePointer` in any signature here — the free
# function takes `mut ring: LogRecordRing` by reference and a POD `MetricPoint`
# by value. No wildcard-origin field. No heap-owning field: every field is an
# `Int` or an `Int64`, so the struct is trivially Movable and Deinitable.
# =============================================================================

from komira_obs.histogram import HistogramPoint
from komira_obs.metric_point import MetricPoint
from komira_obs.metric_sweep import MetricPointSink

from komira_log.engine.calibration import read_raw_ticks
from komira_log.engine.log_manager import LogManager
from komira_log.engine.metric_emit import build_metric_record
from komira_log.engine.record_ring import LogRecordRing


# -----------------------------------------------------------------------------
# The three-valued push outcome. ⛔ NOT A BOOL, AND NOT AN `Optional[Bool]`
# either: the caller has to distinguish "retry me" from "never retry me", and
# both of those spellings make the wrong one the easy one to write.
# -----------------------------------------------------------------------------

comptime METRIC_EMIT_PUSHED: UInt8 = UInt8(0)
"""The record is on the ring. The sweep MUST advance its cursor."""

comptime METRIC_EMIT_RING_FULL: UInt8 = UInt8(1)
"""BACKPRESSURE. The transport is full RIGHT NOW; the same point will encode
fine next tick. This is the ONLY outcome that may become a `False` at the
`MetricPointSink` boundary."""

comptime METRIC_EMIT_UNENCODABLE: UInt8 = UInt8(2)
"""REFUSAL. `build_metric_record` said None — the point cannot be encoded on
this tick or any other. Retrying it is a livelock; drop it and count it."""


def emit_metric_record(
    mut ring: LogRecordRing, point: MetricPoint, time_tick: UInt64
) -> UInt8:
    """Encode `point` and push it onto `ring`. Returns one of the three
    `METRIC_EMIT_*` outcomes above.

    THE ORDER IS LOAD-BEARING: encode FIRST, push second. An unencodable point
    must be refused without consuming a ring slot, and a ring-full push must not
    be reported as an encoding failure — the two counters they feed answer
    different operator questions ("my transport is undersized" vs "something is
    producing points that can never leave")."""
    var rec_opt = build_metric_record(point, time_tick)
    if not rec_opt:
        return METRIC_EMIT_UNENCODABLE
    if not ring.try_push(rec_opt.value().copy()):
        return METRIC_EMIT_RING_FULL
    return METRIC_EMIT_PUSHED


def enable_ring_metric_capture() -> Bool:
    """Turn ON the installed engine's retained metric collector. Returns True
    iff an engine was installed and is now capturing.

    ⛔ WITHOUT THIS CALL THE CHAIN ENDS AT THE RING AND SAYS NOTHING.
    `SharedEngine._capture_metrics` defaults to **False**, and with it off every
    drain arm takes the same exit for a `REC_METRIC`: dropped, and counted into
    `metrics_dropped_count()`. There is no sink fallback for a metric on any
    drain (a `MetricPoint` is POD; rendering it into the text sink would inject
    metric rows into a production LOG index), so "off" is silent at every level
    ABOVE the counter. A service that pushes points without calling this gets a
    green push, a green drain, and no metrics.

    Call it AFTER the sink install that donates the engine to `LogManager` —
    before that, there is no engine to configure and this returns False."""
    # SAFETY: the process-global IMMORTAL engine (LogManager — moved to the heap
    # and unsafe_leak()-leaked at install, so never moved and never freed)
    # outlives every caller. Null-checked before any deref. The pointer is a
    # TRANSIENT LOCAL, never a stored field; this is the same shape
    # `komira_log/facade.mojo` uses on every ambient log call.
    var eng = LogManager._resolve()
    if Int(eng) == 0:
        return False
    eng[].set_capture_metrics(True)
    return eng[].capture_metrics()


def take_ring_metric_points(worker_id: Int = 0) -> List[MetricPoint]:
    """Move out and clear the INSTALLED engine's retained metric buffer for
    `worker_id`. Returns an EMPTY list when no engine is installed.

    ⭐ THE OTHER END OF `enable_ring_metric_capture`, AND IT IS DELIBERATELY THE
    SAME SHAPE: resolve the process-global immortal engine, or answer honestly
    that there is none. Without this function the chain has a producer
    (`RingMetricSink` -> ring(0)) and a retainer (`SharedEngine._metric_buf`)
    and no way for a binary that did not build the engine to reach the points.

    ⛔ THE ENGINE IS NOT REACHABLE ANY OTHER WAY AFTER AN INSTALL, and that is
    why this lives here rather than on the caller. `ServiceLogSink.install()`
    `.take()`s its engine INTO `LogManager`, so after install the sink owns NO
    borrowable engine: a caller holding the sink cannot take its points. The
    same argument `ServiceLogSink.logger()` makes about borrowing the installed
    engine instead of a field, arrived at from the metric side.

    ⚠ CALL IT ON THE DRAINING THREAD, AFTER THE DRAIN. A point reaches
    `_metric_buf` only when a DRAIN decodes its `REC_METRIC` off the ring —
    `ServiceLogSink.pump()` is that drain. Taking BEFORE the pump returns the
    PREVIOUS iteration's points and leaves this one's on the ring; taking on a
    shutdown path before the final drain returns an empty list and DROPS the
    trailing interval, which is the same ordering trap `ServiceLogSink`'s
    header names for logs.

    ⚠ AN EMPTY RESULT IS AMBIGUOUS AND THE COUNTERS ARE WHAT DISAMBIGUATE IT.
    "no engine", "capture off", "nothing swept" and "already taken" all return
    `[]`. `LogManager.is_installed()`, `capture_metrics()` and
    `metrics_dropped_count()` are the three numbers that tell them apart, and a
    caller that reports on this list without them cannot distinguish a working
    idle service from a broken one."""
    # SAFETY: the process-global IMMORTAL engine (LogManager — moved to the heap
    # and unsafe_leak()-leaked at install, so never moved and never freed)
    # outlives every caller. Null-checked before any deref. The pointer is a
    # TRANSIENT LOCAL, never a stored field; the same shape
    # `enable_ring_metric_capture` above and `komira_log/facade.mojo` use.
    var eng = LogManager._resolve()
    if Int(eng) == 0:
        return List[MetricPoint]()
    return eng[].take_metric_points(worker_id)


struct RingMetricSink(MetricPointSink, Movable, Deinitable):
    """THE PRODUCTION `MetricPointSink`: a swept point becomes a `REC_METRIC` on
    the installed engine's `ring(worker_id)`.

    ⚠ `worker_id` MUST BE THE RING THE PUMP DRAINS. `ServiceLogSink.install()`
    binds the calling thread as worker 0 and `pump()` drains ring(0), so a
    service that installs a log sink on its serve thread passes 0 — the default.
    A point pushed onto a ring nobody drains is not lost, it is INVISIBLE: it
    sits there until the ring wraps, and the only number that moves is the log
    path's own overflow counter.

    ⚠ THIS IS A SINGLE-REACTOR SINK. `LogRecordRing` is SPSC and the sweep is
    single-threaded by construction (`MetricSweep._collect`'s header: "worker
    disjointness is a property of the WRITE, never of the export"), so the
    thread that ticks the sweep must be the thread that owns `worker_id`'s ring.
    That is one thread in a serve loop and it is not a property a multi-worker
    binary gets for free."""

    var worker_id: Int
    var _accepted: Int64
    var _backpressured: Int64
    var _refused_unencodable: Int64
    var _refused_histogram: Int64
    var _refused_no_engine: Int64

    def __init__(out self, worker_id: Int = 0):
        self.worker_id = worker_id
        self._accepted = Int64(0)
        self._backpressured = Int64(0)
        self._refused_unencodable = Int64(0)
        self._refused_histogram = Int64(0)
        self._refused_no_engine = Int64(0)

    # -------------------------------------------------------------------------
    # ⭐ THE COLLAPSE. The ONE place a three-valued outcome becomes the trait's
    # Bool, and the ONE place a refusal is separated from backpressure.
    # -------------------------------------------------------------------------

    def try_accept(mut self, point: MetricPoint) -> Bool:
        """Push `point` as a `REC_METRIC`. **False ONLY for a full ring.**

        Every other failure returns True — which is not "it worked", it is "do
        not offer me this again". The sweep's contract is that True advances the
        cursor; a refusal that returned False would be re-offered forever. What
        actually happened is in `refused()` and its three components."""
        # SAFETY: the immortal global engine (LogManager — moved to the heap and
        # unsafe_leak()-leaked at install, so never moved and never freed)
        # outlives every caller. Null-checked before any deref. A TRANSIENT
        # LOCAL; never a stored field.
        #
        # ⚠ THE ORIGIN CAST IS DELIBERATE, AND IT IS ABOUT THE CALLER, NOT US.
        # `LogManager._resolve()` hands back a `MutExternalOrigin` pointer, and a
        # WILDCARD origin aliases EVERYTHING — including `MetricSweep._pending`,
        # the List whose element `point` is a borrowed ref INTO while this method
        # runs. Doing a mutable operation through the raw wildcard inside the
        # sweep's drain loop tells the compiler that loop's own buffers may have
        # been mutated underneath it. `origin_of(self)` names the SINK, which is
        # disjoint from the sweep's buffers, so no such claim is made. It
        # UNDERSTATES the true lifetime — an immortal object outlives `self` by
        # construction — and understating a borrow is the conservative direction.
        # Identical reasoning and identical spelling to `ServiceLogSink.logger()`.
        var eng = LogManager._resolve().unsafe_origin_cast[origin_of(self)]()
        if Int(eng) == 0:
            # A REFUSAL. The engine is installed once at boot; a tick that finds
            # none will find none next tick too. See the header.
            self._refused_no_engine += Int64(1)
            return True
        ref ring = eng[].ring(self.worker_id)
        var outcome = emit_metric_record(ring, point, read_raw_ticks())
        if outcome == METRIC_EMIT_PUSHED:
            self._accepted += Int64(1)
            return True
        if outcome == METRIC_EMIT_RING_FULL:
            # ⭐ THE ONLY LEGITIMATE FALSE. The cursor does not advance and the
            # sweep re-offers this exact point next tick — DROP becomes LATENCY.
            self._backpressured += Int64(1)
            return False
        self._refused_unencodable += Int64(1)
        return True

    def try_accept_histogram(mut self, point: HistogramPoint) -> Bool:
        """⛔ ALWAYS A REFUSAL TODAY, AND ALWAYS `True`.

        The ring codec is SCALAR-only, with no arena codec: an OTel default
        explicit-bucket `HistogramPoint` is count + sum + min + max + 12 buckets
        = 128 B of payload plus 12 B of header, and `ARG_INLINE_BYTES` is 48, so
        it needs the `FLAG_HAS_ARG_OVERFLOW` arena path that has no encoder, no
        decoder and no second buffer (`metric_emit.mojo`'s "THE HISTOGRAM IS A
        NAMED RESIDUAL" block lists exactly what building it takes).

        So there is nowhere to put this point — not now, and not on the next
        tick either. Returning False here would livelock the export on the FIRST
        histogram series any service records, taking every scalar series in the
        process down with it, because the sweep finishes a generation before
        starting the next one. Dropped, counted in `refused_histogram()`, and
        the cursor advances.

        ⚠ WHEN THE ARENA CODEC LANDS, THIS METHOD IS THE ONLY THING THAT
        CHANGES: `refused_histogram()` going to zero is the observable that says
        so, and a non-zero value is the honest statement that this process's
        histograms are being discarded."""
        self._refused_histogram += Int64(1)
        return True

    # -------------------------------------------------------------------------
    # Observability of the sink itself. Every one of these is a number a
    # dashboard can carry, and the split between them is the point of the file.
    # -------------------------------------------------------------------------

    @always_inline
    def accepted(self) -> Int:
        """Points that reached the ring. The chain's only positive evidence."""
        return Int(self._accepted)

    @always_inline
    def backpressured(self) -> Int:
        """Pushes refused by a FULL RING. NOT a loss — the sweep did not advance
        its cursor, so each of these points was re-offered. Non-zero means the
        log ring is undersized relative to the metric burst, i.e. export
        LATENCY."""
        return Int(self._backpressured)

    @always_inline
    def refused_unencodable(self) -> Int:
        """Points `build_metric_record` REFUSED (a kind the two-bit ring field
        cannot hold, including the default `METRIC_KIND_UNKNOWN`). LOST, on
        purpose: encoding one would put a record on the ring claiming to be a
        histogram."""
        return Int(self._refused_unencodable)

    @always_inline
    def refused_histogram(self) -> Int:
        """`HistogramPoint`s dropped for want of the arena codec. LOST. See
        `try_accept_histogram`."""
        return Int(self._refused_histogram)

    @always_inline
    def refused_no_engine(self) -> Int:
        """Points dropped because no engine was installed — the service is
        running without a log sink, so there is no ring at all. LOST."""
        return Int(self._refused_no_engine)

    @always_inline
    def refused(self) -> Int:
        """Every point this sink DROPPED, across the three refusal arms.

        ⭐ THE NUMBER THAT IS NOT `backpressured()`. These points will never be
        re-offered; those ones already were. Summing the two would report a
        latency figure as a loss figure and vice versa."""
        return (
            Int(self._refused_unencodable)
            + Int(self._refused_histogram)
            + Int(self._refused_no_engine)
        )
