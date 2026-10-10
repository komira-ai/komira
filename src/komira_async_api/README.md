# komira_async_api

Cancellation token, detached-drop spawn, the dispatcher / worker-pool / fork-join / scale-signal trait contracts, and the pool-depth counter.

The package root re-exports nothing; import each name from its module:

- `komira_async_api.token`: `CancellationToken` (a tree of cancellation
  flags: cancelling a token cancels its descendants, never its ancestors) and
  the `Cancellable` trait.
- `komira_async_api.spawn_drop`: `spawn_drop(value)` destroys a value on a
  detached background thread (inline if the thread cannot be created).
- `komira_async_api.parallel_dispatch`: the `ParallelDispatch` trait a
  dispatcher implements, and `NoDispatch`, a conformer that owns no workers.
- `komira_async_api.worker_pool_traits`: `KeepAlive` and `Segment`, the
  state and per-worker task contracts of `run_with_state`.
- `komira_async_api.shared_chunk_work` and
  `komira_async_api.fork_join_shared`: the `SharedChunkWork` trait and
  `fork_join_shared`, which runs a chunked job whose chunks write disjoint
  slots of one shared payload, across a dispatcher's workers or inline.
- `komira_async_api.scale_signal`: the `ScaleSignal` trait.
- The pool-depth counter is a C counter of dispatches in flight;
  `fork_join_pool_depth()` reads it, and a fork-join wave that finds it above
  zero runs its chunks inline.

## Examples

Cancellation flows down a token tree, never up. The first reason given wins,
and the never-cancelled token ignores `cancel`:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_async_api.token import CancellationToken

var root = CancellationToken.new()
var child = root.child()
var shared = root.clone()  # the same token, a second owner

var leaf = child.child()
leaf.cancel("leaf done")
assert_true(leaf.is_cancelled())
assert_false(child.is_cancelled())  # not upward

root.cancel("deadline")
root.cancel("ignored")  # idempotent: the first reason stays
assert_true(shared.is_cancelled())
assert_true(child.is_cancelled())  # downward
assert_equal(child.reason(), "deadline")
assert_equal(leaf.reason(), "deadline")  # the outermost reason wins

var never = CancellationToken.never()
never.cancel("no effect")
assert_false(never.is_cancelled())
```

A shared-payload fork-join: each chunk squares its own slice of the input into
the same output list. `has_pool=False` with `NoDispatch` runs the chunks
inline on the calling thread; a pooled dispatcher (one implementing
`ParallelDispatch`) runs the same work across its workers. Outside any
dispatch the pool depth is zero:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_async_api.fork_join_shared import fork_join_pool_depth, fork_join_shared
from komira_async_api.parallel_dispatch import NoDispatch
from komira_async_api.shared_chunk_work import SharedChunkWork
from komira_async_api.token import CancellationToken

@fieldwise_init
struct SquareChunk(SharedChunkWork):
    var chunk_len: Int

    def process[In: Deinitable, P: Movable & Deinitable](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P
    ) raises:
        # squares() below binds both In and P to List[Int].
        ref src = rebind[List[Int]](input)
        ref dst = rebind[List[Int]](payload)
        for i in range(chunk_id * self.chunk_len, (chunk_id + 1) * self.chunk_len):
            dst[i] = src[i] * src[i]

def squares(imm values: List[Int], chunk_len: Int) raises -> List[Int]:
    var serial = NoDispatch()
    return fork_join_shared[
        SquareChunk, List[Int], List[Int], origin_of(values), NoDispatch,
        has_pool=False, disp_o=origin_of(serial),
    ](
        SquareChunk(chunk_len),
        values,
        List[Int](length=len(values), fill=0),
        len(values) // chunk_len,  # chunks
        2,  # fewest chunks worth dispatching
        0,  # worker cap: 0 means the dispatcher's own count
        None,  # no dispatcher
        CancellationToken.never(),
        UInt32(0),  # sched-trace site id
    )

assert_equal(squares([1, 2, 3, 4, 5, 6], 2), [1, 4, 9, 16, 25, 36])
assert_equal(fork_join_pool_depth(), Int64(0))
```
