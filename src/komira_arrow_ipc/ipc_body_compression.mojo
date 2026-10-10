# =============================================================================
# ipc_body_compression.mojo — per-buffer body compression
# =============================================================================
#
# Implements the Arrow IPC RecordBatch body compression (per-buffer
# compression).
#
# Arrow IPC's compression model is PER-BUFFER, not per-body. Each Buffer
# entry inside a compressed RecordBatch body is wire-formatted as:
#
#     <i64 uncompressed_length_LE> <compressed_bytes...>
#
# where `compressed_bytes` has length `BufferDescriptor.length - 8`. If
# the compressed form would be LARGER than the uncompressed form, the
# writer emits `uncompressed_length = -1` (sentinel) followed by the
# RAW uncompressed bytes — readers detect the sentinel and skip
# decompression for that buffer. This rule is implemented in
# `_compress_buffer_with_threshold` below.
#
# The RecordBatch flatbuf message gains a `BodyCompression` child table
# (field 3) carrying the codec id:
#
#     0 = LZ4_FRAME  (LZ4 frame format, magic 0x184D2204)
#     1 = ZSTD
#
# An `Uncompressed` writer MUST NOT emit the BodyCompression flatbuf field
# — the spec's "no field" path means "uncompressed body". The dispatch
# routes `Uncompressed` through
# the existing `encode_record_batch_message` (no compression infra
# entered); `Lz4Frame` and `Zstd[*]` route through this module.
#
# This module exposes:
#   - `encode_record_batch_message_compressed[C: ArrowIpcCompression]`
#     — encoder entry; mirrors `encode_record_batch_message` shape.
#   - `decompress_record_batch_body_in_place[C: ArrowIpcCompression]`
#     — decoder helper; rewrites the body bytes + BufferDescriptors
#     in a fresh frame BEFORE the per-column build pass walks them.
# =============================================================================

from std.memory import UnsafePointer
from std.sys import num_physical_cores

from komira_buffer.aligned_buffer_trait import AlignedBufferTrait
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_collections.slab import Slab

from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_buffer.heap_region import HeapRegion
from komira_compression.compression import ArrowIpcCompression
from komira_compression.compression_codecs import _CodecDctxHandle
from komira_arrow_ipc.ipc_flatbuf import (
    FlatbufWriter,
    BufferDescriptor,
    FieldNode,
    write_record_batch,
    write_record_batch_compressed,
    write_body_compression,
    write_dictionary_batch,
    write_message,
    write_ipc_message,
    parse_ipc_message,
    flatbuf_reader_over,
    read_message,
    read_record_batch,
    MESSAGE_HEADER_RECORD_BATCH,
    MESSAGE_HEADER_DICTIONARY_BATCH,
    MESSAGE_HEADER_SCHEMA,
    METADATA_VERSION_V5,
    IPC_CONTINUATION_MARKER,
)
from komira_async_api.token import CancellationToken
from komira_async_api.parallel_dispatch import (
    ParallelDispatch,
    NoDispatch,
)
from komira_arrow_ipc.ipc_body_sink import AlignedBufferBodySink
from komira_arrow_ipc.ipc_encoder_dispatch import encode_column, _estimate_body_size

# -----------------------------------------------------------------------------
# LANE-2 sched-trace call-site ids. MIRRORED,
# not imported: `komira_async` deps on the core packages, so importing
# `komira_async.runtime.sched_trace` here would close a package cycle. These
# two comptime values MUST stay in lockstep with `SITE_FORMAT_READ` /
# `SITE_FORMAT_WRITE` in `komira_async/runtime/sched_trace.mojo` and with the
# `_sched_site_name` switch in `komira_async/reactor/_posix_shim.c`. A drift
# here mislabels a diagnostic row; it cannot corrupt the accounting. `site_id`
# is a plain runtime UInt32 on `run_with_state` — no type dependency is created.
# -----------------------------------------------------------------------------
comptime _SITE_FORMAT_READ: UInt32 = 32
comptime _SITE_FORMAT_WRITE: UInt32 = 33


# Sentinel value for "buffer is left uncompressed in a compressed body";
# per Arrow IPC spec, writers emit this when the compressed form would
# be larger than the uncompressed form. Readers detect it + skip
# decompression for that buffer.
comptime UNCOMPRESSED_LEN_SENTINEL: Int64 = -1

# Per-buffer u_lens marker used by
# `_build_rb_context[C]` to signal "this RB carried no BodyCompression FB
# field (codec == -1); the buffer body is verbatim — no i64 prefix, no
# decompress; the dispatch branches MUST memcpy `c_len` bytes starting at
# `body_pos + c_off` (not body_pos + c_off + 8)". Distinct from
# `UNCOMPRESSED_LEN_SENTINEL` (-1) which is per-BUFFER inside a compressed
# RB body. -2 picks a value that cannot collide with any legal
# uncompressed length (which are >= 0) or with the per-buffer sentinel.
comptime _BUF_VERBATIM_COPY_SENTINEL: Int64 = -2


# Per-buffer parallel-dispatch threshold. Below this many non-empty
# buffers, the LocalDispatcher run_with_state dispatch + per-shard
# error/length bookkeeping costs more than the serial codec call wall.
# Small dict batches have just 2-3 buffers (validity + offsets + data),
# so they stay serial.
comptime _MIN_PARALLEL_COMPRESS_BUFS: Int = 4

# Cap on worker shards for per-buffer parallel compress. Above ~16
# workers the partition + dispatch overhead exceeds the per-task compute
# win for typical per-buffer task sizes. The dispatcher's own worker
# count caps this further (run_with_state picks min(worker_count, n)).
comptime _MAX_COMPRESS_WORKERS: Int = 16


# Per-buffer parallel-dispatch threshold for the READ side. Mirrors the
# write-side `_MIN_PARALLEL_COMPRESS_BUFS`. Below this many non-empty
# buffers, the dispatcher overhead + per-shard error bookkeeping exceeds
# the per-buffer codec FFI wall, so the helper falls back to a serial
# decompress loop (small dict batches have 2-3 buffers).
comptime _MIN_PARALLEL_DECOMPRESS_BUFS: Int = 4

# Cap on worker shards for per-buffer parallel decompress. Same shape + rationale as
# `_MAX_COMPRESS_WORKERS` — a per-buffer decompress is comparable work
# to a per-buffer compress on the same fixture (codec FFI dominates),
# so the dispatch / partition overhead crosses the break-even point at
# the same worker count.
comptime _MAX_DECOMPRESS_WORKERS: Int = 16


