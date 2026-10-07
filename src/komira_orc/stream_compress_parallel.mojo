# =============================================================================
# stream_compress_parallel.mojo — ORC per-stripe parallel stream compress.
# =============================================================================
#
# The inverse of `orc_codec.decompress_stream`. Given a stripe's RAW
# (uncompressed) index + data streams, compress each ONCE in parallel, then
# serial-frame them in index order.
#
# Why this exists: compressing each stream synchronously during stripe emit
# makes the codec dominate write wall time — a wide table written with a
# small stride emits tens of thousands of streams, each paying a full ZSTD
# block compress on the writer thread. Compressing the streams of a stripe in
# parallel removes that serial bottleneck.
#
# The per-stream work — `compress_stream(raw, codec)` — is a one-method
# `ChunkWork` impl over the shared `komira_async.runtime.parallel_fork_join`
# helper, which owns the dispatch safety contract once: same stride
# partition, INDEX-ORDER output, first error wins.
#
# Encapsulation: the public entry takes/returns owned `List[List[UInt8]]` +
# a typed-origin dispatcher Pointer. No `UnsafePointer` crosses the module
# boundary.
# =============================================================================

from std.memory import UnsafePointer

from komira_collections.slab import Slab

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.chunk_work import ChunkWork
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_fork_join import parallel_fork_join

from .orc_codec import compress_stream


# =============================================================================
# Thresholds.
# =============================================================================
#
# Below this many streams, dispatcher run_with_state overhead exceeds the
# parallel-compress wall win — serial fallback is the same shape, oblivious to
# the caller. A single-stripe single-column emit has 1-3 streams (PRESENT +
# DATA + maybe LENGTH); below the threshold those go serial. A 21-column
# stripe has ~30 streams per stripe — well above.

comptime _MIN_PARALLEL_COMPRESS_STREAMS: Int = 4

# Cap on parallel-compress workers. Sized for a 10-core machine with one slot
# of headroom; the dispatcher caps further via
# min(worker_count, n_workers).
comptime _MAX_STREAM_COMPRESS_WORKERS: Int = 16


# =============================================================================
# _StreamCompressWork — the per-stream ChunkWork unit.
# =============================================================================
#
# `process(chunk_id, ...)` compresses stream `chunk_id` of the borrowed
# `raw_streams` and writes the owned compressed `List[UInt8]` into its own
# disjoint output slot. The shared `parallel_fork_join` helper invokes this
# once per stream (n_chunks == n_streams), stride-partitioned across workers,
# and owns the State/Task/dispatch/reclaim/error contract.
#
# DISPATCH-BOUNDARY SAFETY is centralized in
# `parallel_fork_join`: disjoint pre-sized Slab[Optional[O]], immutable-origin
# borrow of `raw_streams`, wake-word-barrier liveness, Optional.take reclaim.
# This work unit only carries the codec tag + the per-stream compress call.


@fieldwise_init
struct _StreamCompressWork(ChunkWork):
    """Per-stream compress work. Reads `raw_streams[chunk_id]`, writes the
    compressed payload into `out_slot`. `compress_stream` is a pure-FFI call
    (libzstd / snappy / libz / liblz4) with no shared mutable state. LZO is
    NOT in that list: it is read-only here (liblzo2 is GPL-2.0-or-later and
    is not linked), and `compress_stream` refuses CompressionKind.LZO by
    name."""

    var codec: Int

    def process[
        In: Deinitable, O: Movable & Deinitable
    ](
        self,
        chunk_id: Int,
        n_chunks: Int,
        ref input: In,
        mut out_slot: Optional[O],
    ) raises:
        # SAFETY: the helper binds In=List[List[UInt8]], O=List[UInt8] at the
        # `parallel_fork_join[...]` call site; the bitcasts resolve to those
        # concrete types. Internal to this module; never exposed publicly.
        var rp = UnsafePointer(to=input).bitcast[List[List[UInt8]]]()
        ref raw = rp[][chunk_id]
        var compressed = compress_stream(raw, self.codec)
        var op = UnsafePointer(to=out_slot).bitcast[Optional[List[UInt8]]]()
        op[] = Optional[List[UInt8]](compressed^)


def compress_streams_parallel[
    raw_o: ImmOrigin,
    disp_o: Origin[mut=True],
](
    raw_streams: List[List[UInt8]],
    codec: Int,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> Slab[List[UInt8]]:
    """Compress every stream in `raw_streams` in parallel via the shared
    `parallel_fork_join` fork-join helper.

    Returns a `Slab[List[UInt8]]` of compressed payloads in INDEX ORDER (slot
    `i` holds the compressed bytes for `raw_streams[i]`).

    NONE codec callers should bypass — `compress_stream(NONE, raw)` is a copy.
    The caller can frame the raw stream directly (zero-copy frame-raw shape).

    Below `_MIN_PARALLEL_COMPRESS_STREAMS` streams the helper falls back to a
    serial per-stream compress (via `min_parallel_chunks`); same-shape result
    (caller is oblivious).
    """
    var n_streams = len(raw_streams)

    # One chunk per stream. The helper stride-partitions chunks across workers
    # internally, gates parallel-vs-serial via `min_parallel_chunks`, caps
    # workers via `max_workers`, runs the dispatch + Optional.take reclaim +
    # first-error-wins re-raise, and returns one Optional[List[UInt8]] per
    # stream in INDEX ORDER.
    var work = _StreamCompressWork(codec)
    comptime in_o = origin_of(raw_streams)
    var fj_out = parallel_fork_join[
        _StreamCompressWork,
        List[List[UInt8]],
        List[UInt8],
        in_o,
        disp_o,
    ](
        work^,
        raw_streams,
        n_streams,
        dispatcher_ptr,
        cancel_token^,
        min_parallel_chunks=_MIN_PARALLEL_COMPRESS_STREAMS,
        max_workers=_MAX_STREAM_COMPRESS_WORKERS,
    )

    # Unwrap the helper's per-chunk Optional[O] into the public
    # Slab[List[UInt8]] (every slot is always filled by the work unit).
    var out_streams = Slab[List[UInt8]].create(n_streams)
    var i = 0
    while i < n_streams:
        ref slot = fj_out.get_mut_interior(i)
        if slot:
            out_streams.append(slot.take())
        else:
            out_streams.append(List[UInt8]())
        i = i + 1
    _ = fj_out^
    return out_streams^
