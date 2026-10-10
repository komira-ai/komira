# =============================================================================
# komira_shuffle_streaming/shuffle_streaming_sink.mojo
#   ShuffleWriteSink — segment N's output as a first-class STREAMING sink (the
#   SEGMENT-CUT write side of multi-segment continuous streaming).
# =============================================================================
#
# Multi-segment streaming. The continuous
# multi-epoch SEAL foundation (komira_shuffle
# tests/test_shuffle_continuous_epoch_seal.mojo) is PROVEN: epoch ==
# step_id; every shuffle object family is per-step-keyed (`{shuffle_id}/{step_id}/`);
# the proven free fns are sink_shuffle_write / seal_step / read_shuffle_partition.
#
# -----------------------------------------------------------------------------
# WHY A SEGMENT CUT IS A TYPE BOUNDARY (no new trait, no erasure)
# -----------------------------------------------------------------------------
# A multi-segment streaming pipeline is a DAG of segments cut at shuffle
# boundaries. Segment N's output is a `ShuffleWriteSink`;
# segment N+1's input is a `ShuffleReadSource` (shuffle_streaming_source.mojo).
# Both conform the EXISTING streaming traits (`StreamingMorselSink` /
# `StreamingMorselSource` in komira_morsel), so they slot into the existing
# source / step / sink triple with NO new trait and NO erasure —
# the cut is just a typed sink / typed source over the SAME `shuffle_id`
# namespace. This file is conformance PLUMBING over the proven, monolith-free
# free fns (sink_shuffle_write / seal_step) — it imports NONE of the heavy
# EngineContext / execute_segments tower.
#
# -----------------------------------------------------------------------------
# THE PER-EPOCH 2PC LIFECYCLE
# -----------------------------------------------------------------------------
# epoch == the StepId. The sink scatters delta rows into R buckets and writes
# them per-epoch, then seals at the step boundary. The StreamingMorselSink
# lifecycle maps onto the proven shuffle free fns 1:1:
#
#   consume(worker, morsel)  -> scatter the morsel's (key, value) rows into the
#                               CURRENT epoch's row accumulator (no IO yet —
#                               the whole step's delta is buffered, then written
#                               in one sink_shuffle_write at pre_commit so the
#                               producer's `.seg` is one dense write per epoch).
#   pre_commit(step)         -> sink_shuffle_write(store, shuffle_id, epoch=step,
#                               producer_id, R, rows): partition + write the
#                               `{producer}.seg` (DENSE R-entry trailer incl
#                               zero-length) + append `_entries` idempotently
#                               (the DedupSentinel each-once guard — a replay of
#                               the same (producer, epoch) lands no 2nd chunk).
#                               Returns a CommitToken{step, txn_handle=epoch}.
#   commit(step)             -> seal_step(store, shuffle_id, epoch=step, R,
#                               expected_producers): the driver-join seal
#                               (StepComplete{expected, committed} verified as
#                               sets, each-once). The seal is the per-epoch
#                               hand-off barrier the consumer blocks on.
#                               Then ADVANCE to the next epoch +
#                               clear the row accumulator.
#   abort(step)              -> discard the current epoch's buffered rows (the
#                               un-sealed `.seg`/`_entries` are inert without a
#                               seal — the consumer block-on-absence never reads
#                               an unsealed epoch); re-arm the accumulator.
#   restore_from(token)      -> set the current epoch from the token so a re-drive
#                               re-writes the SAME (producer, epoch): the
#                               idempotent producer + idempotent seal collapse
#                               the duplicate (EXACTLY-ONCE per epoch).
#   sink_class()             -> transactional (2PC over the durable seal).
#
# SINGLE-PRODUCER MVP (the time-sliced single-driver shape):
# one segment driver writes one producer's `.seg` per epoch, so
# `expected_producers == [producer_id]`. A multi-producer fan-in (P>1) per epoch
# is the same seal_step call with the full producer set — the seal verifies the
# set each-once REGARDLESS of producer count (proven by the continuous-epoch
# test's n_prod=4). The conformer pins ONE producer; the planner supplies the
# producer set when a map fan-in lands.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline (the Mojo pointer rules)
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins / `unsafe_from_address` / `take_pointee`.
#   * `consume` takes the delta morsel by OWNED MOVE; `pre_commit` returns a
#     SAFE POD `CommitToken`.
#   * `_store: S` held BY VALUE (owns/clone-shares its substrate); the row
#     accumulator is an owned `List[ShuffleRow]` (transient owned-List values,
#     never a byte-slab element). The sink is a stack/struct value, not a
#     byte-slab element (owned Movable substrate + POD Int64
#     scalars; NO heap-owning inner field stored in any Slab).
#     The role is held as a concrete typed Movable field,
#     NOT byte-slab-stored "to make it Copyable."
# =============================================================================

