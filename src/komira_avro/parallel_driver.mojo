# =============================================================================
# parallel_driver.mojo — block-parallel OCF decode via the runtime
# LocalDispatcher.
# =============================================================================
#
# OCF blocks are sync-marker-delimited and INDEPENDENTLY DECODABLE: each block
# carries its own record-count + byte-size + codec-compressed payload, and the
# sync marker bounds it. Decoding block N requires nothing from block N-1's
# decoder state. They are embarrassingly parallel. This driver decodes them
# in parallel:
#
#   1. Block discovery: `scan_ocf_blocks_after_header` chained-walks the sync
#      markers ONCE on the driver thread to get every block's (offset, len,
#      object_count) in file order. This is O(num_blocks) varint reads — cheap
#      vs the per-block decompress + decode each worker runs.
#   2. Block→worker partition: the N blocks are split into K contiguous
#      worker-ranges (K = worker count). Worker w decodes blocks [lo_w, hi_w),
#      decompressing each block's payload (codec FFI) and running the
#      comptime decoder (hot shapes) or the runtime ActionTableInterpreter
#      (UNKNOWN long tail) into a per-worker accumulator slab → one per-worker
#      RecordBatch.
#   3. Reassembly: each worker writes its batch into `Slab[Optional[
#      RecordBatch]]` slot `w` (disjoint write). Because worker-ranges are
#      contiguous + in file order, slot order IS file order. Staging slots
#      0..K-1 in slot order and folding them with ONE N-way concat reassembles
#      the final single RecordBatch — row-for-row identical to the serial
#      decode (see `_reassemble_in_order`).
#
# The fork-join runs on `LocalDispatcher.run_with_state`, never on stdlib
# `parallelize` (library code dispatches through the runtime). It has the
# same shape as the Arrow IPC body-compression dispatch:
#
#   * `_DecodeBlockRangeState[bytes_o]` (KeepAlive, Movable) OWNS the
#     per-dispatch scratch (`blocks`, `block_los`, `block_his`, `header`,
#     `schema`, the per-worker output `worker_batches: Slab[Optional[
#     RecordBatch]]` + `worker_errors: List[Optional[String]]`), and BORROWS
#     the caller-owned read-only `bytes` Span via a CONCRETE typed-origin
#     UnsafePointer field (`bytes_o: ImmutOrigin`). ZERO MutExternalOrigin
#     wildcard fields. The output Slab / lists move IN at
#     dispatch time and are reclaimed via `Optional.take()` post-dispatch
#     (never a partial move through UnsafePointer).
#   * `_DecodeBlockRangeTask[bytes_o]` (Segment) carries only a POD Int32
#     discriminant; `execute` reaches the concrete State via the canonical
#     one-line bitcast and runs ONE worker-shard `[lo, hi)` decode.
#   * Three entry points (canonical _serial / _with_dispatcher / _impl
#     split, mirroring `_compress_buffers_into*`):
#     - `read_avro_bytes_parallel` — serial-fallback wrapper (no dispatcher);
#       fixtures / direct-invocation callers without a EngineContext hit this.
#     - `read_avro_bytes_parallel_with_dispatcher[disp_o]` — dispatcher-aware
#       variant; threads `ctx.dispatcher()` / `ctx.cancel_token()` into
#       `LocalDispatcher.run_with_state`.
#     - `_read_avro_bytes_parallel_impl[has_pool, disp_o]` — shared body;
#       comptime `has_pool` branches between the dispatch + serial-loop arms.
#
# DISPATCH-BOUNDARY safety:
#   * Disjointness: worker `w` is the UNIQUE writer to `worker_batches[w]`
#     (Slab __setitem__ on a pre-sized slot) and `worker_errors[w]`. Every
#     other field read by `execute` (`bytes` via the typed-origin borrow,
#     `blocks`, `block_los`, `block_his`, `header`, `schema`, `shape_kind`,
#     `hot`) is read-only across workers.
#   * Liveness: `run_with_state` is a SYNCHRONOUS wake-word barrier — it
#     rejoins every worker shard before returning, so the State (and the
#     caller's `bytes`) outlives every worker. No OwnedPointer / async
#     boundary; no `_ = struct` keepalive needed (the barrier IS the
#     keepalive — same shape as IPC).
#   * No-realloc: `worker_batches` + `worker_errors` are pre-sized to K and
#     only ever written via __setitem__, never `append`.
#   * Encapsulation: the only raw pointer is the State's `bytes_ptr` field,
#     a CONCRETE typed-origin UnsafePointer (NOT wildcard); the per-shard
#     state pointer the dispatcher hands `execute` is the bitcast resolved
#     at the `run_with_state[State, T]` call site. No UnsafePointer crosses
#     any public module/function boundary.
# =============================================================================

