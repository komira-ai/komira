# =============================================================================
# ocf_block_emit.mojo — OCF header + block writer + OS-entropy sync marker.
# =============================================================================
#
# The inverse of ocf_header.mojo (decode) + ocf_block_scan.mojo (block walk):
#
#   header := "Obj" 0x01                          // 4-byte magic + version
#             map<string,bytes>                   // file metadata (Avro binary)
#                 "avro.schema" -> <JSON>
#                 "avro.codec"  -> <wire-name>
#             sync_marker                          // 16 OS-entropy bytes
#   block  := long object_count                    // # records (zigzag)
#             long byte_count                       // post-compression size
#             bytes payload                         // (compressed) records
#             sync_marker                           // same 16 bytes
#
# CRITICAL — sync marker via OS entropy. A
# userland PRNG is BANNED: the marker must be unpredictable so it never
# collides with record bytes (the reader chained-walk + resync rely on the
# marker being effectively random). We source 16 bytes from the OS CSPRNG via
# `getrandom(2)` (Linux) / `arc4random_buf` (Darwin), through `external_call`
# (matching the codec FFI precedent — no UnsafePointer crosses the public API).
#
# Encapsulation: the public API takes/returns owned values + borrowed Spans.
# The entropy FFI confines its one pointer to a stack InlineArray it owns for
# the duration of the synchronous syscall.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget

from komira_collections.slab import Slab

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.chunk_work import ChunkWork
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_fork_join import parallel_fork_join

from .ocf_header import (
    OCF_MAGIC_LEN,
    OCF_SYNC_LEN,
    codec_wire_name,
    AVRO_CODEC_NULL,
)
from .avro_codec import compress_block
from .varint_encode import encode_long, encode_string, encode_bytes


# =============================================================================
# Parallel block-compress thresholds.
# =============================================================================
#
# Per-block parallel-dispatch threshold. Below this many blocks, the dispatcher
# run_with_state overhead exceeds the parallel-compress wall win, so the helper
# falls back to a serial per-block compress. A multi-million-row file produces
# thousands of 64-KiB blocks, far above this threshold; small files (single
# block) take the serial path.
comptime _MIN_PARALLEL_COMPRESS_BLOCKS: Int = 4

# Cap on parallel-compress workers. Sized for a 10-core machine
# with one slot of headroom; the dispatcher caps further via
# min(worker_count, n_workers).
comptime _MAX_BLOCK_COMPRESS_WORKERS: Int = 16


# =============================================================================
# OS-entropy sync marker (getrandom / arc4random_buf).
# =============================================================================


def generate_sync_marker() raises -> Array[UInt8, OCF_SYNC_LEN]:
    """Produce a 16-byte sync marker from the OS CSPRNG.

    Linux:  getrandom(buf, 16, 0) — blocks until the pool is initialized;
            returns the count read (must equal 16).
    Darwin: arc4random_buf(buf, 16) — void, always succeeds.

    SAFETY (FFI carve-out): `marker` is a stack InlineArray this function
    owns; we hand the OS a pointer to its storage for the duration of the
    synchronous syscall only. The OS fills it and never retains the pointer.
    No pointer crosses the module boundary (we return the InlineArray by
    value)."""
    var marker = Array[UInt8, OCF_SYNC_LEN](fill=0)

    comptime if CompilationTarget.is_macos():
        # void arc4random_buf(void* buf, size_t nbytes);
        external_call["arc4random_buf", NoneType](
            marker.unsafe_ptr(), Int64(OCF_SYNC_LEN)
        )
    else:
        # ssize_t getrandom(void* buf, size_t buflen, unsigned int flags);
        var got = external_call["getrandom", Int64](
            marker.unsafe_ptr(), Int64(OCF_SYNC_LEN), UInt32(0)
        )
        if Int(got) != OCF_SYNC_LEN:
            raise Error(  # cov: unreachable getrandom does not return short for 16 bytes
                String("AvroWriteError.ENTROPY_FAILED: getrandom returned ")  # cov: unreachable getrandom does not return short for 16 bytes
                + String(Int(got))  # cov: unreachable getrandom does not return short for 16 bytes
                + " (expected " + String(OCF_SYNC_LEN) + ")"  # cov: unreachable getrandom does not return short for 16 bytes
            )
    return marker^


