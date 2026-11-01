# =============================================================================
# komira_log_index.flush_stage: the off-core bounded flush stage.
# =============================================================================
#
# The work splits across a core boundary:
#   * ON the producing drain core (cheap, budgeted): the drain (a plain pop and
#     arena copy) and `log_views_to_record_batch`, the transpose. This is the
#     cost class of a text render, so it stays on-core. The wiring point is
#     `LogIndexHandoff.offer`, called from the drain seam.
#   * OFF the producing core (heavy, millisecond-scale, failure-prone): the
#     `SearchSink` build (tokenize, invert, serialize) and the publish (the
#     split PUT, then the metastore append). These must not run inline.
#
# THIS FILE owns the load-bearing safety primitives of the off-core stage. It
# does not publish; the consumer (`komira_log_index.consumer`) does.
#
#   1. `InFlightBytesGate`, the memory cap. An atomic counter of bytes held
#      across queued batches and the batch being published. The producer
#      reserves before it enqueues; if the reservation would exceed the cap the
#      producer is told to back off (block or shed, per the ring's overflow
#      policy) instead of growing memory without bound. A slow object store
#      stalls publish, so reservations are not released, so new reservations
#      are rejected, so the drain core stops producing, so the ring fills and
#      its existing overflow policy applies. Resident memory is bounded by the
#      cap.
#
#   2. `LogIndexFlushBuffer`, the byte and time flush ceiling. It accumulates
#      transposed batches and fires a flush at a byte ceiling or a time ceiling,
#      whichever comes first. The time ceiling makes a low-volume stream
#      searchable within a bounded time instead of waiting under the byte
#      threshold forever. The un-flushed buffer is the at-most-once loss
#      window, bounded by these two ceilings.
#
#   3. `FlushRetryPolicy`, the bounded retry of the publish step.
#
# THE DURABILITY CONTRACT (stated, not over-promised): a log is searchable only
# after its publish succeeds. Records in the current un-flushed in-memory buffer
# (transposed off the ring, not yet published) are at-most-once: lost on a
# process crash or on an index-build error that fails the batch. The loss window
# is bounded by the byte ceiling and the time ceiling. A re-drain is not
# possible: the ring is the only source and a pop is destructive. The publish
# step itself is fail-safe: the split object is written first (an unreferenced
# object if the process dies before the next step) and its summary is appended
# to the metastore second (the step that makes it searchable).
#
# Encapsulation: no UnsafePointer in any signature. The in-flight counters are
# `Atomic` fields; the batches are held in a `Slab[RecordBatch]` (RecordBatch is
# move-only, so it cannot live in a `List`), reached by concrete-origin
# `__getitem__`, `take_slot_unchecked` and `pop`.
# =============================================================================

from std.atomic import Atomic
from std.ffi import external_call

from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab


# -----------------------------------------------------------------------------
# Default flush ceilings. Tunable per index; these are the defaults.
# -----------------------------------------------------------------------------
#
# The BYTE ceiling sizes one segment toward few, large objects (the L0 index
# costs about 198 bytes per document, so 4 MiB is about 20K documents per split).
# The TIME ceiling bounds the at-most-once loss window for a low-volume stream:
# even a trickle of logs becomes searchable within DEFAULT_FLUSH_MS. The IN-FLIGHT
# cap bounds resident memory under publish lag: at most a few segments' worth of
# bytes are held before the producer is pushed back.
# -----------------------------------------------------------------------------

comptime DEFAULT_FLUSH_BYTES: Int64 = Int64(4 * 1024 * 1024)  # 4 MiB/segment
comptime DEFAULT_FLUSH_MS: Int64 = Int64(1000)  # 1 s loss-window ceiling
comptime DEFAULT_INFLIGHT_CAP_BYTES: Int64 = Int64(64 * 1024 * 1024)  # 64 MiB


