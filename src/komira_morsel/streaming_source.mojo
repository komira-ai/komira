# =============================================================================
# StreamingMorselSource -- first-class streaming source contract (CONTRACTS ONLY)
# =============================================================================
#
# Streaming ADR Phase 0, items 2-4 (an internal doc §5.3, EPIC
# / ). DISTINCT from the batch `MorselSourceImpl` trait
# (`morsel_source.mojo`): a batch source's `next_morsel` returns
# `Optional[Morsel]` which HARD-CODES "no data == permanent EOF" (latches
# `None`). A streaming source must distinguish "no data RIGHT NOW, the source
# is still live" (`Idle`) from "no more data, ever" (`Closed`) — that
# distinction is the whole reason this trait exists (ADR §5.3).
#
# CONTRACTS-ONLY (Phase 0): trait + type + enum definitions. NO impls, NO
# streaming behavior. The batch path is UNCHANGED — this trait is additive
# and does NOT overload `MorselSourceImpl`.
#
# NOTE ON THE MORSEL HOT TYPE (carrier tag DEFERRED — v1/v2 review decision):
# the ADR Phase-0 list mentioned a cold Morsel waterline/step-id carrier tag;
# the reviews DECIDED watermark propagation is OUT-OF-BAND — the waterline is
# advanced at the STEP boundary, operator-local, NOT carried on the Morsel
# (workers reorder morsels). This file therefore does NOT touch the hot
# `Morsel` type. The step driver carries step-id/waterline out-of-band later.
#
# ENCAPSULATION (maintainer rule): every type here is a safe type. The opaque
# `Position` is serialized to/from a `ByteBuffer` (a safe Movable byte
# container that owns its `List[UInt8]`), NEVER a raw pointer. No
# `UnsafePointer` crosses any boundary in this contract surface.
# =============================================================================

from komira_core.collections.byte_buffer import ByteBuffer
from .morsel import Morsel


# -----------------------------------------------------------------------------
# CheckpointSerializable -- the bound the OPAQUE, source-owned Position satisfies
# -----------------------------------------------------------------------------
#
# THE Offset abstraction (the maintainer's "be careful with the traits" ask). The
# stream position is NOT a framework `Int64` — a single scalar fits broker +
# WAL but CANNOT express the FS-tail source's out-of-order frontier (forcing
# it onto a scalar mtime watermark re-introduces Spark's silent-skip bug, ADR
# §5.4). Instead the position is an OPAQUE, SOURCE-OWNED associated type
# (FLIP-27: "the split IS the state"), bounded ONLY by the ability to
# serialize itself to a checkpointable byte form. The streaming engine never
# inspects a Position's internals — it captures `current_position()` into the
# OFFSET-LOG before compute, and `seek()`s it back on recovery; the bytes are
# what land durably in the CAS checkpoint manifest.
#
# How the ONE abstraction genuinely generalizes across the 3 sources:
#   * BROKER     -> a monotonic `Int64` offset. `to_checkpoint_bytes` = 8 LE
#                   bytes; `from_checkpoint_bytes` = read them back. Trivial.
#   * HTTP-via-WAL -> literally the broker position (the HTTP front appends to
#                   a WAL topic; the source is the broker source pointed at it).
#                   Same 8-byte LE offset. ADR §5.3 / §5.5.
#   * FS-TAIL    -> a HYBRID FRONTIER: a LOW-watermark (everything strictly
#                   below is fully committed & forgettable) + a BOUNDED
#                   recent-set (the frontier window above it where out-of-order
#                   arrivals are still possible), each file keyed by
#                   etag/version (Spark's same-name-recreate trap, ADR §5.4).
#                   `to_checkpoint_bytes` serializes BOTH the low-watermark AND
#                   the bounded recent-set — a structured, variable-length
#                   blob. A scalar offset could NEVER express this; the
#                   byte-blob contract can, because the SOURCE owns the codec.
#
# That is why the bound is "serialize yourself", not "be an integer": the
# offset, the WAL position, and the FS-tail frontier are all just bytes the
# source knows how to round-trip, and the checkpoint substrate stores bytes.
# -----------------------------------------------------------------------------

