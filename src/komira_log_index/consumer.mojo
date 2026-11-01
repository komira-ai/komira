# =============================================================================
# komira_log_index.consumer: the off-core index-consumer driver.
# =============================================================================
#
# This is the off-core half of the flush pipeline: it owns the heavy,
# millisecond-scale, failure-prone steps that must not run on the producing drain
# core.
#
# WHAT THE CONSUMER DOES (one per drain-worker sub-lineage; the sharding gives
# zero cross-worker contention):
#   1. `accept_unit(unit, now_ms)`: take a `HandoffUnit` (the on-core-transposed
#      batch with its gate reservation receipt) and buffer it. The reservation
#      happened at `offer` time on the producer side; the consumer carries the
#      receipt so it releases the exact amount after the segment publishes.
#   2. `maybe_flush(gate, now_ms)`: if the byte OR time ceiling fires, drain the
#      buffer into ONE `SearchSink` segment (tokenize, invert, serialize) and
#      publish it: the split object is written first (`store.put`), the summary
#      is appended to the metastore second (`metastore.publish`), which is the
#      step that makes the split searchable. The reserved bytes are released
#      after the publish lands or finally fails. A publish or index error
#      increments a counter and is printed; it is never swallowed, and the bytes
#      are released so the gate does not leak (the unpublished batch is the
#      at-most-once loss).
#   3. `shutdown_flush(gate)`: force a final flush of any buffered batch on a
#      clean shutdown, so the last partial segment is published, not lost.
#
# THE DURABILITY CONTRACT: a log is searchable only after its publish lands. The
# un-flushed buffer is at-most-once: lost on a crash or on an index-build error
# that fails the batch, bounded by the byte and time flush ceiling. A crash
# between the two publish writes leaves an unreferenced object, never a summary
# naming a missing one.
#
# GENERIC OVER THE STORE. `[Storage: ConditionalWriteStore]` is the same store
# type parameter the metastore uses: the in-memory conditional store in tests,
# any `komira_objectstore` conditional-write store in production. The consumer
# writes the split bytes through the store and appends the summary through its
# `SearchMetastore`. No cloud client is named here.
#
# SPLIT UUIDS. The 16-byte uuid is the worker discriminant byte, the low 56 bits
# of the consumer's construction time in microseconds (the install-time epoch),
# and a per-consumer sequence. The split `put` overwrites unconditionally, so a
# restarted process (whose sequence starts at 0 again) must not mint the key an
# earlier process already published; the epoch keeps the keys apart.
#
# Encapsulation: no UnsafePointer in any signature. The views carry owned Strings;
# the RecordBatch columns are List-owned; the gate and handoff are borrowed
# mutably by the methods that use them (sharing them with a producer on another
# thread needs the owner's thread-launch design, see flush_thread); the
# metastore and store are owned by value.
# =============================================================================

from std.time import perf_counter_ns

from komira_arrow.record_batch import RecordBatch
from komira_clock import now_unix_us
from komira_collections.slab import Slab

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from komira_search.sink import SearchSink
from komira_search_catalog import (
    SearchMetastore,
    make_split_summary,
)

from komira_log_index.transpose import (
    LOG_INDEX_TEXT_FIELD,
    LOG_INDEX_SOURCE_FIELD,
    log_index_schema,
)
from komira_log_index.flush_stage import (
    InFlightBytesGate,
    LogIndexFlushBuffer,
    FlushRetryPolicy,
    _estimate_batch_bytes,
    _sleep_us,
    DEFAULT_FLUSH_BYTES,
    DEFAULT_FLUSH_MS,
)
from komira_log_index.handoff import HandoffUnit, LogIndexHandoff


# -----------------------------------------------------------------------------
# _drain_batches_into: move every buffered batch into the sink, in FIFO order.
#
# `accept` raises, and `Slab.take_slot_unchecked` leaves the slab claiming all
# its slots until a trailing `set_len_unchecked(0)`; a raise in between would
# make the slab destroy slots already moved out (a double free of the batches'
# heap columns). So the loop counts the slots it has taken, and on a raise the
# handler takes and drops the rest, zeroes the length and re-raises: the slab is
# empty on every exit path. The batch handed to the failing `accept` is consumed
# by it.
# -----------------------------------------------------------------------------