from komira_objectstore.store import CloneableConditionalWriteStore
from komira_shuffle.sink import ShuffleRow, sink_shuffle_write
from komira_shuffle.seal_driver import seal_step

from komira_morsel.morsel import Morsel
from komira_morsel.streaming_sink import (
    CommitToken,
    SinkClass,
    StepId,
    StreamingMorselSink,
)

from .shuffle_streaming_codec import (
    encode_value_payload,
    encode_key_bytes,
)


# =============================================================================
# ShuffleWriteSink[S] — segment N's output as a streaming shuffle-write sink.
# =============================================================================
#
# Generic over `S: CloneableConditionalWriteStore` — runs over LocalFs (the
# correctness-first single-node MVP: durable byte-identical to
# multi-node), the in-memory store (offline e2e), and S3ConditionalStore[C]
# (multi-node) identically. The SAME store the seal/source bind.
# =============================================================================


struct ShuffleWriteSink[S: CloneableConditionalWriteStore](StreamingMorselSink):
    """Segment N's output as a first-class `StreamingMorselSink`:
    scatter the delta morsel's (key, value) rows into R buckets per epoch and
    write them via `sink_shuffle_write`; at the step/epoch boundary
    (commit) `seal_step` the current epoch and advance. `sink_class()` is
    `transactional` (2PC over the durable per-epoch seal).

    Wraps the PROVEN free fns (plumbing, not protocol) — epoch == StepId; the
    shuffle namespace is per-step-keyed so distinct epochs are fully namespace-
    isolated (no protocol change).

    Fields:
      var _store: S                 — the durable shuffle store (clone-shared).
      var _shuffle_id: Int64        — this segment-cut's shuffle namespace id.
      var _producer_id: Int64       — this segment's single producer id (MVP).
      var _partition_count: Int64   — R, the reduce-partition fan-out.
      var _key_col: Int             — the morsel column index the shuffle key
        comes from (partitioned on).
      var _value_col: Int           — the morsel column index the row value
        (payload) comes from (round-tripped to the consumer).
      var _current_epoch: Int64     — the epoch (step_id) the next pre_commit
        writes + commit seals; advances per committed step.
      var _rows: List[ShuffleRow]   — the current epoch's accumulated rows
        (cleared on commit/abort; owned transient values, never a slab elem).
      var _expected_producers: List[Int64] — the producer set the seal verifies
        each-once (the MVP single-producer set [producer_id]; the planner
        supplies the full set for a map fan-in).
      var _written: Bool            — whether pre_commit already wrote the
        current epoch's `.seg` (so commit knows the producer committed).
    """

    var _store: Self.S
    var _shuffle_id: Int64
    var _producer_id: Int64
    var _partition_count: Int64
    var _key_col: Int
    var _value_col: Int
    var _current_epoch: Int64
    var _rows: List[ShuffleRow]
    var _expected_producers: List[Int64]
    var _written: Bool

    def __init__(
        out self,
        var store: Self.S,
        shuffle_id: Int64,
        partition_count: Int64,
        producer_id: Int64 = Int64(0),
        key_col: Int = 0,
        value_col: Int = 1,
        start_epoch: Int64 = Int64(0),
    ):
        """Construct a shuffle-write sink over a durable store.

        `shuffle_id` is the segment-cut namespace; `partition_count` is R (the
        reduce fan-out, MUST be a power of two for the high-bits radix);
        `producer_id` is this single producer (MVP); `key_col` / `value_col`
        select the morsel columns; `start_epoch` is the first epoch this sink
        writes (0 for a fresh job, or the recovered epoch on restore)."""
        self._store = store^
        self._shuffle_id = shuffle_id
        self._producer_id = producer_id
        self._partition_count = partition_count
        self._key_col = key_col
        self._value_col = value_col
        self._current_epoch = start_epoch
        self._rows = List[ShuffleRow]()
        self._expected_producers = List[Int64]()
        self._expected_producers.append(producer_id)
        self._written = False

    # =========================================================================
    # StreamingMorselSink conformance.
    # =========================================================================

    def consume(mut self, worker_id: Int, var delta_morsel: Morsel) raises:
        """Scatter the delta morsel's (key, value) rows into the CURRENT epoch's
        row accumulator (no IO yet — the whole step's delta is buffered, then
        written in ONE `sink_shuffle_write` at pre_commit so each producer's
        `.seg` is one dense write per epoch).

        Reads the Int64 key column (`_key_col`) + value column (`_value_col`)
        per row, encodes the key bytes (the partition driver) + the value
        payload (round-tripped to the consumer), and appends a `ShuffleRow`. An
        empty morsel (0 rows) is a no-op."""
        var batch = delta_morsel^.take_batch()
        var n = batch.num_rows()
        for r in range(n):
            var key_scalar = batch.column_value(self._key_col, r)
            var val_scalar = batch.column_value(self._value_col, r)
            var key = encode_key_bytes(Int64(key_scalar))
            var payload = encode_value_payload(Int64(val_scalar))
            self._rows.append(ShuffleRow(key^, payload^))
        _ = batch^

    def pre_commit(mut self, step: StepId) raises -> CommitToken:
        """Phase 1: write the CURRENT epoch's accumulated rows via
        `sink_shuffle_write` (partition into R buckets, write the `{producer}.seg`
        DENSE R-entry trailer incl zero-length, append `_entries` idempotently —
        the DedupSentinel each-once guard). The data is durable-but-INVISIBLE:
        the consumer's block-on-absence never reads it until the seal lands in
        commit.

        epoch == step (the StepId IS the epoch). Returns
        `CommitToken{step, txn_handle=epoch}` — the receipt `restore_from`
        rebuilds the pending epoch from. Idempotent: a re-drive of the SAME
        (producer, epoch) re-writes byte-identical content + lands no 2nd
        `_entries` chunk (EXACT-SET each-once)."""
        var epoch = self._current_epoch
        # The whole epoch's delta is written in one dense `.seg` (incl zero-length
        # partitions — the DENSE-INDEX INVARIANT the empty-partition read relies on).
        _ = sink_shuffle_write(
            self._store,
            self._shuffle_id,
            epoch,
            self._producer_id,
            self._partition_count,
            self._rows,
        )
        self._written = True
        return CommitToken(step, UInt64(epoch))

    def commit(mut self, step: StepId) raises:
        """Phase 2: `seal_step` the CURRENT epoch — the driver-join seal
        (StepComplete{expected, committed} verified as sets each-once). The seal
        is THE per-epoch hand-off barrier the consumer blocks on (the
        proven block-on-absence gate). The instant the seal lands, epoch
        `step` becomes readable by segment N+1's ShuffleReadSource.

        IDEMPOTENT-on-recovery: `seal_step` returns the existing decoded seal on
        a re-drive (single-slot pre-check), so a re-applied commit is a no-op.
        After the seal lands, ADVANCE to the next epoch + clear the accumulator
        so the next step writes `{shuffle_id}/{epoch+1}/`."""
        var epoch = self._current_epoch
        if not self._written:
            # An empty step that never wrote — still write the (empty) `.seg`
            # so the seal's producer set is complete (the dense zero-length
            # partitions make the consumer read 0 rows for every pid). This keeps
            # every epoch sealed even when a step produced no delta.
            _ = sink_shuffle_write(
                self._store,
                self._shuffle_id,
                epoch,
                self._producer_id,
                self._partition_count,
                self._rows,
            )
            self._written = True

        _ = seal_step(
            self._store,
            self._shuffle_id,
            epoch,
            self._partition_count,
            self._expected_producers,
        )

        # The seal landed — advance to the next epoch + re-arm the accumulator.
        self._current_epoch = epoch + Int64(1)
        self._rows = List[ShuffleRow]()
        self._written = False

    def abort(mut self, step: StepId) raises:
        """Discard the CURRENT epoch's buffered rows (planner abort / breaker
        rejection). An un-sealed `.seg`/`_entries` is INERT — the consumer's
        block-on-absence never reads an epoch whose own `_seal` is absent (the
        proven per-epoch gate), so dropping the buffer (no seal written) is a
        clean abort. The NEXT step re-writes a fresh epoch. The accumulator is
        re-armed; the epoch is NOT advanced (the aborted epoch number is reused
        on the retry — a deterministic re-drive)."""
        self._rows = List[ShuffleRow]()
        self._written = False

    def restore_from(mut self, var token: CommitToken) raises:
        """Recovery: set the CURRENT epoch from the token so a re-drive
        re-writes the SAME (producer, epoch). Idempotent: the idempotent
        producer (DedupSentinel) + idempotent seal (single-slot pre-check)
        collapse the duplicate — re-writing + re-sealing epoch `token.txn_handle`
        is a no-op effect (EXACTLY-ONCE per epoch). Re-arms the accumulator so
        the step replays its delta into the recovered epoch. Owned move."""
        self._current_epoch = Int64(token.txn_handle)
        self._rows = List[ShuffleRow]()
        self._written = False

    def sink_class(self) -> SinkClass:
        """The EO capability class: `transactional` (2PC over the durable
        per-epoch seal). The planner ANDs `qualifies_for_exactly_once()` with the
        source's `replayable` bit to promise EO at plan time."""
        return SinkClass.transactional()

    # =========================================================================
    # Observability for the test / governor.
    # =========================================================================

    @always_inline
    def current_epoch(self) -> Int64:
        """The epoch (step_id) the next pre_commit writes + commit seals."""
        return self._current_epoch

    @always_inline
    def buffered_rows(self) -> Int:
        """The count of rows accumulated for the current (not-yet-written)
        epoch."""
        return len(self._rows)

    @always_inline
    def shuffle_id(self) -> Int64:
        """The segment-cut shuffle namespace id."""
        return self._shuffle_id