from komira_async.runtime.sched_trace import SITE_FORMAT_READ
from std.sys import num_physical_cores

from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.concat import concat_record_batches_nway
from komira_collections.slab import Slab
from komira_async_api.worker_pool_traits import KeepAlive, Segment

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from .action_table import (
    ActionTableInterpreter,
    ColumnAccVariant,
    ResolutionTable,
)
from .avro_codec import decompress_block
from .avro_schema import AvroSchema
from .comptime_decoder import (
    _build_col_plans,
    classify_avro_shape,
    decode_block_comptime,
    is_hot_shape,
    SHAPE_KIND_STRUCT_OF_1_INT,
    SHAPE_KIND_STRUCT_OF_N_PRIMS,
    SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS,
)
from .ocf_block_scan import OcfBlock, scan_ocf_blocks_after_header
from .ocf_header import OcfHeader, decode_ocf_header


# =============================================================================
# Threshold gates + tunables.
# =============================================================================

# Below this many blocks, the partition + concat overhead exceeds the parallel
# decode win; defer to the single-thread serial path. A 1-block file (the
# common small-file case) always takes the serial fast path.
comptime _MIN_PARALLEL_BLOCKS: Int = 2

# Cap worker count. More than 32 workers rarely pays back the partition
# overhead; on high-core machines this keeps each worker's block-range large
# enough to amortize the per-worker accumulator-slab + RecordBatch build cost.
comptime _MAX_WORKERS: Int = 32


# =============================================================================
# _DecodeBlockRangeState[bytes_o] — per-dispatch State for the block-parallel
# decode (KeepAlive, Movable).
# =============================================================================
#
# OWNS the per-dispatch scratch + the per-worker output Slab + error list;
# BORROWS the caller-owned read-only `bytes` Span via a CONCRETE typed-origin
# UnsafePointer field. ZERO wildcard fields.
#
# The output Slab + error list are moved IN at dispatch time and extracted via
# `Optional.take()` at dispatch return — this avoids the `mut state` ↔
# caller-held mut borrow aliasing the compiler would flag: `Optional.take()` is
# the safe replacement for `UnsafePointer(to=state.field).take_pointee()`.


