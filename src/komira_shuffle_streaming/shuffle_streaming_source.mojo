# =============================================================================
# komira_shuffle_streaming/shuffle_streaming_source.mojo
#   ShuffleReadSource — segment N+1's input as a first-class STREAMING source
#   (the SEGMENT-CUT read side of multi-segment continuous streaming).
# =============================================================================
#
# Multi-segment streaming. The PROVEN free
# fn is read_shuffle_partition(step_id: Int64) — the SOLE reduce-facing read
# barrier (block-on-absence + exact-producer-set re-verify). epoch == step_id.
#
# -----------------------------------------------------------------------------
# THE QUAD-STATE poll_next (the IDLE-on-unsealed gate is load-bearing)
# -----------------------------------------------------------------------------
# `poll_next` reads this reducer's partition (`_partition_id`) of the CURRENT
# cursor epoch via the proven `read_shuffle_partition`:
#
#   * ITEM   — the current epoch is SEALED and has data for this pid. Decode the
#              concatenated `[len][payload]` frames back into the value column,
#              return one Item morsel, ADVANCE the cursor to the next epoch.
#   * IDLE   — the current epoch is NOT yet sealed (segment N is still forming
#              it). `read_shuffle_partition` BLOCKS-on-absence then RAISES (the
#              proven per-epoch gate); we catch the seal-absence raise and return
#              `Idle` (LIVE, NOT EOF — the driver parks + re-polls; a later seal
#              makes the next poll an Item). This is THE distinction the batch
#              `Optional[Morsel]` cannot express (it latches None as EOF).
#   * CLOSED — only on a permanent end signal (`mark_closed()` — the upstream
#              segment will mint no further epochs). A continuous stream never
#              closes on its own (an unsealed epoch is Idle, not EOF).
#
# IDLE != CLOSED is the whole reason the streaming trait exists (a
# withheld seal is IDLE, not error). A SEALED-but-EMPTY epoch (segment N
# committed a step that produced no delta for this pid) is an Item with a
# zero-row morsel — the dense-index-incl-zero-length read returns 0 bytes, never
# blocks (the per-epoch empty-partition property); the cursor advances past it.
#
# -----------------------------------------------------------------------------
# THE EPOCH CURSOR + BACKLOG (the epoch-lag for the micro-batch governor)
# -----------------------------------------------------------------------------
# Position = `EpochCursor` (CheckpointSerializable): the epoch the consumer has
# read THROUGH (the next epoch to poll). 8 LE bytes, like a broker
# offset. `seek(EpochCursor)` replays from that epoch (re-reads the SAME
# durable sealed `.seg` keys deterministically — the seal is immutable once
# written). `backlog() = latest_sealed_epoch - cursor_epoch` (the epoch lag)
# feeds the UPSTREAM segment's MicroBatchGovernor between steps.
# caps = unbounded + replayable + exactly_once_capable.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline (the Mojo pointer rules)
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins / `unsafe_from_address` / `take_pointee`.
#   * Position is `EpochCursor`, round-trips via `ByteBuffer` (owns
#     `List[UInt8]`) — NEVER a raw pointer.
#   * `_store: S` held BY VALUE (clone-shared substrate); `_expected_producers`
#     is an owned `List[Int64]`. The source is a stack/struct value, not a
#     byte-slab element (owned Movable substrate + POD Int64
#     scalars; NO heap-owning inner field stored in any Slab). The
#     role is a concrete typed Movable field, NOT byte-slab-stored.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_buffer.byte_buffer import ByteBuffer

from komira_objectstore.store import CloneableConditionalWriteStore
from komira_shuffle.source import (
    read_shuffle_partition,
    decode_partition_payloads,
)

from komira_morsel.morsel import Morsel
from komira_morsel.streaming_source import (
    BacklogReading,
    CheckpointSerializable,
    StreamingMorselSource,
    StreamPoll,
    StreamSourceCaps,
)

