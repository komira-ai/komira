# =============================================================================
# komira_log_index.flush_thread: the dedicated off-core flush thread driver.
# =============================================================================
#
# The heavy steps run off the producing core, on a dedicated flush thread. This
# module is the drive loop that thread runs: `LogIndexConsumer.drive_once` in a
# loop, so the tokenize, invert, serialize and publish never run on the producing
# drain core. One flush thread per drain-worker sub-lineage.
#
# WHAT IS HERE AND WHAT IS NOT. This struct provides the off-core drive loop
# (`run_until_shutdown`) gated by an atomic shutdown flag, and the
# `request_shutdown` signal. It does not create the OS thread: the owner launches
# a thread whose body calls `run_until_shutdown` (through the runtime's
# worker-launch facility), records the handle with `set_thread_id` and joins it
# on shutdown. Keeping the launch out of this module means it adds no thread
# creation or address-laundering site of its own. `drive_step` and `final_flush`
# advance the stage on the calling thread, for tests and cooperative drivers.
#
# LIFECYCLE (the at-most-once contract):
#   * the owner starts a thread running `run_until_shutdown`;
#   * the loop: `drive_once(handoff, gate, now_ms())`, then a short park when
#     idle (no units and nothing buffered), so the thread is cheap when quiet;
#   * on shutdown, `request_shutdown()` sets the atomic flag; the loop exits at
#     its next iteration, then drains the handoff one last time (every unit the
#     producer offered before it stopped) and runs a final `shutdown_flush`,
#     which publishes the last partial segment, so a graceful stop loses nothing
#     the producer handed off and only a crash loses the un-flushed window. The
#     owner quiesces the producer before it requests shutdown; a unit offered
#     after the final drain is not published. The owner then joins the thread. The consumer and
#     its metastore drop only after the join, so the thread never touches freed
#     state.
#
# Encapsulation: no UnsafePointer in any signature. The consumer is owned by
# value; the handoff and gate are borrowed mutably into the loop. Their methods
# take `mut self`, so running the loop on one thread while the producer uses the
# same handoff and gate on another is not expressible in safe code here: the
# thread-launch design the owner supplies has to settle how they are shared.
# =============================================================================

from std.atomic import Atomic

from komira_clock import now_unix_ms

from komira_objectstore.store import ConditionalWriteStore

from komira_log_index.consumer import LogIndexConsumer
from komira_log_index.flush_stage import InFlightBytesGate, _sleep_us
from komira_log_index.handoff import LogIndexHandoff


# -----------------------------------------------------------------------------
# Default idle park (microseconds). When a drive finds no work and nothing is
# buffered, the thread parks this long before the next poll, keeping the off-core
# thread cheap when the log stream is quiet. Small enough that the time ceiling
# (default 1 s) still fires promptly.
# -----------------------------------------------------------------------------

comptime DEFAULT_IDLE_PARK_US: Int64 = Int64(2000)  # 2 ms


# -----------------------------------------------------------------------------
# OffCoreFlushThread[Storage]: owns the consumer and the shutdown flag, borrows
# the handoff and gate, and runs the off-core drive loop.
#
# NON-MOVABLE (it owns an Atomic shutdown flag and the consumer; the thread holds
# the struct's address for its lifetime, so the struct must not move after the
# thread starts). Hold it in an `OwnedPointer[OffCoreFlushThread[Storage]]`.
#
# THE HANDOFF AND GATE ARE BORROWED, NOT OWNED. They are shared with the
# producing drain core (the producer offers; this thread drains and releases).
# The owner keeps them and passes them into `run_until_shutdown`; they outlive
# the thread (the thread is joined before they drop).
# -----------------------------------------------------------------------------


struct OffCoreFlushThread[Storage: ConditionalWriteStore](
    Deinitable
):
    """The dedicated off-core flush thread driver. Owns the LogIndexConsumer
    (the heavy index build and publish); borrows the handoff and gate. Runs
    `consumer.drive_once` in a loop until the atomic shutdown flag is set, then
    does a final `shutdown_flush` and returns.

    Non-movable (atomic flag, and address-stable for the thread). Construct it
    behind an `OwnedPointer`."""

    var _consumer: LogIndexConsumer[Self.Storage]
    var _shutdown: Atomic[DType.uint8]
    var _idle_park_us: Int64
    var _thread_id: Int64  # thread handle recorded by the owner (0 == none)

    def __init__(
        out self,
        var consumer: LogIndexConsumer[Self.Storage],
        idle_park_us: Int64 = DEFAULT_IDLE_PARK_US,
    ):
        self._consumer = consumer^
        self._shutdown = Atomic[DType.uint8](UInt8(0))
        self._idle_park_us = idle_park_us
        self._thread_id = Int64(0)

    @always_inline
    def request_shutdown(mut self):
        """Signal the drive loop to exit (after a final shutdown_flush). The
        flag is atomic; calling it more than once is harmless."""
        var expected = UInt8(0)
        _ = self._shutdown.compare_exchange(expected, UInt8(1))

    @always_inline
    def _is_shutdown(self) -> Bool:
        return self._shutdown.load() != UInt8(0)

    def run_until_shutdown(
        mut self, mut handoff: LogIndexHandoff, mut gate: InFlightBytesGate
    ):
        """The off-core drive loop (the thread body). Drains the handoff and
        flushes on the byte/time ceiling each iteration; parks when idle. On the
        shutdown signal it drains the handoff once more (units offered since
        the last iteration are buffered, not dropped), then does a final
        shutdown_flush (publishes the last partial segment) and returns. The
        producer must be quiesced before shutdown is requested."""
        while not self._is_shutdown():
            var now_ms = now_unix_ms()
            var n = self._consumer.drive_once(handoff, gate, now_ms)
            # Park only when fully idle (no units accepted AND nothing buffered
            # waiting on the time ceiling); otherwise loop hot to keep up.
            if n == 0 and self._consumer.buffered_rows() == Int64(0):
                _sleep_us(self._idle_park_us)
        # Drain what the producer offered after the last iteration (its
        # reservations travel with the units and are released by the flush
        # below), then FINAL flush on clean shutdown: publish the last partial
        # segment.
        _ = self._consumer.drive_once(handoff, gate, now_unix_ms())
        self._consumer.shutdown_flush(gate)

    @always_inline
    def consumer_stats_splits(self) -> Int64:
        return self._consumer.stats().splits_published

    @always_inline
    def consumer_stats_failures(self) -> Int64:
        return self._consumer.stats().publish_failures

    @always_inline
    def set_thread_id(mut self, tid: Int64):
        """Record the thread handle the owner's launch returns (so the owner can
        join it on shutdown)."""
        self._thread_id = tid

    @always_inline
    def thread_id(self) -> Int64:
        return self._thread_id

    # -------------------------------------------------------------------------
    # drive_step: the test and single-step entry (no thread). One drive_once at
    # the given wall-ms; lets a test or a cooperative single-threaded driver
    # advance the off-core stage deterministically. The production path uses
    # run_until_shutdown on a dedicated thread.
    # -------------------------------------------------------------------------

    def drive_step(
        mut self,
        mut handoff: LogIndexHandoff,
        mut gate: InFlightBytesGate,
        now_ms: Int64,
    ) -> Int:
        return self._consumer.drive_once(handoff, gate, now_ms)

    def final_flush(mut self, mut gate: InFlightBytesGate):
        """Force the final shutdown flush (the clean-stop publish of the last
        partial segment). Idempotent: a no-op if the buffer is empty."""
        self._consumer.shutdown_flush(gate)