trait CheckpointSerializable(Copyable, Movable, Deinitable):
    """A source-owned stream position that can round-trip through a checkpoint.

    The bound on `StreamingMorselSource.Position`. Implementors define how
    THEIR position serializes — a broker offset is 8 LE bytes; an FS-tail
    frontier is a low-watermark plus a bounded recent-set blob. The engine
    treats the result as opaque bytes: it lands them in the durable
    offset-log / checkpoint manifest and hands them back to `seek` on
    recovery.

    The two halves are inverses:
        from_checkpoint_bytes(p.to_checkpoint_bytes()) == p

    ENCAPSULATION: positions serialize to / from a `ByteBuffer` (owns
    `List[UInt8]`, a safe Movable container) — NEVER a raw pointer. The
    read side takes the buffer by owned `var` (matching the in-tree
    `DbStorable.from_row` / `Proto3Json.from_json_value` static-factory
    shape) so the trait method stays non-parametric and AOT-clean; a
    concrete-origin `ByteView` over the buffer is available internally via
    `ByteBuffer.view_at[origin]` when an impl wants a borrowed read cursor.
    """

    def to_checkpoint_bytes(self) raises -> ByteBuffer:
        """Serialize this position to a self-describing, checkpointable byte
        form. The SOURCE owns the codec (length-prefixed / framed as the
        source sees fit) — the engine never parses it."""
        ...

    @staticmethod
    def from_checkpoint_bytes(var bytes: ByteBuffer) raises -> Self:
        """Reconstruct a position from bytes produced by
        `to_checkpoint_bytes`. Called on recovery before `seek`. Takes the
        buffer by owned move (safe container; no raw pointer)."""
        ...


# -----------------------------------------------------------------------------
# StreamPoll -- the QUAD-STATE poll result (Item | Idle | Watermark | Closed)
# -----------------------------------------------------------------------------

comptime STREAM_POLL_ITEM: UInt8 = 0
"""A morsel is available; reach it via `take_item()`."""
comptime STREAM_POLL_IDLE: UInt8 = 1
"""No data RIGHT NOW, but the source is still LIVE (NOT permanent EOF). The
step driver parks / re-polls later. This is the state the batch
`Optional[Morsel]` cannot express (it latches `None` as EOF)."""
comptime STREAM_POLL_WATERMARK: UInt8 = 2
"""A source-generated event-time watermark; the timestamp is `watermark_ts`.
Flink-style source watermark (ADR §6.2) — advances the operator-local
waterline OUT-OF-BAND at the step boundary, NOT via the Morsel carrier."""
comptime STREAM_POLL_CLOSED: UInt8 = 3
"""Permanent end-of-stream: no more items, ever. The scheduler must not poll
this source again (the batch-source EOF contract, but now an EXPLICIT 4th
state distinct from Idle)."""