trait _BatchAcceptor:
    def accept(mut self, var rb: RecordBatch) raises:
        ...


struct _SinkAcceptor(_BatchAcceptor, Movable):
    var sink: SearchSink

    def __init__(out self, var sink: SearchSink):
        self.sink = sink^

    def accept(mut self, var rb: RecordBatch) raises:
        self.sink.accept_batch(rb^)


def _drain_batches_into[
    A: _BatchAcceptor
](mut acceptor: A, mut batches: Slab[RecordBatch]) raises:
    var nb = len(batches)
    var taken = 0
    try:
        while taken < nb:
            var rb = batches.take_slot_unchecked(taken)
            taken += 1
            acceptor.accept(rb^)
    except e:
        for j in range(taken, nb):
            _ = batches.take_slot_unchecked(j)
        batches.set_len_unchecked(0)
        raise e^
    batches.set_len_unchecked(0)


# -----------------------------------------------------------------------------
# PublishStats: the counters of the publish path. `splits_published` and
# `docs_published` are the success path; `publish_failures` and `index_failures`
# are the surfaced failures (a failed batch is the at-most-once loss; its bytes
# are released so the gate does not leak).
# -----------------------------------------------------------------------------


@fieldwise_init
struct PublishStats(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Observability counters for the off-core publish path. A non-zero
    `publish_failures` or `index_failures` is the surfaced loss signal; the
    failure is never swallowed silently."""

    var splits_published: Int64
    var docs_published: Int64
    var publish_failures: Int64
    var index_failures: Int64

    @staticmethod
    def zero() -> PublishStats:
        return PublishStats(Int64(0), Int64(0), Int64(0), Int64(0))


# -----------------------------------------------------------------------------
# LogIndexConsumer[Storage]: the off-core driver. Holds the byte/time flush
# buffer, the per-(index, drain-writer) SearchMetastore, a store for the split
# PUT and the publish target strings. One consumer per drain-worker sub-lineage.
# -----------------------------------------------------------------------------


struct LogIndexConsumer[Storage: ConditionalWriteStore](
    Movable, Deinitable
):
    """The off-core index consumer: buffer, flush, index build, publish, bounded
    by the InFlightBytesGate and the byte/time ceiling.

    `[Storage]` selects the store backend. The consumer owns its metastore
    (advanced across publishes) and a store for the split-bytes PUT.

    Move-only: it owns a SearchMetastore. The gate is NOT a field (it is shared
    across producer and consumer); it is borrowed mutably by the methods that
    release."""

    var _store: Self.Storage
    var _metastore: SearchMetastore[Self.Storage]
    var _buffer: LogIndexFlushBuffer
    var _bucket: String
    var _key_prefix: String
    var _index: String
    var _stats: PublishStats
    # The bounded retry of the publish step: a transient failure is retried a few
    # times with a short backoff, no new backoff starting past the policy budget,
    # so a blip that succeeds on attempt 2 or 3 lands the records instead of
    # dropping them. POD, no heap.
    var _flush_retry: FlushRetryPolicy
    # Monotone split-uuid counter (per consumer, so per sub-lineage). The 16-byte
    # uuid embeds the worker discriminant byte, the install-time epoch and this
    # counter, so two drain workers never mint the same split object key and a
    # restarted consumer does not reuse an earlier one's keys.
    var _split_seq: Int64
    var _worker_disc: UInt8
    # Wall-clock microseconds read once at construction; mixed into every uuid.
    var _epoch_us: UInt64

    def __init__(
        out self,
        var store: Self.Storage,
        var metastore: SearchMetastore[Self.Storage],
        var bucket: String,
        var key_prefix: String,
        var index: String,
        worker_disc: UInt8 = UInt8(0),
        flush_bytes: Int64 = DEFAULT_FLUSH_BYTES,
        flush_ms: Int64 = DEFAULT_FLUSH_MS,
        flush_retry: FlushRetryPolicy = FlushRetryPolicy.default(),
        epoch_us: Int64 = Int64(-1),
    ):
        """`epoch_us` is the install time mixed into every split uuid. A
        negative value (the default) reads the wall clock now; pass an explicit
        value only to pin the epoch."""
        self._store = store^
        self._metastore = metastore^
        self._buffer = LogIndexFlushBuffer(flush_bytes, flush_ms)
        self._bucket = bucket^
        self._key_prefix = key_prefix^
        self._index = index^
        self._stats = PublishStats.zero()
        self._flush_retry = flush_retry
        self._split_seq = Int64(0)
        self._worker_disc = worker_disc
        if epoch_us < Int64(0):
            self._epoch_us = UInt64(now_unix_us())
        else:
            self._epoch_us = UInt64(epoch_us)

    @always_inline
    def stats(self) -> PublishStats:
        return self._stats

    @always_inline
    def buffered_bytes(self) -> Int64:
        return self._buffer.buffered_bytes()

    @always_inline
    def buffered_rows(self) -> Int64:
        return self._buffer.buffered_rows()

    # -------------------------------------------------------------------------
    # accept_unit: the consumer-side handoff sink. Takes a HandoffUnit the
    # off-core thread popped from the bounded queue: the on-core-transposed
    # batch and its gate reservation receipt. Buffers it (the byte/time ceiling
    # decides when to flush). There is no re-reservation here.
    # -------------------------------------------------------------------------

    def accept_unit(mut self, var unit: HandoffUnit, now_ms: Int64):
        """Buffer the on-core-transposed batch the off-core thread popped. The
        gate reservation (`unit.reserved_bytes`) traveled with the unit from the
        producer's `offer`; it is carried on the flush buffer so a flush
        releases exactly it after the segment publishes. `est` (the flush
        trigger accounting unit) is re-derived from the batch row count.

        The scalar receipts are read first (Int64 copies), then the batch is
        taken with `take_batch()`, never a partial move out of the unit."""
        var reserved = unit.reserved_bytes
        var batch = unit.take_batch()
        var est = _estimate_batch_bytes(batch)
        self._buffer.add(batch^, est, reserved, now_ms)

    @always_inline
    def should_flush(self, now_ms: Int64) -> Bool:
        return self._buffer.should_flush(now_ms)

    # -------------------------------------------------------------------------
    # drive_once: the off-core flush-thread loop body. Takes every currently
    # queued unit from the handoff, buffers them, then evaluates the byte/time
    # flush ceiling. Returns the number of units processed (0 is idle). The
    # dedicated flush thread calls this in a loop with a small park between idle
    # iterations.
    # -------------------------------------------------------------------------

    def drive_once(
        mut self,
        mut handoff: LogIndexHandoff,
        mut gate: InFlightBytesGate,
        now_ms: Int64,
    ) -> Int:
        """One off-core flush-thread iteration: bulk-drain the handoff (accept
        every queued unit IN FIFO ORDER) then evaluate the flush ceiling.
        Returns the unit count accepted this iteration. A time-only flush still
        fires on an idle iteration (`now_ms` advanced past the time ceiling)."""
        var units = handoff.drain_all()
        var n = len(units)
        # Forward-order drain (FIFO) via take_slot_unchecked and
        # set_len_unchecked, the canonical Slab bulk drain. A LIFO `pop` would
        # reverse the order and break the time-sorted-split invariant.
        for i in range(n):
            self.accept_unit(units.take_slot_unchecked(i), now_ms)
        units.set_len_unchecked(0)
        _ = self.maybe_flush(gate, now_ms)
        return n

    # -------------------------------------------------------------------------
    # maybe_flush: the byte/time-triggered publish. If the ceiling fired, drain
    # the buffer into ONE SearchSink segment and publish. Releases the reserved
    # bytes against the gate after the publish lands (or fails). A failure
    # increments a counter and releases the bytes; it is never swallowed.
    # Returns True if a flush ran (regardless of publish success), False if the
    # ceiling had not fired.
    # -------------------------------------------------------------------------

    def maybe_flush(mut self, mut gate: InFlightBytesGate, now_ms: Int64) -> Bool:
        if not self._buffer.should_flush(now_ms):
            return False
        self._flush_now(gate)
        return True

    def shutdown_flush(mut self, mut gate: InFlightBytesGate):
        """Force a final flush of any buffered batch (clean shutdown) so the
        last partial segment is published, not lost. Bypasses the ceiling."""
        if self._buffer.is_empty():
            return
        self._flush_now(gate)

    # -------------------------------------------------------------------------
    # _flush_now: drain the buffer into one segment, index-build, publish.
    # Releases the reserved bytes regardless of outcome (so the gate never
    # leaks).
    # -------------------------------------------------------------------------

    def _flush_now(mut self, mut gate: InFlightBytesGate):
        # Capture the gate reservation sum BEFORE draining (take_batches resets
        # the buffer accounting). Exactly this many bytes are released after
        # publish: the receipts that traveled with the units from `offer`, so
        # the gate counter returns to 0 when all in-flight work has published.
        var reserved = self._buffer.reserved_bytes()
        var doc_count = self._buffer.buffered_rows()
        var batches = self._buffer.take_batches()
        if len(batches) == 0:
            return

        # ---- index build (the deterministic, off-network half; built ONCE) ---
        # The index build (tokenize, invert, serialize) is deterministic and
        # CPU-only; only the PUBLISH (the split PUT and the metastore append)
        # touches the network and can fail transiently. So the segment is built
        # once and only the publish is retried, keeping `split_bytes` across
        # attempts. If the build itself raises (a data error, not a transient
        # blip) there is nothing to retry; it surfaces as the loss immediately.
        var built_ok = True
        var split_bytes = List[UInt8]()
        # The uuid and object key are fixed here, once per flush, and passed to
        # the publish: a retry re-writes the same key.
        var uuid = self._next_uuid()
        var object_key = String("")
        try:
            split_bytes = self._build_segment(batches^, uuid, object_key)
        except e:
            print(
                "ERROR LogIndexConsumer: index-build failed (at-most-once",
                " loss of",
                doc_count,
                "docs):",
                String(e),
            )
            self._stats.index_failures += Int64(1)
            built_ok = False

        if built_ok:
            # ---- publish with bounded retry ----
            #
            # Retry the publish (split PUT, then metastore append) up to
            # `max_attempts` with a short backoff. The split object key comes
            # from the segment's uuid, so a PUT with no append leaves a harmless
            # unreferenced object, and a re-PUT of the same bytes under the same
            # key is idempotent. The total elapsed time is bounded by
            # `budget_us`: before each backoff the wall time is checked against
            # the budget and the loop STOPS if the next backoff would exceed it.
            # This bounds the time spent backing off, not the time inside one
            # `put` or `publish` call, which is not interrupted. A `budget_us`
            # of zero or less disables the check: attempts alone bound the loop.
            var blen = Int64(len(split_bytes))
            var start_ns = perf_counter_ns()
            var attempts = self._flush_retry.max_attempts
            if attempts < 1:
                attempts = 1
            var published = False
            var last_err = String("")
            var k = 0
            while k < attempts:
                try:
                    # Re-PUT and re-append the SAME built bytes (borrowed, so a
                    # retry copies nothing).
                    self._publish_segment(
                        split_bytes, object_key, uuid, doc_count, blen
                    )
                    published = True
                    break
                except e:
                    last_err = String(e)
                    k += 1
                    if k >= attempts:
                        break
                    # BUDGET CHECK: would the backoff push us past the budget?
                    # If so, stop now; a store that is down must not block past
                    # the grace period.
                    var elapsed_us = Int64(
                        (perf_counter_ns() - start_ns) // 1_000
                    )
                    var backoff = self._flush_retry.backoff_us
                    if (
                        self._flush_retry.budget_us > Int64(0)
                        and elapsed_us + backoff >= self._flush_retry.budget_us
                    ):
                        break
                    _sleep_us(backoff)

            if published:
                self._stats.splits_published += Int64(1)
                self._stats.docs_published += doc_count
            else:
                # Do not swallow. After exhausting the bounded retry the batch's
                # logs are the at-most-once loss. Count it and print it; the
                # bytes are released below so the gate does not leak. (Any
                # attempt that reached the store left its split object behind,
                # unreferenced; it is not searchable because no summary names
                # it.)
                print(
                    "ERROR LogIndexConsumer: index/publish failed after",
                    attempts,
                    "attempt(s) (at-most-once loss of",
                    doc_count,
                    "docs):",
                    last_err,
                )
                self._stats.publish_failures += Int64(1)

        # ---- RELEASE the reservation, ALWAYS (success or failure) ----
        gate.release(reserved)

    # -------------------------------------------------------------------------
    # _build_segment: the heavy off-core index build (tokenize, invert,
    # serialize). Drives the same public SearchSink the batch path uses. The
    # object key the sink resolves from `uuid` is written to `object_key`.
    # -------------------------------------------------------------------------

    def _build_segment(
        mut self,
        var batches: Slab[RecordBatch],
        uuid: InlineArray[UInt8, 16],
        mut object_key: String,
    ) raises -> List[UInt8]:
        var sink = SearchSink(
            self._bucket,
            self._key_prefix,
            self._index,
            LOG_INDEX_TEXT_FIELD,  # message is the inverted TEXT field
            uuid.copy(),
            LOG_INDEX_SOURCE_FIELD,  # designated _source column
        )
        sink.init_sink(log_index_schema())
        var acceptor = _SinkAcceptor(sink^)
        _drain_batches_into(acceptor, batches)
        acceptor.sink.finish()
        # The sink computes the key from the same uuid, prefix and index.
        object_key = acceptor.sink.object_key()
        return acceptor.sink.take_split_bytes()

    # -------------------------------------------------------------------------
    # _publish_segment: the two-step publish. The split object is written FIRST
    # (an unreferenced object if the process dies before the next step), the
    # summary is appended to the metastore SECOND (the step that makes the split
    # searchable). The same order every publisher over the catalog follows,
    # generic over the store type. A summary append that lands server-side but
    # raises can be appended again by the retry: a duplicate summary for one
    # object.
    # -------------------------------------------------------------------------

    def _publish_segment(
        mut self,
        split_bytes: List[UInt8],
        object_key: String,
        uuid: InlineArray[UInt8, 16],
        doc_count: Int64,
        byte_size: Int64,
    ) raises:
        # (1) split PUT FIRST.
        _ = self._store.put(Path.parse(object_key), split_bytes)
        # (2) metastore append SECOND.
        var summary = make_split_summary(
            uuid.copy(),
            doc_count,
            byte_size,
            Int64(0),  # min_doc_id (per-split base 0)
            doc_count - Int64(1) if doc_count > 0 else Int64(0),  # max_doc_id
            self._index,
            LOG_INDEX_TEXT_FIELD,
            object_key,
        )
        _ = self._metastore.publish(summary^)

    # -------------------------------------------------------------------------
    # _next_uuid: mint a split uuid unique per (worker discriminant, install
    # epoch, sequence). Byte 0 is the worker discriminant, bytes 1..7 the low 56
    # bits of the install-time epoch (microseconds), bytes 8..15 the sequence.
    # POD InlineArray, no heap.
    # -------------------------------------------------------------------------

    def _next_uuid(mut self) -> InlineArray[UInt8, 16]:
        self._split_seq += Int64(1)
        var u = InlineArray[UInt8, 16](fill=UInt8(0))
        u[0] = self._worker_disc
        for i in range(7):
            u[1 + i] = UInt8(
                Int((self._epoch_us >> UInt64(i * 8)) & UInt64(0xFF))
            )
        var s = UInt64(self._split_seq)
        for i in range(8):
            u[8 + i] = UInt8(Int((s >> UInt64(i * 8)) & UInt64(0xFF)))
        return u^