# -----------------------------------------------------------------------------
# _sleep_us: the one microsecond sleep of this package (the consumer's retry
# backoff and the flush thread's idle park). It uses libc `usleep`, the in-tree
# idiom (the standard library's `time.sleep` calls `nanosleep`, which collides
# with the async reactor's declaration in an AOT binary). `usleep` may fail with
# EINVAL for a value of one second or more on some libcs, and its argument is a
# 32-bit `useconds_t`, so a long sleep is split into chunks of at most half a
# second; a value of zero or less is a no-op.
# -----------------------------------------------------------------------------

comptime _SLEEP_CHUNK_US: Int64 = Int64(500_000)


def _sleep_us(us: Int64):
    var remaining = us
    while remaining > Int64(0):
        var chunk = remaining
        if chunk > _SLEEP_CHUNK_US:
            chunk = _SLEEP_CHUNK_US
        # FFI-BOUNDARY: libc `usleep`, no pointers; the argument is a value
        # in (0, 500_000].
        _ = external_call["usleep", Int32](UInt32(chunk))
        remaining -= chunk


# -----------------------------------------------------------------------------
# FlushRetryPolicy: the bounded retry of the publish step. A transient failure
# (a slow PUT, a momentary 503, a cold connection) is retried a few times with a
# short backoff, so a blip that would succeed on attempt 2 or 3 lands the records
# instead of dropping them. The total elapsed time is bounded by `budget_us`, so
# the whole retry stays inside a caller's shutdown grace period: the retries
# share that budget, they do not extend it. A store that is down for every
# attempt within the budget still fails loudly (`publish_failures` is
# incremented) and the flush returns within the grace period. POD, passable by
# value.
#
# THE BUDGET CONTRACT. The consumer's retry loop stamps a start time, then
# before each backoff sleep checks `elapsed + backoff < budget_us`; if the next
# backoff would reach the budget it stops and surfaces the failure. So no new
# backoff starts past `budget_us`, whatever `max_attempts` says. A `put` or
# `publish` call already in flight is not interrupted: the per-attempt request
# is bounded only by the store's own request timeout, so size the budget with
# one request timeout of slack under the grace period. A `budget_us` of zero or
# less disables the check, and `max_attempts` alone bounds the loop.
# -----------------------------------------------------------------------------