@fieldwise_init
struct StreamPoll(Movable, Deinitable):
    """The quad-state result of `StreamingMorselSource.poll_next` (ADR §5.3).

    Tagged-union (Mojo has no native sum type) following the in-tree
    `TryRecvOutcome` idiom (`spsc.mojo`): a `status: UInt8` discriminant plus
    an `Optional[Morsel]` payload (present only for `Item`) plus an `Int64`
    watermark slot (meaningful only for `Watermark`).

    Movable-not-Copyable: it OWNS its `Optional[Morsel]` payload (Morsel is
    Movable-only). The primary move-out accessor is `take_item()`.

    The four states:
        Item(Morsel)   -- a chunk of rows; `take_item()`         (status 0)
        Idle           -- live but no data now; park & re-poll   (status 1)
        Watermark(ts)  -- source watermark; `watermark()`        (status 2)
        Closed         -- permanent EOF; stop polling            (status 3)
    """

    var status: UInt8
    var _item: Optional[Morsel]
    var _watermark_ts: Int64

    @staticmethod
    def item(var morsel: Morsel) -> StreamPoll:
        return StreamPoll(
            status=STREAM_POLL_ITEM,
            _item=Optional[Morsel](morsel^),
            _watermark_ts=Int64(0),
        )

    @staticmethod
    def idle() -> StreamPoll:
        return StreamPoll(
            status=STREAM_POLL_IDLE,
            _item=Optional[Morsel](),
            _watermark_ts=Int64(0),
        )

    @staticmethod
    def watermark(ts: Int64) -> StreamPoll:
        return StreamPoll(
            status=STREAM_POLL_WATERMARK,
            _item=Optional[Morsel](),
            _watermark_ts=ts,
        )

    @staticmethod
    def closed() -> StreamPoll:
        return StreamPoll(
            status=STREAM_POLL_CLOSED,
            _item=Optional[Morsel](),
            _watermark_ts=Int64(0),
        )

    @always_inline
    def is_item(self) -> Bool:
        return self.status == STREAM_POLL_ITEM

    @always_inline
    def is_idle(self) -> Bool:
        return self.status == STREAM_POLL_IDLE

    @always_inline
    def is_watermark(self) -> Bool:
        return self.status == STREAM_POLL_WATERMARK

    @always_inline
    def is_closed(self) -> Bool:
        return self.status == STREAM_POLL_CLOSED

    def take_item(mut self) -> Morsel:
        """Move the Morsel OUT (status == ITEM only). Leaves the Optional
        in `None`. Caller MUST verify `is_item()` first."""
        return self._item.take()

    @always_inline
    def watermark_ts(self) -> Int64:
        """The event-time watermark (status == WATERMARK only)."""
        return self._watermark_ts


# -----------------------------------------------------------------------------
# BacklogReading -- the scalar backlog a source CAN report (ADR §8A.0 / §8A.2)
# -----------------------------------------------------------------------------
#
# The streaming micro-batch GOVERNOR (ADR §8A.8(a), the first concrete slice of
# the scaling model) drives `_max_items_per_step` off the source's backlog. Lag
# is *free* for the broker source — one subtraction over two already-read values
# (`num_chunks - drained_chunks` and `next_offset - cursor_offset`, ADR §8A.0).
# But NOT every source can report a scalar backlog: the FS-tail source has an
# out-of-order frontier (a low-watermark + a bounded recent-set), not a scalar
# offset, so it cannot say "I am N behind." `backlog()` is therefore OPTIONAL —
# a source that cannot report a scalar backlog returns `None`, and the governor
# HOLDS `_max_items_per_step` unchanged (a no-op) for that step.
#
# `BacklogReading` carries BOTH backlog axes the broker source has (the brief's
# "lag / lag_budget OR arrival/drain ratio"):
#   * `outstanding` — items (chunks) committed at the source head but NOT yet
#     consumed (`num_chunks - drained_chunks`). The raw lag.
#   * `budget`      — the lag budget: how many outstanding items is "keeping up"
#     (the steady-state target). pressure == outstanding / budget; > 1.0 means
#     behind, < 1.0 means spare. A source sets `budget` to its per-step poll cap
#     (the most one step CAN drain) so pressure == 1.0 exactly when the backlog
#     equals one step's drain capacity.
#
# A safe POD value type (two Int64 scalars); Copyable so it threads freely as an
# `Optional[BacklogReading]` return. No pointer crosses; never a byte-slab elem.
# -----------------------------------------------------------------------------