from .shuffle_streaming_codec import decode_value_payload


# =============================================================================
# EpochCursor — the opaque, source-owned epoch position.
# =============================================================================
#
# The shuffle-read position IS a monotonic Int64 epoch (the next epoch to poll).
# It conforms `CheckpointSerializable`: `to_checkpoint_bytes` = 8 LE bytes;
# `from_checkpoint_bytes` reads them back. The engine treats it as opaque — it
# lands the bytes in the WAL offset-log + hands them back to `seek` on recovery.
# A seek-back re-reads the SAME immutable sealed epochs (replay-correct).
# =============================================================================


struct EpochCursor(CheckpointSerializable):
    """The opaque, source-owned shuffle-read position: the epoch (step_id) the
    consumer has read THROUGH (the next epoch to poll). Round-trips through a
    `ByteBuffer` (8 LE bytes) for the WAL offset-log / checkpoint manifest. POD
    value type (one Int64); no pointer, no wildcard, never a byte-slab element."""

    var epoch: Int64

    def __init__(out self, epoch: Int64 = Int64(0)):
        self.epoch = epoch

    def copy(self) -> Self:
        return EpochCursor(self.epoch)

    def to_checkpoint_bytes(self) raises -> ByteBuffer:
        """Serialize to 8 LE bytes (the source owns the codec). `seek(
        from_checkpoint_bytes(to_checkpoint_bytes(p))) == seek(p)`."""
        var data = List[UInt8]()
        var u = UInt64(self.epoch)
        for i in range(8):
            data.append(UInt8(Int((u >> UInt64(8 * i)) & UInt64(0xFF))))
        return ByteBuffer(data^)

    @staticmethod
    def from_checkpoint_bytes(var bytes: ByteBuffer) raises -> Self:
        """Reconstruct from the 8 LE bytes `to_checkpoint_bytes` produced.
        Called on recovery before `seek`. Takes the buffer by owned move."""
        var v = bytes.read_u64_le()
        return EpochCursor(Int64(v))


# -----------------------------------------------------------------------------
# Seal-absence detection: the proven block-on-absence raise carries "absent" in
# its message (komira_shuffle seal_driver.read_seal — "seal absent after N park
# iterations"). The streaming source maps THAT raise (and only that one) to
# IDLE; a torn-set / corrupt-seal raise (committed ⊊ expected) propagates as a
# real error. This is the documented contract (the continuous-epoch falsifying
# test 1 asserts the absence raise names "absent"), not message-fragility — the
# seal-absence signal is the per-epoch IDLE gate.
# -----------------------------------------------------------------------------


def _is_seal_absent_error(msg: String) -> Bool:
    """True iff a `read_shuffle_partition` raise was the block-on-absence of an
    unsealed epoch (-> IDLE), vs a real error (torn set / corrupt -> propagate).
    Matches the proven `read_seal` absence message ("seal absent after ...")."""
    return msg.find(String("absent")) >= 0


# =============================================================================
# ShuffleReadSource[S] — segment N+1's input as a streaming shuffle-read.
# =============================================================================
#
# Generic over `S: CloneableConditionalWriteStore` — the SAME backend selector
# the sink + seal bind, so single-node (LocalFs / in-memory) and multi-node
# (S3ConditionalStore[C]) become the SAME source differing only in store backend
# (the object-store-defined per-epoch shuffle is the CORRECTNESS
# CONTRACT, byte-identical across backends).
#
# The per-poll forward probe cap bounds how far ahead `backlog()` scans for the
# latest sealed epoch (a bounded, advisory governor signal — never a correctness
# input). Tunable at construction.
# =============================================================================

comptime _DEFAULT_BACKLOG_PROBE_CAP: Int = 64