@fieldwise_init
struct FlushRetryPolicy(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Bounded retry for the flush publish path. POD.

    Field layout:
      var max_attempts: Int: total publish attempts (>=1). 1 is no retry.
                              Default 3.
      var backoff_us: Int64: fixed backoff between attempts, microseconds
                              (default 200_000 = 200 ms). Not exponential: the
                              budget is small, so a flat short backoff keeps the
                              total predictable.
      var budget_us: Int64: the total time the whole retry may consume
                              (attempts plus backoffs), microseconds. Default
                              6_000_000 = 6 s. 0 means unbounded by time (still
                              bounded by max_attempts); not recommended on a
                              shutdown path.
    """

    var max_attempts: Int
    var backoff_us: Int64
    var budget_us: Int64

    @staticmethod
    def default() -> FlushRetryPolicy:
        # 3 attempts, 200 ms backoff, 6 s total budget.
        return FlushRetryPolicy(3, Int64(200_000), Int64(6_000_000))

    @staticmethod
    def single_attempt() -> FlushRetryPolicy:
        # One attempt, no retry.
        return FlushRetryPolicy(1, Int64(0), Int64(0))

    @staticmethod
    def fast_test() -> FlushRetryPolicy:
        # A tight schedule for tests: 3 attempts, 1 ms backoff, 1 s budget. The
        # retry semantics are identical, only the waits are shorter.
        return FlushRetryPolicy(3, Int64(1_000), Int64(1_000_000))

    @always_inline
    def is_retrying(self) -> Bool:
        return self.max_attempts > 1


# -----------------------------------------------------------------------------
# InFlightBytesGate: the memory cap. An atomic counter of in-flight unpublished
# bytes (queued plus being published). The producer reserves before it accepts
# work into the off-core stage; over the cap the reservation is rejected and the
# producer backs off. Reservations are released when the bytes have been
# published (or dropped with a failed batch).
#
# The gate is shared by the producer (the drain core, which reserves) and the
# consumer (the off-core flush thread, which releases). The two `Atomic` fields
# are the shared cross-thread cells.
# -----------------------------------------------------------------------------


struct InFlightBytesGate(Deinitable):
    """Atomic in-flight-bytes reservation gate (the memory cap).

    `try_reserve(n)` admits `n` bytes if `current + n <= cap`, else rejects
    (the producer must back off). `release(n)` returns `n` bytes to the pool
    after the corresponding batch has been published (or dropped).

    NON-MOVABLE (it owns `Atomic` fields, so its address is stable). Share ONE
    instance by `ref`; to move atomic-bearing state across a boundary, wrap it
    in an `OwnedPointer`. The producer and the consumer both hold a borrowed
    ref to the same instance."""

    var _cap_bytes: Int64
    var _in_flight: Atomic[DType.int64]
    # Rejection counter: a rejected reservation means the producer is being
    # pushed back; distinct from the ring's overflow drop.
    var _rejections: Atomic[DType.int64]

    def __init__(out self, cap_bytes: Int64 = DEFAULT_INFLIGHT_CAP_BYTES):
        self._cap_bytes = cap_bytes
        self._in_flight = Atomic[DType.int64](Int64(0))
        self._rejections = Atomic[DType.int64](Int64(0))

    @always_inline
    def cap_bytes(self) -> Int64:
        return self._cap_bytes

    @always_inline
    def in_flight_bytes(self) -> Int64:
        """Current reserved (unpublished) bytes. The resident-memory proxy the
        tests assert is bounded by `cap_bytes`."""
        return self._in_flight.load()

    @always_inline
    def rejection_count(self) -> Int64:
        return self._rejections.load()

    def try_reserve(mut self, n: Int64) -> Bool:
        """Reserve `n` bytes against the cap. Returns True if admitted (the
        producer may enqueue), False if it would exceed the cap (the producer
        must back off: block or shed per the ring's overflow policy). A single
        reservation larger than the whole cap is admitted iff the pool is
        currently EMPTY, so an over-sized batch can still make progress rather
        than deadlock; it just runs alone.

        Race-safe across threads via a CAS loop on the atomic counter
        (`compare_exchange(expected, new)` rewrites `expected` with the live
        value on a miss, so it is re-read each spin)."""
        if n <= Int64(0):
            return True
        while True:
            var expected = self._in_flight.load()
            var nxt = expected + n
            if nxt > self._cap_bytes:
                # Over the cap. Allow ONLY if the pool is empty (an oversize
                # batch runs alone); otherwise reject.
                if expected > Int64(0):
                    _ = self._rejections.fetch_add(Int64(1))
                    return False
            # CAS the counter up. On contention, retry.
            if self._in_flight.compare_exchange(expected, nxt):
                return True

    def release(mut self, n: Int64):
        """Return `n` bytes to the pool (called by the consumer after the
        corresponding batch has been published or dropped). Never goes below 0
        (a release of more than is held clamps at 0)."""
        if n <= Int64(0):
            return
        while True:
            var expected = self._in_flight.load()
            var nxt = expected - n
            if nxt < Int64(0):
                nxt = Int64(0)
            if self._in_flight.compare_exchange(expected, nxt):
                return


# -----------------------------------------------------------------------------
# _estimate_batch_bytes: the reservation and flush accounting unit. A cheap
# per-batch byte estimate: the row count times a per-row constant (the L0 index
# costs about 198 bytes per document), so the byte ceiling tracks roughly the
# produced split size.
# -----------------------------------------------------------------------------


comptime _EST_BYTES_PER_ROW: Int64 = Int64(200)  # about the measured B/doc


@always_inline
def _estimate_batch_bytes(rb: RecordBatch) -> Int64:
    """Cheap per-batch byte estimate for reservation and flush accounting. It
    is the accounting unit, not an exact split size (the exact size is known
    only after the build)."""
    return Int64(rb.num_rows()) * _EST_BYTES_PER_ROW


# -----------------------------------------------------------------------------
# LogIndexFlushBuffer: the byte and time flush ceiling. Accumulates the
# transposed batches off-core; the consumer asks `should_flush(now_ms)` and, when
# True, `take_batches()` to drain them into one SearchSink segment.
# -----------------------------------------------------------------------------


struct LogIndexFlushBuffer(Movable, Deinitable):
    """Off-core accumulator and byte/time flush trigger. The un-flushed buffer
    is the at-most-once loss window; the two ceilings bound it.

    `add(rb, est, reserved, now_ms)` buffers a transposed batch with its byte
    estimate and stamps the oldest-buffered time (the time-ceiling anchor).
    `should_flush` fires at the byte ceiling OR the time ceiling (whichever
    first). `take_batches` drains the batches (resetting the accounting) for one
    segment."""

    var _flush_bytes: Int64
    var _flush_ms: Int64
    # RecordBatch is move-only, so the buffer is a `Slab[RecordBatch]`, not a
    # `List[RecordBatch]` (`List[T]` requires `T: Copyable`).
    var _batches: Slab[RecordBatch]
    var _buffered_bytes: Int64  # sum of per-batch byte ESTIMATES (flush trigger)
    var _reserved_bytes: Int64  # sum of per-batch gate RESERVATIONS (release)
    var _buffered_rows: Int64
    var _oldest_ms: Int64  # -1 sentinel == empty (no time anchor yet).

    def __init__(
        out self,
        flush_bytes: Int64 = DEFAULT_FLUSH_BYTES,
        flush_ms: Int64 = DEFAULT_FLUSH_MS,
    ):
        self._flush_bytes = flush_bytes
        self._flush_ms = flush_ms
        self._batches = Slab[RecordBatch]()
        self._buffered_bytes = Int64(0)
        self._reserved_bytes = Int64(0)
        self._buffered_rows = Int64(0)
        self._oldest_ms = Int64(-1)

    @always_inline
    def buffered_bytes(self) -> Int64:
        return self._buffered_bytes

    @always_inline
    def reserved_bytes(self) -> Int64:
        """Sum of gate reservations across the buffered batches: the exact
        amount the consumer releases on the gate after the segment publishes."""
        return self._reserved_bytes

    @always_inline
    def buffered_rows(self) -> Int64:
        return self._buffered_rows

    @always_inline
    def batch_count(self) -> Int:
        return len(self._batches)

    @always_inline
    def is_empty(self) -> Bool:
        return len(self._batches) == 0

    def add(mut self, var rb: RecordBatch, est: Int64, reserved: Int64, now_ms: Int64):
        """Buffer a transposed batch with its byte estimate (flush trigger) and
        its gate reservation (release receipt). Stamps the oldest-ms time anchor
        on the FIRST batch of a new buffer (the time-ceiling start)."""
        if self._oldest_ms < Int64(0):
            self._oldest_ms = now_ms
        self._buffered_bytes += est
        self._reserved_bytes += reserved
        self._buffered_rows += Int64(rb.num_rows())
        self._batches.append(rb^)

    @always_inline
    def should_flush(self, now_ms: Int64) -> Bool:
        """Flush at the byte ceiling OR the time ceiling (whichever first). An
        empty buffer never flushes. The time ceiling makes a low-volume stream
        searchable within a bounded time."""
        if len(self._batches) == 0:
            return False
        if self._buffered_bytes >= self._flush_bytes:
            return True
        if self._oldest_ms >= Int64(0):
            if now_ms - self._oldest_ms >= self._flush_ms:
                return True
        return False

    def take_batches(mut self) -> Slab[RecordBatch]:
        """Drain the buffered batches for one segment and reset the accounting.
        The caller (the consumer) captures `reserved_bytes()` BEFORE this call;
        it releases exactly that amount on the gate AFTER the publish lands (or
        fails)."""
        var out = self._batches^
        self._batches = Slab[RecordBatch]()
        self._buffered_bytes = Int64(0)
        self._reserved_bytes = Int64(0)
        self._buffered_rows = Int64(0)
        self._oldest_ms = Int64(-1)
        return out^