# =============================================================================
# OCF header emit.
# =============================================================================


def emit_ocf_header(
    schema_json: String,
    codec_tag: Int,
    sync_marker: Array[UInt8, OCF_SYNC_LEN],
    mut out: List[UInt8],
):
    """Emit the OCF header (magic + metadata map + sync marker) into `out`.

    The metadata map is an Avro `map<string,bytes>`: a positive `long` count of
    the entry pairs, then each (key:string, value:bytes), then a terminating
    zero-count `long`. We always emit exactly two entries: avro.schema +
    avro.codec."""
    # Magic: "Obj" 0x01.
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(UInt8(0x01))

    # Metadata map: 2 entries.
    encode_long(Int64(2), out)
    encode_string(String("avro.schema"), out)
    encode_bytes(schema_json.as_bytes(), out)
    encode_string(String("avro.codec"), out)
    var codec_name = codec_wire_name(codec_tag)
    encode_bytes(codec_name.as_bytes(), out)
    # Terminating zero-count block.
    encode_long(Int64(0), out)

    # Sync marker — one bulk extend (vs 16 per-byte appends).
    out.extend(Span(sync_marker))


def emit_ocf_header_kv(
    schema_json: String,
    codec_tag: Int,
    sync_marker: Array[UInt8, OCF_SYNC_LEN],
    extra_keys: List[String],
    extra_vals: List[String],
    mut out: List[UInt8],
):
    """Emit an OCF header with EXTRA file-metadata key-value pairs.

    The standard `emit_ocf_header` writes exactly two metadata entries
    (avro.schema + avro.codec). Some Avro consumers — notably Apache Iceberg's
    manifest files — require ADDITIONAL OCF file-metadata entries (Iceberg's
    manifest header carries `schema` / `schema-id` / `partition-spec` /
    `partition-spec-id` / `format-version` / `content`). This variant emits
    avro.schema + avro.codec FIRST (so a plain Avro reader still finds them),
    then each (extra_keys[i], extra_vals[i]) pair, then the terminating
    zero-count block + sync marker.

    `len(extra_keys)` must equal `len(extra_vals)` (the caller's contract;
    a mismatch writes min(len) pairs — defensive, not enforced via raise so
    the signature stays non-raising like `emit_ocf_header`)."""
    # Magic: "Obj" 0x01.
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(UInt8(0x01))

    var n_extra = len(extra_keys)
    if len(extra_vals) < n_extra:
        n_extra = len(extra_vals)

    # Metadata map: 2 standard entries + n_extra.
    encode_long(Int64(2 + n_extra), out)
    encode_string(String("avro.schema"), out)
    encode_bytes(schema_json.as_bytes(), out)
    encode_string(String("avro.codec"), out)
    var codec_name = codec_wire_name(codec_tag)
    encode_bytes(codec_name.as_bytes(), out)
    for i in range(n_extra):
        encode_string(extra_keys[i], out)
        encode_bytes(extra_vals[i].as_bytes(), out)
    # Terminating zero-count block.
    encode_long(Int64(0), out)

    out.extend(Span(sync_marker))


# =============================================================================
# OCF block emit.
# =============================================================================


def emit_ocf_block(
    record_payload: Span[UInt8, _],
    object_count: Int,
    codec_tag: Int,
    sync_marker: Array[UInt8, OCF_SYNC_LEN],
    mut out: List[UInt8],
) raises:
    """Emit one OCF block (object_count + byte_count + compressed payload +
    sync marker) into `out`.

    `record_payload` is the RAW (uncompressed) Avro-binary record bytes for
    this block; we codec-compress it, then frame:
        long object_count, long byte_count, <compressed bytes>, sync_marker.
    """
    # NULL codec is a no-op — frame the raw payload directly (bulk extend),
    # skipping the full byte-copy that `compress_block` would do for it (like
    # arrow-avro's `None => buf` write_ocf_block path).
    if codec_tag == AVRO_CODEC_NULL:
        encode_long(Int64(object_count), out)
        encode_long(Int64(len(record_payload)), out)
        out.extend(record_payload)
        out.extend(Span(sync_marker))
        return

    var compressed = compress_block(codec_tag, record_payload)
    encode_long(Int64(object_count), out)
    encode_long(Int64(len(compressed)), out)
    # One bulk extend each (vs N + 16 per-byte appends).
    out.extend(Span(compressed))
    out.extend(Span(sync_marker))