struct ShuffleReadSource[S: CloneableConditionalWriteStore](
    StreamingMorselSource
):
    """Segment N+1's input as a first-class `StreamingMorselSource`:
    poll this reducer's partition of the current cursor epoch via the proven
    `read_shuffle_partition`. `Item` when the epoch is sealed + has data; `Idle`
    when the epoch is NOT yet sealed (block-on-absence -> the driver parks +
    re-polls — NOT EOF); `Closed` only on a permanent end signal. The opaque
    position is an `EpochCursor` (the epoch read through). `backlog()` is the
    epoch-lag (latest_sealed_epoch - cursor_epoch) for the micro-batch governor.

    Wraps the PROVEN free fn (plumbing, not protocol) — epoch == step_id; the
    shuffle namespace is per-step-keyed (no protocol change).

    Fields:
      var _store: S                 — the durable shuffle store (clone-shared).
      var _shuffle_id: Int64        — the segment-cut shuffle namespace id.
      var _partition_id: Int64      — THIS reducer's partition id (the pid it
        reads from every epoch).
      var _partition_count: Int64   — R (used by read_shuffle_partition's range
        check; the seal carries the authoritative R).
      var _cursor_epoch: Int64      — the next epoch to poll (the position).
      var _expected_producers: List[Int64] — the plan-fixed producer set the
        seal-read re-verifies each-once (MUST equal the set the driver sealed).
      var _max_park_iters: Int      — the bounded park `read_shuffle_partition`
        uses per poll before raising seal-absent (-> Idle). Small (the streaming
        driver re-polls; it does NOT want a long in-call block).
      var _closed: Bool             — set by `mark_closed()`; once true poll_next
        returns Closed (the permanent end signal).
      var _backlog_probe_cap: Int   — the bounded forward probe `backlog()` uses
        to find the latest sealed epoch (advisory; never a correctness input).
    """

    var _store: Self.S
    var _shuffle_id: Int64
    var _partition_id: Int64
    var _partition_count: Int64
    var _cursor_epoch: Int64
    var _expected_producers: List[Int64]
    var _max_park_iters: Int
    var _closed: Bool
    var _backlog_probe_cap: Int

    def __init__(
        out self,
        var store: Self.S,
        shuffle_id: Int64,
        partition_id: Int64,
        partition_count: Int64,
        var expected_producers: List[Int64],
        start_epoch: Int64 = Int64(0),
        max_park_iters: Int = 2,
        backlog_probe_cap: Int = _DEFAULT_BACKLOG_PROBE_CAP,
    ):
        """Construct a shuffle-read source over a durable store.

        `shuffle_id` is the segment-cut namespace; `partition_id` is THIS
        reducer's pid; `partition_count` is R; `expected_producers` is the
        plan-fixed producer set the seal-read re-verifies (MUST equal the
        driver's set); `start_epoch` is the first epoch to poll (0 = the head);
        `max_park_iters` is the bounded in-call park before seal-absent -> Idle
        (small: the streaming driver re-polls between steps, so a poll should NOT
        block long)."""
        self._store = store^
        self._shuffle_id = shuffle_id
        self._partition_id = partition_id
        self._partition_count = partition_count
        self._cursor_epoch = start_epoch
        self._expected_producers = expected_producers^
        self._max_park_iters = max_park_iters if max_park_iters > 0 else 1
        self._closed = False
        self._backlog_probe_cap = (
            backlog_probe_cap if backlog_probe_cap > 0 else 1
        )

    # =========================================================================
    # StreamingMorselSource conformance.
    # =========================================================================

    comptime Position = EpochCursor

    def poll_next(mut self, worker_id: Int) raises -> StreamPoll:
        """Poll this reducer's partition of the CURRENT cursor epoch via the
        proven `read_shuffle_partition`.

        Returns:
          * `Item(morsel)` — the cursor epoch is SEALED + has data for this pid:
            decode the partition body into a 1-column Int64 `value` RecordBatch,
            wrap it in a Morsel, ADVANCE the cursor. A SEALED-but-EMPTY epoch
            (0 bytes for this pid — the dense-index-zero read) is an Item with a
            zero-row morsel; the cursor still advances (the epoch IS done).
          * `Idle` — the cursor epoch is NOT yet sealed: `read_shuffle_partition`
            blocks-on-absence then raises; we map the seal-absence raise to Idle
            (LIVE, NOT EOF). The driver parks + re-polls; a later seal -> Item.
          * `Closed` — only after `mark_closed()` (the permanent end signal)."""
        if self._closed:
            return StreamPoll.closed()

        var epoch = self._cursor_epoch
        try:
            var body = read_shuffle_partition(
                self._store,
                self._shuffle_id,
                epoch,
                self._partition_id,
                self._expected_producers,
                self._max_park_iters,
            )
            # Sealed (possibly empty) — decode the partition body into a morsel.
            var morsel = self._body_to_morsel(body, Int(epoch))
            # Advance the cursor past the (now-read) epoch.
            self._cursor_epoch = epoch + Int64(1)
            return StreamPoll.item(morsel^)
        except e:
            var msg = String(e)
            if _is_seal_absent_error(msg):
                # The epoch is not yet sealed (segment N still forming it) —
                # IDLE, not EOF. The driver parks + re-polls.
                return StreamPoll.idle()
            # A real error (torn producer set / corrupt seal) — propagate.
            raise e^

    def current_position(self) -> Self.Position:
        """The cursor epoch (next to poll) to capture into the WAL offset-log
        BEFORE compute. On recovery this is the value `seek` is called with to
        resume (the replayable position for exactly-once)."""
        return EpochCursor(self._cursor_epoch)

    def seek(mut self, var pos: Self.Position) raises:
        """Replay from a checkpointed epoch (recovery / resume). Sets the cursor
        to `pos.epoch` so the next poll re-reads the SAME immutable sealed `.seg`
        keys deterministically (the seal is immutable once written; a seek-back +
        re-poll reproduces the identical row sequence — the EO source leg). Takes
        the position by OWNED MOVE."""
        self._cursor_epoch = pos.epoch
        self._closed = False

    def capabilities(self) -> StreamSourceCaps:
        """Advertise the shuffle-read source's capabilities: unbounded (segment
        N mints epochs forever), replayable (epoch-cursor seek over immutable
        sealed epochs), and exactly_once_capable (the position round-trips
        durably -> the EO source leg). Does NOT emit a watermark (event-time
        crosses the cut via the seal's watermark field, a later increment).
        The planner ANDs this with the sink's class to
        decide EO-vs-ALO at plan time."""
        return StreamSourceCaps(
            is_unbounded=True,
            replayable=True,
            emits_watermark=False,
            exactly_once_capable=True,
        )

    def backlog(mut self) raises -> Optional[BacklogReading]:
        """Report the epoch-lag: `outstanding =
        latest_sealed_epoch - cursor_epoch` (the number of sealed-but-unconsumed
        epochs at the head), `budget = 1` (one epoch per step is the steady-state
        target, so pressure == 1.0 exactly when the consumer is one epoch behind).

        The latest sealed epoch is found by a BOUNDED forward probe from the
        cursor (try reading partition 0 of successive epochs with a 1-iter park;
        the last present seal is the latest sealed). This is an ADVISORY governor
        signal, NOT a correctness input — a bounded probe is the right shape (a
        far-ahead producer is capped at `_backlog_probe_cap`; the governor reads
        a lower bound on the lag, the safe direction). This feeds the UPSTREAM
        segment's MicroBatchGovernor to throttle its epoch-mint rate (the
        epoch-lag is the cross-segment backpressure signal)."""
        var latest_sealed = self._cursor_epoch - Int64(1)  # nothing sealed ahead yet
        var probe = self._cursor_epoch
        var iters = 0
        while iters < self._backlog_probe_cap:
            var sealed = self._epoch_is_sealed(probe)
            if not sealed:
                break
            latest_sealed = probe
            probe += Int64(1)
            iters += 1
        # Never negative: `latest_sealed` starts at cursor - 1 and only rises.
        var outstanding = latest_sealed - self._cursor_epoch + Int64(1)
        return Optional[BacklogReading](
            BacklogReading(outstanding, Int64(1))
        )

    # =========================================================================
    # Permanent end signal.
    # =========================================================================

    def mark_closed(mut self):
        """Signal the permanent end of the stream (the upstream segment will
        mint no further epochs). After this, `poll_next` returns `Closed`. A
        continuous stream never closes on its own — an unsealed epoch is Idle,
        not EOF — so the close is an EXPLICIT external signal (the facade's
        downstream-first stop)."""
        self._closed = True

    # =========================================================================
    # Helpers.
    # =========================================================================

    def _epoch_is_sealed(mut self, epoch: Int64) raises -> Bool:
        """True iff `epoch`'s per-step `_seal` is present (the epoch is readable).
        Probes via `read_shuffle_partition` on partition 0 with a 1-iter park:
        present seal -> True (no raise); seal-absent raise -> False. A real error
        (torn set / corrupt) propagates. Used by `backlog()` only — an advisory
        governor probe, NOT the poll path (poll reads THIS reducer's pid)."""
        try:
            _ = read_shuffle_partition(
                self._store,
                self._shuffle_id,
                epoch,
                Int64(0),
                self._expected_producers,
                1,
            )
            return True
        except e:
            if _is_seal_absent_error(String(e)):
                return False
            raise e^

    def _body_to_morsel(
        self, body: List[UInt8], epoch: Int
    ) raises -> Morsel:
        """Decode a partition body (concatenated `[len][payload]` frames) into a
        1-column Int64 `value` RecordBatch, wrapped in a Morsel. An EMPTY body
        (sealed-but-empty epoch for this pid) yields a zero-row morsel — never
        blocks. The value codec is the shared `decode_value_payload`."""
        var payloads = decode_partition_payloads(body)
        var n = len(payloads)
        var schema = Schema(
            names=[String("value")],
            arrow_types=[ArrowType.INT64.type_id],
            dtypes=[DType.int64],
            nullables=[False],
        )
        var v_arr = PrimitiveArray[DType.int64].allocate(n)
        for i in range(n):
            v_arr.set(i, decode_value_payload(payloads[i]))
        var v_col = Column.from_primitive[DType.int64](v_arr^)
        var batch = RecordBatch.from_typed_columns_1(schema^, v_col^)
        return Morsel(batch^, epoch, Int(self._partition_id))

    # =========================================================================
    # Observability for the test / governor.
    # =========================================================================

    @always_inline
    def cursor_epoch(self) -> Int64:
        """The next epoch to poll (the current position)."""
        return self._cursor_epoch

    @always_inline
    def consumer_epoch_cursor(self) -> Int64:
        """OVERRIDE of the `StreamingMorselSource` default (which returns the
        `Int64.MAX` no-floor sentinel for a non-consumer source): THIS source IS
        a per-epoch shuffle consumer, so it reports its durable checkpointed
        cursor — the next epoch to poll (`_cursor_epoch`). This is the retention/
        GC floor input: the reaper computes
        `reclaim_floor = min(consumer_cursors)` across all reducers and reclaims
        epoch `e` iff `e < floor` (an epoch AT the floor — at this cursor — is
        STILL NEEDED). `_cursor_epoch` advances ONLY when `poll_next` returns an
        Item (the epoch was sealed + read), so it is exactly the durable
        read-through position a checkpoint would persist (`current_position()`
        wraps the SAME value in an `EpochCursor`). Returning it here lets the
        multi-segment driver collect the floor generically through the `Segment`
        trait without naming the concrete source type."""
        return self._cursor_epoch

    @always_inline
    def partition_id(self) -> Int64:
        """This reducer's partition id."""
        return self._partition_id
