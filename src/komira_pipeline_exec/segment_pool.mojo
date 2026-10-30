# =============================================================================
# segment_pool -- the memory pool the workers of a segment draw from
# =============================================================================
#
# A sink that holds state asks for memory at morsel boundaries, never inside a
# kernel's inner loop. A fixed share of the budget per worker starves a skewed
# worker while the others sit idle, so the workers draw from one pool in
# blocks:
#
#   * `SegmentPool` is a handle on one atomic count of the bytes granted. Any
#     number of handles (`share`) address the same count, so the workers of one
#     segment, and later two segments running at once, share one budget. A
#     grant is a compare-and-swap loop: it adds the bytes only if the total
#     stays within the budget, so the count never passes the budget and a
#     request that fits is never refused because another worker asked at the
#     same moment.
#   * `WorkerReservation` is one worker's plain tally inside the blocks it was
#     granted. Only its worker touches it, so it needs no atomic: a grow that
#     fits the blocks already held costs an add, and one that does not takes a
#     further block from the pool (or, when a whole block does not fit, exactly
#     what is missing). A reservation returns its blocks when it is dropped.
#
# A pool made without a budget grants everything and only counts.

from std.memory import ArcPointer

from komira_atomic_alias import AtomicI64
from komira_collections.slab import Slab

comptime POOL_UNBOUNDED: Int = -1
comptime POOL_DEFAULT_BLOCK: Int = 64 * 1024


struct SegmentPool(Movable):
    """A handle on a shared, atomic byte count with an optional budget."""

    var _granted: ArcPointer[Slab[AtomicI64]]
    var _budget: Int

    def __init__(out self, budget: Int = POOL_UNBOUNDED):
        self._granted = ArcPointer[Slab[AtomicI64]](
            Slab[AtomicI64].create_prefilled(1)
        )
        self._budget = budget if budget >= 0 else POOL_UNBOUNDED

    def share(self) -> SegmentPool:
        """Another handle on the same count and budget."""
        var other = SegmentPool(self._budget)
        other._granted = ArcPointer(copy=self._granted)
        return other^

    def budget(self) -> Int:
        """The budget in bytes, or `POOL_UNBOUNDED`."""
        return self._budget

    def granted(self) -> Int:
        """The bytes granted and not yet returned, across every handle."""
        return Int(self._granted[].get_mut_interior(0).load())

    def try_acquire(self, bytes: Int) -> Bool:
        """Add `bytes` to the granted count if the count stays within the
        budget. A denial leaves the count unchanged."""
        if bytes <= 0:
            return True
        while True:
            var seen = self._granted[].get_mut_interior(0).load()
            var want = seen + Int64(bytes)
            if self._budget != POOL_UNBOUNDED and want > Int64(self._budget):
                return False
            var expected = seen
            if self._granted[].get_mut_interior(0).compare_exchange(
                expected, want
            ):
                return True

    def give_back(self, bytes: Int):
        """Return `bytes` that an earlier `try_acquire` granted."""
        if bytes > 0:
            _ = self._granted[].get_mut_interior(0).fetch_add(-Int64(bytes))


struct WorkerReservation(Movable):
    """One worker's tally inside the blocks it drew from a `SegmentPool`."""

    var _pool: SegmentPool
    var _block: Int
    var _held: Int
    var _used: Int

    def __init__(
        out self, var pool: SegmentPool, block: Int = POOL_DEFAULT_BLOCK
    ):
        self._pool = pool^
        self._block = block if block > 0 else POOL_DEFAULT_BLOCK
        self._held = 0
        self._used = 0

    def __del__(deinit self):
        # A reservation that is dropped (a failed query drops its sink without
        # a combine) returns its blocks, so a pool that outlives the segment
        # does not lose them.
        self._pool.give_back(self._held)

    def try_grow(mut self, bytes: Int) -> Bool:
        """Tally `bytes` more; draws from the pool when the blocks held do not
        cover them. False (nothing tallied) when the pool refuses."""
        if bytes <= 0:
            return True
        var free = self._held - self._used
        if bytes <= free:
            self._used += bytes
            return True
        var missing = bytes - free
        var blocks = (missing + self._block - 1) // self._block
        var take = blocks * self._block
        if not self._pool.try_acquire(take):
            take = missing
            if not self._pool.try_acquire(take):
                return False
        self._held += take
        self._used += bytes
        return True

    def release(mut self, bytes: Int):
        """Take `bytes` back off the tally; the blocks stay held until
        `give_back_all`."""
        self._used -= bytes

    def used(self) -> Int:
        """The bytes tallied."""
        return self._used

    def held(self) -> Int:
        """The bytes drawn from the pool."""
        return self._held

    def give_back_all(mut self):
        """Return every block to the pool and clear the tally."""
        self._pool.give_back(self._held)
        self._held = 0
        self._used = 0