def _align_to_8(n: Int) -> Int:
    """8-byte alignment helper (matches the encoder's body-cursor
    alignment discipline in `ipc_encoder_dispatch`)."""
    return ((n + 7) // 8) * 8


def _align_to_8_zero_pad[
    B: AlignedBufferTrait,
](
    mut body: B, cursor: Int
) raises -> Int:
    """Round `cursor` up to the next 8-byte boundary AND write 0-7 pad
    zero bytes at positions `[cursor, aligned_cursor)`.

    The compressed-write paths do not blanket-zero `raw_body` /
    `compressed_body`, so padding bytes are written explicitly here. Identical
    semantics to `_align_to_8_zero_pad` in `ipc_encoder_dispatch` (the
    one used by the uncompressed encoder arms reachable via
    `encode_column`); duplicated here to keep the compressed-only
    `_align_to_8(compressed_cursor)` call sites self-contained. Both versions are O(0..7) per call —
    libc-memcpy-free, just inline byte writes via `write_u8_at`.
    """
    var aligned = ((cursor + 7) // 8) * 8
    var pad = aligned - cursor
    if pad > 0:
        for i in range(pad):
            body.write_u8_at(cursor + i, UInt8(0))
    return aligned


def _slice_body_bytes[
    B: AlignedBufferTrait,
](
    body: B, offset: Int, length: Int
) raises -> List[UInt8]:
    """Slice `length` bytes from `body` starting at `offset` into a
    fresh `List[UInt8]`. Used by the per-buffer compress pre-pass.

    The codec FFI methods (`Lz4Frame.compress` / `Zstd.compress`) take
    `Span[UInt8, _]`; the simplest portable approach is to copy into a
    List and pass `.as_span()`. Codec compress is O(input); the extra
    copy is O(input) too — acceptable for correctness; a `Span` taken
    directly off the body buffer would remove it.
    """
    var out = List[UInt8](capacity=max(length, 1))
    for i in range(length):
        out.append(body.read_u8_at(offset + i))
    return out^


# `decompress_record_batch_frame` PASS 4 and
# `decompress_dictionary_batch_frame` PASS 4 pass a zero-copy `Span` of
# the frame bytes directly to `C.decompress_into(...)`, which writes its
# output straight into the output frame's body region. No intermediate List.


# =============================================================================
# Per-buffer compress driver — LocalDispatcher.run_with_state dispatch
# =============================================================================
#
# Dispatched through `LocalDispatcher.run_with_state`, not stdlib
# `parallelize`: main code never uses parallelize directly.
#
# Shared between `encode_record_batch_message_compressed` and
# `encode_dictionary_batch_message_from_string_column_compressed`. Runs the
# per-buffer compress in parallel via the EngineContext-owned
# LocalDispatcher (passed through as `dispatcher_ptr`), then walks the
# per-buffer results in serial order to build the final on-wire compressed
# body + buffer descriptors.
#
# Two-buffer layout:
#   - `worker_body`: staging buffer sized to `sum(compress_bound[i]) + pads`.
#     Each worker writes its compressed payload into a disjoint per-buffer
#     slot here.
#   - `compressed_body` (returned): final compact buffer with `[i64 prefix,
#     compressed_or_raw_payload, ...8B-align]` blocks per Arrow IPC §6.
#
# State + Task shape (canonical _dedup_count_parallel_impl template):
#   * `_CompressBuffersState[C, raw_o, work_o]` OWNS the per-dispatch
#     scratch (`bounds`, `worker_offsets`, `raw_offs`, `raw_lens`,
#     `actuals`, `errors`); BORROWS the caller-owned `raw_body` +
#     `worker_body` via typed-origin pointers (NOT MutExternalOrigin).
#   * `_CompressBuffersTask[C, raw_o, work_o]` carries a single Int32
#     discriminator (n_workers) and bitcasts to the concrete State at the
#     top of `execute`; the trampoline monomorphizes correctly per
#     (State, Task) at the run_with_state[State, T] call site.
#   * Three entry points per the canonical split:
#     - `_compress_buffers_into[C]` — serial fallback (no dispatcher)
#     - `_compress_buffers_into_with_dispatcher[C, disp_o]` — parallel
#     - `_compress_buffers_into_impl[C, has_pool, disp_o]` — shared body
#
# DISPATCH-BOUNDARY SAFETY:
#   * Disjointness: task `tid` writes to `worker_body` only at
#     `state.worker_offsets[i] + 8` for the buffer indices `i` that
#     map to its task (stride: `i % n_workers == tid`); every buffer
#     maps to exactly one task. Errors / actual-lengths are stored at
#     unique slots `errors[i]` / `actuals[i]`.
#   * Liveness: `run_with_state` is a synchronous wake-word barrier;
#     every captured value lives through the dispatch frame (State is
#     borrowed-mut by the driver; caller-owned `raw_body` / `worker_body`
#     outlive the helper by stack discipline). State is moved into
#     run_with_state atomically; no UAF window.
#   * No-realloc: `actuals`, `errors`, `worker_body` all pre-sized
#     before dispatch; workers ONLY mutate via index assignment.
#   * No-reload: State is a Movable struct with inline-stored List +
#     typed UnsafePointer fields; every worker access hits the bitcast'd
#     `sp[].field` form.
#
# Threshold gate: below `_MIN_PARALLEL_COMPRESS_BUFS` non-empty buffers,
# OR when no dispatcher is available, the helper falls back to a serial
# per-buffer compress (dispatch overhead would exceed the gain). Dict-
# batch paths typically take the serial branch.
# =============================================================================


struct _CompressBuffersState[
    C: ArrowIpcCompression,
    raw_o: ImmOrigin,
](KeepAlive, Movable):
    """State for per-buffer parallel compress dispatch.

    OWNS the per-dispatch scratch lists + counters + the worker staging
    body; BORROWS the caller-owned `raw_body` read-only via typed-origin
    pointer. ZERO wildcard fields.

    `worker_body` is moved INTO State at dispatch time + extracted via
    `Optional.take()` at dispatch return — this avoids the `mut state`
    ↔ caller-held mut borrow aliasing the compiler would flag and stays
    inside the sink design: the
    `Optional.take()` pattern is the canonical replacement for the
    banned `UnsafePointer(to=state.field).take_pointee()` partial-move.
    """
    # Borrowed read-only input — pinned to caller via `raw_o`.
    # SAFETY: Internal typed pointer — never exposed to public API.
    # The pointee type is SharedAlignedBuffer[HeapRegion]. The
    # `raw_o: ImmutOrigin` parameter is CONCRETE (not wildcard), so this
    # is the canonical typed-origin-borrow pattern (no stale-pointer hazard):
    # a SAB[HeapRegion] borrow through
    # a typed-origin UnsafePointer field. ref-field would be cleaner but
    # Mojo struct fields cannot hold `ref` directly; typed-origin
    # UnsafePointer is the canonical encoding.
    var raw_body_ptr: UnsafePointer[SharedAlignedBuffer[HeapRegion], Self.raw_o]
    # OWNED staging body — workers write to disjoint slots; driver
    # extracts via `take()` post-dispatch for PASS 4 compact.
    var worker_body: Optional[OwnedAlignedBuffer]
    # OWNED per-buffer scratch (also via Optional.take pattern so the
    # State drop sees None placeholders rather than moved-out bits).
    var bounds: Optional[List[Int]]
    var worker_offsets: Optional[List[Int]]
    var raw_offs: Optional[List[Int]]
    var raw_lens: Optional[List[Int]]
    var actuals: Optional[List[Int]]
    var errors: Optional[List[Optional[String]]]
    # POD scalars.
    var n_bufs: Int
    var n_workers: Int

    def __init__(
        out self,
        raw_body_ptr: UnsafePointer[SharedAlignedBuffer[HeapRegion], Self.raw_o],
        var worker_body: OwnedAlignedBuffer,
        var bounds: List[Int],
        var worker_offsets: List[Int],
        var raw_offs: List[Int],
        var raw_lens: List[Int],
        var actuals: List[Int],
        var errors: List[Optional[String]],
        n_bufs: Int,
        n_workers: Int,
    ):
        self.raw_body_ptr = raw_body_ptr
        self.worker_body = Optional[OwnedAlignedBuffer](worker_body^)
        self.bounds = Optional[List[Int]](bounds^)
        self.worker_offsets = Optional[List[Int]](worker_offsets^)
        self.raw_offs = Optional[List[Int]](raw_offs^)
        self.raw_lens = Optional[List[Int]](raw_lens^)
        self.actuals = Optional[List[Int]](actuals^)
        self.errors = Optional[List[Optional[String]]](errors^)
        self.n_bufs = n_bufs
        self.n_workers = n_workers


@fieldwise_init
struct _CompressBuffersTask[
    C: ArrowIpcCompression,
    raw_o: ImmOrigin,
](Segment):
    """POD Segment for _CompressBuffersState dispatch — n_workers
    tasks, stride-partitioned across [0, n_bufs)."""
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the dispatch helper parameterizes run_with_state over
        # (_CompressBuffersState[C, raw_o], _CompressBuffersTask[C, raw_o]);
        # the bitcast resolves to the concrete state at the call site.
        var sp = UnsafePointer(to=state).bitcast[
            _CompressBuffersState[Self.C, Self.raw_o]
        ]()
        var tid = Int(task_id)
        var n_workers = sp[].n_workers
        var n_bufs_local = sp[].n_bufs
        # Stride partition: worker `tid` handles every buffer `i` with
        # `i % n_workers == tid`. Same shape as the prior parallelize
        # path; preserves balanced load across skewed buffer sizes.
        var i = tid
        while i < n_bufs_local:
            var raw_len = sp[].raw_lens.value()[i]
            if raw_len == 0:
                i = i + n_workers
                continue
            var bound = sp[].bounds.value()[i]
            var wo = sp[].worker_offsets.value()[i]
            var ro = sp[].raw_offs.value()[i]
            try:
                # FFI-BOUNDARY: codec writes into the staging body at
                # the disjoint region owned by buffer `i`.
                # Migrated from BANNED `_codec_ptr_mut()` onto
                # origin-tied `view_mut()._unsafe_ptr()`. View hoisted
                # to a local so the typed origin (bound to
                # `sp[].worker_body.value()`) lives across the FFI call.
                # `compress_into[o: Origin[mut=True]]` is mut-poly so
                # the typed origin flows through cleanly. The mut
                # borrow on `worker_body` (one field of `sp[]`) does
                # not conflict with the `sp[].actuals.value()[i] = got`
                # assignment to a different field below — Mojo's
                # borrow checker tracks field-level granularity.
                var wb_view = sp[].worker_body.value().view_mut()
                var got = Self.C.compress_into(
                    sp[].raw_body_ptr[].view_range_ro(ro, raw_len).into_span(),
                    wb_view._unsafe_ptr() + wo + 8,
                    bound,
                )
                sp[].actuals.value()[i] = got
            except e:
                sp[].errors.value()[i] = Optional[String](String(e))
            i = i + n_workers


def _compress_buffers_into[C: ArrowIpcCompression](
    raw_body: SharedAlignedBuffer[HeapRegion],
    raw_buffers: List[BufferDescriptor],
    mut compressed_body: OwnedAlignedBuffer,
    mut compressed_buffers: List[BufferDescriptor],
) raises -> Int:
    """Serial-fallback wrapper for `_compress_buffers_into_with_dispatcher[C]`.

    Serial entry point: callers without an EngineContext-owned
    dispatcher (e.g. test fixtures) use it.
    """
    # Class C: serial-fallback substitutes D=NoDispatch with a CONCRETE
    # origin (origin_of a stack-local NoDispatch), NOT a MutAnyOrigin
    # wildcard. The Optional is always None (has_pool=False prunes the
    # dispatch branch), so the pointer/origin is a never-deref'd phantom —
    # but it is now a concrete, ASAP-trackable origin.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return _compress_buffers_into_impl[
        C, NoDispatch, has_pool=False, disp_o=nd_o,
    ](
        raw_body,
        raw_buffers,
        compressed_body,
        compressed_buffers,
        Optional[Pointer[NoDispatch, nd_o]](None),
        CancellationToken.never(),
    )


def _compress_buffers_into_with_dispatcher[
    C: ArrowIpcCompression,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    raw_body: SharedAlignedBuffer[HeapRegion],
    raw_buffers: List[BufferDescriptor],
    mut compressed_body: OwnedAlignedBuffer,
    mut compressed_buffers: List[BufferDescriptor],
    dispatcher_ptr: Pointer[D, disp_o],
    var cancel_token: CancellationToken,
) raises -> Int:
    """Dispatcher-aware variant — typed-origin dispatcher required.

    Threads `dispatcher_ptr` + `cancel_token` from the calling
    EngineContext (`ctx.dispatcher()` + `ctx.cancel_token()`) down to
    `D.run_with_state` for the parallel per-buffer compress. `D` is the
    monomorphized concrete dispatcher (e.g. `LocalDispatcher[NoopSink]`);
    the call devirtualizes per instantiation.
    """
    return _compress_buffers_into_impl[
        C, D, has_pool=True, disp_o=disp_o,
    ](
        raw_body,
        raw_buffers,
        compressed_body,
        compressed_buffers,
        Optional[Pointer[D, disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _compress_buffers_into_impl[
    C: ArrowIpcCompression,
    D: ParallelDispatch,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    raw_body: SharedAlignedBuffer[HeapRegion],
    raw_buffers: List[BufferDescriptor],
    mut compressed_body: OwnedAlignedBuffer,
    mut compressed_buffers: List[BufferDescriptor],
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
) raises -> Int:
    """Per-buffer compress driver. PASS 1 sizes the worker staging area
    + final compact body; PASS 2 runs `C.compress_into` in parallel (or
    serial when no dispatcher / below threshold) for every non-empty
    buffer; PASS 3 drains worker errors; PASS 4 walks the per-buffer
    actual lengths in order to build the final compact `compressed_body`
    + `compressed_buffers` descriptors.

    Returns the final compressed body length (cursor position after the
    last buffer's alignment pad).

    Comptime `has_pool` flag prunes the parallel/serial branch —
    no wildcard origin reaches the dispatch in either path (canonical
    _dedup_count_parallel_impl pattern).

    Caller contract:
      - `raw_body` is the uncompressed body from `encode_column`; lives
        for the duration of this call.
      - `compressed_body` is pre-allocated to *some* size but may be
        grown here if the worst-case staging + compact body together
        exceed its capacity. Caller MUST ignore any value of
        `compressed_body.length` before this call; it is set after.
      - `compressed_buffers` is appended to (one entry per buffer in
        `raw_buffers`).
    """
    var n_bufs = len(raw_buffers)
    if n_bufs == 0:
        _ = cancel_token^
        return 0

    # === PASS 1: compute per-buffer bounds, worker offsets, count non-empty ===
    var bounds = List[Int](capacity=n_bufs)
    var worker_offsets = List[Int](capacity=n_bufs)
    var raw_offs = List[Int](capacity=n_bufs)
    var raw_lens = List[Int](capacity=n_bufs)
    var worker_cursor: Int = 0
    var non_empty: Int = 0
    for i in range(n_bufs):
        ref buf = raw_buffers[i]
        var raw_len = Int(buf.length)
        var raw_off = Int(buf.offset)
        raw_offs.append(raw_off)
        raw_lens.append(raw_len)
        if raw_len == 0:
            bounds.append(0)
            worker_offsets.append(worker_cursor)
            continue
        var bound = C.compress_bound(raw_len)
        bounds.append(bound)
        worker_offsets.append(worker_cursor)
        worker_cursor = worker_cursor + 8 + bound
        worker_cursor = ((worker_cursor + 7) // 8) * 8
        non_empty = non_empty + 1

    var worker_body_size = worker_cursor + 8  # tail pad headroom
    var worker_body = OwnedAlignedBuffer(max(worker_body_size, 1))

    # === PASS 2: parallel or serial compress ===
    var actuals = List[Int]()
    var errors = List[Optional[String]]()
    for _ in range(n_bufs):
        actuals.append(0)
        errors.append(Optional[String](None))

    # Take dispatch path only when (a) threshold met, (b) dispatcher
    # available; otherwise fall back to a serial per-buffer loop.
    var go_parallel: Bool = (
        has_pool and non_empty >= _MIN_PARALLEL_COMPRESS_BUFS
    )

    comptime if has_pool:
        if go_parallel:
            # Resolve effective worker count: cap at min(n_bufs, cores, max).
            var n_workers = num_physical_cores()
            if n_workers > _MAX_COMPRESS_WORKERS:
                n_workers = _MAX_COMPRESS_WORKERS
            if n_workers > n_bufs:
                n_workers = n_bufs
            if n_workers < 1:
                n_workers = 1

            # DISPATCH-BOUNDARY: build State + Task; dispatch via
            # LocalDispatcher.run_with_state. typed origins; no
            # MutExternalOrigin wildcards. `raw_body` is borrowed read-
            # only via typed origin pointer; `worker_body` is MOVED INTO
            # State and back out (avoids the `mut state` ↔ caller-held
            # mut alias the compiler would flag).
            comptime r_o = origin_of(raw_body)
            var raw_body_ptr = UnsafePointer(to=raw_body).unsafe_origin_cast[
                r_o
            ]()
            var state = _CompressBuffersState[C, r_o](
                raw_body_ptr,
                worker_body^,
                bounds^,
                worker_offsets^,
                raw_offs^,
                raw_lens^,
                actuals^,
                errors^,
                n_bufs,
                n_workers,
            )
            var task = _CompressBuffersTask[C, r_o](Int32(0))
            var disp = dispatcher_ptr.value()
            _ = disp[].run_with_state[
                _CompressBuffersState[C, r_o],
                _CompressBuffersTask[C, r_o],
            ](state, task^, n_workers, cancel_token^, site_id=_SITE_FORMAT_WRITE)

            # Reclaim the buffers + lists from State via Optional.take
            # (canonical replacement for partial-move-via-UnsafePointer).
            # State drops at scope exit
            # with all Optional fields in None state.
            worker_body = state.worker_body.take()
            bounds = state.bounds.take()
            worker_offsets = state.worker_offsets.take()
            raw_offs = state.raw_offs.take()
            raw_lens = state.raw_lens.take()
            actuals = state.actuals.take()
            errors = state.errors.take()
            _ = state^
        else:
            # has_pool but below threshold (e.g. dict batch with 2-3
            # buffers) — serial loop on the same lists.
            # Migrated from BANNED `_codec_ptr_mut()` onto
            # origin-tied `view_mut()._unsafe_ptr()`. View scoped to
            # each loop iteration so the mut borrow on `worker_body`
            # is RELEASED before PASS 3 / PASS 4 below (which take
            # read-only `view_range_ro` borrows). Same disjoint-slot
            # write semantics as the OLD `_codec_ptr_mut() + wo + 8`.
            _ = cancel_token^
            for i in range(n_bufs):
                var raw_len = raw_lens[i]
                if raw_len == 0:
                    continue
                var bound = bounds[i]
                var wo = worker_offsets[i]
                try:
                    var wb_view_below = worker_body.view_mut()
                    var got = C.compress_into(
                        raw_body.view_range_ro(raw_offs[i], raw_len).into_span(),
                        wb_view_below._unsafe_ptr() + wo + 8,
                        bound,
                    )
                    actuals[i] = got
                except e:
                    errors[i] = Optional[String](String(e))
    else:
        # has_pool=False: caller did not thread a dispatcher. Serial-
        # only branch; matches the pre-DISPATCHER-PLUMB serial-fallback
        # arm exactly.
        # Migrated from BANNED `_codec_ptr_mut()` (same shape
        # as the has_pool-below-threshold arm above; per-iteration view).
        _ = cancel_token^
        for i in range(n_bufs):
            var raw_len = raw_lens[i]
            if raw_len == 0:
                continue
            var bound = bounds[i]
            var wo = worker_offsets[i]
            try:
                var wb_view_serial = worker_body.view_mut()
                var got = C.compress_into(
                    raw_body.view_range_ro(raw_offs[i], raw_len).into_span(),
                    wb_view_serial._unsafe_ptr() + wo + 8,
                    bound,
                )
                actuals[i] = got
            except e:
                errors[i] = Optional[String](String(e))

    # === PASS 3: drain worker errors ===
    for i in range(n_bufs):
        if errors[i]:
            var msg = errors[i].value().copy()
            raise Error(
                String("_compress_buffers_into: buffer ")
                + String(i)
                + String(" (raw_len=")
                + String(raw_lens[i])
                + String(", bound=")
                + String(bounds[i])
                + String("): ")
                + msg
            )

    # === PASS 4: serial compact + descriptor build ===
    var compact_upper: Int = 0
    for i in range(n_bufs):
        var per_buf_max = max(actuals[i], raw_lens[i])
        compact_upper = compact_upper + 8 + per_buf_max + 7
    compact_upper = compact_upper + 8
    if compressed_body.capacity() < compact_upper:
        compressed_body = OwnedAlignedBuffer(compact_upper)

    var compressed_cursor: Int = 0
    for i in range(n_bufs):
        var raw_len = raw_lens[i]
        var raw_off = raw_offs[i]

        if raw_len == 0:
            compressed_buffers.append(
                BufferDescriptor(
                    offset=Int64(compressed_cursor),
                    length=Int64(0),
                )
            )
            continue

        var block_off = compressed_cursor
        var actual = actuals[i]

        if actual >= raw_len:
            compressed_body.write_i64_le_at(
                block_off, UNCOMPRESSED_LEN_SENTINEL
            )
            if raw_len > 0:
                compressed_body.copy_from_view_at(
                    block_off + 8,
                    raw_body.view_range_ro(raw_off, raw_len),
                )
            compressed_cursor = block_off + 8 + raw_len
            compressed_buffers.append(
                BufferDescriptor(
                    offset=Int64(block_off),
                    length=Int64(8 + raw_len),
                )
            )
        else:
            compressed_body.write_i64_le_at(block_off, Int64(raw_len))
            if actual > 0:
                var wo = worker_offsets[i]
                compressed_body.copy_from_view_at(
                    block_off + 8,
                    worker_body.view_range_ro(wo + 8, actual),
                )
            compressed_cursor = block_off + 8 + actual
            compressed_buffers.append(
                BufferDescriptor(
                    offset=Int64(block_off),
                    length=Int64(8 + actual),
                )
            )

        compressed_cursor = _align_to_8_zero_pad(
            compressed_body, compressed_cursor
        )

    _ = worker_body^
    _ = actuals^
    _ = errors^
    _ = bounds^
    _ = worker_offsets^
    _ = raw_offs^
    _ = raw_lens^
    return compressed_cursor


# =============================================================================
# Per-buffer decompress driver — LocalDispatcher.run_with_state dispatch
# =============================================================================
#
# Mirror of the write-side
# `_compress_buffers_into[C]` helper for the READ path. Dispatched
# through `LocalDispatcher.run_with_state` for the same reason.
#
# Shared between `decompress_record_batch_frame` and
# `decompress_dictionary_batch_frame`. Runs the per-buffer
# `C.decompress_into(...)` calls in parallel across the dispatcher's
# worker pool; each worker writes to a DISJOINT destination region in the
# output frame's pre-allocated body slab.
#
# The READ side is simpler than the WRITE side because the actual
# uncompressed size of every buffer is KNOWN BEFORE the codec runs
# (it's the i64 prefix on each compressed block). So the destination
# layout is fixed (`new_buffers[i].offset` is the byte offset in the
# output body; `u_lens[i]` is the size). There is no two-buffer
# staging step + no serial compact step — workers write straight into
# their final destination.
#
# State + Task shape: same template as the write-side compress helper.
#   * `_DecompressBuffersState[C, f_o, out_o]` OWNS the per-dispatch
#     scratch (`rb_buffers`, `new_buffers`, `u_lens`, `errors`,
#     `err_prefix`); BORROWS the caller-owned `frame` + `out` via
#     typed-origin pointers (NOT MutExternalOrigin).
#   * `_DecompressBuffersTask[C, f_o, out_o]` carries a single Int32
#     discriminator; bitcasts to the concrete State at the top of
#     `execute`.
#
# DISPATCH-BOUNDARY SAFETY:
#   * Disjointness: task `tid` writes to `out` only at
#     `body_start + new_buffers[i].offset` for every buffer index `i`
#     in `{i : i % n_workers == tid}`. `new_buffers[i].offset` is the
#     cumulative-aligned offset computed in PASS 1; no two indices
#     have the same offset, and the writes are bounded by
#     `u_lens[i]` (also computed in PASS 1).
#   * Liveness: `run_with_state` is a synchronous wake-word barrier;
#     every captured value lives through the dispatch frame. State is
#     borrowed-mut by the driver; caller-owned `frame` / `out` outlive
#     the helper by stack discipline.
#   * No-realloc: `errors` pre-sized to `n_bufs` BEFORE dispatch; `out`
#     pre-sized by the caller. No worker performs allocation.
#   * No-reload: State is Movable with inline-stored List + typed
#     UnsafePointer fields.
#
# Threshold gate: below `_MIN_PARALLEL_DECOMPRESS_BUFS` non-empty
# buffers, OR when no dispatcher is available, the helper falls back
# to a serial per-buffer decompress.
# =============================================================================


struct _DecompressBuffersState[
    C: ArrowIpcCompression,
    f_o: ImmOrigin,
](KeepAlive, Movable):
    """State for per-buffer parallel decompress dispatch.

    OWNS the per-dispatch scratch + error message + the output frame
    being assembled; BORROWS the caller-owned input frame read-only via
    typed-origin pointer. ZERO wildcard fields.

    `out` (+ owned Lists) moved INTO State at dispatch time + extracted
    via `Optional.take()` at dispatch return — the canonical pattern.
    """
    # Borrowed read-only input frame — pinned to caller via `f_o`.
    # SAFETY: Internal typed pointer — never exposed to public API.
    var frame_ptr: UnsafePointer[SharedAlignedBuffer[HeapRegion], Self.f_o]
    # OWNED output frame — workers write to disjoint slots; driver
    # extracts via `take()` post-dispatch for the alignment-pad
    # post-pass + `out.length = total_size`.
    var out: Optional[SharedAlignedBuffer[HeapRegion]]
    # OWNED per-buffer scratch (Optional.take pattern).
    var rb_buffers: Optional[List[BufferDescriptor]]
    var new_buffers: Optional[List[BufferDescriptor]]
    var u_lens: Optional[List[Int]]
    var errors: Optional[List[Optional[String]]]
    var err_prefix: String
    # POD scalars.
    var body_pos: Int
    var body_start: Int
    var n_bufs: Int
    var n_workers: Int

    def __init__(
        out self,
        frame_ptr: UnsafePointer[SharedAlignedBuffer[HeapRegion], Self.f_o],
        var out: SharedAlignedBuffer[HeapRegion],
        var rb_buffers: List[BufferDescriptor],
        var new_buffers: List[BufferDescriptor],
        var u_lens: List[Int],
        var errors: List[Optional[String]],
        var err_prefix: String,
        body_pos: Int,
        body_start: Int,
        n_bufs: Int,
        n_workers: Int,
    ):
        self.frame_ptr = frame_ptr
        self.out = Optional[SharedAlignedBuffer[HeapRegion]](out^)
        self.rb_buffers = Optional[List[BufferDescriptor]](rb_buffers^)
        self.new_buffers = Optional[List[BufferDescriptor]](new_buffers^)
        self.u_lens = Optional[List[Int]](u_lens^)
        self.errors = Optional[List[Optional[String]]](errors^)
        self.err_prefix = err_prefix^
        self.body_pos = body_pos
        self.body_start = body_start
        self.n_bufs = n_bufs
        self.n_workers = n_workers


@fieldwise_init
struct _DecompressBuffersTask[
    C: ArrowIpcCompression,
    f_o: ImmOrigin,
](Segment):
    """POD Segment for _DecompressBuffersState dispatch — n_workers
    tasks, stride-partitioned across [0, n_bufs)."""
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the dispatch helper parameterizes run_with_state over
        # (_DecompressBuffersState[C, f_o], _DecompressBuffersTask[C, f_o]);
        # the bitcast resolves to the concrete state at the call site.
        var sp = UnsafePointer(to=state).bitcast[
            _DecompressBuffersState[Self.C, Self.f_o]
        ]()
        var tid = Int(task_id)
        var n_workers = sp[].n_workers
        var n_bufs_local = sp[].n_bufs
        var body_pos_local = sp[].body_pos
        var body_start_local = sp[].body_start
        # Stride partition: worker `tid` handles every buffer `i` with
        # `i % n_workers == tid`. Same shape as the prior parallelize
        # path.
        var i = tid
        while i < n_bufs_local:
            var c_len = Int(sp[].rb_buffers.value()[i].length)
            if c_len == 0:
                i = i + n_workers
                continue
            var c_off = Int(sp[].rb_buffers.value()[i].offset)
            var compressed_payload_len = c_len - 8
            var dst_off = (
                body_start_local + Int(sp[].new_buffers.value()[i].offset)
            )
            try:
                var src_u_len = Int(
                    sp[].frame_ptr[].read_i64_le_at(
                        body_pos_local + c_off
                    )
                )
                if src_u_len == Int(UNCOMPRESSED_LEN_SENTINEL):
                    if compressed_payload_len > 0:
                        sp[].out.value().copy_from_view_at(
                            dst_off,
                            sp[].frame_ptr[].view_range_ro(
                                body_pos_local + c_off + 8,
                                compressed_payload_len,
                            ),
                        )
                else:
                    var u_len_i = sp[].u_lens.value()[i]
                    # FFI-BOUNDARY: codec writes directly into out's
                    # body region at the disjoint slot owned by buffer
                    # `i`.
                    # Migrated from BANNED `_codec_ptr_mut()`
                    # onto origin-tied `view_mut()._unsafe_ptr()`. View
                    # bound to `sp[].out.value()`; the typed origin
                    # flows through `decompress_into[o: Origin[mut=True]]`
                    # cleanly. The mut borrow on the `out` field of
                    # `sp[]` does not conflict with the read on
                    # `sp[].u_lens.value()[i]` or `sp[].frame_ptr[]` or
                    # the write to `sp[].errors.value()[i]` (different
                    # fields, field-level borrow granularity).
                    var out_view = sp[].out.value().view_mut()
                    var got = Self.C.decompress_into(
                        sp[].frame_ptr[].view_range_ro(
                            body_pos_local + c_off + 8,
                            compressed_payload_len,
                        ).into_span(),
                        out_view._unsafe_ptr() + dst_off,
                        u_len_i,
                    )
                    if got != u_len_i:
                        sp[].errors.value()[i] = Optional[String](
                            String("decompressed size ")
                            + String(got)
                            + String(" does not match prefix ")
                            + String(u_len_i)
                        )
            except e:
                sp[].errors.value()[i] = Optional[String](String(e))
            i = i + n_workers


def _decompress_buffers_into[C: ArrowIpcCompression](
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
    rb_buffers: List[BufferDescriptor],
    new_buffers: List[BufferDescriptor],
    u_lens: List[Int],
    var out: SharedAlignedBuffer[HeapRegion],
    body_start: Int,
    err_prefix: String,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Serial-fallback wrapper for `_decompress_buffers_into_with_dispatcher[C]`.

    Serial entry point: callers without an EngineContext-owned
    dispatcher (e.g. test fixtures) use it.

    Takes `out` by `var` (consumes) and returns it back — the parallel
    branch moves `out` into a per-dispatch State to satisfy the
    `mut state` ↔ caller-mut-borrow alias check; the serial branch
    just writes into it. Either way, ownership round-trips through the
    return value.
    """
    # Class C: serial-fallback substitutes D=NoDispatch with a CONCRETE
    # origin, NOT a MutAnyOrigin wildcard. None Optional; has_pool=False
    # prunes the dispatch branch.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return _decompress_buffers_into_impl[
        C, NoDispatch, has_pool=False, disp_o=nd_o,
    ](
        frame,
        body_pos,
        rb_buffers,
        new_buffers,
        u_lens,
        out^,
        body_start,
        err_prefix,
        Optional[Pointer[NoDispatch, nd_o]](None),
        CancellationToken.never(),
    )


def _decompress_buffers_into_with_dispatcher[
    C: ArrowIpcCompression,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
    rb_buffers: List[BufferDescriptor],
    new_buffers: List[BufferDescriptor],
    u_lens: List[Int],
    var out: SharedAlignedBuffer[HeapRegion],
    body_start: Int,
    err_prefix: String,
    dispatcher_ptr: Pointer[D, disp_o],
    var cancel_token: CancellationToken,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Dispatcher-aware variant — typed-origin dispatcher required.

    Threads `dispatcher_ptr` + `cancel_token` from the calling
    EngineContext (`ctx.dispatcher()` + `ctx.cancel_token()`) down to
    `D.run_with_state` for the parallel per-buffer decompress. Consumes
    `out` and returns it back.
    """
    return _decompress_buffers_into_impl[
        C, D, has_pool=True, disp_o=disp_o,
    ](
        frame,
        body_pos,
        rb_buffers,
        new_buffers,
        u_lens,
        out^,
        body_start,
        err_prefix,
        Optional[Pointer[D, disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _decompress_buffers_into_impl[
    C: ArrowIpcCompression,
    D: ParallelDispatch,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
    rb_buffers: List[BufferDescriptor],
    new_buffers: List[BufferDescriptor],
    u_lens: List[Int],
    var out: SharedAlignedBuffer[HeapRegion],
    body_start: Int,
    err_prefix: String,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Per-buffer decompress driver. Same per-buffer behaviour as the
    prior helper; dispatch happens via LocalDispatcher.run_with_state
    when `has_pool=True` AND the threshold is met.

    Comptime `has_pool` flag prunes the parallel/serial branch.
    """
    var n_bufs = len(rb_buffers)
    if n_bufs == 0:
        _ = cancel_token^
        return out^

    # Count non-empty buffers for threshold-gate decision.
    var non_empty: Int = 0
    for i in range(n_bufs):
        if Int(rb_buffers[i].length) > 0:
            non_empty = non_empty + 1

    # Per-task error slot, pre-sized BEFORE dispatch.
    var errors = List[Optional[String]]()
    for _ in range(n_bufs):
        errors.append(Optional[String](None))

    # `new_buffers` is also needed for the post-pass alignment-pad walk.
    # Make a local copy up-front so we can both pass it into State
    # (parallel branch) AND keep a driver-local copy for the post-pass.
    var new_buffers_local = List[BufferDescriptor](capacity=n_bufs)
    for i in range(n_bufs):
        new_buffers_local.append(new_buffers[i].copy())

    var go_parallel: Bool = (
        has_pool and non_empty >= _MIN_PARALLEL_DECOMPRESS_BUFS
    )

    comptime if has_pool:
        if go_parallel:
            # Resolve effective worker count: cap at min(non_empty, cores, max).
            var n_workers = num_physical_cores()
            if n_workers > _MAX_DECOMPRESS_WORKERS:
                n_workers = _MAX_DECOMPRESS_WORKERS
            if n_workers > non_empty:
                n_workers = non_empty
            if n_workers < 1:
                n_workers = 1

            # DISPATCH-BOUNDARY: build State + Task; dispatch via
            # LocalDispatcher.run_with_state. typed origins; no
            # MutExternalOrigin wildcards. `out` moves INTO State and
            # back OUT after dispatch.
            comptime fo = origin_of(frame)
            var frame_ptr_typed = UnsafePointer(
                to=frame
            ).unsafe_origin_cast[fo]()
            # State-side copies of the descriptor lists. BufferDescriptor
            # isn't ImplicitlyCopyable; use explicit `.copy()`.
            var rb_buffers_copy = List[BufferDescriptor](capacity=n_bufs)
            for i in range(n_bufs):
                rb_buffers_copy.append(rb_buffers[i].copy())
            var new_buffers_copy = List[BufferDescriptor](capacity=n_bufs)
            for i in range(n_bufs):
                new_buffers_copy.append(new_buffers[i].copy())
            var u_lens_copy = List[Int](capacity=n_bufs)
            for i in range(n_bufs):
                u_lens_copy.append(u_lens[i])
            var state = _DecompressBuffersState[C, fo](
                frame_ptr_typed,
                out^,
                rb_buffers_copy^,
                new_buffers_copy^,
                u_lens_copy^,
                errors^,
                err_prefix,
                body_pos,
                body_start,
                n_bufs,
                n_workers,
            )
            var task = _DecompressBuffersTask[C, fo](Int32(0))
            var disp = dispatcher_ptr.value()
            _ = disp[].run_with_state[
                _DecompressBuffersState[C, fo],
                _DecompressBuffersTask[C, fo],
            ](state, task^, n_workers, cancel_token^, site_id=_SITE_FORMAT_READ)
            # Reclaim `out` + errors via Optional.take post-dispatch
            # for the alignment-pad post-pass + error drain.
            out = state.out.take()
            errors = state.errors.take()
            _ = state^
        else:
            # has_pool but below threshold (e.g. dict batch with 2-3
            # buffers) — serial loop.
            # Migrated from BANNED `out._codec_ptr_mut()` onto
            # `view_mut()._unsafe_ptr()`; view scoped per loop iteration
            # so the mut borrow on `out` releases before the post-loop
            # `out.write_u8_at` zero-pad pass below.
            _ = cancel_token^
            for i in range(n_bufs):
                var c_len = Int(rb_buffers[i].length)
                var c_off = Int(rb_buffers[i].offset)
                if c_len == 0:
                    continue
                var compressed_payload_len = c_len - 8
                var dst_off = body_start + Int(new_buffers[i].offset)
                var src_u_len = Int(frame.read_i64_le_at(body_pos + c_off))
                if src_u_len == Int(UNCOMPRESSED_LEN_SENTINEL):
                    if compressed_payload_len > 0:
                        out.copy_from_view_at(
                            dst_off,
                            frame.view_range_ro(
                                body_pos + c_off + 8, compressed_payload_len
                            ),
                        )
                else:
                    var u_len_i = u_lens[i]
                    var out_view = out.view_mut()
                    var got = C.decompress_into(
                        frame.view_range_ro(
                            body_pos + c_off + 8, compressed_payload_len
                        ).into_span(),
                        out_view._unsafe_ptr() + dst_off,
                        u_len_i,
                    )
                    if got != u_len_i:
                        raise Error(
                            err_prefix + String(": buffer ") + String(i)
                            + String(" decompressed size ") + String(got)
                            + String(" does not match prefix ")
                            + String(u_len_i)
                        )
    else:
        # has_pool=False: caller did not thread a dispatcher. Serial-
        # only branch.
        # Migrated from BANNED `out._codec_ptr_mut()` (same
        # shape as the has_pool-below-threshold arm above).
        _ = cancel_token^
        for i in range(n_bufs):
            var c_len = Int(rb_buffers[i].length)
            var c_off = Int(rb_buffers[i].offset)
            if c_len == 0:
                continue
            var compressed_payload_len = c_len - 8
            var dst_off = body_start + Int(new_buffers[i].offset)
            var src_u_len = Int(frame.read_i64_le_at(body_pos + c_off))
            if src_u_len == Int(UNCOMPRESSED_LEN_SENTINEL):
                if compressed_payload_len > 0:
                    out.copy_from_view_at(
                        dst_off,
                        frame.view_range_ro(
                            body_pos + c_off + 8, compressed_payload_len
                        ),
                    )
            else:
                var u_len_i = u_lens[i]
                var out_view = out.view_mut()
                var got = C.decompress_into(
                    frame.view_range_ro(
                        body_pos + c_off + 8, compressed_payload_len
                    ).into_span(),
                    out_view._unsafe_ptr() + dst_off,
                    u_len_i,
                )
                if got != u_len_i:
                    raise Error(
                        err_prefix + String(": buffer ") + String(i)
                        + String(" decompressed size ") + String(got)
                        + String(" does not match prefix ")
                        + String(u_len_i)
                    )

    # Drain worker errors (and the serial-branch size-mismatch
    # records). Re-raise the first failure in buffer order.
    for i in range(n_bufs):
        if errors[i]:
            var msg = errors[i].value().copy()
            raise Error(
                err_prefix + String(": buffer ") + String(i)
                + String(": ") + msg
            )

    # Serial post-pass: write the 0-7 byte alignment-gap zero-pad
    # between every successive buffer. The gap is at
    # `[tail, aligned_tail)` in output coords where `tail = body_start
    # + new_buffers_local[i].offset + new_buffers_local[i].length`.
    for i in range(n_bufs):
        ref nb = new_buffers_local[i]
        var dst_off = body_start + Int(nb.offset)
        var tail = dst_off + Int(nb.length)
        var aligned_tail = body_start + (
            ((Int(nb.offset) + Int(nb.length) + 7) // 8) * 8
        )
        var pad_n = aligned_tail - tail
        if pad_n > 0:
            for k in range(pad_n):
                out.write_u8_at(tail + k, UInt8(0))

    _ = errors^
    _ = new_buffers_local^
    return out^


def encode_record_batch_message_compressed[C: ArrowIpcCompression](
    var columns: Slab[Column[HeapRegion]],
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Serial-fallback wrapper for
    `encode_record_batch_message_compressed_with_dispatcher[C]`.

    Serial entry point: callers without an EngineContext-owned
    dispatcher (e.g. test fixtures, direct invocations from non-engine
    code) use it.

    Encodes N columns as one Arrow IPC RecordBatch message frame WITH
    per-buffer body compression per `C: ArrowIpcCompression`.

    The on-wire layout differs from `encode_record_batch_message`:
      - The RecordBatch flatbuf table carries a BodyCompression child
        table (field 3) with `codec = C.ARROW_IPC_CODEC_ID`.
      - The body bytes are rewritten as a sequence of
            <i64 uncompressed_length_LE> <compressed_bytes...>
        blocks (one per Buffer). When compressed >= uncompressed, the
        block emits `uncompressed_length = -1` (sentinel) followed by
        the raw uncompressed bytes for that buffer.
      - `BufferDescriptor.{offset, length}` are rewritten to reference
        the COMPRESSED body layout (offset = start of the 8-byte length
        prefix; length = 8 + compressed_size [or 8 + raw_size if
        sentinel'd]).

    Caller contract:
      - `C` MUST be `Lz4Frame` or `Zstd[*]`. Routing `Uncompressed`
        through this path would emit `BodyCompression{codec:-1}` which
        is NOT valid Arrow IPC. The FileSink dispatch routes
        `Uncompressed` through the unbranded
        `encode_record_batch_message` instead.

    Mirrors `encode_record_batch_message` shape.
    """
    # Class C: serial-fallback substitutes D=NoDispatch with a CONCRETE
    # origin, NOT MutAnyOrigin.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return _encode_record_batch_message_compressed_impl[
        C, NoDispatch, has_pool=False, disp_o=nd_o
    ](
        columns^,
        Optional[Pointer[NoDispatch, nd_o]](None),
        CancellationToken.never(),
    )


def encode_record_batch_message_compressed_with_dispatcher[
    C: ArrowIpcCompression,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    var columns: Slab[Column[HeapRegion]],
    dispatcher_ptr: Pointer[D, disp_o],
    var cancel_token: CancellationToken,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Dispatcher-aware variant — threads the EngineContext-owned
    dispatcher `D` into the per-buffer compress helper. ARROW-IPC-
    """
    return _encode_record_batch_message_compressed_impl[
        C, D, has_pool=True, disp_o=disp_o
    ](
        columns^,
        Optional[Pointer[D, disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _encode_record_batch_message_compressed_impl[
    C: ArrowIpcCompression,
    D: ParallelDispatch,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    var columns: Slab[Column[HeapRegion]],
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Shared body for the two encode_record_batch_message_compressed
    entry points. `has_pool` comptime branches on whether to dispatch
    the per-buffer compress via `D.run_with_state` or fall back to
    serial."""
    if len(columns) == 0:
        _ = cancel_token^
        raise Error("encode_record_batch_message_compressed: zero columns")

    var row_count = columns[0]._length
    for i in range(1, len(columns)):
        if columns[i]._length != row_count:
            _ = cancel_token^
            raise Error(
                "encode_record_batch_message_compressed: row count"
                " mismatch at column " + String(i)
            )

    # Step 1: Build the UNCOMPRESSED (body, buffers, nodes) via the
    # existing per-DType encoder.
    # The same rationale carries — encode_column writes every byte
    # it claims.
    var raw_sink = AlignedBufferBodySink(_estimate_body_size(columns))
    var raw_cursor: Int = 0
    var raw_buffers = List[BufferDescriptor]()
    var nodes = List[FieldNode]()

    for i in range(len(columns)):
        raw_cursor = encode_column[AlignedBufferBodySink](
            columns[i], raw_sink, raw_cursor, raw_buffers, nodes
        )
    var raw_body = raw_sink.finalize()

    # Step 2: Per-buffer compression pre-pass.
    # When `has_pool`, dispatch the per-buffer compress
    # via LocalDispatcher.run_with_state; else serial loop. Both branches
    # land in `_compress_buffers_into_impl[C, has_pool, disp_o]`.
    var n_bufs = len(raw_buffers)
    var compressed_body = OwnedAlignedBuffer(raw_cursor + 64 * n_bufs + 1024)
    var compressed_buffers = List[BufferDescriptor]()
    var compressed_cursor = _compress_buffers_into_impl[
        C, D, has_pool=has_pool, disp_o=disp_o
    ](
        raw_body,
        raw_buffers,
        compressed_body,
        compressed_buffers,
        dispatcher_ptr,
        cancel_token^,
    )

    # Pad the compressed body to an
    # 8-byte boundary per Arrow IPC spec §4. pyarrow asserts the body
    # is 8-aligned and rejects unpadded inputs.
    var comp_body_pad = (8 - (compressed_cursor % 8)) % 8
    if comp_body_pad > 0:
        for _ in range(comp_body_pad):
            compressed_body.write_u8_at(compressed_cursor, UInt8(0))
            compressed_cursor += 1
    compressed_body.set_length(Int64(compressed_cursor))

    _ = raw_body^

    # Step 3: Emit the FB metadata (BodyCompression child table + new
    # RecordBatch table) + outer IPC frame.
    var w = FlatbufWriter(2048)
    var bc_pos = write_body_compression(w, C.ARROW_IPC_CODEC_ID)
    var rb_pos = write_record_batch_compressed(
        w, Int64(row_count), nodes, compressed_buffers, bc_pos
    )
    var msg_pos = write_message(
        w,
        Int16(Int(METADATA_VERSION_V5)),
        MESSAGE_HEADER_RECORD_BATCH,
        rb_pos,
        Int64(compressed_cursor),
    )
    var fb_payload = w^.finalize(msg_pos)

    var w2 = FlatbufWriter(64)
    var body_span = compressed_body.view_range_ro(
        0, compressed_cursor
    ).into_span()
    var frame = write_ipc_message(w2, fb_payload^, body_span, True)
    _ = compressed_body^
    return frame^


def decompress_record_batch_frame[C: ArrowIpcCompression](
    var frame: SharedAlignedBuffer[HeapRegion],
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Serial-fallback wrapper for
    `decompress_record_batch_frame_with_dispatcher[C]`.

    Serial entry point: test fixtures + direct invocations that have no
    EngineContext use it; the per-buffer decompress runs serially.
    """
    # Class C: serial-fallback substitutes D=NoDispatch with a CONCRETE
    # origin, NOT MutAnyOrigin.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return _decompress_record_batch_frame_impl[
        C, NoDispatch, has_pool=False, disp_o=nd_o,
    ](
        frame^,
        Optional[Pointer[NoDispatch, nd_o]](None),
        CancellationToken.never(),
    )


def decompress_record_batch_frame_with_dispatcher[
    C: ArrowIpcCompression,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    var frame: SharedAlignedBuffer[HeapRegion],
    dispatcher_ptr: Pointer[D, disp_o],
    var cancel_token: CancellationToken,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Dispatcher-aware variant — threads the EngineContext-owned
    dispatcher `D` into the per-buffer decompress helper for the hot
    RB-decompress path. """
    return _decompress_record_batch_frame_impl[
        C, D, has_pool=True, disp_o=disp_o,
    ](
        frame^,
        Optional[Pointer[D, disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _decompress_record_batch_frame_impl[
    C: ArrowIpcCompression,
    D: ParallelDispatch,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    var frame: SharedAlignedBuffer[HeapRegion],
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Decompress a per-buffer-compressed RecordBatch frame into a
    fresh frame whose buffers reference the UNCOMPRESSED body layout.

    The output frame's metadata FB is re-emitted with:
      - BodyCompression flatbuf field STRIPPED (uncompressed body
        downstream).
      - Each `BufferDescriptor` rewritten to point at the (offset,
        length) of the decompressed bytes in the fresh body.
      - FieldNode, length and variadicBufferCounts fields preserved
        verbatim.

    The output is consumable by `decode_record_batch_message` (and
    `decode_record_batch_message_nested`) WITHOUT any further changes
    to the per-column builders — they see UNCOMPRESSED buffer offsets
    + lengths, identical to a writer that emitted `Uncompressed`.


    The inner per-buffer decompress dispatches via
    `_decompress_buffers_into_impl[C, has_pool, disp_o]`.

    Caller contract:
      - Pre-condition: the frame's RecordBatch table MUST carry a
        BodyCompression child with `codec = C.ARROW_IPC_CODEC_ID`.
        Caller (the strict-mode decoder dispatch) is responsible for
        peeking the codec first via
        `peek_record_batch_codec_from_frame` and matching against the
        declared `C`.
    """
    # 1. Parse the outer IPC framing.
    var f = parse_ipc_message(frame)

    # 2. Extract the FB metadata + read the RecordBatch table.
    # scalar
    # byte-copy loop → libc memcpy via `copy_from_view_at`. Mojo's
    # autovec does NOT lift the scalar loop.
    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(max(f.metadata_size, 1))
    if f.metadata_size > 0:
        fb.copy_from_view_at(
            0, frame.view_range_ro(f.metadata_pos, f.metadata_size)
        )
    fb.set_length(f.metadata_size)

    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    if msg.header_tag != MESSAGE_HEADER_RECORD_BATCH:
        raise Error(
            "decompress_record_batch_frame: expected RECORD_BATCH header"
            " (tag " + String(Int(MESSAGE_HEADER_RECORD_BATCH))
            + "), got " + String(Int(msg.header_tag))
        )
    var rb = read_record_batch(reader, msg.header_table_pos)

    #
    # IN-PLACE BODY CONSTRUCTION — eliminates the dominant `write_ipc_message`
    # body memcpy that is the largest non-FFI cost on the LZ4 / ZSTD read
    # arms otherwise (a large fraction of LZ4 wall).
    #
    # Previous shape (1 alloc + 2 memcpy per body byte):
    #   1) allocate MmapAlignedBuffer[64] new_body
    #   2) for each buffer: codec.decompress() returns List[UInt8],
    #      copy_from_bytes_list_at into new_body
    #   3) write_ipc_message(fb, new_body.view) allocates output
    #      frame and copy_from_span_at the ENTIRE new_body into
    #      the output frame body slot — the dominant cost (5-20 MB
    #      per RB on lineitem; full-body memcpy on top of the
    #      per-buffer memcpy already done in step 2).
    #
    # New shape (1 alloc + 1 memcpy per body byte):
    #   PASS 1) walk compressed-body buffer descriptors, read each
    #           i64 uncompressed_length prefix (cheap — 8 bytes per
    #           buffer); compute new_buffers + total body size.
    #   PASS 2) build FB metadata once (FlatbufWriter for new
    #           RecordBatch + Message with new_buffers).
    #   PASS 3) allocate output frame sized for
    #           [continuation + size + fb_aligned + body_size]; write
    #           header + FB into output.
    #   PASS 4) for each buffer codec.decompress() +
    #           copy_from_bytes_list_at DIRECTLY into output frame's
    #           body region (one memcpy per buffer, into the FINAL
    #           destination).
    #
    # No FB re-encode is "eliminated" per se — the FB metadata still
    # gets re-emitted because the BufferDescriptors must reference the
    # uncompressed offsets — but the dominant whole-body memcpy is gone.
    # This is a self-contained substrate change in this function +
    # decompress_dictionary_batch_frame; no consumer signatures change
    # (the output remains an SharedAlignedBuffer[HeapRegion] frame, identical wire
    # shape; only the assembly order differs).
    var n_bufs = len(rb.buffers)

    # === PASS 1: scan compressed body, compute new offsets + body size ===
    var new_buffers = List[BufferDescriptor]()
    var new_cursor: Int = 0
    var u_lens = List[Int](capacity=n_bufs)
    for i in range(n_bufs):
        ref buf = rb.buffers[i]
        var c_len = Int(buf.length)
        var c_off = Int(buf.offset)
        if c_len == 0:
            new_buffers.append(
                BufferDescriptor(
                    offset=Int64(new_cursor),
                    length=Int64(0),
                )
            )
            u_lens.append(0)
            continue
        if c_len < 8:
            raise Error(
                "decompress_record_batch_frame: buffer " + String(i)
                + " has length " + String(c_len)
                + " < 8 (the i64 uncompressed_length prefix);"
                + " malformed compressed body"
            )
        var u_len = Int(frame.read_i64_le_at(f.body_pos + c_off))
        var compressed_payload_len = c_len - 8
        var uncompressed_len: Int
        if u_len == Int(UNCOMPRESSED_LEN_SENTINEL):
            uncompressed_len = compressed_payload_len
        else:
            if u_len < 0:
                raise Error(
                    "decompress_record_batch_frame: buffer " + String(i)
                    + " has negative uncompressed_length "
                    + String(u_len)
                    + " (only -1 sentinel is valid;"
                    + " malformed compressed body)"
                )
            uncompressed_len = u_len
        new_buffers.append(
            BufferDescriptor(
                offset=Int64(new_cursor),
                length=Int64(uncompressed_len),
            )
        )
        u_lens.append(uncompressed_len)
        new_cursor += uncompressed_len
        # 8-byte align between buffers (matches the writer's discipline +
        # parses identically downstream).
        new_cursor = ((new_cursor + 7) // 8) * 8

    var body_size = new_cursor

    # === PASS 2: build FB metadata once with finalized new_buffers ===
    var w = FlatbufWriter(2048)
    var rb_pos = write_record_batch(
        w, Int64(rb.length), rb.nodes, new_buffers, rb.variadic_buffer_counts
    )
    var msg_pos = write_message(
        w,
        Int16(Int(METADATA_VERSION_V5)),
        MESSAGE_HEADER_RECORD_BATCH,
        rb_pos,
        Int64(body_size),
    )
    var fb_payload = w^.finalize(msg_pos)
    var fb_size = fb_payload.len()
    var fb_aligned = ((fb_size + 7) // 8) * 8
    var pad_after_fb = fb_aligned - fb_size

    # === PASS 3: allocate output frame in one shot + assemble header ===
    var continuation_size = 4
    var header_size = continuation_size + 4 + fb_aligned
    var total_size = header_size + body_size
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(total_size, 1))
    var pos = 0
    out.write_u32_le_at(pos, IPC_CONTINUATION_MARKER)
    pos += 4
    out.write_u32_le_at(pos, UInt32(fb_aligned))
    pos += 4
    if fb_size > 0:
        out.copy_from_aligned_buffer_at(pos, fb_payload, 0, fb_size)
    pos += fb_size
    if pad_after_fb > 0:
        for i in range(pad_after_fb):
            out.write_u8_at(pos + i, UInt8(0))
        pos += pad_after_fb
    _ = fb_payload^

    # === PASS 4: decompress each buffer DIRECTLY into output's body region ===
    # the per-buffer
    # decompress + alignment-pad lives in the shared helper
    # `_decompress_buffers_into_impl[C, has_pool, disp_o]`. When
    # `has_pool=True`, dispatches via LocalDispatcher.run_with_state;
    # else serial loop. Helper consumes + returns `out` so it can move
    # the buffer into State for the dispatch window.
    var body_start = header_size
    var out_back = _decompress_buffers_into_impl[
        C, D, has_pool=has_pool, disp_o=disp_o
    ](
        frame,
        f.body_pos,
        rb.buffers,
        new_buffers,
        u_lens,
        out^,
        body_start,
        String("decompress_record_batch_frame"),
        dispatcher_ptr,
        cancel_token^,
    )

    out_back.set_length(total_size)

    _ = frame^
    _ = u_lens^
    return out_back^


# =============================================================================
# File-level coalesced multi-RB decompress
# =============================================================================
#
# Eliminates the per-RB fork-join
# barrier that dominated the post-DISPATCHER-PLUMB read path. Before this
# slot, the file-level driver (arrow_file_reader.mojo) walked N RBs and
# called `decompress_record_batch_frame_with_dispatcher` once per RB; each
# call did its own `LocalDispatcher.run_with_state` dispatch + wake-word
# barrier. On lineitem (49 RBs) the dispatcher fired 49 fork-join barriers
# and the `_dispatch_semaphore_wait_slow` samples were the dominant
# remaining non-FFI cost in the LZ4 read profile.
#
#
# Once RecordBatches are coalesced, the dominant cost is the codec's
# create/free-decompression-context calls (`LZ4F_createDecompressionContext`
# / `LZ4F_freeDecompressionContext`, mirror for Zstd). On lineitem that's
# ~1617 create/free pairs per file decode. arrow-cpp keeps ONE dctx per
# thread and calls `LZ4F_resetDecompressionContext` between buffers; this
# slot mirrors that pattern.
#
# Combined fix shape:
#   1. **RB-batch task partition**: stride dimension switches from per-(rb,
#      buf) global pairs to per-RB. Each worker processes its assigned RBs
#      sequentially; all buffers within an RB go to the same worker. This
#      is load-bearing for (2) — without it, the dctx is held briefly per
#      task and we'd lose locality.
#   2. **Per-worker dctx cache**: `_CoalescedState` carries a
#      `Slab[_CodecDctxHandle[C]]` pre-sized to n_workers. Each worker
#      lazily creates ONE dctx on first buffer in its first RB, then
#      calls `_CodecDctxHandle.decompress_into_with_dctx` which internally
#      issues `LZ4F_resetDecompressionContext` (or `ZSTD_DCtx_reset`)
#      between buffers. Total dctx create/free pairs: n_workers (~10) per
#      file, not ~1617. Slab's destructor cascades to each handle's
#      destructor, which calls `C.free_dctx`.
#
# Driver split (3 passes, mirrors the per-RB helper):
#   PASS A (serial, per-file): for each RB → parse outer framing → build
#     new_buffers + u_lens via the i64 prefix walk → re-emit FB metadata
#     → allocate output frame + write header + FB. Append context to
#     `Slab[_RbDecompressContext]`.
#   PASS B (parallel, single dispatch): one
#     `LocalDispatcher.run_with_state[_CoalescedState[C], _CoalescedTask[C]]`
#     call dispatches n_workers tasks; each task strides through the RB
#     list (`ri += n_workers`); workers process all buffers of each
#     assigned RB sequentially, reusing their per-worker dctx via reset.
#   PASS C (serial, per-RB): alignment-pad post-pass + set output frame
#     length. Caller then walks the decompressed frames + builds Columns.
#
# State + Task shape:
#   * `_RbDecompressContext` — per-RB struct holding (frame, out, rb_buffers,
#     new_buffers, u_lens, body_pos, body_start). Movable, not Copyable.
#     Held as `Slab[_RbDecompressContext]` inside the State.
#   * `_CoalescedState[C]` — OWNS the per-dispatch scratch (contexts,
#     dctxs, errors). BORROWS nothing across module boundaries; the
#     input + output frames live INSIDE the Slab held in State (so the
#     State is the sole owner during the dispatch window).
#   * `_CoalescedTask[C]` — POD Segment; per-worker stride dimension is
#     per-RB (`ri = tid; ri += n_workers`).
#
# DISPATCH-BOUNDARY SAFETY:
#   * Disjointness: task `tid` handles every RB index `ri` with
#     `ri % n_workers == tid`. Within an RB, the worker walks each buffer
#     and writes to `contexts[ri].out` at `body_start + new_buffers[bi].offset`
#     — disjoint regions. Workers touching different `ri` slots write to
#     different `out` AlignedBuffers in different Slab slots. The dctx
#     handle at `dctxs[tid]` is the SOLE property of worker `tid`; no
#     cross-thread access.
#   * Liveness: `run_with_state` is a synchronous wake-word barrier; every
#     captured value (contexts, dctxs, errors) lives through the dispatch
#     frame. Slabs are moved INTO state (Optional.take pattern) and back
#     OUT after dispatch.
#   * No-realloc: all Slabs / Lists pre-sized BEFORE dispatch; output
#     frames pre-allocated in PASS A; dctx slab pre-filled with empty
#     handles. No worker performs allocation (the codec FFI's dctx-reset
#     path is alloc-free; dctx is reused).
#   * No-reload: State is Movable; the task bitcast'd `sp[].field` access
#     pattern matches the existing per-buffer helper.
#
# Threshold gate: the file-level driver gates this helper behind
# `total_non_empty_bufs >= _MIN_PARALLEL_DECOMPRESS_BUFS`. With ~1617
# buffers on lineitem this is comfortably above the gate; small files
# with 1-2 RBs and few buffers/RB fall back to the per-RB serial loop.
# =============================================================================


@fieldwise_init
struct _RbDecompressContext(Movable, Deinitable):
    """Per-RB context for the coalesced decompress dispatch.

    The driver builds one of these per RB in PASS A and appends to a
    `Slab[_RbDecompressContext]` held in `_CoalescedState`. After PASS B
    completes, the driver walks the slab to (a) run PASS C alignment-pad
    + length set, then (b) take each `out` MmapAlignedBuffer for the column
    build phase.

    `frame` + `out` are wrapped in `Optional` so that PASS C's
    `_finalize_rb_context` can `.take()` the MmapAlignedBuffer out for the
    return value without partial-moving a field of a struct that has
    other heap-owning fields (the canonical replacement for
    `UnsafePointer(to=struct.field).take_pointee()`).
    """
    var frame: Optional[SharedAlignedBuffer[HeapRegion]]
    var out: Optional[SharedAlignedBuffer[HeapRegion]]
    var rb_buffers: List[BufferDescriptor]
    var new_buffers: List[BufferDescriptor]
    var u_lens: List[Int]
    var body_pos: Int
    var body_start: Int
    var total_size: Int


struct _CoalescedState[C: ArrowIpcCompression](KeepAlive, Movable):
    """State for the file-level coalesced decompress dispatch.

    Holds the per-RB contexts slab + per-worker dctx slab + per-RB error
    slots. Moved IN and OUT of LocalDispatcher.run_with_state via the
    Optional.take pattern.

    Per-worker dctx cache:
    `dctxs` is pre-sized to `n_workers`; slot `tid` is the sole property
    of worker `tid`. Each handle is empty (null sentinel) at construction
    and lazily acquires a dctx on first call to
    `decompress_into_with_dctx`. The slab's destructor cascades to each
    handle's destructor, which calls `C.free_dctx` at most once.

    ZERO wildcard origin fields. All references to
    input frames live INSIDE the slab — the State is the sole owner
    during the dispatch window. The raw dctx pointers are encapsulated
    in `_CodecDctxHandle[C]` (FFI carve-out — see compression_codecs.mojo);
    they never appear in this struct's fields directly.
    """
    var contexts: Optional[Slab[_RbDecompressContext]]
    var dctxs: Optional[Slab[_CodecDctxHandle[Self.C]]]
    # Per-RB first-error-wins. Pre-sized to n_rbs. Note: errors is
    # `Slab[Optional[String]]` not `List[...]` because we want
    # take()-able element extraction post-dispatch without partial-move
    # warnings. `Slab[Optional[String]]` is free of stale-pointer hazards (Optional[String]
    # is Movable + Deinitable).
    var errors: Optional[List[Optional[String]]]
    var n_rbs: Int
    var n_workers: Int

    def __init__(
        out self,
        var contexts: Slab[_RbDecompressContext],
        var dctxs: Slab[_CodecDctxHandle[Self.C]],
        var errors: List[Optional[String]],
        n_rbs: Int,
        n_workers: Int,
    ):
        self.contexts = Optional[Slab[_RbDecompressContext]](contexts^)
        self.dctxs = Optional[Slab[_CodecDctxHandle[Self.C]]](dctxs^)
        self.errors = Optional[List[Optional[String]]](errors^)
        self.n_rbs = n_rbs
        self.n_workers = n_workers


@fieldwise_init
struct _CoalescedTask[C: ArrowIpcCompression](Segment):
    """POD Segment for coalesced decompress dispatch. n_workers tasks
    stride-partition the per-RB axis (each worker gets ~n_rbs/n_workers
    RBs and processes all buffers within those RBs sequentially —
    keeping the per-worker dctx hot).

    When the
    file has exactly ONE RecordBatch (n_rbs == 1), the per-RB stride
    collapses to one worker (all others find `ri = tid >= n_rbs` and
    exit immediately). To keep parallelism for the single-batch shape,
    the stride axis switches from RB to BUFFER when n_rbs == 1:
    each worker takes a stride slice of the buffer axis within the
    single RB. The single shared dctx-per-worker stays at dctxs[tid]
    and is reset between buffers as before.
    """
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: helper parameterizes run_with_state over
        # (_CoalescedState[C], _CoalescedTask[C]); bitcast resolves to
        # the concrete state.
        var sp = UnsafePointer(to=state).bitcast[
            _CoalescedState[Self.C]
        ]()
        var tid = Int(task_id)
        var n_workers = sp[].n_workers
        var n_rbs_local = sp[].n_rbs

        # Single-RB special case: stride by BUFFER axis within the
        # single RB. The default per-RB stride would leave n_workers-1
        # workers idle (each finds ri = tid >= n_rbs and exits the
        # while loop), parked in `_dispatch_semaphore_wait_slow` while one
        # thread single-handedly runs LZ4F_decompress.
        if n_rbs_local == 1:
            ref ctx = sp[].contexts.value()[0]
            var n_bufs = len(ctx.rb_buffers)
            try:
                ref handle = sp[].dctxs.value()[tid]
                var bi = tid
                while bi < n_bufs:
                    var c_len = Int(ctx.rb_buffers[bi].length)
                    if c_len == 0:
                        bi = bi + n_workers
                        continue
                    var c_off = Int(ctx.rb_buffers[bi].offset)
                    var dst_off = ctx.body_start + Int(
                        ctx.new_buffers[bi].offset
                    )
                    # codec-absent
                    # RB; memcpy verbatim with no i64 prefix.
                    if (
                        ctx.u_lens[bi] == Int(_BUF_VERBATIM_COPY_SENTINEL)
                    ):
                        ctx.out.value().copy_from_view_at(
                            dst_off,
                            ctx.frame.value().view_range_ro(
                                ctx.body_pos + c_off, c_len,
                            ),
                        )
                        bi = bi + n_workers
                        continue
                    var compressed_payload_len = c_len - 8
                    var src_u_len = Int(
                        ctx.frame.value().read_i64_le_at(
                            ctx.body_pos + c_off
                        )
                    )
                    if src_u_len == Int(UNCOMPRESSED_LEN_SENTINEL):
                        if compressed_payload_len > 0:
                            ctx.out.value().copy_from_view_at(
                                dst_off,
                                ctx.frame.value().view_range_ro(
                                    ctx.body_pos + c_off + 8,
                                    compressed_payload_len,
                                ),
                            )
                    else:
                        var u_len_i = ctx.u_lens[bi]
                        # FFI-BOUNDARY: codec writes directly into the
                        # output frame at the disjoint slot owned by
                        # buffer `bi`. Per-buffer stride means worker
                        # `tid` only ever touches `bi` values in the
                        # set { tid, tid + n_workers, tid + 2*n_workers, ... };
                        # different workers' bi sets are disjoint by
                        # construction.
                        # Migrated from BANNED
                        # `ctx.out.value()._codec_ptr_mut()` onto
                        # origin-tied `view_mut()._unsafe_ptr()`. View
                        # bound to `ctx.out.value()`; the typed mut
                        # origin flows through `decompress_into_with_dctx[o]`.
                        var out_view = ctx.out.value().view_mut()
                        var got = handle.decompress_into_with_dctx(
                            ctx.frame.value().view_range_ro(
                                ctx.body_pos + c_off + 8,
                                compressed_payload_len,
                            ).into_span(),
                            out_view._unsafe_ptr() + dst_off,
                            u_len_i,
                        )
                        if got != u_len_i:
                            sp[].errors.value()[0] = Optional[String](
                                String("rb=0")
                                + String(" buf=") + String(bi)
                                + String(": decompressed size ")
                                + String(got)
                                + String(" does not match prefix ")
                                + String(u_len_i)
                            )
                            return
                    bi = bi + n_workers
            except e:
                if not sp[].errors.value()[0]:
                    sp[].errors.value()[0] = Optional[String](
                        String("rb=0: ") + String(e)
                    )
            return

        # Stride-partition across the RB axis. Each worker processes
        # all buffers within its assigned RBs sequentially, reusing
        # its per-worker dctx (held at dctxs[tid]) via reset between
        # buffers. tid IS the canonical worker index in the dispatcher
        # — n_workers `_TaskEntry`s are enqueued, one per worker shard;
        # `task_id` is the shard index.
        var ri = tid
        while ri < n_rbs_local:
            # Per-RB error: skip if a prior worker (or this one on a
            # prior RB) recorded an error for THIS rb. First-error-
            # wins; the driver re-raises the lowest-index error after
            # dispatch.
            if sp[].errors.value()[ri]:
                ri = ri + n_workers
                continue
            # Bind a mutable ref to the RB context. Slab's __getitem__
            # returns a ref into the slab's internal storage; touching
            # different ri values from different workers is safe per
            # Slab disjointness.
            ref ctx = sp[].contexts.value()[ri]
            var n_bufs = len(ctx.rb_buffers)
            try:
                # Process all buffers within this RB sequentially.
                # The dctx at dctxs[tid] is reused via reset between
                # calls (zero ctor/dtor overhead per buffer).
                ref handle = sp[].dctxs.value()[tid]
                for bi in range(n_bufs):
                    var c_len = Int(ctx.rb_buffers[bi].length)
                    if c_len == 0:
                        continue
                    var c_off = Int(ctx.rb_buffers[bi].offset)
                    var dst_off = ctx.body_start + Int(
                        ctx.new_buffers[bi].offset
                    )
                    # codec-absent
                    # RB; memcpy verbatim with no i64 prefix.
                    if (
                        ctx.u_lens[bi] == Int(_BUF_VERBATIM_COPY_SENTINEL)
                    ):
                        ctx.out.value().copy_from_view_at(
                            dst_off,
                            ctx.frame.value().view_range_ro(
                                ctx.body_pos + c_off, c_len,
                            ),
                        )
                        continue
                    var compressed_payload_len = c_len - 8
                    var src_u_len = Int(
                        ctx.frame.value().read_i64_le_at(
                            ctx.body_pos + c_off
                        )
                    )
                    if src_u_len == Int(UNCOMPRESSED_LEN_SENTINEL):
                        if compressed_payload_len > 0:
                            ctx.out.value().copy_from_view_at(
                                dst_off,
                                ctx.frame.value().view_range_ro(
                                    ctx.body_pos + c_off + 8,
                                    compressed_payload_len,
                                ),
                            )
                    else:
                        var u_len_i = ctx.u_lens[bi]
                        # FFI-BOUNDARY: codec writes directly into the
                        # per-RB output frame's body region at the
                        # disjoint slot owned by buffer `bi`. The dctx
                        # is reused across buffers (LZ4F_reset / ZSTD
                        # DCtx_reset internally).
                        # Migrated from BANNED
                        # `ctx.out.value()._codec_ptr_mut()` onto
                        # origin-tied `view_mut()._unsafe_ptr()`.
                        var out_view = ctx.out.value().view_mut()
                        var got = handle.decompress_into_with_dctx(
                            ctx.frame.value().view_range_ro(
                                ctx.body_pos + c_off + 8,
                                compressed_payload_len,
                            ).into_span(),
                            out_view._unsafe_ptr() + dst_off,
                            u_len_i,
                        )
                        if got != u_len_i:
                            sp[].errors.value()[ri] = Optional[String](
                                String("rb=") + String(ri)
                                + String(" buf=") + String(bi)
                                + String(": decompressed size ")
                                + String(got)
                                + String(" does not match prefix ")
                                + String(u_len_i)
                            )
                            break
            except e:
                if not sp[].errors.value()[ri]:
                    sp[].errors.value()[ri] = Optional[String](
                        String("rb=") + String(ri)
                        + String(": ") + String(e)
                    )
            ri = ri + n_workers


def _build_rb_context[C: ArrowIpcCompression](
    var frame: SharedAlignedBuffer[HeapRegion],
) raises -> _RbDecompressContext:
    """PASS A per-RB build. Parses outer framing + FB metadata, computes
    new_buffers + u_lens via the i64 prefix walk, re-emits FB metadata,
    allocates output frame + writes header + FB. Returns the context the
    coalesced dispatch + post-pass operate on.

    Mirrors PASSes 1-3 of `_decompress_record_batch_frame_impl` (lines
    1376-1527) exactly; the only difference is the helper returns the
    context for batched dispatch instead of immediately calling
    `_decompress_buffers_into_impl`.
    """
    var f = parse_ipc_message(frame)

    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(max(f.metadata_size, 1))
    if f.metadata_size > 0:
        fb.copy_from_view_at(
            0, frame.view_range_ro(f.metadata_pos, f.metadata_size)
        )
    fb.set_length(f.metadata_size)

    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    if msg.header_tag != MESSAGE_HEADER_RECORD_BATCH:
        raise Error(
            "_build_rb_context: expected RECORD_BATCH header (tag "
            + String(Int(MESSAGE_HEADER_RECORD_BATCH))
            + "), got "
            + String(Int(msg.header_tag))
        )
    var rb = read_record_batch(reader, msg.header_table_pos)

    # When the RB's FB carries no
    # BodyCompression child (codec == -1), the body is laid down verbatim
    # WITHOUT the per-buffer i64 uncompressed_length prefix. Reading the
    # first 8 bytes as an i64 in that case grabs actual data bytes, which
    # can land at a multi-GB positive value and `MmapAlignedBuffer(total_size)`
    # alloc fails. Detect codec==-1 and bypass the prefix
    # walk: each buffer's c_len IS the uncompressed length; the decompress
    # driver's serial+coalesced branches must memcpy verbatim. Signal this
    # via the `_BUF_VERBATIM_COPY_SENTINEL` u_lens entry — the serial /
    # coalesced decompress dispatch branches treat that sentinel as
    # "memcpy this buffer's c_len bytes WITHOUT consuming an i64 prefix".
    var codec_absent: Bool = (Int(rb.body_compression_codec) == -1)
    var n_bufs = len(rb.buffers)
    var new_buffers = List[BufferDescriptor]()
    var new_cursor: Int = 0
    var u_lens = List[Int](capacity=n_bufs)
    for i in range(n_bufs):
        ref buf = rb.buffers[i]
        var c_len = Int(buf.length)
        var c_off = Int(buf.offset)
        if c_len == 0:
            new_buffers.append(
                BufferDescriptor(
                    offset=Int64(new_cursor), length=Int64(0)
                )
            )
            u_lens.append(0)
            continue
        if codec_absent:
            # No i64 prefix; body data starts at offset c_off, length c_len.
            new_buffers.append(
                BufferDescriptor(
                    offset=Int64(new_cursor),
                    length=Int64(c_len),
                )
            )
            u_lens.append(Int(_BUF_VERBATIM_COPY_SENTINEL))
            new_cursor += c_len
            new_cursor = ((new_cursor + 7) // 8) * 8
            continue
        if c_len < 8:
            raise Error(
                "_build_rb_context: buffer " + String(i)
                + " has length " + String(c_len)
                + " < 8 (the i64 uncompressed_length prefix);"
                + " malformed compressed body"
            )
        var u_len = Int(frame.read_i64_le_at(f.body_pos + c_off))
        var compressed_payload_len = c_len - 8
        var uncompressed_len: Int
        if u_len == Int(UNCOMPRESSED_LEN_SENTINEL):
            uncompressed_len = compressed_payload_len
        else:
            if u_len < 0:
                raise Error(
                    "_build_rb_context: buffer " + String(i)
                    + " has negative uncompressed_length "
                    + String(u_len)
                    + " (only -1 sentinel is valid)"
                )
            uncompressed_len = u_len
        new_buffers.append(
            BufferDescriptor(
                offset=Int64(new_cursor),
                length=Int64(uncompressed_len),
            )
        )
        u_lens.append(uncompressed_len)
        new_cursor += uncompressed_len
        new_cursor = ((new_cursor + 7) // 8) * 8

    var body_size = new_cursor

    var w = FlatbufWriter(2048)
    var rb_pos = write_record_batch(
        w, Int64(rb.length), rb.nodes, new_buffers, rb.variadic_buffer_counts
    )
    var msg_pos = write_message(
        w,
        Int16(Int(METADATA_VERSION_V5)),
        MESSAGE_HEADER_RECORD_BATCH,
        rb_pos,
        Int64(body_size),
    )
    var fb_payload = w^.finalize(msg_pos)
    var fb_size = fb_payload.len()
    var fb_aligned = ((fb_size + 7) // 8) * 8
    var pad_after_fb = fb_aligned - fb_size

    var continuation_size = 4
    var header_size = continuation_size + 4 + fb_aligned
    var total_size = header_size + body_size
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(total_size, 1))
    var pos = 0
    out.write_u32_le_at(pos, IPC_CONTINUATION_MARKER)
    pos += 4
    out.write_u32_le_at(pos, UInt32(fb_aligned))
    pos += 4
    if fb_size > 0:
        out.copy_from_aligned_buffer_at(pos, fb_payload, 0, fb_size)
    pos += fb_size
    if pad_after_fb > 0:
        for i in range(pad_after_fb):
            out.write_u8_at(pos + i, UInt8(0))
        pos += pad_after_fb
    _ = fb_payload^

    # Capture rb.buffers as a list copy (BufferDescriptor isn't
    # ImplicitlyCopyable; use explicit .copy()).
    var rb_buffers_copy = List[BufferDescriptor](capacity=n_bufs)
    for i in range(n_bufs):
        rb_buffers_copy.append(rb.buffers[i].copy())

    return _RbDecompressContext(
        frame=Optional[SharedAlignedBuffer[HeapRegion]](frame^),
        out=Optional[SharedAlignedBuffer[HeapRegion]](out^),
        rb_buffers=rb_buffers_copy^,
        new_buffers=new_buffers^,
        u_lens=u_lens^,
        body_pos=f.body_pos,
        body_start=header_size,
        total_size=total_size,
    )


def _finalize_rb_context(mut ctx: _RbDecompressContext) raises -> SharedAlignedBuffer[HeapRegion]:
    """PASS C per-RB finalize. Writes the alignment-pad zero-fill bytes
    between successive buffers + sets the output frame length. Returns
    the finished uncompressed frame ready for `decode_record_batch_message`.

    Mirrors the alignment-pad post-pass at lines 1119-1133 of
    `_decompress_buffers_into_impl` + the `out_back.length = total_size`
    final set from `_decompress_record_batch_frame_impl`.

    Uses `Optional.take()` to extract the output frame — partial-moving `ctx.out^` out of a struct with other
    heap-owning fields is rejected by the compiler. `ctx` is borrowed and left
    with `out = None`, so the caller's context slab stays live throughout.
    """
    var n_bufs = len(ctx.new_buffers)
    for i in range(n_bufs):
        ref nb = ctx.new_buffers[i]
        var dst_off = ctx.body_start + Int(nb.offset)
        var tail = dst_off + Int(nb.length)
        var aligned_tail = ctx.body_start + (
            ((Int(nb.offset) + Int(nb.length) + 7) // 8) * 8
        )
        var pad_n = aligned_tail - tail
        if pad_n > 0:
            for k in range(pad_n):
                ctx.out.value().write_u8_at(tail + k, UInt8(0))
    var out_buf = ctx.out.take()
    out_buf.set_length(ctx.total_size)

    return out_buf^


def decompress_all_rbs_into_with_dispatcher[
    C: ArrowIpcCompression,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    var frames: Slab[SharedAlignedBuffer[HeapRegion]],
    dispatcher_ptr: Pointer[D, disp_o],
    var cancel_token: CancellationToken,
) raises -> Slab[SharedAlignedBuffer[HeapRegion]]:
    """File-level coalesced multi-RB decompress entry point.

    Takes ownership of a slab of compressed RB frames (one per RB in the
    file); returns a slab of decompressed RB frames in the same order.
    The slab is moved through the dispatch + back out via Optional.take.

    Internal driver shape:
      PASS A: per-RB context build (parse framing, compute new_buffers,
              allocate output frame, write header+FB).
      PASS B: ONE LocalDispatcher.run_with_state dispatch with
              n_workers tasks; workers stride through the flat global
              (rb, buf) task list.
      PASS C: per-RB alignment-pad post-pass + set out.length.

    Replaces the N per-RB
    `decompress_record_batch_frame_with_dispatcher[C]` calls in the
    file-level driver with one coalesced dispatch — eliminates the
    `_dispatch_semaphore_wait_slow` samples that dominate a per-RB
    dispatch profile.
    """
    var n_rbs = len(frames)
    if n_rbs == 0:
        _ = cancel_token^
        return frames^

    # === PASS A: per-RB context build (serial) ===
    #
    # DECODE-ERROR UNWIND SAFETY. `_build_rb_context` raises on a malformed
    # frame, so the frames must leave the slab through moves that keep every
    # container's length equal to its count of live slots at each point: a
    # forward `take_slot_unchecked` drain fixed up by `set_len_unchecked`
    # after the loop unwinds with the moved-out slots still counted, and the
    # slab's destructor frees those frames a second time (a double free that
    # crashed the reader on a malformed file). `pop` from the back of the
    # slab fills `pending` in reverse, so popping `pending` from its back
    # yields frame 0, 1, ... in order. Both pops adjust the length as they
    # go; an unwind drops exactly the frames not yet handed on. O(n_rbs).
    var pending = List[SharedAlignedBuffer[HeapRegion]](capacity=n_rbs)
    while len(frames) > 0:
        var last = frames.pop()
        pending.append(last.take())
    _ = frames^
    var contexts = Slab[_RbDecompressContext]()
    var total_non_empty: Int = 0
    for _ in range(n_rbs):
        var ctx = _build_rb_context[C](pending.pop())
        var n_bufs = len(ctx.rb_buffers)
        for bi in range(n_bufs):
            if Int(ctx.rb_buffers[bi].length) > 0:
                total_non_empty += 1
        contexts.append(ctx^)
    _ = pending^

    # Per-RB error slots — first-error-wins within an RB. Pre-sized to
    # n_rbs (one slot per RB, not per buffer; the worker handles all
    # buffers of an RB sequentially so per-RB granularity is sufficient).
    var errors = List[Optional[String]]()
    for _ in range(n_rbs):
        errors.append(Optional[String](None))

    # Threshold gate: below `_MIN_PARALLEL_DECOMPRESS_BUFS` non-empty
    # buffers, fall back to serial loop (dispatcher overhead would
    # exceed gain).
    if total_non_empty < _MIN_PARALLEL_DECOMPRESS_BUFS:
        _ = cancel_token^
        # Serial walk over all (rb, buf) pairs. NO dctx caching on
        # this branch (workload is small; one create/free pair is
        # negligible).
        for ri in range(n_rbs):
            ref ctx = contexts[ri]
            var n_bufs = len(ctx.rb_buffers)
            for bi in range(n_bufs):
                var c_len = Int(ctx.rb_buffers[bi].length)
                if c_len == 0:
                    continue
                var c_off = Int(ctx.rb_buffers[bi].offset)
                var dst_off = ctx.body_start + Int(
                    ctx.new_buffers[bi].offset
                )
                # codec-absent RB
                # path. `_build_rb_context` marks buffers with
                # `_BUF_VERBATIM_COPY_SENTINEL` u_lens when the FB carries
                # no BodyCompression child — body is laid down without an
                # i64 prefix; memcpy `c_len` bytes from `body_pos + c_off`.
                if (
                    ctx.u_lens[bi] == Int(_BUF_VERBATIM_COPY_SENTINEL)
                ):
                    ctx.out.value().copy_from_view_at(
                        dst_off,
                        ctx.frame.value().view_range_ro(
                            ctx.body_pos + c_off, c_len,
                        ),
                    )
                    continue
                var compressed_payload_len = c_len - 8
                var src_u_len = Int(
                    ctx.frame.value().read_i64_le_at(ctx.body_pos + c_off)
                )
                if src_u_len == Int(UNCOMPRESSED_LEN_SENTINEL):
                    if compressed_payload_len > 0:
                        ctx.out.value().copy_from_view_at(
                            dst_off,
                            ctx.frame.value().view_range_ro(
                                ctx.body_pos + c_off + 8,
                                compressed_payload_len,
                            ),
                        )
                else:
                    var u_len_i = ctx.u_lens[bi]
                    # Migrated from BANNED
                    # `ctx.out.value()._codec_ptr_mut()` onto origin-tied
                    # `view_mut()._unsafe_ptr()`.
                    var out_view = ctx.out.value().view_mut()
                    var got = C.decompress_into(
                        ctx.frame.value().view_range_ro(
                            ctx.body_pos + c_off + 8,
                            compressed_payload_len,
                        ).into_span(),
                        out_view._unsafe_ptr() + dst_off,
                        u_len_i,
                    )
                    if got != u_len_i:
                        raise Error(
                            String("decompress_all_rbs_into: rb=")
                            + String(ri)
                            + String(" buf=") + String(bi)
                            + String(": decompressed size ")
                            + String(got)
                            + String(" does not match prefix ")
                            + String(u_len_i)
                        )
    else:
        # === PASS B: single coalesced dispatch with per-worker dctx ===
        var n_workers = num_physical_cores()
        if n_workers > _MAX_DECOMPRESS_WORKERS:
            n_workers = _MAX_DECOMPRESS_WORKERS
        # Cap workers at n_rbs (RB-batched stride; no point dispatching
        # more workers than there are RBs).
        # The
        # single-RB case (n_rbs == 1) takes the per-BUFFER stride path
        # inside _CoalescedTask.execute — for that path we cap at
        # min(n_workers, total_non_empty_bufs). This avoids a
        # collapse-to-1-worker shape that leaves the other workers parked in
        # `_dispatch_semaphore_wait_slow` while one thread single-handedly
        # runs LZ4F_decompress (several times slower than a single-threaded
        # pyarrow read).
        if n_rbs == 1:
            if n_workers > total_non_empty:
                n_workers = total_non_empty
        else:
            if n_workers > n_rbs:
                n_workers = n_rbs
        if n_workers < 1:
            n_workers = 1

        # Pre-fill per-worker dctx slab with empty handles. Each handle
        # lazily acquires its dctx inside the first
        # `decompress_into_with_dctx` call from its assigned worker —
        # this gives one create/free per worker per dispatch (n_workers
        # total) instead of one per buffer (~1617 on lineitem).
        var dctxs = Slab[_CodecDctxHandle[C]]()
        for _ in range(n_workers):
            dctxs.append(_CodecDctxHandle[C]())

        var state = _CoalescedState[C](
            contexts^,
            dctxs^,
            errors^,
            n_rbs,
            n_workers,
        )
        var task = _CoalescedTask[C](Int32(0))
        _ = dispatcher_ptr[].run_with_state[
            _CoalescedState[C], _CoalescedTask[C],
        ](state, task^, n_workers, cancel_token^, site_id=_SITE_FORMAT_READ)

        # Reclaim slabs via Optional.take post-dispatch. The dctxs slab
        # is reclaimed too — its destructor cascades to each handle's
        # `__del__` which calls `C.free_dctx`, releasing the per-worker
        # contexts at end-of-dispatch (exactly the lifecycle arrow-cpp
        # uses for its per-thread cache: free at thread-pool teardown).
        contexts = state.contexts.take()
        var dctxs_back = state.dctxs.take()
        errors = state.errors.take()
        _ = state^
        # Explicit drop to make the free_dctx fan-out happen here
        # (visible in profiles as one batched cleanup, not interleaved
        # with the post-dispatch column build).
        _ = dctxs_back^

    # Drain worker errors. Re-raise the first failure (rb-order).
    for ri in range(n_rbs):
        if errors[ri]:
            var msg = errors[ri].value().copy()
            raise Error(
                String("decompress_all_rbs_into_with_dispatcher: ") + msg
            )

    _ = errors^

    # === PASS C: per-RB alignment-pad post-pass + collect output frames ===
    # Each context is finalized in place (its `out` taken, leaving `None`),
    # so `contexts` stays fully live and drops soundly on any exit.
    var out_frames = Slab[SharedAlignedBuffer[HeapRegion]]()
    for ri in range(n_rbs):
        out_frames.append(_finalize_rb_context(contexts[ri]))
    _ = contexts^

    return out_frames^


# =============================================================================
# encode_dictionary_batch_message_from_string_column_compressed
# =============================================================================
#
#
#
# Per-buffer-compressed sibling of `encode_dictionary_batch_message_from_
# string_column` (ipc_encoder_dispatch.mojo). Mirrors the
# `encode_record_batch_message_compressed[C]` shape but wraps the inner
# RecordBatch table in a DictionaryBatch wrapper per Arrow IPC
# Message.fbs.
#
# Wire layout of the dict frame body:
#   <validity_block><offsets_block><data_block>
# Where each <block> is:
#   <i64 uncompressed_length_LE> <compressed_or_raw_bytes>
# If compressed_size >= uncompressed_size, writer emits
# `uncompressed_length = -1` sentinel followed by raw bytes; readers
# detect the sentinel and skip decompression for that buffer.
#
# The inner RecordBatch table carries BodyCompression (field 3) per the
# normal compressed RB shape; the DictionaryBatch wrapper around it
# does NOT have a body-compression field of its own — the compression
# applies to the body bytes, not to the wrapper metadata.


def encode_dictionary_batch_message_from_string_column_compressed[
    C: ArrowIpcCompression
](
    dict_id: Int64,
    var dict_col: Column[HeapRegion],
    is_delta: Bool,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Serial-fallback wrapper. Dict batches typically have only 2-3
    buffers (validity + offsets + data); even when a dispatcher IS
    available, the helper's threshold falls back to a serial loop, so
    forcing this serial entry point is correct for dict-batch perf.


    """
    # Class C: serial-fallback substitutes D=NoDispatch with a CONCRETE
    # origin, NOT MutAnyOrigin.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return _encode_dictionary_batch_message_from_string_column_compressed_impl[
        C, NoDispatch, has_pool=False, disp_o=nd_o,
    ](
        dict_id,
        dict_col^,
        is_delta,
        Optional[Pointer[NoDispatch, nd_o]](None),
        CancellationToken.never(),
    )


def encode_dictionary_batch_message_from_string_column_compressed_with_dispatcher[
    C: ArrowIpcCompression,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    dict_id: Int64,
    var dict_col: Column[HeapRegion],
    is_delta: Bool,
    dispatcher_ptr: Pointer[D, disp_o],
    var cancel_token: CancellationToken,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Dispatcher-aware variant — symmetric to the RB-frame encoder.

    Dict batches are typically below the threshold and take the serial
    branch inside the helper. Surfacing the dispatcher here keeps the
    write-path API symmetric with the read path (and avoids a stranded
    `_with_dispatcher`-less call from `FileSink._emit_dict_batches_for_
    rb_compressed_with_dispatcher`).
    """
    return _encode_dictionary_batch_message_from_string_column_compressed_impl[
        C, D, has_pool=True, disp_o=disp_o,
    ](
        dict_id,
        dict_col^,
        is_delta,
        Optional[Pointer[D, disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _encode_dictionary_batch_message_from_string_column_compressed_impl[
    C: ArrowIpcCompression,
    D: ParallelDispatch,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    dict_id: Int64,
    var dict_col: Column[HeapRegion],
    is_delta: Bool,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Encode a DictionaryBatch IPC message frame for a STRING-valued
    dictionary WITH per-buffer body compression per `C: ArrowIpcCompression`.

    Mirrors `encode_dictionary_batch_message_from_string_column` but
    routes the dict values' buffers through the same per-buffer
    compression pre-pass used by `encode_record_batch_message_compressed`.

    Returns a complete IPC frame: [u32 0xFFFFFFFF, u32 size,
    FB(Message{header=DictionaryBatch{id, data(with BodyCompression),
    isDelta}}), pad, compressed_body].
    """
    if dict_col.arrow_type != ArrowType.STRING:
        _ = cancel_token^
        raise Error(
            "encode_dictionary_batch_message_from_string_column_compressed:"
            " dict_col.arrow_type must be STRING; got "
            + String(Int(dict_col.arrow_type.type_id))
            + " (only STRING-valued dictionaries are supported)"
        )

    # Step 1: Build the uncompressed (body, buffers, nodes).
    var dict_cols = Slab[Column[HeapRegion]]()
    dict_cols.append(dict_col^)
    var dict_row_count = 0
    var raw_sink = AlignedBufferBodySink(_estimate_body_size(dict_cols))
    var raw_cursor: Int = 0
    var raw_buffers = List[BufferDescriptor]()
    var nodes = List[FieldNode]()
    for i in range(len(dict_cols)):
        ref c = dict_cols[i]
        if i == 0:
            dict_row_count = c._length
        raw_cursor = encode_column[AlignedBufferBodySink](
            c, raw_sink, raw_cursor, raw_buffers, nodes
        )
    var raw_body = raw_sink.finalize()

    # Step 2: Per-buffer compression pre-pass.
    # Same dispatcher threading as the RB encoder.
    var n_bufs = len(raw_buffers)
    var compressed_body = OwnedAlignedBuffer(raw_cursor + 64 * n_bufs + 1024)
    var compressed_buffers = List[BufferDescriptor]()
    var compressed_cursor = _compress_buffers_into_impl[
        C, D, has_pool=has_pool, disp_o=disp_o
    ](
        raw_body,
        raw_buffers,
        compressed_body,
        compressed_buffers,
        dispatcher_ptr,
        cancel_token^,
    )

    var comp_body_pad = (8 - (compressed_cursor % 8)) % 8
    if comp_body_pad > 0:
        for _ in range(comp_body_pad):
            compressed_body.write_u8_at(compressed_cursor, UInt8(0))
            compressed_cursor += 1
    compressed_body.set_length(Int64(compressed_cursor))

    _ = raw_body^

    # Step 3: Emit FB metadata.
    var w = FlatbufWriter(2048)
    var bc_pos = write_body_compression(w, C.ARROW_IPC_CODEC_ID)
    var rb_pos = write_record_batch_compressed(
        w, Int64(dict_row_count), nodes, compressed_buffers, bc_pos
    )
    var db_pos = write_dictionary_batch(w, dict_id, rb_pos, is_delta)
    var msg_pos = write_message(
        w,
        Int16(Int(METADATA_VERSION_V5)),
        MESSAGE_HEADER_DICTIONARY_BATCH,
        db_pos,
        Int64(compressed_cursor),
    )
    var fb_payload = w^.finalize(msg_pos)

    var w2 = FlatbufWriter(64)
    var body_span = compressed_body.view_range_ro(
        0, compressed_cursor
    ).into_span()
    var frame = write_ipc_message(w2, fb_payload^, body_span, True)
    _ = compressed_body^
    return frame^


# =============================================================================
# decompress_dictionary_batch_frame
# =============================================================================
#
#
#
# Symmetric to `decompress_record_batch_frame` but for DictionaryBatch
# message frames. The outer wrapper is a DictionaryBatch table whose
# `data` field references an inner RecordBatch table; the BodyCompression
# (field 3) lives on that inner RecordBatch table and applies to the
# body bytes (which are the dict VALUES buffers).
#
# Output: a fresh DictionaryBatch frame whose inner RecordBatch table
# has no BodyCompression field + whose body bytes are the UNCOMPRESSED
# buffers (matching exactly what the Uncompressed encoder would have
# produced). Downstream `_consume_dictionary_batch_frame` can walk it
# without any codec awareness.


def decompress_dictionary_batch_frame[C: ArrowIpcCompression](
    var frame: SharedAlignedBuffer[HeapRegion],
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Serial-fallback wrapper. Dict batches typically have 2-3 buffers
    and stay below the parallel threshold even when a dispatcher IS
    available — this entry point is correct for the test-fixture +
    transient-decode case.


    """
    # Class C: serial-fallback substitutes D=NoDispatch with a CONCRETE
    # origin, NOT MutAnyOrigin.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return _decompress_dictionary_batch_frame_impl[
        C, NoDispatch, has_pool=False, disp_o=nd_o,
    ](
        frame^,
        Optional[Pointer[NoDispatch, nd_o]](None),
        CancellationToken.never(),
    )


def decompress_dictionary_batch_frame_with_dispatcher[
    C: ArrowIpcCompression,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    var frame: SharedAlignedBuffer[HeapRegion],
    dispatcher_ptr: Pointer[D, disp_o],
    var cancel_token: CancellationToken,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Dispatcher-aware variant. Surfacing the dispatcher here keeps
    the read-path API symmetric with the RB-decompress path even though
    dict batches typically take the serial branch inside the helper."""
    return _decompress_dictionary_batch_frame_impl[
        C, D, has_pool=True, disp_o=disp_o,
    ](
        frame^,
        Optional[Pointer[D, disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _decompress_dictionary_batch_frame_impl[
    C: ArrowIpcCompression,
    D: ParallelDispatch,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    var frame: SharedAlignedBuffer[HeapRegion],
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Decompress a per-buffer-compressed DictionaryBatch frame into a
    fresh frame whose inner RecordBatch references the UNCOMPRESSED
    body layout (no BodyCompression flatbuf field on the inner RB).

    Mirror of `decompress_record_batch_frame` for DictionaryBatch
    frames. inner per-buffer
    decompress dispatches via `_decompress_buffers_into_impl[C, has_pool,
    disp_o]`.
    """
    # 1. Parse outer IPC framing.
    var f = parse_ipc_message(frame)

    # 2. Extract the FB metadata.
    # scalar
    # byte-copy → libc memcpy. Same fix shape as
    # decompress_record_batch_frame.
    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(max(f.metadata_size, 1))
    if f.metadata_size > 0:
        fb.copy_from_view_at(
            0, frame.view_range_ro(f.metadata_pos, f.metadata_size)
        )
    fb.set_length(f.metadata_size)

    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    if msg.header_tag != MESSAGE_HEADER_DICTIONARY_BATCH:
        raise Error(
            "decompress_dictionary_batch_frame: expected DICTIONARY_BATCH"
            " header (tag "
            + String(Int(MESSAGE_HEADER_DICTIONARY_BATCH))
            + "), got " + String(Int(msg.header_tag))
        )

    # 3. Read the DictionaryBatch table + the inner RecordBatch table
    # (which carries BodyCompression).
    from komira_arrow_ipc.ipc_flatbuf import read_dictionary_batch
    var db_desc = read_dictionary_batch(reader, msg.header_table_pos)
    var rb = read_record_batch(reader, db_desc.data_table_pos)

    #
    # IN-PLACE BODY CONSTRUCTION — mirror of decompress_record_batch_frame.
    # Same 4-pass shape (scan → FB build → output frame alloc + header →
    # per-buffer decompress directly into output body region). Eliminates
    # the dominant body-memcpy via write_ipc_message.
    var n_bufs = len(rb.buffers)

    # === PASS 1: scan compressed body, compute new offsets + body size ===
    var new_buffers = List[BufferDescriptor]()
    var new_cursor: Int = 0
    var u_lens = List[Int](capacity=n_bufs)
    for i in range(n_bufs):
        ref buf = rb.buffers[i]
        var c_len = Int(buf.length)
        var c_off = Int(buf.offset)
        if c_len == 0:
            new_buffers.append(
                BufferDescriptor(
                    offset=Int64(new_cursor),
                    length=Int64(0),
                )
            )
            u_lens.append(0)
            continue
        if c_len < 8:
            raise Error(
                "decompress_dictionary_batch_frame: buffer " + String(i)
                + " has length " + String(c_len)
                + " < 8 (the i64 uncompressed_length prefix);"
                + " malformed compressed body"
            )
        var u_len = Int(frame.read_i64_le_at(f.body_pos + c_off))
        var compressed_payload_len = c_len - 8
        var uncompressed_len: Int
        if u_len == Int(UNCOMPRESSED_LEN_SENTINEL):
            uncompressed_len = compressed_payload_len
        else:
            if u_len < 0:
                raise Error(
                    "decompress_dictionary_batch_frame: buffer "
                    + String(i)
                    + " has negative uncompressed_length "
                    + String(u_len)
                    + " (only -1 sentinel is valid;"
                    + " malformed compressed body)"
                )
            uncompressed_len = u_len
        new_buffers.append(
            BufferDescriptor(
                offset=Int64(new_cursor),
                length=Int64(uncompressed_len),
            )
        )
        u_lens.append(uncompressed_len)
        new_cursor += uncompressed_len
        new_cursor = ((new_cursor + 7) // 8) * 8

    var body_size = new_cursor

    # === PASS 2: build FB metadata once ===
    var w = FlatbufWriter(2048)
    var rb_pos = write_record_batch(
        w, Int64(rb.length), rb.nodes, new_buffers, rb.variadic_buffer_counts
    )
    var db_pos = write_dictionary_batch(
        w, db_desc.id, rb_pos, db_desc.is_delta
    )
    var msg_pos = write_message(
        w,
        Int16(Int(METADATA_VERSION_V5)),
        MESSAGE_HEADER_DICTIONARY_BATCH,
        db_pos,
        Int64(body_size),
    )
    var fb_payload = w^.finalize(msg_pos)
    var fb_size = fb_payload.len()
    var fb_aligned = ((fb_size + 7) // 8) * 8
    var pad_after_fb = fb_aligned - fb_size

    # === PASS 3: allocate output frame in one shot + assemble header ===
    var continuation_size = 4
    var header_size = continuation_size + 4 + fb_aligned
    var total_size = header_size + body_size
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(total_size, 1))
    var pos = 0
    out.write_u32_le_at(pos, IPC_CONTINUATION_MARKER)
    pos += 4
    out.write_u32_le_at(pos, UInt32(fb_aligned))
    pos += 4
    if fb_size > 0:
        out.copy_from_aligned_buffer_at(pos, fb_payload, 0, fb_size)
    pos += fb_size
    if pad_after_fb > 0:
        for i in range(pad_after_fb):
            out.write_u8_at(pos + i, UInt8(0))
        pos += pad_after_fb
    _ = fb_payload^

    # === PASS 4: decompress directly into output frame body region ===
    # delegated to the shared
    # `_decompress_buffers_into_impl[C, has_pool, disp_o]` helper. Dict
    # batches typically have 2-3 buffers; the threshold gate (4) keeps
    # them on the serial branch even when a dispatcher IS available.
    # Helper consumes + returns `out`.
    var body_start = header_size
    var out_back = _decompress_buffers_into_impl[
        C, D, has_pool=has_pool, disp_o=disp_o
    ](
        frame,
        f.body_pos,
        rb.buffers,
        new_buffers,
        u_lens,
        out^,
        body_start,
        String("decompress_dictionary_batch_frame"),
        dispatcher_ptr,
        cancel_token^,
    )

    out_back.set_length(total_size)

    _ = frame^
    _ = u_lens^
    return out_back^


def peek_dictionary_batch_codec_from_frame(
    ref frame: SharedAlignedBuffer[HeapRegion],
) raises -> Int8:
    """Peek the inner RecordBatch's BodyCompression.codec field on a
    DictionaryBatch IPC frame WITHOUT decoding the body. Returns -1
    when the inner RB has no BodyCompression field (uncompressed body).


    """
    var f = parse_ipc_message(frame)
    # scalar
    # byte-copy → libc memcpy. Same fix shape.
    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(max(f.metadata_size, 1))
    if f.metadata_size > 0:
        fb.copy_from_view_at(
            0, frame.view_range_ro(f.metadata_pos, f.metadata_size)
        )
    fb.set_length(f.metadata_size)

    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    if msg.header_tag != MESSAGE_HEADER_DICTIONARY_BATCH:
        raise Error(
            "peek_dictionary_batch_codec_from_frame: expected"
            " DICTIONARY_BATCH header (tag "
            + String(Int(MESSAGE_HEADER_DICTIONARY_BATCH))
            + "), got " + String(Int(msg.header_tag))
        )
    from komira_arrow_ipc.ipc_flatbuf import read_dictionary_batch
    var db_desc = read_dictionary_batch(reader, msg.header_table_pos)
    var rb_desc = read_record_batch(reader, db_desc.data_table_pos)
    return rb_desc.body_compression_codec