struct BacklogReading(ImplicitlyCopyable, Movable, Deinitable):
    """A scalar backlog snapshot a streaming source CAN optionally report
    (ADR §8A.0 / §8A.2). The micro-batch governor reads it at the step boundary
    to compute demand-side pressure (`outstanding / budget`). A source that
    cannot express a scalar backlog (FS-tail's out-of-order frontier) returns
    `None` from `backlog()` and the governor HOLDS the burst unchanged.

    Fields:
      var outstanding: Int64 — committed-but-unconsumed items at the source head
        (the raw lag; broker == `num_chunks - drained_chunks`).
      var budget: Int64      — the lag budget: outstanding == budget is the
        steady-state target (pressure == 1.0). Typically the per-step poll cap.

    POD value type (two Int64 scalars); no pointer, no wildcard, never a byte-
    slab element. `pressure()` is computed by the `StreamingSourceLag` signal,
    not here — this is a pure data carrier."""

    var outstanding: Int64
    var budget: Int64

    def __init__(out self, outstanding: Int64, budget: Int64 = Int64(1)):
        """`budget` defaults to 1 (a zero/negative budget is clamped to 1 by the
        signal so pressure is always well-defined)."""
        self.outstanding = outstanding
        self.budget = budget if budget > Int64(0) else Int64(1)


# -----------------------------------------------------------------------------
# StreamSourceCaps -- streaming-source capability descriptor (ADR §6.1)
# -----------------------------------------------------------------------------


struct StreamSourceCaps(ImplicitlyCopyable, Movable):
    """Capability descriptor a streaming source advertises (ADR §5.3 / §6.1).

    The planner consults these BEFORE promising exactly-once: EO requires a
    `replayable` source whose position is checkpointed (`seek`-able) AND a
    qualifying sink class (`StreamingMorselSink.sink_class()`). A non-
    replayable source forces a plan-time downgrade, surfaced LOUDLY (ADR
    §6.1 "ALO as downgrade, NOT a mode").

    Phase 0 declares the fields; Phase 1+ concrete sources set them.
    """

    var is_unbounded: Bool
    """True for a forever-running stream (broker tail, FS-tail, HTTP-WAL).
    A global sort / distinct over an unbounded source with no bounding
    window is a plan-time error (ADR §3.4 PipelineChecker)."""

    var replayable: Bool
    """True if the source can `seek(position)` back to a checkpointed
    position and re-emit the same items deterministically. LEG 1 of the EO
    tripod (ADR §6.1). Broker/WAL: yes (offset seek); FS-tail: yes
    (re-discover + skip <= low-watermark + skip recent-set)."""

    var emits_watermark: Bool
    """True if the source generates event-time watermarks (returns
    `StreamPoll.watermark(ts)`). Flink-style source watermark (ADR §6.2).
    Sources without an event-time column leave this False."""

    var exactly_once_capable: Bool
    """True if the source satisfies its half of the EO contract: replayable
    AND its position is durably checkpointable (the `Position` round-trips
    via `CheckpointSerializable`). The planner ANDs this with the sink's
    class to decide EO-vs-ALO at plan time (ADR §6.1)."""

    def __init__(
        out self,
        is_unbounded: Bool = False,
        replayable: Bool = False,
        emits_watermark: Bool = False,
        exactly_once_capable: Bool = False,
    ):
        self.is_unbounded = is_unbounded
        self.replayable = replayable
        self.emits_watermark = emits_watermark
        self.exactly_once_capable = exactly_once_capable


# -----------------------------------------------------------------------------
# StreamingMorselSource -- the trait (DISTINCT from batch MorselSourceImpl)
# -----------------------------------------------------------------------------