struct _DecodeBlockRangeState[bytes_o: ImmOrigin](KeepAlive, Movable):
    """State for the per-worker block-range parallel decode dispatch."""

    # Borrowed read-only input — pinned to the caller via `bytes_o`.
    # SAFETY: Internal typed pointer — never exposed to public API. The
    # `bytes_o: Origin` parameter is CONCRETE (the caller's Span origin, not a
    # wildcard like MutExternalOrigin), so this is the canonical typed-origin-
    # borrow pattern (no stale-pointer hazard across destroy and recreate).
    # Mojo struct fields cannot hold `ref`
    # directly; a typed-origin UnsafePointer is the canonical encoding (same
    # shape as `_CompressBuffersState.raw_body_ptr`). The decode reads the
    # bytes read-only regardless of the origin's mutability.
    var bytes_ptr: UnsafePointer[UInt8, Self.bytes_o]
    var bytes_len: Int
    # OWNED per-dispatch scratch (via Optional.take pattern so the State drop
    # sees None placeholders rather than moved-out bits).
    var blocks: Optional[List[OcfBlock]]
    var block_los: Optional[List[Int]]
    var block_his: Optional[List[Int]]
    var header: Optional[OcfHeader]
    var schema: Optional[AvroSchema]
    # OWNED per-worker output slots — worker `tid` writes ONLY slot `tid`.
    var worker_batches: Optional[Slab[Optional[RecordBatch]]]
    var worker_errors: Optional[List[Optional[String]]]
    # POD scalars shared read-only across workers.
    var shape_kind: Int
    var hot: Bool
    var k: Int

    def __init__(
        out self,
        bytes_ptr: UnsafePointer[UInt8, Self.bytes_o],
        bytes_len: Int,
        var blocks: List[OcfBlock],
        var block_los: List[Int],
        var block_his: List[Int],
        var header: OcfHeader,
        var schema: AvroSchema,
        var worker_batches: Slab[Optional[RecordBatch]],
        var worker_errors: List[Optional[String]],
        shape_kind: Int,
        hot: Bool,
        k: Int,
    ):
        self.bytes_ptr = bytes_ptr
        self.bytes_len = bytes_len
        self.blocks = Optional[List[OcfBlock]](blocks^)
        self.block_los = Optional[List[Int]](block_los^)
        self.block_his = Optional[List[Int]](block_his^)
        self.header = Optional[OcfHeader](header^)
        self.schema = Optional[AvroSchema](schema^)
        self.worker_batches = Optional[Slab[Optional[RecordBatch]]](
            worker_batches^
        )
        self.worker_errors = Optional[List[Optional[String]]](worker_errors^)
        self.shape_kind = shape_kind
        self.hot = hot
        self.k = k


