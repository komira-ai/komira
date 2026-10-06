# =============================================================================
# komira_broker/flush_fence.mojo
#   The per-partition flush fence and the leaked-segment counters.
# =============================================================================
#
# A `BrokerCore` flush PUTs its `.seg` and then appends the manifest chunk
# that references it. Nothing deletes a `.seg` that no chunk references
# (komira-ai/komira#488 tracks a sound sweep), so every flush refused AFTER its
# PUT leaks one object for good. This module holds the local knowledge a core
# uses to refuse BEFORE the PUT, and counts the leaks it cannot prevent.
#
#   * The fence. A flush is refused before its PUT when
#     `writer_lease_epoch < max(current_lease_epoch, fence_epoch)`.
#     `fence_epoch` is the highest epoch this core has seen fence a writer:
#       - a refusal at entry records `current_lease_epoch`;
#       - a `lease_fenced` from the manifest AFTER the PUT records
#         `writer_lease_epoch + 1`. The manifest refused `writer`, so the
#         partition's live epoch is above it, even when the caller's
#         `current` did not say so. That flush passed the entry check, so
#         `writer >= current` and `writer + 1` is above `current` too.
#         Recording `writer + 1` and no more never refuses a new owner, whose
#         epoch is above the fence that refused `writer`.
#     The fence never goes down. No I/O: both inputs are local.
#   * The counters (`FlushLeakStats`):
#       - `refused_before_put`: refused at entry, no `.seg` written;
#       - `fenced_after_put`: the manifest returned `lease_fenced` after the
#         PUT, so the `.seg` is leaked;
#       - `unknown_outcome`: the append raised anything else after the PUT
#         (a transport error, exhausted retries). The chunk may or may not
#         have landed, so the `.seg` is possibly leaked.
#
# Hard-rule audit: POD fields only, no pointer, no wildcard origin.
# =============================================================================

from komira_objectstore.cas_manifest import is_lease_fenced


@fieldwise_init
struct FlushLeakStats(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Counts of flushes whose `.seg` was refused, leaked, or possibly leaked.
    See the module header for what each counter means."""

    var refused_before_put: Int64
    var fenced_after_put: Int64
    var unknown_outcome: Int64

    @staticmethod
    def zero() -> FlushLeakStats:
        return FlushLeakStats(Int64(0), Int64(0), Int64(0))


struct FlushFence(Movable, Deinitable):
    """The highest epoch seen fencing a writer of this partition, plus the
    leaked-segment counters. Owned by value by one `BrokerCore`."""

    var _fence_epoch: Int64
    var _stats: FlushLeakStats

    def __init__(out self):
        self._fence_epoch = Int64(0)
        self._stats = FlushLeakStats.zero()

    @always_inline
    def fence_epoch(self) -> Int64:
        """The cached fence (0 = none recorded)."""
        return self._fence_epoch

    @always_inline
    def is_fenced(self) -> Bool:
        """True once any flush of this core has been fenced."""
        return self._fence_epoch > Int64(0)

    @always_inline
    def stats(self) -> FlushLeakStats:
        return self._stats

    @always_inline
    def refuses(self, writer_lease_epoch: Int64, current_lease_epoch: Int64) -> Bool:
        """True iff a flush at `(writer, current)` must be refused before its
        PUT."""
        return (
            writer_lease_epoch < current_lease_epoch
            or writer_lease_epoch < self._fence_epoch
        )

    def _record(mut self, epoch: Int64):
        if epoch > self._fence_epoch:
            self._fence_epoch = epoch

    def note_refused(mut self, current_lease_epoch: Int64):
        """A flush was refused at entry: count it and record `current`."""
        self._stats.refused_before_put += Int64(1)
        self._record(current_lease_epoch)

    def note_fenced_after_put(mut self, writer_lease_epoch: Int64):
        """The manifest fenced the append after the `.seg` PUT. The caller
        passed the entry check, so `writer >= current`: `writer + 1` is the
        lowest epoch the partition can be at."""
        self._stats.fenced_after_put += Int64(1)
        self._record(writer_lease_epoch + Int64(1))

    def note_append_raise(mut self, msg: String, writer_lease_epoch: Int64):
        """The manifest append raised `msg` after the `.seg` PUT: a
        `lease_fenced` is a fence, anything else an unknown outcome."""
        if is_lease_fenced(msg):
            self.note_fenced_after_put(writer_lease_epoch)
        else:
            self._stats.unknown_outcome += Int64(1)

    def refusal_message(
        self, variant: String, writer_lease_epoch: Int64, current_lease_epoch: Int64
    ) -> String:
        """The error a refused flush raises. It carries the same `lease_fenced`
        marker the manifest's refusal carries, so `is_lease_fenced` classifies
        both alike."""
        return (
            "BrokerCore."
            + variant
            + ": lease_fenced — writer_lease_epoch "
            + String(writer_lease_epoch)
            + " < max(current_lease_epoch "
            + String(current_lease_epoch)
            + ", cached fence "
            + String(self._fence_epoch)
            + ") (refused before the segment PUT; no .seg written)"
        )