trait StreamingMorselSource(Movable, Deinitable):
    """First-class streaming source contract (ADR §5.3). CONTRACTS-ONLY.

    DISTINCT from the batch `MorselSourceImpl` trait — do NOT overload it.
    A batch source returns `Optional[Morsel]` (None == permanent EOF); a
    streaming source returns the quad-state `StreamPoll` so the step driver
    can tell `Idle` (live, no data now -> park & re-poll) from `Closed`
    (permanent EOF -> stop polling). `Idle != Closed` is the reason this
    trait exists.

    The associated `Position` is the OPAQUE, source-owned, checkpointable
    token (see `CheckpointSerializable` above) — NOT a framework Int64. The
    engine captures `current_position()` into the durable offset-log BEFORE
    compute, and `seek()`s it back on recovery (an OWNED MOVE).

    TRAIT-HIERARCHY BINDING (PINNED, ADR §1.2): a streaming source's
    position is ALLOCATED / linearized by the broker-log / WAL face, which
    binds `ConditionalWriteStore` via `CasManifestStore` (the CAS append IS
    the offset/LSN allocator). The FS-tail source's frontier is checkpointed
    through the same CAS-manifest checkpoint face. NO streaming source binds
    `FileSystem` alone for position allocation — only spill does, and spill
    is not a streaming source. The Position bytes (`CheckpointSerializable`)
    are what land in that CAS manifest.

    ENCAPSULATION: no `UnsafePointer` in any signature; `Position`
    round-trips via `ByteBuffer` / `ByteView`, never raw pointers.
    """

    comptime Position: CheckpointSerializable

    def poll_next(mut self, worker_id: Int) raises -> StreamPoll:
        """Poll for the next item. Returns one of Item / Idle / Watermark /
        Closed (see `StreamPoll`). `Idle` means live-but-no-data-now (park
        and re-poll); `Closed` means permanent EOF (never poll again)."""
        ...

    def current_position(self) -> Self.Position:
        """The position to capture into the OFFSET-LOG before compute. On
        recovery this is the value `seek` is called with to resume."""
        ...

    def seek(mut self, var pos: Self.Position) raises:
        """Restore the source to a checkpointed position (recovery / resume).
        Takes the position by OWNED MOVE (ADR §6.1 leg 1)."""
        ...

    def capabilities(self) -> StreamSourceCaps:
        """Advertise boundedness / replayable / watermark / EO capability.
        The planner consults this BEFORE promising exactly-once (ADR §6.1)."""
        ...

    def backlog(mut self) raises -> Optional[BacklogReading]:
        """Report the source's current scalar backlog, IF it can express one
        (ADR §8A.0 / §8A.2). The micro-batch governor reads this at the step
        boundary to compute demand-side pressure (`outstanding / budget`).

        OPTIONAL by design: a source whose position is NOT a scalar offset
        (the FS-tail source's out-of-order frontier — a low-watermark + a
        bounded recent-set) cannot report a scalar backlog and returns the
        DEFAULT `None`; the governor then HOLDS `_max_items_per_step` unchanged
        for that step (a no-op). The broker source overrides this to return
        `Some(BacklogReading(num_chunks - drained_chunks, poll_cap))` — lag is
        *free* there (one subtraction over two already-read values).

        DEFAULT: `None` (cannot report a scalar backlog). This default keeps the
        method ADDITIVE — existing conformers that do not report a backlog need
        no change; the governor treats them as hold-only sources."""
        return Optional[BacklogReading]()

    def consumer_epoch_cursor(self) -> Int64:
        """The durable, checkpointed SHUFFLE-READ epoch cursor IF this source is
        a per-epoch shuffle CONSUMER (the multi-segment retention/GC floor input,
        ADR §3 net-new #2). The cursor is "the next epoch to poll" — a consumer
        at cursor `c` has read-and-checkpointed THROUGH `c-1` and STILL needs
        epoch `c` onward, so the cross-epoch reaper's reclaim floor =
        `min(consumer_cursors)` and an epoch `e` is reclaimable iff `e < floor`
        (the slowest consumer's durable position pins the floor; see
        `komira_objectstore.shuffle_retention`).

        DEFAULT: `Int64.MAX` — a source that is NOT a shuffle consumer (a broker
        tail, an FS-tail, a synthetic test source) does NOT pin any retention
        floor. Returning the MAX sentinel makes a non-consumer a no-op in the
        `min(consumer_cursors)` floor (it can never lower the floor), so a
        pipeline with no shuffle consumer simply never reaps — the fail-SAFE
        direction (when no consumer pins a floor, RETAIN). `ShuffleReadSource`
        OVERRIDES this to return its `_cursor_epoch`. This default keeps the
        method ADDITIVE — every existing conformer inherits it untouched
        (the same additive shape as `backlog()` above)."""
        return Int64.MAX