@fieldwise_init
struct _DecodeBlockRangeTask[bytes_o: ImmOrigin](Segment):
    """POD Segment for `_DecodeBlockRangeState` dispatch — k tasks, one
    contiguous block-range per worker (slot order == file order)."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the dispatch helper parameterizes run_with_state over
        # (_DecodeBlockRangeState[bytes_o], _DecodeBlockRangeTask[bytes_o]);
        # the bitcast resolves to the concrete state at the call site.
        var sp = UnsafePointer(to=state).bitcast[
            _DecodeBlockRangeState[Self.bytes_o]
        ]()
        var tid = Int(task_id)
        if tid >= sp[].k:
            return
        var lo = sp[].block_los.value()[tid]
        var hi = sp[].block_his.value()[tid]
        # Reconstruct the borrowed bytes Span over [0, bytes_len) from the
        # typed-origin pointer field. `bytes_o` is concrete, so the produced
        # Span carries the caller's origin (the read-only borrow contract).
        var bytes_span = Span[UInt8, Self.bytes_o](
            unsafe_ptr=sp[].bytes_ptr, length=sp[].bytes_len
        )
        try:
            var batch = _decode_block_range(
                bytes_span,
                sp[].blocks.value(),
                lo,
                hi,
                sp[].header.value(),
                sp[].schema.value(),
                sp[].shape_kind,
                sp[].hot,
            )
            # Disjoint write: worker `tid` owns slot `tid`.
            sp[].worker_batches.value()[tid] = Optional[RecordBatch](batch^)
        except e:
            sp[].worker_errors.value()[tid] = Optional[String](String(e))


# =============================================================================
# Public entry — serial-fallback wrapper.
# =============================================================================


def read_avro_bytes_parallel(
    bytes: Span[UInt8, _],
    n_workers: Int = 0,
    *,
    print_timing: Bool = False,
) raises -> RecordBatch:
    """Read an entire Avro OCF byte stream into one RecordBatch, decoding blocks
    in parallel across worker threads — serial-fallback wrapper.

    Callers WITHOUT an EngineContext-owned dispatcher (test fixtures / direct-invocation
    callers) hit this entry point, which routes into the shared
    `_read_avro_bytes_parallel_impl[has_pool=False]` serial decode. The
    dispatcher-aware parallel path is `read_avro_bytes_parallel_with_dispatcher`
    (threaded from `ctx.read_avro`).

    Identity resolution (reader == writer ==
    OCF-header schema). Byte-identical output to `read_avro_bytes` /
    `decode_avro_bytes_comptime` for every shape.

    Args:
        bytes: Origin-poly Span over the full OCF file contents.
        n_workers: Caller-requested worker count (advisory for the parallel
            path; the serial wrapper decodes single-threaded regardless).
        print_timing: Forwarded to `decode_avro_bytes_comptime`; prints its
            per-phase decode timers to stdout. Off by default.

    Returns:
        A single `RecordBatch` carrying every row in file order.

    Raises:
        On recursive / malformed schema, unsupported codec, malformed OCF wire
        data, or a codec CRC mismatch.
    """
    # Force an IMMUTABLE borrow of the input bytes — the decode is read-only,
    # and the State's typed-origin pointer field MUST be immutable so the
    # `mut state` ↔ borrowed-bytes pair the dispatch passes to
    # `run_with_state` does not trip Mojo's write-alias check (same contract
    # as `_CompressBuffersState.raw_o: ImmutOrigin`).
    var bytes_ro = bytes.as_imm()
    return _read_avro_bytes_parallel_impl[
        has_pool=False, disp_o=MutAnyOrigin,
    ](
        bytes_ro,
        n_workers,
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
        print_timing,
    )


# =============================================================================
# Public entry — dispatcher-aware parallel decode.
# =============================================================================


def read_avro_bytes_parallel_with_dispatcher[
    disp_o: Origin[mut=True],
](
    bytes: Span[UInt8, _],
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
    n_workers: Int = 0,
    *,
    print_timing: Bool = False,
) raises -> RecordBatch:
    """Dispatcher-aware variant — typed-origin dispatcher required.

    Threads `dispatcher_ptr` +
    `cancel_token` from the calling EngineContext (`ctx.dispatcher()` +
    `ctx.cancel_token()`) down to `LocalDispatcher.run_with_state` for the
    parallel per-worker block-range decode. Byte-identical output to the
    serial path.

    Args:
        bytes: Origin-poly Span over the full OCF file contents.
        dispatcher_ptr: Borrowed pointer to the EngineContext's
            LocalDispatcher.
        cancel_token: The session-wide cancellation token clone; consumed.
        n_workers: Caller-requested worker count. Defaults to 0, which queries
            `num_physical_cores()` and caps at `_MAX_WORKERS`. Pass 1 to force
            single-thread.
        print_timing: Forwarded to `decode_avro_bytes_comptime` when the
            decode falls back to the serial path; prints its per-phase timers
            to stdout. Off by default.

    Returns:
        A single `RecordBatch` carrying every row in file order.

    Raises:
        On recursive / malformed schema, unsupported codec, malformed OCF wire
        data, or a codec CRC mismatch (re-raised from the failing worker at the
        run_with_state barrier).
    """
    # Force an IMMUTABLE borrow of the input bytes — see the serial wrapper's
    # note: the State's typed-origin pointer field must be immutable so the
    # dispatch's `mut state` ↔ borrowed-bytes pair does not trip the write-
    # alias check in `run_with_state`.
    var bytes_ro = bytes.as_imm()
    return _read_avro_bytes_parallel_impl[
        has_pool=True, disp_o=disp_o,
    ](
        bytes_ro,
        n_workers,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
        print_timing,
    )


# =============================================================================
# Shared body — block-parallel OCF decode (the default read path).
# =============================================================================


def _read_avro_bytes_parallel_impl[
    bytes_o: ImmOrigin,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    bytes: Span[UInt8, bytes_o],
    n_workers: Int,
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
    var cancel_token: CancellationToken,
    print_timing: Bool,
) raises -> RecordBatch:
    """Shared body for the serial + dispatcher-aware block-parallel decode.

    Comptime `has_pool` flag prunes the parallel/serial branch — no wildcard
    origin reaches the dispatch in either path (canonical
    `_compress_buffers_into_impl` pattern).

    Falls back to the single-thread serial path (`decode_avro_bytes_comptime`)
    when:
      - the file has fewer than `_MIN_PARALLEL_BLOCKS` blocks (1-block / tiny
        file), OR
      - `n_workers == 1` (caller-requested serial), OR
      - the effective worker count after the block partition resolves to 1, OR
      - `has_pool=False` (no dispatcher threaded).
    """
    from .comptime_decoder import decode_avro_bytes_comptime

    # has_pool=False: serial-only branch — caller did not thread a dispatcher.
    comptime if not has_pool:
        _ = cancel_token^
        return decode_avro_bytes_comptime(bytes, print_timing=print_timing)
    else:
        var header = decode_ocf_header(bytes)
        var blocks = scan_ocf_blocks_after_header(bytes, header)
        var num_blocks = len(blocks)

        # Resolve effective worker count.
        var effective_workers = n_workers
        if effective_workers <= 0:
            effective_workers = num_physical_cores()
        if effective_workers > _MAX_WORKERS:
            effective_workers = _MAX_WORKERS
        if effective_workers < 1:
            effective_workers = 1

        # Threshold gate: too few blocks or serial requested → serial fast
        # path.
        if num_blocks < _MIN_PARALLEL_BLOCKS or effective_workers == 1:
            _ = cancel_token^
            return decode_avro_bytes_comptime(bytes, print_timing=print_timing)

        # Never spawn more workers than blocks (an empty worker-range is
        # wasted).
        if effective_workers > num_blocks:
            effective_workers = num_blocks

        # =================================================================
        # Block→worker partition: K contiguous block-ranges, in file order.
        # =================================================================
        # Worker w decodes blocks [block_los[w], block_his[w]). Contiguous +
        # ascending → slot order == file order for the reassembly concat.
        var block_los = List[Int]()
        var block_his = List[Int]()
        _partition_blocks(num_blocks, effective_workers, block_los, block_his)
        var k = len(block_los)

        if k <= 1:
            # Partition collapsed to one worker — serial fast path.
            _ = cancel_token^
            return decode_avro_bytes_comptime(bytes, print_timing=print_timing)

        # =================================================================
        # Resolve schema + decode plan ONCE on the driver thread.
        # =================================================================
        # Identity resolution: every worker shares the SAME ResolutionTable
        # shape. We classify the shape once; each worker rebuilds its own
        # accumulator slab (accumulators are per-worker mutable state — they
        # must NOT be shared).
        var schema = header.parse_schema()
        var shape_kind = classify_avro_shape(schema)
        var hot = is_hot_shape(shape_kind)

        # =================================================================
        # Pre-size per-worker output + error channels (no growth across
        # dispatch).
        # =================================================================
        # Slab[Optional[RecordBatch]] (not List) because RecordBatch is
        # Movable but NOT Copyable; List[T] requires Copyable.
        var worker_batches = Slab[Optional[RecordBatch]].create(k)
        var slot = 0
        while slot < k:
            worker_batches.append(Optional[RecordBatch](None))
            slot = slot + 1

        var worker_errors = List[Optional[String]]()
        var slot2 = 0
        while slot2 < k:
            worker_errors.append(Optional[String](None))
            slot2 = slot2 + 1

        # =================================================================
        # DISPATCH-BOUNDARY: build State + Task; dispatch via
        # LocalDispatcher.run_with_state. typed origins; no
        # MutExternalOrigin wildcards. `bytes` is borrowed read-only via a
        # CONCRETE typed-origin pointer; the per-worker output Slab + error
        # list are MOVED INTO State and reclaimed via Optional.take().
        # =================================================================
        var bytes_ptr = bytes.unsafe_ptr()
        var bytes_len = len(bytes)
        var state = _DecodeBlockRangeState[bytes_o](
            bytes_ptr,
            bytes_len,
            blocks^,
            block_los^,
            block_his^,
            header^,
            schema^,
            worker_batches^,
            worker_errors^,
            shape_kind,
            hot,
            k,
        )
        var task = _DecodeBlockRangeTask[bytes_o](Int32(0))
        var disp = dispatcher_ptr.value()
        _ = disp[].run_with_state[
            _DecodeBlockRangeState[bytes_o],
            _DecodeBlockRangeTask[bytes_o],
        ](state, task^, k, cancel_token^, site_id=SITE_FORMAT_READ)

        # Reclaim the output Slab + error list + schema from State via
        # Optional.take (never a partial move through UnsafePointer). State
        # drops at scope exit with Optional fields in None state.
        var batches_back = state.worker_batches.take()
        var errors_back = state.worker_errors.take()
        var schema_back = state.schema.take()
        _ = state^

        # =================================================================
        # Drain error slots; re-raise the first failure (file order).
        # =================================================================
        var e_idx = 0
        while e_idx < k:
            if errors_back[e_idx]:
                var msg = errors_back[e_idx].value().copy()
                raise Error(
                    String("komira_avro.parallel_driver: worker ")
                    + String(e_idx)
                    + String(" failed: ")
                    + msg
                )
            e_idx = e_idx + 1

        # =================================================================
        # Reassemble into file order: serial in-order concat over slots
        # 0..K-1.
        # =================================================================
        return _reassemble_in_order(batches_back^, k, schema_back)


# =============================================================================
# Block→worker partition.
# =============================================================================


def _partition_blocks(
    num_blocks: Int,
    k_desired: Int,
    mut los: List[Int],
    mut his: List[Int],
):
    """Split [0, num_blocks) into up to `k_desired` contiguous block-ranges.

    Distributes the remainder across the first `num_blocks % k_desired`
    workers so range sizes differ by at most 1 (balanced). Empty ranges are
    dropped. On return len(los) == len(his) <= k_desired, and the ranges
    exactly tile [0, num_blocks) in ascending order.
    """
    los.clear()
    his.clear()
    if k_desired <= 1 or num_blocks <= 0:
        los.append(0)
        his.append(num_blocks)
        return

    var base = num_blocks // k_desired
    var rem = num_blocks % k_desired
    var pos = 0
    var w = 0
    while w < k_desired:
        var span = base + (1 if w < rem else 0)
        var lo = pos
        var hi = pos + span
        if hi > lo:
            los.append(lo)
            his.append(hi)
        pos = hi
        w = w + 1


# =============================================================================
# Per-worker block-range decode → one RecordBatch.
# =============================================================================


def _decode_block_range(
    bytes: Span[UInt8, _],
    blocks: List[OcfBlock],
    lo: Int,
    hi: Int,
    header: OcfHeader,
    schema: AvroSchema,
    shape_kind: Int,
    hot: Bool,
) raises -> RecordBatch:
    """Decode the contiguous block range [lo, hi) into one RecordBatch.

    Each worker independently rebuilds its own ResolutionTable + accumulator
    slab (per-worker MUTABLE state — must never be shared across the
    dispatch boundary). The `schema` is a read-only borrow shared across
    workers (ResolutionTable.identity consumes it by borrow). Hot shapes run
    the comptime cascade; the UNKNOWN long tail runs the runtime
    ActionTableInterpreter — identical to the serial decode, just over this
    worker's block subset.
    """
    if hot:
        # Hot path: per-worker accumulator slab + plans.
        var table = ResolutionTable.identity(schema)
        var plans = _build_col_plans(table)
        var accs = Slab[ColumnAccVariant]()
        for i in range(len(table.out_specs)):
            var rfd = table.out_specs[i].copy()
            accs.append(ColumnAccVariant.create(rfd))

        var bi = lo
        while bi < hi:
            var blk = blocks[bi].copy()
            var raw = bytes[blk.payload_offset : blk.payload_offset + blk.payload_len]
            var decompressed = decompress_block(header.codec_tag, raw)
            if shape_kind == SHAPE_KIND_STRUCT_OF_1_INT:
                decode_block_comptime[SHAPE_KIND_STRUCT_OF_1_INT](
                    accs, plans, Span(decompressed), Int(blk.object_count)
                )
            elif shape_kind == SHAPE_KIND_STRUCT_OF_N_PRIMS:
                decode_block_comptime[SHAPE_KIND_STRUCT_OF_N_PRIMS](
                    accs, plans, Span(decompressed), Int(blk.object_count)
                )
            else:  # SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS
                decode_block_comptime[SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS](
                    accs, plans, Span(decompressed), Int(blk.object_count)
                )
            bi = bi + 1

        var ncols = len(accs)
        var builder = RecordBatchBuilder.with_capacity(ncols)
        for i in range(ncols):
            builder.add_column(accs[i].build())
        return builder.build(table.out_schema.copy())

    # Long-tail fallback: per-worker runtime ActionTableInterpreter.
    var table = ResolutionTable.identity(schema)
    var interp = ActionTableInterpreter(table^)
    var bi2 = lo
    while bi2 < hi:
        var blk = blocks[bi2].copy()
        var raw = bytes[blk.payload_offset : blk.payload_offset + blk.payload_len]
        var decompressed = decompress_block(header.codec_tag, raw)
        interp.decode_block(Span(decompressed), Int(blk.object_count))
        bi2 = bi2 + 1
    return interp.build_batch()


# =============================================================================
# Reassembly — serial in-order concat over file-ordered worker slots.
# =============================================================================


def _reassemble_in_order(
    var worker_batches: Slab[Optional[RecordBatch]],
    k: Int,
    schema: AvroSchema,
) raises -> RecordBatch:
    """Concatenate the per-worker batches in slot order (== file order) into a
    single RecordBatch.

    Slot `i` holds the batch for the i-th lowest contiguous block-range, so
    staging the populated slots in slot order and folding them ONCE yields the
    exact serial row sequence. None slots (an empty block-range — should not
    occur after the partition drops empties, but defensive) are skipped.

    On all-empty (no batch in any slot) emits an empty batch stamped with the
    identity output schema — mirrors the serial empty path.

    ⛔ ONE sized N-way concat, never a pairwise fold. A pairwise
    `acc = _concat_two_batches(acc^, batch^)` allocates a FRESH destination
    per column and copies BOTH inputs into it — worker slot j of k would be
    re-copied (k - j) times, for O(k^2) destination bytes. The N-way concat
    makes `num_columns` allocations and copies each row once.

    It calls `komira_arrow.concat.concat_record_batches_nway` directly:
    `komira_engine_operators` (which holds the shared sink fold) depends on
    `komira_avro`, so importing it here would be a build cycle. That callee
    routes validity through `_merge_validity_nway` and carries `null_count`,
    `decimal_p/s`, the offsets buffer and the dictionary; nothing is
    open-coded here. `tests/test_avro_block_parallel_decode.mojo` pins both
    correctness contracts: a >= 8-block file decoded in PARALLEL must be
    row-for-row identical to the SERIAL decode — same ORDER
    (`test_nprims_order_parity`) and same NULL BITMAP
    (`test_nullable_order_parity`).
    """
    var batches = worker_batches^
    var staged = Slab[RecordBatch]()
    var i = 0
    while i < k:
        if batches[i]:
            # Slot is populated — MOVE the RecordBatch out of the Optional into
            # the stage, in slot order (== file order). This pass copies
            # NOTHING; the single fold below does every copy, once per
            # destination column.
            staged.append(batches[i].take())
        i = i + 1
    _ = batches^

    if len(staged) > 0:
        return concat_record_batches_nway(staged^)
    _ = staged^

    # All-empty: emit an empty batch with the identity output schema.
    var table = ResolutionTable.identity(schema)
    var ncols = len(table.out_specs)
    var builder = RecordBatchBuilder.with_capacity(ncols)
    for ci in range(ncols):
        var rfd = table.out_specs[ci].copy()
        var acc_v = ColumnAccVariant.create(rfd)
        builder.add_column(acc_v.build())
    return builder.build(table.out_schema.copy())