# =============================================================================
# Block-size defaults.
# =============================================================================
#
# block_size_bytes mirrors Java DataFileWriter.DEFAULT_SYNC_INTERVAL (64 KiB).
# A block flushes when EITHER the accumulated raw record bytes reach
# block_size_bytes OR the accumulated record count reaches block_size_rows —
# whichever comes first. block_size_rows defaults large so the byte trigger
# dominates on wide rows; small files emit a single block.

comptime AVRO_DEFAULT_BLOCK_SIZE_BYTES: Int = 64 * 1024
comptime AVRO_DEFAULT_BLOCK_SIZE_ROWS: Int = 1 << 30  # effectively byte-driven


@always_inline
def should_flush_block(
    current_block_bytes: Int,
    current_block_rows: Int,
    block_size_bytes: Int,
    block_size_rows: Int,
) -> Bool:
    """The bytes-OR-rows whichever-first flush trigger."""
    if current_block_rows == 0:
        return False
    return (
        current_block_bytes >= block_size_bytes
        or current_block_rows >= block_size_rows
    )


# =============================================================================
# Parallel block compress.
# =============================================================================
#
# Per-block parallel compress via the shared `parallel_fork_join` fork-join
# helper (the same shape as ORC's `compress_streams_parallel`, over blocks
# instead of streams).
#
# The per-block work — `compress_block(codec, raw)` — is a one-method
# `_CompressBlockWork` ChunkWork impl; the helper OWNS the dispatch safety
# contract (concrete immutable-origin borrow, NO wildcard; disjoint pre-sized
# `Slab[Optional[O]]`; Optional.take reclaim with chunk errors CAUGHT;
# wake-word-barrier liveness; serial fallback; first error wins). The flow:
#   1. The Avro writer accumulates ALL row blocks' RAW payloads first (each
#      block is fully encoded as a fresh List[UInt8]; the row-loop never
#      compresses inline). Each block has an associated `object_count`.
#   2. The writer calls `compress_blocks_parallel(blocks, codec, dispatcher,
#      cancel_token)` which dispatches one chunk per block via the helper,
#      stride-partitioned (`c % n_workers == tid`) across workers — every
#      block's compress is INDEPENDENT (different output List, different
#      input Span), so no cross-chunk contention.
#   3. The writer then serially walks the per-block compressed payloads + the
#      object counts in INDEX ORDER and frames each via emit_compressed_block
#      into the output.
#
# Stride partition (vs equal-row partition) keeps the load balanced when block
# sizes are skewed (last block may be partial; codecs have data-dependent wall).
#
# DISPATCH-BOUNDARY SAFETY is centralized in
# `parallel_fork_join`: disjoint pre-sized Slab[Optional[O]], immutable-origin
# borrow of `raw_blocks`, wake-word-barrier liveness, Optional.take reclaim.
# This work unit only carries the codec tag + the per-block compress call.


@fieldwise_init
struct _CompressBlockWork(ChunkWork):
    """Per-block compress work. Reads `raw_blocks[chunk_id]`, writes the
    compressed payload into `out_slot`. `compress_block` is a pure-FFI call
    (libsnappy / libz / libzstd) with no shared mutable state."""

    var codec_tag: Int

    def process[
        In: Deinitable, O: Movable & Deinitable
    ](
        self,
        chunk_id: Int,
        n_chunks: Int,
        ref input: In,
        mut out_slot: Optional[O],
    ) raises:
        # SAFETY: the helper binds In=Slab[List[UInt8]], O=List[UInt8] at the
        # `parallel_fork_join[...]` call site; the bitcasts resolve to those
        # concrete types. Internal to this module; never exposed publicly.
        var rp = UnsafePointer(to=input).bitcast[Slab[List[UInt8]]]()
        ref raw = rp[][chunk_id]
        var compressed = compress_block(self.codec_tag, Span(raw))
        var op = UnsafePointer(to=out_slot).bitcast[Optional[List[UInt8]]]()
        op[] = Optional[List[UInt8]](compressed^)


