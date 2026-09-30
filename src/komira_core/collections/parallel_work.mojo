# =============================================================================
# _ParallelWork -- disjoint per-worker views for the parallelize pattern
# =============================================================================
#
# The canonical parallelize pattern for handing each worker a disjoint
# partition of shared state:
#
#     var state = OwnedPointer[GlobalState](...)
#     var work = _ParallelWork[Partition, origin_of(state[]._partitions)](n_workers)
#     for w in range(n_workers):
#         work._set_view_at(w, state[]._partitions.view_mut_at(w, 1))
#
#     var work_p = Pointer(to=work)
#     var state_p = Pointer(to=state[])
#
#     @parameter
#     fn worker(w: Int):
#         var work_ref = work_p[]
#         var state_ref = state_p[]
#         var my_view = work_ref.view_for(w)
#         process_partition(my_view, state_ref.shared_atomic_counter)
#
#     parallelize[worker](n_workers)
#
# What _ParallelWork does: owns a fixed-length array of `ByteView[Self.origin]`
# handles, one per worker. The struct is stack-allocated in the parent
# function; the parallelize closure captures via `Pointer(to=work)`
# (`@parameter parallelize` closures capture via `var p = Pointer(to=X)`,
# NOT bare `ref`).
#
# Why ByteView and not a typed slab: the pattern is UNIVERSAL across
# partition shapes (byte ranges, Slab slices, MmapAlignedBuffer sub-regions).
# A byte-level view lets each worker's code re-cast to its own typed
# handle without forcing the helper to be generic over the partition
# type. If a caller needs a typed view, they construct it inside the
# closure from `view_for(w)._unsafe_ptr()` (which is safe inside the
# closure because the fork-join barrier ensures the parent outlives
# every worker).
#
# Fixed size vs growable: fixed at construction (n_workers). Geometric
# growth would defeat the point -- partitions are carved ONCE before the
# barrier.
#
# Compile-time cap `_MAX_PARTITIONS`: 64, matching the upper bound of
# logical cores we expect on a single machine. If a future system needs
# more, raise the cap -- but confirm the parallelize pattern still
# converges on more than 64 workers first (Amdahl's / contention).
# =============================================================================

from .byte_view import ByteView


comptime _MAX_PARTITIONS: Int = 64


struct _ParallelWork[
    _mut: Bool, //,
    origin: Origin[mut=_mut],
](Movable):
    """N disjoint byte-views, addressable by worker index.

    Stack-owned inside the driver function; captured into the
    `parallelize` closure via `Pointer(to=work)`. See the module header
    for the full surrounding pattern.

    Parameters:
        _mut: Mutability of the partition views (inferred from `origin`).
        origin: Origin the views are tied to (typically
            `origin_of(state[]._partitions)` or similar).

    Fields:
        _views: InlineArray of ByteView slots, indexed by worker id.
        _n: Number of active slots (<= _MAX_PARTITIONS).
    """

    # SAFETY: views share the `origin` parameter of this struct; the
    # compiler tracks them as borrowing from the named origin. Workers
    # receive a fresh view by calling `view_for(w)`, which returns by
    # value (ByteView is Copyable) -- no extra borrow.
    var _views: Array[ByteView[Self.origin], _MAX_PARTITIONS]
    var _n: Int

    @always_inline
    def __init__(out self, n: Int):
        """Construct with `n` empty view slots.

        Callers fill each slot via `_set_view_at(w, view)` before
        entering the dispatch barrier (`pool.run_with_state(..., n)`).

        Args:
            n: Number of worker slots. Must be in [0, _MAX_PARTITIONS].
        """
        debug_assert(
            n >= 0 and n <= _MAX_PARTITIONS,
            "_ParallelWork: n out of range [0, _MAX_PARTITIONS]",
        )
        # Default-fill with empty views (ByteView's default ctor).
        self._views = Array[ByteView[Self.origin], _MAX_PARTITIONS](
            fill=ByteView[Self.origin]()
        )
        self._n = n

    @always_inline
    def _set_view_at(mut self, w: Int, view: ByteView[Self.origin]):
        """Install the worker-w view.

        PANICS if w < 0 or w >= _n.

        Args:
            w: Worker index in [0, n).
            view: The disjoint partition view for this worker.
        """
        debug_assert(
            w >= 0 and w < self._n,
            "_ParallelWork._set_view_at: w out of range",
        )
        self._views[w] = view

    @always_inline
    def view_for(self, w: Int) -> ByteView[Self.origin]:
        """Return the worker-w view.

        PANICS if w < 0 or w >= _n. Callable from inside the
        `parallelize` worker closure via
        `var my_view = work_ref.view_for(w)`.

        Args:
            w: Worker index in [0, n).

        Returns:
            The worker's pre-sliced disjoint partition view.
        """
        debug_assert(
            w >= 0 and w < self._n,
            "_ParallelWork.view_for: w out of range",
        )
        return self._views[w]

    @always_inline
    def __len__(self) -> Int:
        """Return the number of worker slots."""
        return self._n

    @always_inline
    def len(self) -> Int:
        """Return the number of worker slots."""
        return self._n