def compress_blocks_parallel[
    raw_o: ImmOrigin,
    disp_o: Origin[mut=True],
](
    raw_blocks: Slab[List[UInt8]],
    codec_tag: Int,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> Slab[List[UInt8]]:
    """Compress every block in `raw_blocks` in parallel via the shared
    `parallel_fork_join` fork-join helper.

    Returns a `Slab[List[UInt8]]` of compressed payloads in INDEX ORDER (slot
    `i` holds the compressed bytes for `raw_blocks[i]`).

    Empty / NULL codec callers should bypass — they don't need this entry.
    The NULL codec STILL runs through here (compress_block(NULL) is a
    memcpy); when the caller wants the zero-copy frame-raw shape, it must
    skip this helper and frame the raw block directly.

    Below `_MIN_PARALLEL_COMPRESS_BLOCKS` blocks the helper falls back to a
    serial per-block compress (via `min_parallel_chunks`); same-shape result
    (caller is oblivious).
    """
    var n_blocks = raw_blocks.len()

    # One chunk per block. The helper stride-partitions chunks across workers
    # internally, gates parallel-vs-serial via `min_parallel_chunks`, caps
    # workers via `max_workers`, runs the dispatch + Optional.take reclaim +
    # first-error-wins re-raise, and returns one Optional[List[UInt8]] per
    # block in INDEX ORDER.
    var work = _CompressBlockWork(codec_tag)
    comptime in_o = origin_of(raw_blocks)
    var fj_out = parallel_fork_join[
        _CompressBlockWork,
        Slab[List[UInt8]],
        List[UInt8],
        in_o,
        disp_o,
    ](
        work^,
        raw_blocks,
        n_blocks,
        dispatcher_ptr,
        cancel_token^,
        min_parallel_chunks=_MIN_PARALLEL_COMPRESS_BLOCKS,
        max_workers=_MAX_BLOCK_COMPRESS_WORKERS,
    )

    # Unwrap the helper's per-chunk Optional[O] into the public
    # Slab[List[UInt8]] (every slot is always filled by the work unit).
    var out_blocks = Slab[List[UInt8]].create(n_blocks)
    var i = 0
    while i < n_blocks:
        ref slot = fj_out.get_mut_interior(i)
        if slot:
            out_blocks.append(slot.take())
        else:
            out_blocks.append(List[UInt8]())  # cov: unreachable parallel_fork_join fills every slot or raises
        i = i + 1
    _ = fj_out^
    return out_blocks^


def emit_compressed_block(
    compressed_payload: Span[UInt8, _],
    object_count: Int,
    sync_marker: Array[UInt8, OCF_SYNC_LEN],
    mut out: List[UInt8],
):
    """Frame ONE already-compressed block (object_count + byte_count +
    payload + sync marker) into `out`.

    The inverse-not-included variant of `emit_ocf_block`: callers using
    `compress_blocks_parallel` get pre-compressed payloads and frame each via
    this helper in INDEX ORDER. NULL codec uses the same shape (the raw
    payload IS the compressed payload — it's a memcpy at compress time)."""
    encode_long(Int64(object_count), out)
    encode_long(Int64(len(compressed_payload)), out)
    out.extend(compressed_payload)
    out.extend(Span(sync_marker))


def emit_raw_block_null_codec(
    raw_payload: Span[UInt8, _],
    object_count: Int,
    sync_marker: Array[UInt8, OCF_SYNC_LEN],
    mut out: List[UInt8],
):
    """NULL-codec specialization: frame the raw payload directly (no copy).
    Same as the inline NULL fast path inside `emit_ocf_block` —
    avoids the memcpy that `compress_block(NULL, ...)` would do.
    """
    encode_long(Int64(object_count), out)
    encode_long(Int64(len(raw_payload)), out)
    out.extend(raw_payload)
    out.extend(Span(sync_marker))
