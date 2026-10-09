# =============================================================================
# komira_broker/broker_core.mojo
#   BrokerCore + the PRODUCE path
# =============================================================================
#
# The Komira message broker keeps all of its state in an object store. This
# file is the CONCRETE, NON-GENERIC broker core: the data plane a
# `MessageBroker[Protocol]` thin edge struct holds by value / OwnedPointer.
#
# -----------------------------------------------------------------------------
# The [Protocol] firewall (normative).
# -----------------------------------------------------------------------------
#
# `BrokerCore` MUST NOT take `Protocol` as a type parameter. If it did, the
# whole broker would monomorphize per wire protocol — a comptime blow-up. The
# core operates ONLY on the concrete internal types `RecordBatch` (+ the
# broker-assigned offset range). Wire-protocol codecs translate wire bytes <->
# `RecordBatch` ABOVE this core, in a `[Protocol]` edge struct. So:
#
#   * `Protocol` is NOT a parameter here.
#   * `Storage: ConditionalWriteStore` IS a parameter — but it is a BACKEND
#     SELECTOR (one backend per deployment: an object store in production, the
#     in-memory conformer offline), the same discipline as `S3Fs[C]` /
#     `CasManifestStore[Store]`. It does NOT multiply per-request.
#
# -----------------------------------------------------------------------------
# THE PRODUCE PATH
# -----------------------------------------------------------------------------
#
#   1. `produce(rb)` appends a RecordBatch to the per-partition in-memory write
#      buffer (records + a running byte estimate + the oldest-buffered wall ts).
#   2. A FLUSH TRIGGER fires when the buffer hits the size threshold
#      (`FLUSH_BYTES`, default 8 MiB) OR the time threshold (`FLUSH_MS`,
#      default 250 ms) — whichever comes first.
#   3. On flush the buffered RecordBatches are encoded as ONE Arrow-IPC SEGMENT:
#      a Schema message + N RecordBatch messages + the EOS marker, followed by
#      a small fixed SEGMENT FOOTER (offset range, record count, CRC32). The
#      Arrow-IPC stream is engine-readable for free (the streaming-source
#      consumer decodes it with the IPC decoder it already has).
#   4. The broker PUTs the segment object at the key
#      `<cluster>/topics/<topic>/<partition>/segments/<flush_ts>-<broker_id>-
#      <uuid>.seg` — NO offset in the key (offsets are assigned at commit
#      time). Many brokers can PUT concurrently for one partition with zero
#      coordination.
#   5. The broker COMMITS the segment's metadata via `CasManifestStore.append(
#      body, record_count)` — the `If-None-Match` manifest-append IS the offset
#      allocator: it assigns the contiguous offset range
#      `[base, base + record_count - 1]`. The manifest append goes through the
#      process-wide CAS gate (low-rate; fine).
#   6. The broker ACKS the producer ONLY AFTER both the PUT and the manifest
#      commit land (the durability contract: acked == in the object store
#      (data) == committed in the manifest (offsets) == survives any broker
#      death). `flush()` returns the `AppendResult` carrying the acked offset
#      range; the ack is "flush returned without raising".
#
# This is "ordering is fixed AT COMMIT, not at PUT": a broker that PUTs a
# `.seg` but dies before the manifest append leaves an UNREFERENCED object
# (never visible to a consumer) — NO offset gap. Nothing deletes an
# unreferenced `.seg` today: retention deletes only the segments of chunks it
# tombstoned, and no sweep exists (komira-ai/komira#488). So a flush whose
# append fails or is fenced after its PUT leaks that object for good. A flush
# from a writer this core already knows is displaced is refused BEFORE the PUT
# (`flush_fence.mojo`), and the leaks that remain are counted
# (`BrokerCore.flush_leak_stats`).
#
# -----------------------------------------------------------------------------
# SEGMENT FORMAT — Arrow-IPC stream + a fixed 40-byte footer
# -----------------------------------------------------------------------------
#
#   [ Arrow IPC Schema message frame      ]   (encode_schema_message)
#   [ Arrow IPC RecordBatch message frame ] *  (encode_record_batch_message)
#   [ Arrow IPC EOS marker (8 bytes)       ]   (arrow_ipc_eos_bytes)
#   [ SEGMENT FOOTER (40 bytes, fixed)     ]   (this file — SegmentFooter)
#
# The leading Schema..EOS is a STANDARD Arrow IPC stream — `decode_arrow_ipc_
# stream(stream_bytes)` round-trips it with zero broker-specific decode logic.
# The footer is appended AFTER the EOS so an Arrow-only reader that stops at
# EOS still reads the records correctly; a broker-aware reader peeks the
# trailing 40 bytes for the offset range / record count / CRC. The footer
# layout (all little-endian) is:
#
#   off  0 : magic        u32  = 'T''S''G''1' (0x31475354 LE)  "TSG1"
#   off  4 : version      u32  = 1
#   off  8 : base_offset  i64  (broker-assigned; -1 until commit — see note)
#   off 16 : last_offset  i64  (broker-assigned; -1 until commit)
#   off 24 : record_count i64
#   off 32 : crc32        u32  (IEEE 802.3 over the Arrow stream bytes only)
#   off 36 : footer_len   u32  = 40
#
# NOTE on base/last in the footer: offsets are assigned by the MANIFEST append,
# which happens AFTER the segment is PUT. So the footer's offset fields carry
# the broker's PRE-COMMIT estimate (the manifest HEAD's next_offset at flush
# start). They are debug/recovery hints; the AUTHORITATIVE offset range is the
# `AppendResult` the manifest returns (and the manifest body the broker
# appends). The CRC + record_count are exact at PUT time. This keeps the
# segment object content-addressable BEFORE its offset is known (a broker can
# PUT its .seg before it knows its offset range).
#
# -----------------------------------------------------------------------------
# Encapsulation
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any public signature (the surface is value /
#     RecordBatch / List[UInt8] / POD).
#   * ZERO wildcard origins (no MutAnyOrigin / MutExternalOrigin / ...).
#   * ZERO `unsafe_from_address`.
#   * The owned substrate (`Storage` + `CasManifestStore[Storage]`) is held BY
#     VALUE (both are Movable structs that themselves encapsulate their
#     ArcPointer/Slab internals — no pointer crosses this module boundary).
#   * BrokerCore is a stack value, NOT a byte-slab element, so it has no
#     stale-pointer hazard across destroy and recreate. Its fields are owned
#     `String`s, two Movable substrate structs, and a `List[RecordBatch]`
#     write buffer — none stored in an `OwnedSlab`/`AtomicSlab`/`MutableArray`
#     with a wildcard cast.
# =============================================================================

from std.ffi import external_call

from komira_arrow_ipc.ipc_encoder_dispatch import (
    arrow_ipc_eos_bytes,
    encode_record_batch_message,
    encode_schema_message,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from komira_objectstore.cas_manifest import (
    AppendResult,
    CasManifestStore,
    IdempotentAppendResult,
    IDEMPOTENT_COMMITTED,
    IDEMPOTENT_DUPLICATE,
    IDEMPOTENT_FENCED,
    IDEMPOTENT_LEASE_FENCED,
    IDEMPOTENT_RETRYABLE,
    ManifestHead,
)
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from .flush_fence import FlushFence, FlushLeakStats
from komira_objectstore.types import WritePrecondition

# The disjoint-keyspace WRITE-path sub-lineage
# prefix builder lives in partition_assignment.mojo (the sharding home, alongside
# shard_id minting). This is cycle-free: partition_assignment is a pure-value leaf
# that imports NOTHING from broker_core.
from .partition_assignment import sublineage_prefix

# ManifestBody + its codec are a LEAF type (manifest_body.mojo) so both this
# file and retention.mojo import them without a circular dependency. Re-exported
# here for back-compat (callers that `from .broker_core import ManifestBody`).
from .manifest_body import (
    ManifestBody,
    encode_manifest_body,
    MARKER_NONE,
    MARKER_COMMIT,
    MARKER_ABORT,
)

# Retention orchestrators. retention.mojo -> manifest_body (leaf), NOT
# broker_core, so this import is cycle-free.
from .retention import (
    ReapResult,
    ReapWorker,
    RetentionPolicy,
    RetentionResult,
    RetentionPass,
)


# =============================================================================
# Config constants — the flush triggers (8 MiB / 250 ms defaults).
# / 250 ms defaults). `comptime` so the hot path branches on a constant.
# =============================================================================

comptime FLUSH_BYTES: Int = 8 * 1024 * 1024  # 8 MiB
comptime FLUSH_MS: Int64 = 250  # 250 ms

# Segment footer constants.
comptime SEGMENT_FOOTER_LEN: Int = 40
comptime SEGMENT_FOOTER_MAGIC: UInt32 = 0x31475354  # "TSG1" little-endian
comptime SEGMENT_FOOTER_VERSION: UInt32 = 1


# =============================================================================
# CRC32 (IEEE 802.3) — small standalone implementation (no tree dep).
# Used over the Arrow-stream bytes for the segment footer integrity field.
# =============================================================================


@always_inline
def _crc32_ieee(data: List[UInt8]) -> UInt32:
    """CRC32 (IEEE 802.3, reflected, poly 0xEDB88420). Bytewise — segments are
    flushed at ~250 ms cadence so a table-free bytewise CRC is cheap enough;
    this is integrity, not a hot inner loop."""
    var crc = UInt32(0xFFFFFFFF)
    for i in range(len(data)):
        crc ^= UInt32(Int(data[i]))
        for _ in range(8):
            var mask = UInt32(0)
            if (crc & UInt32(1)) != UInt32(0):
                mask = UInt32(0xEDB88420)
            crc = (crc >> UInt32(1)) ^ mask
    return crc ^ UInt32(0xFFFFFFFF)


# =============================================================================
# Little-endian writers for the footer (POD).
# =============================================================================


@always_inline
def _put_u32_le(mut out: List[UInt8], v: UInt32):
    for i in range(4):
        out.append(UInt8(Int((v >> UInt32(8 * i)) & UInt32(0xFF))))


@always_inline
def _put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8(Int((u >> UInt64(8 * i)) & UInt64(0xFF))))


@always_inline
def _get_u32_le(bytes: List[UInt8], off: Int) raises -> UInt32:
    if off + 4 > len(bytes):
        raise Error("segment footer: truncated u32 at " + String(off))
    var u = UInt32(0)
    for i in range(4):
        u |= UInt32(Int(bytes[off + i])) << UInt32(8 * i)
    return u


@always_inline
def _get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(bytes):
        raise Error("segment footer: truncated i64 at " + String(off))
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


# =============================================================================
# SegmentFooter — the fixed 40-byte trailer.
# =============================================================================


@fieldwise_init
struct SegmentFooter(Copyable, Movable, Deinitable):
    """The fixed-size segment trailer. POD.

    Field layout (see the module header for the byte offsets):
      var base_offset: Int64   — broker pre-commit estimate (-1 if unknown).
      var last_offset: Int64   — broker pre-commit estimate (-1 if unknown).
      var record_count: Int64  — exact record count in this segment.
      var crc32: UInt32        — IEEE CRC32 over the Arrow-stream bytes.
    """

    var base_offset: Int64
    var last_offset: Int64
    var record_count: Int64
    var crc32: UInt32

    def encode(self) -> List[UInt8]:
        """Serialize to the fixed 40-byte little-endian footer."""
        var out = List[UInt8]()
        _put_u32_le(out, SEGMENT_FOOTER_MAGIC)
        _put_u32_le(out, SEGMENT_FOOTER_VERSION)
        _put_i64_le(out, self.base_offset)
        _put_i64_le(out, self.last_offset)
        _put_i64_le(out, self.record_count)
        _put_u32_le(out, self.crc32)
        _put_u32_le(out, UInt32(SEGMENT_FOOTER_LEN))
        return out^

    @staticmethod
    def decode(bytes: List[UInt8]) raises -> SegmentFooter:
        """Parse the trailing 40 bytes of a segment object. `bytes` must be
        the WHOLE segment object (or at least its tail >= 40 bytes); the
        footer is read from `len(bytes) - 40`."""
        var n = len(bytes)
        if n < SEGMENT_FOOTER_LEN:
            raise Error(
                "SegmentFooter.decode: object too small ("
                + String(n)
                + " bytes) to hold a 40-byte footer"
            )
        var base = n - SEGMENT_FOOTER_LEN
        var magic = _get_u32_le(bytes, base + 0)
        if magic != SEGMENT_FOOTER_MAGIC:
            raise Error(
                "SegmentFooter.decode: bad magic 0x"
                + String(Int(magic))
                + " (expected TSG1)"
            )
        var version = _get_u32_le(bytes, base + 4)
        if version != SEGMENT_FOOTER_VERSION:
            raise Error(
                "SegmentFooter.decode: unsupported footer version "
                + String(Int(version))
            )
        return SegmentFooter(
            base_offset=_get_i64_le(bytes, base + 8),
            last_offset=_get_i64_le(bytes, base + 16),
            record_count=_get_i64_le(bytes, base + 24),
            crc32=_get_u32_le(bytes, base + 32),
        )

    @always_inline
    def arrow_stream_len(self, total_object_len: Int) -> Int:
        """The length of the leading Arrow-IPC stream (everything before the
        footer) within a segment object of `total_object_len` bytes."""
        return total_object_len - SEGMENT_FOOTER_LEN


# =============================================================================
# Segment encode — Schema + N RecordBatch frames + EOS + footer.
# =============================================================================


@always_inline
def _append_buffer_bytes(
    mut out: List[UInt8], buf: SharedAlignedBuffer[HeapRegion]
):
    """Copy the bytes of an encoded Arrow IPC frame into `out`. Frames are
    small (one schema + the buffered batches per flush); a bytewise copy is
    fine and keeps the byte-view encapsulated (no UnsafePointer escapes)."""
    var n = buf.len()
    for i in range(n):
        out.append(buf.read_u8_at(i))


def encode_segment(
    var batches: Slab[RecordBatch], pre_commit_base: Int64
) raises -> List[UInt8]:
    """Encode the buffered RecordBatches as one Arrow-IPC segment + footer.

    Layout: Schema frame + RecordBatch frame* + EOS + 40-byte
    footer. The Schema message is taken from the FIRST batch (all buffered
    batches for a partition share one schema — a single producer stream).

    `pre_commit_base` is the broker's pre-commit offset estimate (the manifest
    HEAD's `next_offset` at flush start) stamped into the footer's debug
    offset fields; the AUTHORITATIVE offset range is assigned by the manifest
    append AFTER this segment is PUT.

    Consumes `batches` (the buffer is drained by the flush). `RecordBatch` is
    Movable-only (not Copyable), so the buffer is a `Slab[RecordBatch]` — the
    Movable-only container — NOT `List[RecordBatch]` (the Mojo 1.0.0b1
    `List[T]` requires `T: Copyable` constraint).
    """
    var nb = len(batches)
    if nb == 0:
        raise Error("encode_segment: empty batch buffer (nothing to flush)")

    var stream = List[UInt8]()

    # ---- Schema message frame (from the first batch's schema) ----
    var schema_frame = encode_schema_message(batches[0].schema)
    _append_buffer_bytes(stream, schema_frame)
    _ = schema_frame^

    # ---- One RecordBatch message frame per buffered batch (FIFO order) ----
    # Canonical Slab drain: take_slot_unchecked(i) forward, then
    # set_len_unchecked(0) (the buffer is consumed). Forward iteration
    # preserves produce order within the partition.
    var total_records = Int64(0)
    for i in range(nb):
        var rb = batches.take_slot_unchecked(i)
        total_records += Int64(rb.num_rows())
        var cols = rb.take_columns()
        var rb_frame = encode_record_batch_message(cols^)
        _append_buffer_bytes(stream, rb_frame)
        _ = rb_frame^
        _ = rb^
    batches.set_len_unchecked(0)
    _ = batches^

    # ---- EOS marker ----
    var eos = arrow_ipc_eos_bytes()
    _append_buffer_bytes(stream, eos)
    _ = eos^

    # ---- Footer (CRC over the Arrow-stream bytes only) ----
    var crc = _crc32_ieee(stream)
    var last = pre_commit_base + total_records - Int64(1)
    var footer = SegmentFooter(
        base_offset=pre_commit_base,
        last_offset=last,
        record_count=total_records,
        crc32=crc,
    )
    var footer_bytes = footer.encode()
    for i in range(len(footer_bytes)):
        stream.append(footer_bytes[i])

    return stream^


def encode_record_batch_frame_bytes(var rb: RecordBatch) raises -> List[UInt8]:
    """Encode ONE RecordBatch as its Arrow-IPC RecordBatch message frame bytes
    (the per-batch frame `encode_segment` emits in its loop), returned as an
    owned `List[UInt8]`.

    Used by the coalescing-window produce path (broker_coalescing_produce): a
    producer batch is encoded to its frame bytes ONCE at buffer time (when the
    caller owns the RecordBatch by value), and the buffered item carries the
    Copyable frame bytes — so the coalescing-window codec's `encode` (which
    BORROWS the buffered items by ref + must NOT consume them, for the LIVE
    412-loop re-encode) can re-assemble the segment from the retained frame bytes
    without moving / copying a Movable-only RecordBatch (it has no `copy()`).
    Byte-identical to the per-batch frame `encode_segment` produces."""
    var cols = rb.take_columns()
    var rb_frame = encode_record_batch_message(cols^)
    var out = List[UInt8]()
    _append_buffer_bytes(out, rb_frame)
    _ = rb_frame^
    _ = rb^
    return out^


def assemble_segment_from_frames(
    schema: Schema,
    frame_bytes: List[List[UInt8]],
    total_records: Int64,
    pre_commit_base: Int64,
) raises -> List[UInt8]:
    """Assemble a complete Arrow-IPC segment (Schema frame + the pre-encoded N
    RecordBatch frames + EOS + TSG1 footer) from BORROWED, already-encoded
    per-batch frame bytes — byte-identical to `encode_segment`, but borrow-based
    (no RecordBatch consumed).

    The coalescing-window codec calls this in its `encode` (which
    borrows the buffered items by ref + retains them for a LOST_SLOT re-encode):
    the schema comes from the first buffered item; the frame bytes were encoded at
    buffer time (encode_record_batch_frame_bytes). The footer's offset fields
    carry the broker's pre-commit estimate (debug only — the AUTHORITATIVE offset
    is the manifest append's; the flush paths pass 0)."""
    if len(frame_bytes) == 0:
        raise Error(
            "assemble_segment_from_frames: empty frame list (nothing to flush)"
        )
    var stream = List[UInt8]()

    # ---- Schema message frame (from the first item's schema) ----
    var schema_frame = encode_schema_message(schema)
    _append_buffer_bytes(stream, schema_frame)
    _ = schema_frame^

    # ---- The pre-encoded RecordBatch message frames (FIFO produce order) ----
    for i in range(len(frame_bytes)):
        ref fb = frame_bytes[i]
        for j in range(len(fb)):
            stream.append(fb[j])

    # ---- EOS marker ----
    var eos = arrow_ipc_eos_bytes()
    _append_buffer_bytes(stream, eos)
    _ = eos^

    # ---- Footer (CRC over the Arrow-stream bytes only) ----
    var crc = _crc32_ieee(stream)
    var last = pre_commit_base + total_records - Int64(1)
    var footer = SegmentFooter(
        base_offset=pre_commit_base,
        last_offset=last,
        record_count=total_records,
        crc32=crc,
    )
    var footer_bytes = footer.encode()
    for i in range(len(footer_bytes)):
        stream.append(footer_bytes[i])

    return stream^


# =============================================================================
# Key layout — the segment object key + the manifest prefix.
# =============================================================================
#
#   segment:  <cluster>/topics/<topic>/<partition>/segments/
#             <flush_ts>-<broker_id>-<uuid>.seg
#   manifest: <cluster>/_meta/topics/<topic>/<partition>     (CasManifestStore
#             owns the /manifest/<seq> + /_HEAD layout under this prefix)
#
# The segment key carries NO offset — `flush_ts`-`broker_id`-`uuid`
# is purely for uniqueness + debuggability; two brokers PUT for one partition
# without collision. Ordering is established by which manifest-append wins.
# -----------------------------------------------------------------------------


def _segment_key(
    cluster: String,
    topic: String,
    partition: Int64,
    flush_ts: Int64,
    broker_id: String,
    uniq: Int64,
    proc_nonce: Int64 = Int64(0),
) -> String:
    # Segment-PUT collision by default: the per-process `proc_nonce`
    # (getpid, minted once at core construction) is folded into the key so two
    # broker processes left on the DEFAULT `broker_id` ("kafka-broker") — which
    # otherwise mint an IDENTICAL `<flush_ts>-<broker_id>-<uniq>` key (same
    # ms-tick + a `_seg_counter` that BOTH start at 0) — diverge STRUCTURALLY,
    # not by convention. A `proc_nonce` of 0 reproduces the legacy key exactly
    # (back-compat for callers that pass none — e.g. the offline collision
    # repro that deliberately forces a same-key clash).
    return (
        cluster
        + "/topics/"
        + topic
        + "/"
        + String(partition)
        + "/segments/"
        + String(flush_ts)
        + "-"
        + broker_id
        + "-"
        + String(proc_nonce)
        + "-"
        + String(uniq)
        + ".seg"
    )


@always_inline
def _broker_proc_nonce() -> Int64:
    """The current process id (POSIX `getpid`, a vsyscall). Folded into every
    segment key as the per-process uniquifier. Two broker processes have
    distinct pids, so their segment keys never collide even when both run on
    the default `broker_id` with a `_seg_counter` that started at 0."""
    return Int64(external_call["getpid", Int32]())


@always_inline
def _is_precondition_seg(msg: String) -> Bool:
    """Classify a precondition / 412 CAS-conflict store error (the
    segment-key collision re-key path in `BrokerCore._stage_segment`). Same
    substring convention the CAS-manifest `_is_precondition` uses (the store
    trait raises `Error`, not a typed variant)."""
    return (
        msg.find("precondition") >= 0
        or msg.find("Precondition") >= 0
        or msg.find("412") >= 0
        or msg.find("PreconditionFailed") >= 0
    )


@always_inline
def _is_not_found_msg_bc(msg: String) -> Bool:
    """Classify a not-found / 404 store error (the fold's
    retire-tombstone race in `_recover_seq_in_sublineage`'s TOP-DOWN walk).
    Mirrors `consume_core._is_not_found_msg`."""
    return (
        msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("404") >= 0
        or msg.find("NoSuchKey") >= 0
    )


def _manifest_prefix(cluster: String, topic: String, partition: Int64) -> String:
    return (
        cluster + "/_meta/topics/" + topic + "/" + String(partition)
    )


# =============================================================================
# The manifest chunk body the broker appends: `ManifestBody` +
# `encode_manifest_body` now live in the LEAF module `manifest_body.mojo` (so
# `retention.mojo` can import them without a circular dependency on this file);
# they are re-imported above for back-compat.
# =============================================================================


# =============================================================================
# BrokerTopicConfig — the topic's durable metadata.
# =============================================================================
#
# The topic-config object recorded to S3 at `<cluster>/_meta/topics/<topic>/
# config.json` the FIRST time a producer writes a topic (create-if-absent via
# `conditional_put` + `WritePrecondition.if_none_match_star()`, so concurrent
# producers don't clobber — the loser reads the existing config + validates it
# is consistent, never overwrites). This is the topic's metadata that:
#   * the WHOLE-TOPIC consumer reads to learn `num_partitions` (so it can drain
#     partitions `0..num_partitions-1` — without it a multi-partition topic is
#     only partially consumed);
#   * a consumer can later inherit `partition_by` from to co-partition its read;
#   * the Kafka Metadata API serves as the topic's partition count.
#
# Serialization (a compact JSON object — config is low-rate, written once per
# topic, so JSON's readability is worth the bytes). Layout:
#
#   {"num_partitions":N,"partition_by":["c0","c1"],"schema":[
#      {"name":"key","arrow_type":5,"nullable":false}, ...]}
#
# The schema is serialized as per-column `(name, arrow_type_id, nullable)`
# triples — enough to round-trip the column identity via
# `Field(name, ArrowType(type_id), nullable)` (the Field ctor derives the
# backing DType from the arrow_type). Decimal / timestamp / nested params are
# NOT carried here (topic keys + the broker's day-1 numeric/string column set
# are flat primitives); the AUTHORITATIVE per-record schema is always the
# self-describing Arrow-IPC segment stream — this config schema is the topic's
# DECLARED metadata for validation + the Metadata API, not the read path.
#
# Encapsulation: POD-ish (Int + two Lists + a Schema, all owned values). No
# UnsafePointer in any signature; encode/decode are pure value transforms.
# =============================================================================


def _topic_config_key(cluster: String, topic: String) -> String:
    """The stable S3 key the topic-config object lives at:
    `<cluster>/_meta/topics/<topic>/config.json`. Sibling of the per-partition
    manifest prefixes `<cluster>/_meta/topics/<topic>/<partition_id>` — one
    config per topic, the partition count it declares fans the per-partition
    manifests out."""
    return cluster + "/_meta/topics/" + topic + "/config.json"


def _topics_enum_prefix(cluster: String) -> String:
    """The LIST prefix every per-topic subtree lives directly under:
    `<cluster>/_meta/topics/` (note the trailing `/`). A
    `list_with_delimiter` over this prefix enumerates the cluster's persisted
    topics — each topic's `config.json` object key (and, on a delimiter
    backend, the `<topic>/` common-prefix) folds to the distinct `<topic>`
    segment. Used by the broker's BOOT-time topic discovery: the
    topic-config is the durable record a
    runtime CreateTopics / a producer's first write persists, so a fresh broker
    instance over the same store enumerates it here to re-register topics that
    are NOT in the static config (runtime-created topics survive a restart)."""
    return cluster + "/_meta/topics/"


@always_inline
def _json_escape(s: String) -> String:
    """Escape a String for embedding in a JSON string literal. The broker's
    topic / column names are plain identifiers, but `"` / `\\` are escaped for
    safety so the compact decoder's quote-scan is unambiguous."""
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(34):  # "
            out += String('\\"')
        elif c == UInt8(92):  # backslash
            out += String("\\\\")
        else:
            out += chr(Int(c))
    return out^


def _bytes_find(hay: List[UInt8], needle: List[UInt8], start: Int) -> Int:
    """Return the index of the first occurrence of `needle` in `hay` at/after
    `start`, or -1 if not found. Byte-level (no String indexing — robust on the
    Mojo 1.0.0b1 String codepoint API)."""
    var nlen = len(needle)
    if nlen == 0:
        return start
    var hlen = len(hay)
    var i = start if start >= 0 else 0
    while i + nlen <= hlen:
        var ok = True
        for j in range(nlen):
            if hay[i + j] != needle[j]:
                ok = False
                break
        if ok:
            return i
        i += 1
    return -1


def _str_bytes(s: String) -> List[UInt8]:
    """Owned `List[UInt8]` copy of a String's UTF-8 bytes (for byte-level
    scanning of the config JSON)."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _json_find_after(hay: List[UInt8], key: String, start: Int) -> Int:
    """Return the byte index just AFTER the first occurrence of `key`'s bytes
    at/after `start`, or -1 if not found. Used to seek to a field's value."""
    var needle = _str_bytes(key)
    var idx = _bytes_find(hay, needle, start)
    if idx < 0:
        return -1
    return idx + len(needle)


struct BrokerTopicConfig(Copyable, Movable, Deinitable):
    """The topic's durable metadata — partition count + partition-by keys +
    declared schema. Persisted to S3 once per topic (create-if-absent) by the
    producer; read by the whole-topic consumer + the Metadata API.

    Field layout:
      var num_partitions: Int        — partition fan-out (>= 1).
      var partition_by: List[String] — hash-partition key column names (empty ==
                                       single-partition topic).
      var schema: Schema             — the topic's declared Arrow schema (the
                                       producer's resolved output schema at
                                       first write).
      var retention_ms: Int64        — time-based retention: tombstone a
                                       chunk once `now - creation_ts >
                                       retention_ms`. `-1` == disabled
                                       (infinite retention; the default).
      var retention_bytes: Int64     — size-based retention: tombstone
                                       oldest chunks until cumulative live
                                       bytes from log_start <= retention_bytes.
                                       `-1` == disabled (the default).
      var cleanup_policy: Int64      — Kafka
                                       `cleanup.policy`: 0=delete (time/size
                                       retention, the default), 1=compact
                                       (key-based latest-value log compaction),
                                       2=compact,delete (both). See
                                       log_compaction.CLEANUP_POLICY_*.
      var delete_retention_ms: Int64 — Kafka
                                       `delete.retention.ms`: how long a
                                       compaction TOMBSTONE (null-value record)
                                       is retained after becoming the latest
                                       record for its key, before being dropped.
                                       `-1` == retain forever (the default when
                                       compaction is off).
    """

    var num_partitions: Int
    var partition_by: List[String]
    var schema: Schema
    var retention_ms: Int64
    var retention_bytes: Int64
    var cleanup_policy: Int64
    var delete_retention_ms: Int64

    def __init__(
        out self,
        num_partitions: Int,
        var partition_by: List[String],
        var schema: Schema,
        retention_ms: Int64 = Int64(-1),
        retention_bytes: Int64 = Int64(-1),
        cleanup_policy: Int64 = Int64(0),  # CLEANUP_POLICY_DELETE
        delete_retention_ms: Int64 = Int64(-1),
    ):
        self.num_partitions = num_partitions
        self.partition_by = partition_by^
        self.schema = schema^
        self.retention_ms = retention_ms
        self.retention_bytes = retention_bytes
        self.cleanup_policy = cleanup_policy
        self.delete_retention_ms = delete_retention_ms

    def copy(self) -> Self:
        return Self(
            num_partitions=self.num_partitions,
            partition_by=self.partition_by.copy(),
            schema=self.schema.copy(),
            retention_ms=self.retention_ms,
            retention_bytes=self.retention_bytes,
            cleanup_policy=self.cleanup_policy,
            delete_retention_ms=self.delete_retention_ms,
        )

    def encode(self) -> List[UInt8]:
        """Serialize to a compact JSON object (UTF-8 bytes)."""
        var s = String('{"num_partitions":')
        s += String(self.num_partitions)
        s += String(',"partition_by":[')
        for i in range(len(self.partition_by)):
            if i > 0:
                s += String(",")
            s += String('"') + _json_escape(self.partition_by[i]) + String('"')
        s += String('],"schema":[')
        var nc = self.schema.num_columns()
        for i in range(nc):
            if i > 0:
                s += String(",")
            s += String('{"name":"')
            s += _json_escape(self.schema.field_name(i))
            s += String('","arrow_type":')
            s += String(Int(self.schema.field_arrow_type(i).type_id))
            s += String(',"nullable":')
            s += String("true") if self.schema.field_nullable(i) else String(
                "false"
            )
            s += String("}")
        s += String('],"retention_ms":')
        s += String(self.retention_ms)
        s += String(',"retention_bytes":')
        s += String(self.retention_bytes)
        s += String(',"cleanup_policy":')
        s += String(self.cleanup_policy)
        s += String(',"delete_retention_ms":')
        s += String(self.delete_retention_ms)
        s += String("}")
        var b = s.as_bytes()
        var out = List[UInt8]()
        for i in range(len(b)):
            out.append(b[i])
        return out^

    @staticmethod
    def decode(bytes: List[UInt8]) raises -> BrokerTopicConfig:
        """Parse the compact JSON object written by `encode`. Tolerant
        BYTE-LEVEL forward-scan (the writer is the only producer of this
        format) — finds each field by its key marker, then reads the value.
        Reconstructs the schema from the `(name, arrow_type, nullable)` triples
        via `Field(name, ArrowType(type_id), nullable)` + a `SchemaBuilder`.

        Byte-level (not String-indexed) for robustness on the Mojo 1.0.0b1
        String codepoint API — the config is ASCII JSON so byte == char."""
        var n = len(bytes)

        # num_partitions
        var np_at = _json_find_after(bytes, String('"num_partitions":'), 0)
        if np_at < 0:
            raise Error(
                "BrokerTopicConfig.decode: missing 'num_partitions' field"
            )
        var np = _parse_int_at(bytes, np_at)

        # partition_by: [...]
        var pb_at = _json_find_after(bytes, String('"partition_by":['), 0)
        if pb_at < 0:
            raise Error(
                "BrokerTopicConfig.decode: missing 'partition_by' field"
            )
        var pb = List[String]()
        var p = pb_at
        # Read quoted strings until the closing ']'.
        while p < n:
            # skip whitespace / commas
            while p < n and (bytes[p] == UInt8(32) or bytes[p] == UInt8(44)):
                p += 1
            if p >= n or bytes[p] == UInt8(93):  # ']'
                break
            if bytes[p] == UInt8(34):  # '"'
                var sv = _parse_string_at(bytes, p + 1)
                # COPY the String (not `^`-move) so `sv` destroys whole — Mojo
                # 1.0.0b1 rejects a single-field move out of the middle of a
                # value ("field destroyed out of the middle"). Cheap copy on the
                # cold decode path (matches `ManifestBody.decode`).
                pb.append(String(sv.value))
                p = sv.end
            else:
                break

        # schema: [ {name,arrow_type,nullable}, ... ]
        var sc_marker = _str_bytes(String('"schema":['))
        var sc_at = _bytes_find(bytes, sc_marker, 0)
        if sc_at < 0:
            raise Error("BrokerTopicConfig.decode: missing 'schema' field")
        var sc_start = sc_at + len(sc_marker)
        var builder = SchemaBuilder()
        var name_marker = _str_bytes(String('"name":"'))
        var q = sc_start
        while q < n:
            var name_at = _bytes_find(bytes, name_marker, q)
            if name_at < 0:
                break
            var nv = _parse_string_at(bytes, name_at + len(name_marker))
            var at_at = _json_find_after(bytes, String('"arrow_type":'), nv.end)
            if at_at < 0:
                raise Error(
                    "BrokerTopicConfig.decode: column missing 'arrow_type'"
                )
            var type_id = _parse_int_at(bytes, at_at)
            var null_at = _json_find_after(bytes, String('"nullable":'), at_at)
            if null_at < 0:
                raise Error(
                    "BrokerTopicConfig.decode: column missing 'nullable'"
                )
            var true_marker = _str_bytes(String("true"))
            var nullable = _bytes_find(bytes, true_marker, null_at) == null_at
            # Copy the name String (not `^`-move) so `nv` destroys whole.
            builder.add_field(
                Field(String(nv.value), ArrowType(UInt8(type_id)), nullable)
            )
            q = null_at
        var schema = builder.build()

        # Retention fields — tolerant (missing → -1, so an older config
        # JSON decodes with retention disabled). Both are simple top-level
        # integer fields appended after the schema array.
        var retention_ms = Int64(-1)
        var rm_at = _json_find_after(bytes, String('"retention_ms":'), 0)
        if rm_at >= 0:
            retention_ms = Int64(_parse_int_at(bytes, rm_at))
        var retention_bytes = Int64(-1)
        var rb_at = _json_find_after(bytes, String('"retention_bytes":'), 0)
        if rb_at >= 0:
            retention_bytes = Int64(_parse_int_at(bytes, rb_at))

        # Log-compaction fields — tolerant (missing → delete-default, so a
        # pre-compaction config JSON decodes with cleanup.policy=delete and an
        # infinite tombstone-retention). Simple top-level integer fields.
        var cleanup_policy = Int64(0)  # CLEANUP_POLICY_DELETE
        var cp_at = _json_find_after(bytes, String('"cleanup_policy":'), 0)
        if cp_at >= 0:
            cleanup_policy = Int64(_parse_int_at(bytes, cp_at))
        var delete_retention_ms = Int64(-1)
        var dr_at = _json_find_after(bytes, String('"delete_retention_ms":'), 0)
        if dr_at >= 0:
            delete_retention_ms = Int64(_parse_int_at(bytes, dr_at))

        return BrokerTopicConfig(
            num_partitions=np,
            partition_by=pb^,
            schema=schema^,
            retention_ms=retention_ms,
            retention_bytes=retention_bytes,
            cleanup_policy=cleanup_policy,
            delete_retention_ms=delete_retention_ms,
        )


@fieldwise_init
struct _ParsedString(Movable, Deinitable):
    """Internal: a parsed JSON string + the index just past its closing quote."""

    var value: String
    var end: Int


def _parse_string_at(bytes: List[UInt8], start: Int) -> _ParsedString:
    """Read a JSON string body starting AT `start` (just after the opening
    quote) up to the next unescaped `"`. Handles `\\"` / `\\\\` escapes. Builds
    the value char-by-char from the ASCII bytes (matches `ManifestBody.decode`'s
    `chr(Int(byte))` idiom)."""
    var out = String("")
    var i = start
    var n = len(bytes)
    while i < n:
        var c = bytes[i]
        if c == UInt8(92) and i + 1 < n:  # backslash
            out += chr(Int(bytes[i + 1]))
            i += 2
            continue
        if c == UInt8(34):  # '"'
            break
        out += chr(Int(c))
        i += 1
    return _ParsedString(value=out^, end=i + 1)


def _parse_int_at(bytes: List[UInt8], start: Int) raises -> Int:
    """Read a (possibly negative) decimal integer starting at `start`, skipping
    leading whitespace."""
    var i = start
    var n = len(bytes)
    while i < n and bytes[i] == UInt8(32):  # space
        i += 1
    var sign = 1
    if i < n and bytes[i] == UInt8(45):  # '-'
        sign = -1
        i += 1
    var v = 0
    var saw = False
    while i < n:
        var c = bytes[i]
        if c < UInt8(48) or c > UInt8(57):
            break
        v = v * 10 + Int(c - UInt8(48))
        saw = True
        i += 1
    if not saw:
        raise Error(
            "BrokerTopicConfig.decode: expected integer at " + String(start)
        )
    return sign * v


# =============================================================================
# ProduceResult — what a flush returns (the acked offset range + segment key).
# =============================================================================


@fieldwise_init
struct ProduceResult(Copyable, Movable, Deinitable):
    """The result of a successful flush — the durable ack.

    Field layout:
      var base_offset: Int64   — first committed offset (manifest-assigned).
      var last_offset: Int64   — last committed offset (manifest-assigned).
      var record_count: Int64  — records committed in this flush.
      var segment_key: String  — the S3 key the .seg was PUT at.
      var chunk_seq: Int64     — the manifest chunk slot this commit won.
      var segment_bytes: Int64 — EXACT encoded segment size (size-based
                                 retention;).
      var creation_ts_ms: Int64 — flush wall clock (ms) (time-based
                                 retention;).
    """

    var base_offset: Int64
    var last_offset: Int64
    var record_count: Int64
    var segment_key: String
    var chunk_seq: Int64
    var segment_bytes: Int64
    var creation_ts_ms: Int64


# =============================================================================
# ExactlyOnceFlushResult — the outcome of an exactly-once flush.
# =============================================================================

comptime EO_COMMITTED: Int = 0  # won + appended exactly once
comptime EO_DUPLICATE: Int = 1  # already committed (idempotent ack, no re-write)
comptime EO_FENCED: Int = 2  # stale PRODUCER-EPOCH zombie (no write)
comptime EO_RETRYABLE: Int = 3  # in-flight winner / genuine no-commit
# EO_LEASE_FENCED — a stale PARTITION-OWNERSHIP writer (the
# writer-lease-epoch fence). DISTINCT from EO_FENCED (producer-epoch): the broker
# maps it to NOT_LEADER_OR_FOLLOWER, not INVALID_PRODUCER_EPOCH.
comptime EO_LEASE_FENCED: Int = 4


@fieldwise_init
struct ExactlyOnceFlushResult(Copyable, Movable, Deinitable):
    """The outcome of `flush_with_producer_exactly_once`.

    `outcome` is one of EO_{COMMITTED, DUPLICATE, FENCED, RETRYABLE}. On
    COMMITTED / DUPLICATE the offset fields carry the committed location; on
    FENCED / RETRYABLE they are -1 (the caller maps those to Kafka codes /
    retries). POD. Not a byte-slab element."""

    var outcome: Int
    var base_offset: Int64
    var last_offset: Int64
    var record_count: Int64
    var chunk_seq: Int64


# =============================================================================
# BrokerCore[Storage] — the concrete, NON-[Protocol] broker core.
# =============================================================================


struct BrokerCore[Storage: ConditionalWriteStore](Movable, Deinitable):
    """The Komira broker's concrete data-plane core.

    NON-GENERIC over wire protocol — operates ONLY on `RecordBatch` + offsets.
    Parametrized solely over the storage backend `Storage` (a backend selector,
    not a per-request multiplier).

    Scope: PRODUCE, ONE partition per core instance, single-threaded
    produce. Consume lives in ConsumeCore; protocol codecs live in edge
    structs above this core.

    Ownership:
      * `_segment_store: Storage` — owned by value; PUTs the `.seg` objects.
      * `_manifest: CasManifestStore[Storage]` — owned by value; the offset
        allocator (append = commit = assign offset range).
      * The write buffer (`_buffer` + `_buffer_bytes` + `_oldest_ts_ms`) is the
        per-partition in-memory accumulator.

    Fields:
      var _segment_store: Storage
      var _manifest: CasManifestStore[Storage]
      var _cluster: String
      var _topic: String
      var _partition: Int64
      var _broker_id: String
      var _buffer: Slab[RecordBatch]   — buffered batches awaiting flush
                                          (Slab, not List — RecordBatch is
                                          Movable-only, not Copyable).
      var _buffer_bytes: Int           — running byte estimate for the trigger.
      var _oldest_ts_ms: Int64         — wall ts of the oldest buffered batch
                                          (-1 = empty), for the time trigger.
      var _seg_counter: Int64          — monotone segment uniquifier (stands in
                                          for a uuid; unique per core).
      var _flush_fence: FlushFence     — the cached lease fence + the
                                          leaked-segment counters.
    """

    var _segment_store: Self.Storage
    var _manifest: CasManifestStore[Self.Storage]
    var _cluster: String
    var _topic: String
    var _partition: Int64
    var _broker_id: String
    var _buffer: Slab[RecordBatch]
    var _buffer_bytes: Int
    var _oldest_ts_ms: Int64
    var _seg_counter: Int64
    # Segment-PUT collision by default: per-process nonce (getpid),
    # minted ONCE at construction + folded into every segment key so two broker
    # processes on the DEFAULT broker_id structurally never mint a colliding
    # segment key. Belt-and-suspenders with the collision-safe staged PUT
    # (`_stage_segment` uses `if_none_match_star` + re-key on a 412), which
    # fails LOUD + re-keys on the residual same-key race.
    var _proc_nonce: Int64
    # Stale-HEAD forward progress: an IN-PROCESS per-producer
    # last-COMMITTED-sequence cache (parallel POD Int64 lists — no
    # heap-owning inner fields). Advanced ONLY on a CONFIRMED commit (never a
    # pre-commit reservation — that earlier design lost records via a
    # stale-reservation window), so it can never manufacture a false DUPLICATE.
    # An idempotent producer holds ONE direct connection to ONE broker process,
    # so for that connection THIS process is the sole writer of the producer's
    # sequence → the cache is EXACT for the hot dedupe path (zero S3 read on a
    # hit). Seeded lazily from an authoritative manifest scan on a cache miss
    # (fresh producer / broker restart); a phantom-durable commit advances it
    # via the produce handler's raise-path re-check.
    var _producer_ids: List[Int64]
    var _producer_last_seq: List[Int64]
    # The disjoint-keyspace WRITE-path sub-lineage SHARDING mode. DEFAULT OFF:
    # when `_sublineage_write_enabled` is False (the constructed default), every
    # flush appends to the consolidated single-partition `_manifest`. When
    # enabled via `enable_sublineage_write`, the manifest-append target switches
    # to `_sublineage_manifest` (a PLAIN `CasManifestStore` over this writer's
    # OWN sub-lineage prefix `<partition>/_lineage/<shard_id>`), so a distinct
    # writer instance owns a distinct `_HEAD` slot → zero cross-writer
    # create-CAS contention. Consumers must read through the sub-lineage `_base`
    # fold (sublineage_consume) once writers are sharded; a consumer that reads
    # only the single manifest would see an empty stream — hence default-OFF.
    #
    # `_LOG_START` (the retention boundary) STAYS on the consolidated `_manifest`
    # and is NOT sharded (the shared retention boundary across shards): only the
    # per-append `_HEAD` create-CAS slot is sharded. The create-CAS base-offset
    # oracle reads the PER-SHARD `_HEAD` automatically (each sub-lineage is its
    # own `CasManifestStore` reading its own `_HEAD`).
    var _sublineage_write_enabled: Bool
    var _shard_id: String
    var _sublineage_manifest: Optional[CasManifestStore[Self.Storage]]
    # The refuse-before-PUT fence: the highest lease epoch seen fencing a
    # writer of this partition, and the counts of refused / leaked /
    # possibly-leaked `.seg` objects (see `flush_fence.mojo`).
    var _flush_fence: FlushFence

    def __init__(
        out self,
        var segment_store: Self.Storage,
        var manifest: CasManifestStore[Self.Storage],
        var cluster: String,
        var topic: String,
        partition: Int64,
        var broker_id: String,
    ):
        """Construct a single-partition broker core. `segment_store` PUTs the
        `.seg` objects; `manifest` is the partition's offset allocator (already
        bound to the partition's manifest prefix by the caller).

        Sub-lineage write mode is DEFAULT OFF — a freshly-constructed core
        appends to the consolidated single-partition `manifest`. Enable it
        explicitly via `enable_sublineage_write`."""
        self._segment_store = segment_store^
        self._manifest = manifest^
        # A broker partition's chunks are reaped below `_LOG_START`, so its
        # writer must never acknowledge a win in a reaped slot (#486): opt in to
        # the manifest's reaped-slot guard (one GET per acknowledged append).
        self._manifest.enable_reaped_slot_guard()
        self._cluster = cluster^
        self._topic = topic^
        self._partition = partition
        self._broker_id = broker_id^
        self._buffer = Slab[RecordBatch]()
        self._buffer_bytes = 0
        self._oldest_ts_ms = Int64(-1)
        self._seg_counter = Int64(0)
        self._proc_nonce = _broker_proc_nonce()
        self._producer_ids = List[Int64]()
        self._producer_last_seq = List[Int64]()
        # Default OFF — no sub-lineage manifest, no shard_id.
        self._sublineage_write_enabled = False
        self._shard_id = String("")
        self._sublineage_manifest = None
        self._flush_fence = FlushFence()

    @always_inline
    def topic(self) -> String:
        return self._topic

    @always_inline
    def partition(self) -> Int64:
        return self._partition

    @always_inline
    def buffered_batches(self) -> Int:
        return len(self._buffer)

    @always_inline
    def buffered_bytes(self) -> Int:
        return self._buffer_bytes

    # -------------------------------------------------------------------------
    # The disjoint-keyspace WRITE-path
    # sub-lineage SHARDING toggle + the manifest-append router.
    # -------------------------------------------------------------------------

    @always_inline
    def sublineage_write_enabled(self) -> Bool:
        """True iff this core appends to its OWN sub-lineage (`<partition>/
        _lineage/<shard_id>`) instead of the consolidated single-partition
        manifest. DEFAULT FALSE."""
        return self._sublineage_write_enabled

    @always_inline
    def shard_id(self) -> String:
        """This core's sub-lineage shard_id when sub-lineage write is enabled (the
        empty string when disabled). Stable for the core's lifetime — minted ONCE
        at `enable_sublineage_write`."""
        return self._shard_id

    @always_inline
    def sublineage_prefix_for(self, shard_id: String) -> String:
        """The sub-lineage manifest prefix THIS core's writer would use for
        `shard_id`: `<cluster>/_meta/topics/<topic>/<partition>/
        _lineage/<shard_id>`. The wiring layer (data_broker / a test) calls this
        to build the per-shard `CasManifestStore` it then hands to
        `enable_sublineage_write` — so the core owns the PREFIX SHAPE (keyed on its
        own cluster/topic/partition) while the store-construction capability stays
        in the wiring layer (the metastore knows its
        prefix, the caller knows how to mint a store)."""
        return sublineage_prefix(
            _manifest_prefix(self._cluster, self._topic, self._partition),
            shard_id,
        )

    def enable_sublineage_write(
        mut self,
        var shard_id: String,
        var sublineage_manifest: CasManifestStore[Self.Storage],
        generation_tag: Int64 = Int64(0),
    ) raises:
        """Switch THIS core's manifest-append target to its OWN sub-lineage
        `<partition>/_lineage/<shard_id>` (the disjoint
        keyspace that makes concurrent writers contention-free).

        `shard_id` MUST be collision-free across concurrent writers (mint it via
        `partition_assignment.mint_shard_id(instance_id, worker_idx)` — which folds
        `getpid` + a per-boot nonce so a reused instance_id/pid can't collide).
        `sublineage_manifest` is a PLAIN `CasManifestStore` the WIRING LAYER
        has already bound to `self.sublineage_prefix_for(shard_id)` — the core
        does NOT mint the store itself, because the clone capability lives on the
        refining `CloneableConditionalWriteStore` trait the wiring layer holds, not
        on this core's `ConditionalWriteStore` bound (prefix here,
        store-construction in the caller). It MUST be bound to the sub-lineage
        prefix (the core trusts the caller — `sublineage_prefix_for` is the
        canonical way to compute it). ZERO `CasManifestStore` change — the sharding
        lives entirely in the prefix.

        `generation_tag` is the partition's current lease generation —
        DEFENSE-IN-DEPTH: a displaced prior-owner is fenced by
        generation even in the (collision-free-by-construction) impossible event
        two writers ever shared a shard_id. It does NOT change the sub-lineage
        prefix (the prefix is keyed by shard_id alone); the flush already threads
        the live generation through `writer_lease_epoch`/`current_lease_epoch`, so
        we keep the parameter only for a self-documenting enable signature.

        The consolidated `_manifest` stays OWNED (it remains the `_LOG_START`
        retention-boundary home + the flag-OFF target), so disabling/round-
        tripping is a pure field toggle. Raises on an empty `shard_id`."""
        if shard_id.byte_length() == 0:
            raise Error(
                "BrokerCore.enable_sublineage_write: shard_id must be non-empty"
                " (mint it via partition_assignment.mint_shard_id)"
            )
        # Sub-lineage chunks are retired and reaped too: same opt-in as the
        # consolidated manifest (#486).
        sublineage_manifest.enable_reaped_slot_guard()
        self._sublineage_manifest = Optional[CasManifestStore[Self.Storage]](
            sublineage_manifest^
        )
        self._shard_id = shard_id^
        self._sublineage_write_enabled = True
        _ = generation_tag

    @always_inline
    def _active_manifest_prefix(self) raises -> String:
        """The manifest lineage prefix the next flush will append to (the
        consolidated `_manifest` prefix when flag-OFF, the sub-lineage prefix when
        flag-ON). Exposed for tests/observability — confirms the write-slot
        DECOUPLING (the append target) from the consolidated `_LOG_START` home."""
        if self._sublineage_write_enabled and self._sublineage_manifest:
            return self._sublineage_manifest.value().prefix()
        return self._manifest.prefix()

    def _append_active(
        mut self,
        var body: List[UInt8],
        record_count: Int64,
        writer_lease_epoch: Int64,
        current_lease_epoch: Int64,
    ) raises -> AppendResult:
        """Route an at-least-once manifest append to the ACTIVE lineage: the
        per-shard `_sublineage_manifest` when sub-lineage write is enabled, else
        the consolidated `_manifest` (the flag-OFF path is byte-identical to the
        `self._manifest.append(...)` call). The create-CAS oracle +
        the per-shard `_HEAD` base-offset read are entirely inside whichever
        `CasManifestStore` we route to — the write-slot location is thus decoupled
        from the consolidated `_LOG_START` retention boundary (which stays on
        `_manifest`)."""
        if self._sublineage_write_enabled and self._sublineage_manifest:
            return self._sublineage_manifest.value().append(
                body^, record_count, writer_lease_epoch, current_lease_epoch
            )
        return self._manifest.append(
            body^, record_count, writer_lease_epoch, current_lease_epoch
        )

    def _append_idempotent_active(
        mut self,
        var body: List[UInt8],
        record_count: Int64,
        producer_id: Int64,
        producer_epoch: Int64,
        first_seq: Int64,
        last_seq: Int64,
        registered_epoch: Int64,
        writer_lease_epoch: Int64,
        current_lease_epoch: Int64,
    ) raises -> IdempotentAppendResult:
        """Route an EXACTLY-ONCE manifest append (the sentinel protocol) to the
        ACTIVE lineage — sub-lineage when enabled, else the consolidated manifest
        (flag-OFF byte-identical). The dedup sentinel is keyed under whichever
        lineage's prefix we route to (per-shard when sharded), which is correct: a
        single idempotent producer holds ONE connection to ONE writer core, so its
        sentinel co-locates with the lineage that core writes."""
        if self._sublineage_write_enabled and self._sublineage_manifest:
            return self._sublineage_manifest.value().append_idempotent(
                body^,
                record_count,
                producer_id,
                producer_epoch,
                first_seq,
                last_seq,
                registered_epoch,
                writer_lease_epoch,
                current_lease_epoch,
            )
        return self._manifest.append_idempotent(
            body^,
            record_count,
            producer_id,
            producer_epoch,
            first_seq,
            last_seq,
            registered_epoch,
            writer_lease_epoch,
            current_lease_epoch,
        )

    # -------------------------------------------------------------------------
    # The refuse-before-PUT fence and the leaked-segment counters.
    # -------------------------------------------------------------------------

    @always_inline
    def is_fenced(self) -> Bool:
        """True once a flush of this partition has been fenced: refused at
        entry, or refused by the manifest after its PUT. This core serves ONE
        partition, so the query takes no partition id.

        The node driver must DROP the partition when this turns true: stop
        serving it and discard this core. Every later flush below the cached
        fence is refused before its PUT (no `.seg` leaks), but only the driver
        can stop the producers. No node driver exists on main yet; until one
        does, nothing reads this."""
        return self._flush_fence.is_fenced()

    @always_inline
    def fence_epoch(self) -> Int64:
        """The cached fence: a flush whose `writer_lease_epoch` is below it is
        refused before its PUT. 0 when none was recorded."""
        return self._flush_fence.fence_epoch()

    @always_inline
    def flush_leak_stats(self) -> FlushLeakStats:
        """Flushes refused before the PUT, fenced after it (`.seg` leaked),
        and unknown-outcome appends (`.seg` possibly leaked)."""
        return self._flush_fence.stats()

    def _refused_at_entry(
        mut self, writer_lease_epoch: Int64, current_lease_epoch: Int64
    ) -> Bool:
        """True iff a flush at `(writer, current)` must be refused before its
        `.seg` PUT: `writer < current`, or `writer` below the cached fence.
        On a refusal the buffered batches are dropped (a flush fenced by the
        manifest dropped them too), the refusal is counted, and `current` is
        recorded as a fence. No I/O."""
        if not self._flush_fence.refuses(writer_lease_epoch, current_lease_epoch):
            return False
        self._buffer = Slab[RecordBatch]()
        self._buffer_bytes = 0
        self._oldest_ts_ms = Int64(-1)
        self._flush_fence.note_refused(current_lease_epoch)
        return True

    # -------------------------------------------------------------------------
    # produce — append to the write buffer; flush if a trigger fires.
    # -------------------------------------------------------------------------

    def produce(
        mut self, var rb: RecordBatch, now_ms: Int64
    ) raises -> Optional[ProduceResult]:
        """Append `rb` to the per-partition write buffer and
        flush if the size OR time trigger fires (step 3 of the produce path).

        `now_ms` is the caller's wall clock (ms) — passed in (not read here)
        so the core stays clock-source-agnostic and deterministically testable.

        Returns `Some(ProduceResult)` if this produce caused a flush (the
        durable ack for the flushed segment), else `None` (records buffered,
        not yet acked). The producer is acked (durability contract
        step 6) only when a `ProduceResult` is returned — buffered-but-not-
        flushed records are NOT yet durable.

        The auto-flush runs at the default epochs (0, 0). Once this core is
        fenced (`is_fenced()`), that flush is below the cached fence: it
        raises `lease_fenced` before any `.seg` PUT and drops the buffer,
        `rb` included. Every dropped batch is unacked (each earlier produce
        returned `None`), so the producer retries against the new owner.
        """
        var est = _estimate_batch_bytes(rb)
        if self._oldest_ts_ms < Int64(0):
            self._oldest_ts_ms = now_ms
        self._buffer.append(rb^)
        self._buffer_bytes += est

        if self._should_flush(now_ms):
            return Optional[ProduceResult](self.flush(now_ms))
        return Optional[ProduceResult](None)

    def buffer_batch(mut self, var rb: RecordBatch, now_ms: Int64) raises:
        """Append `rb` to the write buffer WITHOUT evaluating the flush trigger.
        Used by the producer-aware (idempotent) path, which decides the flush itself
        (via `flush_with_producer`) so the producer trailer is always folded
        into the manifest body — never auto-flushed without it."""
        var est = _estimate_batch_bytes(rb)
        if self._oldest_ts_ms < Int64(0):
            self._oldest_ts_ms = now_ms
        self._buffer.append(rb^)
        self._buffer_bytes += est

    @always_inline
    def _should_flush(self, now_ms: Int64) -> Bool:
        """Produce-path step 3: flush at FLUSH_BYTES OR FLUSH_MS, whichever first."""
        if len(self._buffer) == 0:
            return False
        if self._buffer_bytes >= FLUSH_BYTES:
            return True
        if self._oldest_ts_ms >= Int64(0):
            var age = now_ms - self._oldest_ts_ms
            if age >= FLUSH_MS:
                return True
        return False

    # -------------------------------------------------------------------------
    # _stage_segment — collision-safe segment PUT (fail-LOUD + re-key).
    # -------------------------------------------------------------------------

    def _stage_segment(
        mut self, now_ms: Int64, var seg_bytes: List[UInt8]
    ) raises -> String:
        """PUT the encoded `.seg` bytes at a STRUCTURALLY-UNIQUE key and return
        the key that landed.

        The PUT is
        a CREATE (`If-None-Match: *`) so a colliding key FAILS LOUD (412) instead
        of silently overwriting another node's segment + losing its records. On
        a collision we bump `_seg_counter` (+ the per-process `_proc_nonce` makes
        the next key diverge immediately across processes) and RE-KEY, bounded.

        The segment key carries no offset; the manifest append (step
        5, the caller) is the offset allocator + ordering point — re-keying the
        SEGMENT here is free (the key is purely a unique content address; only
        the manifest body's reference to it is load-bearing). A 412 usually means
        another writer holds the key; but if an earlier attempt's create
        landed and only its response was lost, a retried create can 412 on
        our OWN object, which re-keying then leaves behind unreferenced.
        Either way no offset is consumed (the manifest append has not run
        yet).

        The PUT is the point of no return: if the manifest append that follows
        fails or is fenced, the `.seg` stays unreferenced, and nothing deletes
        an unreferenced `.seg` today (komira-ai/komira#488). Callers refuse a
        known-stale writer before calling this (`_refused_at_entry`)."""
        var attempts = 0
        while attempts < 8:
            attempts += 1
            self._seg_counter += Int64(1)
            var seg_key = _segment_key(
                self._cluster,
                self._topic,
                self._partition,
                now_ms,
                self._broker_id,
                self._seg_counter,
                self._proc_nonce,
            )
            try:
                var put_meta = self._segment_store.conditional_put(
                    Path.parse(seg_key),
                    seg_bytes.copy(),
                    WritePrecondition.if_none_match_star(),
                )
                _ = put_meta
                return seg_key^
            except e:
                # A 412 means the key already exists (another node/process minted
                # the same `<flush_ts>-<broker_id>-<nonce>-<uniq>`). Re-key + retry
                # (fail-LOUD, never silent overwrite). Any non-412 is a real
                # store error — propagate.
                if _is_precondition_seg(String(e)):
                    continue
                raise e^
        raise Error(
            "BrokerCore._stage_segment: exhausted segment-key re-key attempts"
            " under collision (retryable)"
        )

    # -------------------------------------------------------------------------
    # flush — encode segment, PUT, manifest-commit, ack.
    # -------------------------------------------------------------------------

    def flush(
        mut self,
        now_ms: Int64,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ) raises -> ProduceResult:
        """Encode the buffered batches as one segment, PUT it to the object store, commit the
        offset range via the manifest append, and return the durable ack.

        Produce-path steps 4-6:
          4. PUT the segment object (key carries no offset).
          5. APPEND the manifest chunk → assigns the contiguous offset range
             (the append IS the allocator).
          6. ACK: this function returning without raising IS the ack — both the
             PUT and the manifest commit have landed (acked == durable).

        Raises if the buffer is empty (nothing to flush), or if either the PUT
        or the manifest append fails (in which case NO ack — the producer must
        retry). A PUT-but-no-commit leaves an unreferenced `.seg` and no
        offset gap; nothing deletes that `.seg` today (komira-ai/komira#488).

        Raises `lease_fenced` BEFORE the PUT (no `.seg` written) when
        `writer_lease_epoch` is below `current_lease_epoch` or below the
        cached fence (`fence_epoch`); the buffered batches are dropped. The
        default epochs (0, 0) are not a no-op: they pass only while the core
        is unfenced.
        """
        if len(self._buffer) == 0:
            raise Error("BrokerCore.flush: empty buffer (nothing to flush)")
        if self._refused_at_entry(writer_lease_epoch, current_lease_epoch):
            raise Error(
                self._flush_fence.refusal_message(
                    "flush", writer_lease_epoch, current_lease_epoch
                )
            )

        # SKIP the pre-flush `read_head` GET. Its ONLY consumer would be the
        # segment footer's DEBUG `base_offset`/`last_offset` fields
        # (`encode_segment`'s `pre_commit_base`) — NOT load-bearing: the
        # consumer resolves every offset from the MANIFEST append's running sum,
        # never the footer (see the note on the footer's offset fields in the
        # consume_core module header, and read_segment, which returns the
        # manifest's `seg.base_offset`/`seg.last_offset` and uses the footer ONLY
        # for `arrow_stream_len` + the CRC integrity cross-check). The
        # AUTHORITATIVE offset range is assigned by the manifest append (step 5)
        # regardless. So a 0 estimate is harmless and saves one object-store
        # round-trip per durable ack. The exactly-once twin
        # `flush_with_producer_exactly_once` seeds `Int64(0)` the same way.
        var pre_commit_base = Int64(0)

        # ---- Step 4 prep: drain the buffer + encode the segment ----
        var batches = self._buffer^
        self._buffer = Slab[RecordBatch]()
        self._buffer_bytes = 0
        self._oldest_ts_ms = Int64(-1)

        var seg_bytes = encode_segment(batches^, pre_commit_base)

        # Record count + CRC are exact at PUT time (re-derive from the footer).
        var footer = SegmentFooter.decode(seg_bytes)
        var record_count = footer.record_count
        var crc = footer.crc32
        # Retention: capture the EXACT segment size BEFORE `seg_bytes` is
        # ^-moved into the PUT (size-based retention reads this).
        var segment_bytes = Int64(len(seg_bytes))

        # ---- Step 4: PUT the segment object (no offset in the key) ----
        # Collision-safe staged PUT (If-None-Match:* + re-key on a 412).
        var seg_key = self._stage_segment(now_ms, seg_bytes^)

        # ---- Step 5: commit via the manifest append (assigns the offsets) ----
        # `now_ms` is the segment's creation timestamp (time-based retention).
        var body = encode_manifest_body(
            seg_key, record_count, crc, segment_bytes, now_ms
        )
        # Branch on the sub-lineage flag — flag-OFF routes to the consolidated
        # `_manifest`,
        # flag-ON routes to this writer's own sub-lineage `_HEAD` slot.
        var append_res: AppendResult
        try:
            append_res = self._append_active(
                body^, record_count, writer_lease_epoch, current_lease_epoch
            )
        except e:
            # After the PUT: count the leak, cache a fence.
            self._flush_fence.note_append_raise(String(e), writer_lease_epoch)
            raise e^

        # ---- Step 6: ACK (return == durable ack) ----
        return ProduceResult(
            base_offset=append_res.base_offset,
            last_offset=append_res.last_offset,
            record_count=record_count,
            segment_key=seg_key^,
            chunk_seq=append_res.chunk_seq,
            segment_bytes=segment_bytes,
            creation_ts_ms=now_ms,
        )

    def flush_if_buffered(
        mut self,
        now_ms: Int64,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ) raises -> Optional[ProduceResult]:
        """Force a flush of any buffered records (e.g. on a time-tick or a
        clean shutdown). Returns `None` if the buffer is empty. The lease epochs
        go to `flush`, which refuses a writer below `current_lease_epoch` or
        below the cached fence. The defaults (0, 0) pass only while the core
        is unfenced: once `fence_epoch() > 0` they raise `lease_fenced`."""
        if len(self._buffer) == 0:
            return Optional[ProduceResult](None)
        return Optional[ProduceResult](
            self.flush(now_ms, writer_lease_epoch, current_lease_epoch)
        )

    # -------------------------------------------------------------------------
    # Idempotence — producer-aware flush + sequence recovery.
    # -------------------------------------------------------------------------

    def flush_with_producer(
        mut self,
        now_ms: Int64,
        producer_id: Int64,
        producer_epoch: Int64,
        first_seq: Int64,
        last_seq: Int64,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ) raises -> ProduceResult:
        """Flush the buffered records like `flush`, but FOLD the producer
        sequence state `(producer_id, producer_epoch, first_seq, last_seq)`
        into the manifest body so it is committed ATOMICALLY in the SAME
        `If-None-Match` manifest append that links the segment (the
        idempotent-producer durability invariant). A `producer_id` of -1 produces a
        non-idempotent body (identical to `flush`).

        The sequence advances exactly once ⟺ this append wins its slot. A
        broker that PUTs the .seg then dies BEFORE the append leaves the
        sequence un-advanced — the producer's retry is then treated as the
        first attempt (no double-write, no false-dedup).

        Refuses a stale writer with `lease_fenced` before the PUT, as `flush`
        does."""
        if len(self._buffer) == 0:
            raise Error("BrokerCore.flush_with_producer: empty buffer")
        if self._refused_at_entry(writer_lease_epoch, current_lease_epoch):
            raise Error(
                self._flush_fence.refusal_message(
                    "flush_with_producer", writer_lease_epoch, current_lease_epoch
                )
            )

        # SKIP the pre-flush `read_head` GET — see the `flush` variant for the
        # full rationale. `pre_commit_base` seeds ONLY the segment footer's
        # DEBUG offset fields (the consumer resolves offsets from the manifest,
        # never the footer), so a 0 estimate is harmless and trims one
        # object-store round-trip per durable ack. The exactly-once twin
        # `flush_with_producer_exactly_once` seeds `Int64(0)` the same way.
        var pre_commit_base = Int64(0)

        var batches = self._buffer^
        self._buffer = Slab[RecordBatch]()
        self._buffer_bytes = 0
        self._oldest_ts_ms = Int64(-1)

        var seg_bytes = encode_segment(batches^, pre_commit_base)
        var footer = SegmentFooter.decode(seg_bytes)
        var record_count = footer.record_count
        var crc = footer.crc32
        var segment_bytes = Int64(len(seg_bytes))

        # Collision-safe staged PUT (If-None-Match:* + re-key on a 412).
        var seg_key = self._stage_segment(now_ms, seg_bytes^)

        # The manifest body now carries the producer trailer — committed in
        # the same atomic append.
        var body = encode_manifest_body(
            seg_key,
            record_count,
            crc,
            segment_bytes,
            now_ms,
            producer_id,
            producer_epoch,
            first_seq,
            last_seq,
        )
        # Route to the active lineage (sub-lineage or consolidated).
        var append_res: AppendResult
        try:
            append_res = self._append_active(
                body^, record_count, writer_lease_epoch, current_lease_epoch
            )
        except e:
            # After the PUT: count the leak, cache a fence.
            self._flush_fence.note_append_raise(String(e), writer_lease_epoch)
            raise e^

        # Stale-HEAD forward progress: the commit LANDED (the append
        # won its slot) — advance the in-process per-producer cache so the next
        # produce on this connection is a read-free dedupe hit.
        self.note_committed_seq(producer_id, last_seq)

        return ProduceResult(
            base_offset=append_res.base_offset,
            last_offset=append_res.last_offset,
            record_count=record_count,
            segment_key=seg_key^,
            chunk_seq=append_res.chunk_seq,
            segment_bytes=segment_bytes,
            creation_ts_ms=now_ms,
        )

    # -------------------------------------------------------------------------
    # EXACTLY-ONCE flush via the producer-batch dedup sentinel.
    #
    # -------------------------------------------------------------------------

    def flush_with_producer_exactly_once(
        mut self,
        now_ms: Int64,
        producer_id: Int64,
        producer_epoch: Int64,
        first_seq: Int64,
        last_seq: Int64,
        registered_epoch: Int64,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ) raises -> ExactlyOnceFlushResult:
        """Flush the buffered records like `flush_with_producer`, but commit via
        the EXACTLY-ONCE sentinel protocol (`CasManifestStore.append_idempotent`)
        instead of the at-least-once `append`. The producer-batch identity
        `(producer_id, first_seq)` is claimed by an `If-None-Match` create-CAS
        (the SINGLE cross-process linearization point for commission) BEFORE the
        chunk append, so a cross-process same-producer duplicate loses at the
        sentinel (never reaches a second chunk slot), and a phantom-success
        (chunk durable, ack lost) returns the recorded offset with NO re-append.

        Returns `ExactlyOnceFlushResult{outcome, base_offset, last_offset,
        record_count, chunk_seq}`:
          * COMMITTED  — we won + appended exactly once.
          * DUPLICATE  — already committed (idempotent ack; the recorded offset
                         is returned, NO re-write).
          * FENCED     — stale-epoch zombie (no write).
          * RETRYABLE  — in-flight winner / genuine no-commit (the caller maps
                         it to a retriable Kafka code; the buffered records are
                         RE-STAGED so the client retry re-drives cleanly).

        The segment `.seg` is PUT before the sentinel claim (a create at a
        fresh key). A DUPLICATE / FENCED / RETRYABLE / LEASE_FENCED outcome
        leaves that `.seg` unreferenced (no offset is consumed), and nothing
        deletes an unreferenced `.seg` today (komira-ai/komira#488). On a
        DUPLICATE / FENCED / RETRYABLE we drop the buffered batches WITHOUT
        advancing the offset log; on RETRYABLE the caller is responsible for
        re-buffering.

        A writer below `current_lease_epoch` or the cached fence gets
        `EO_LEASE_FENCED` BEFORE the PUT (no `.seg` written, the buffered
        batches dropped). This check runs before the manifest's producer-epoch
        check, so a call stale on both counts reports LEASE_FENCED."""
        if len(self._buffer) == 0:
            raise Error(
                "BrokerCore.flush_with_producer_exactly_once: empty buffer"
            )
        if self._refused_at_entry(writer_lease_epoch, current_lease_epoch):
            return ExactlyOnceFlushResult(
                EO_LEASE_FENCED, Int64(-1), Int64(-1), Int64(0), Int64(-1)
            )

        # SKIP the pre-flush `read_head` GET. The exactly-once path's
        # `append_idempotent` reads HEAD authoritatively inside `_append_inner`
        # (and assigns the AUTHORITATIVE offset range there), so a second
        # pre-flush HEAD read is pure redundant latency on the contended hot
        # path. `pre_commit_base` only seeds the segment footer's DEBUG offset
        # fields (NOT load-bearing — the consumer resolves offsets from the
        # manifest, never the footer), so a 0 estimate is harmless. This keeps
        # the sentinel's create-CAS from adding a round-trip over the
        # at-least-once flush (it swaps the redundant GET for the sentinel PUT).
        var pre_commit_base = Int64(0)

        var batches = self._buffer^
        self._buffer = Slab[RecordBatch]()
        self._buffer_bytes = 0
        self._oldest_ts_ms = Int64(-1)

        var seg_bytes = encode_segment(batches^, pre_commit_base)
        var footer = SegmentFooter.decode(seg_bytes)
        var record_count = footer.record_count
        var crc = footer.crc32
        var segment_bytes = Int64(len(seg_bytes))

        # Collision-safe staged PUT (If-None-Match:* + re-key on a 412).
        var seg_key = self._stage_segment(now_ms, seg_bytes^)

        var body = encode_manifest_body(
            seg_key,
            record_count,
            crc,
            segment_bytes,
            now_ms,
            producer_id,
            producer_epoch,
            first_seq,
            last_seq,
        )
        # Route the exactly-once append to the active lineage (sub-lineage or
        # consolidated).
        var ir: IdempotentAppendResult
        try:
            ir = self._append_idempotent_active(
                body^,
                record_count,
                producer_id,
                producer_epoch,
                first_seq,
                last_seq,
                registered_epoch,
                writer_lease_epoch,  # the partition-ownership fence
                current_lease_epoch,
            )
        except e:
            # After the PUT: count the leak, cache a fence.
            self._flush_fence.note_append_raise(String(e), writer_lease_epoch)
            raise e^

        if ir.outcome == IDEMPOTENT_COMMITTED:
            # The commit LANDED — advance the in-process per-producer cache so
            # the next produce on this connection is a read-free dedupe hit.
            self.note_committed_seq(producer_id, last_seq)
            return ExactlyOnceFlushResult(
                EO_COMMITTED,
                ir.base_offset,
                ir.last_offset,
                record_count,
                ir.chunk_seq,
            )
        if ir.outcome == IDEMPOTENT_DUPLICATE:
            # Already committed (idempotent) — advance the cache to the recorded
            # last_seq + return the recorded offset, NO re-write.
            self.note_committed_seq(producer_id, last_seq)
            return ExactlyOnceFlushResult(
                EO_DUPLICATE,
                ir.base_offset,
                ir.last_offset,
                record_count,
                ir.chunk_seq,
            )
        if ir.outcome == IDEMPOTENT_FENCED:
            return ExactlyOnceFlushResult(
                EO_FENCED, Int64(-1), Int64(-1), Int64(0), Int64(-1)
            )
        if ir.outcome == IDEMPOTENT_LEASE_FENCED:
            # The partition-OWNERSHIP fence (distinct from the
            # producer-epoch EO_FENCED). The broker maps it to
            # NOT_LEADER_OR_FOLLOWER. Unreachable today: the manifest checks
            # only the `(writer, current)` pair `_refused_at_entry` already
            # passed. A manifest that carries a fence of its own makes this
            # reachable after the `.seg` PUT; that change must count it here
            # with `self._flush_fence.note_fenced_after_put(writer_lease_epoch)`.
            return ExactlyOnceFlushResult(  # cov: unreachable the manifest checks only the (writer, current) pair _refused_at_entry already passed
                EO_LEASE_FENCED, Int64(-1), Int64(-1), Int64(0), Int64(-1)
            )
        # IDEMPOTENT_RETRYABLE — in-flight winner / genuine no-commit.
        return ExactlyOnceFlushResult(
            EO_RETRYABLE, Int64(-1), Int64(-1), Int64(0), Int64(-1)
        )

    # -------------------------------------------------------------------------
    # Transactions — txn-open flush + COMMIT/ABORT marker append.
    # -------------------------------------------------------------------------

    def flush_with_producer_txn(
        mut self,
        now_ms: Int64,
        producer_id: Int64,
        producer_epoch: Int64,
        first_seq: Int64,
        last_seq: Int64,
        txn_id: String,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ) raises -> ProduceResult:
        """Flush like `flush_with_producer`, but TAG the manifest chunk as
        txn-open (`marker_type == MARKER_NONE`, non-empty `txn_id`). The chunk
        is durable on return, but a `read_committed` consumer treats it as
        INVISIBLE until the transaction's control object reads `Complete` AND
        the chunk's epoch matches the control epoch (the pinned-snapshot filter
        in the consume path). `read_uncommitted` consumers see it immediately
        (Kafka's default isolation). The (producer_id, epoch, first_seq,
        last_seq) sequence state is still folded in (idempotent dedupe applies
        within a transaction too).

        Refuses a stale writer with `lease_fenced` before the PUT, as `flush`
        does."""
        if len(self._buffer) == 0:
            raise Error("BrokerCore.flush_with_producer_txn: empty buffer")
        if self._refused_at_entry(writer_lease_epoch, current_lease_epoch):
            raise Error(
                self._flush_fence.refusal_message(
                    "flush_with_producer_txn",
                    writer_lease_epoch,
                    current_lease_epoch,
                )
            )

        # SKIP the pre-flush `read_head` GET — see the `flush` variant for the
        # full rationale. `pre_commit_base` seeds ONLY the segment footer's
        # DEBUG offset fields (the consumer resolves offsets from the manifest,
        # never the footer), so a 0 estimate is harmless and trims one
        # object-store round-trip per durable ack. The exactly-once twin
        # `flush_with_producer_exactly_once` seeds `Int64(0)` the same way.
        var pre_commit_base = Int64(0)

        var batches = self._buffer^
        self._buffer = Slab[RecordBatch]()
        self._buffer_bytes = 0
        self._oldest_ts_ms = Int64(-1)

        var seg_bytes = encode_segment(batches^, pre_commit_base)
        var footer = SegmentFooter.decode(seg_bytes)
        var record_count = footer.record_count
        var crc = footer.crc32
        var segment_bytes = Int64(len(seg_bytes))

        # Collision-safe staged PUT (If-None-Match:* + re-key on a 412).
        var seg_key = self._stage_segment(now_ms, seg_bytes^)

        # The chunk carries the txn tag (txn-open) committed in the same atomic
        # append.
        var body = encode_manifest_body(
            seg_key,
            record_count,
            crc,
            segment_bytes,
            now_ms,
            producer_id,
            producer_epoch,
            first_seq,
            last_seq,
            MARKER_NONE,
            txn_id,
        )
        # Route to the active lineage (sub-lineage or consolidated).
        var append_res: AppendResult
        try:
            append_res = self._append_active(
                body^, record_count, writer_lease_epoch, current_lease_epoch
            )
        except e:
            # After the PUT: count the leak, cache a fence.
            self._flush_fence.note_append_raise(String(e), writer_lease_epoch)
            raise e^

        return ProduceResult(
            base_offset=append_res.base_offset,
            last_offset=append_res.last_offset,
            record_count=record_count,
            segment_key=seg_key^,
            chunk_seq=append_res.chunk_seq,
            segment_bytes=segment_bytes,
            creation_ts_ms=now_ms,
        )

    def append_txn_marker(
        mut self,
        now_ms: Int64,
        producer_id: Int64,
        producer_epoch: Int64,
        txn_id: String,
        is_commit: Bool,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ) raises -> Int64:
        """Append a COMMIT (or ABORT) control-batch MARKER chunk to THIS
        partition's manifest via the same `If-None-Match` atomic append a
        segment uses. The marker is a zero-record chunk (`record_count == 0`, no
        `.seg` object — it carries no data) tagged with `marker_type ==
        MARKER_COMMIT / MARKER_ABORT` + the `txn_id` it closes + the producer
        epoch (the epoch-equality fence input). Returns the marker's
        chunk_seq.

        A marker is a RECORD-LOCATOR, NOT the linearization point: appending it
        makes it durable, but the txn becomes visible only when the control
        object flips to `Complete` (the caller does that AFTER every
        participating partition's marker is durable). A marker occupies a
        manifest slot but advances the offset range by ZERO (record_count 0), so
        it never consumes an offset — consumers skip it during offset
        resolution and only consult it for the txn close-boundary + abort
        filter."""
        var marker_type = MARKER_COMMIT if is_commit else MARKER_ABORT
        # A marker has no segment object key (it carries no data) — empty key.
        var body = encode_manifest_body(
            String(""),
            Int64(0),  # record_count == 0 (no data records)
            UInt32(0),  # crc (no data)
            Int64(0),  # segment_bytes
            now_ms,
            producer_id,
            producer_epoch,
            Int64(-1),  # first_seq (n/a for a marker)
            Int64(-1),  # last_seq (n/a for a marker)
            marker_type,
            txn_id,
        )
        # A txn marker co-locates with the txn's data chunks — route to
        # the active lineage.
        var append_res = self._append_active(
            body^, Int64(0), writer_lease_epoch, current_lease_epoch
        )
        return append_res.chunk_seq

    def _cached_producer_seq_idx(self, producer_id: Int64) -> Int:
        for i in range(len(self._producer_ids)):
            if self._producer_ids[i] == producer_id:
                return i
        return -1

    def producer_seq_is_cached(self, producer_id: Int64) -> Bool:
        """True iff this process holds an EXACT in-process last-committed-seq
        for `producer_id` (it committed >=1 of that producer's batches on this
        connection). The dedupe gate uses this to SKIP the authoritative LIST
        re-check on the hot path — a cache hit is already exact for a
        single-connection idempotent producer (this process is the sole writer
        of that producer's sequence)."""
        return self._cached_producer_seq_idx(producer_id) >= 0

    def note_committed_seq(mut self, producer_id: Int64, last_seq: Int64):
        """Advance the IN-PROCESS per-producer last-committed-seq cache after a
        CONFIRMED commit (monotone-forward; never lowers). Called from
        `flush_with_producer` on success AND from the produce handler's
        phantom-durable raise-path. There is NO pre-commit reservation, so the
        cache can never report a seq that did not actually commit."""
        if producer_id < Int64(0):
            return
        var idx = self._cached_producer_seq_idx(producer_id)
        if idx >= 0:
            if last_seq > self._producer_last_seq[idx]:
                self._producer_last_seq[idx] = last_seq
            return
        self._producer_ids.append(producer_id)
        self._producer_last_seq.append(last_seq)

    def recover_last_committed_seq(
        mut self, producer_id: Int64, authoritative: Bool = False
    ) raises -> Int64:
        """The last sequence `producer_id` has committed in this partition, or
        -1 if none (the dedupe gate's bucket-is-truth recovery).

        Three tiers, fast → slow:

        (1) IN-PROCESS cache (HOT path, no S3 read; `authoritative=False`). An
            idempotent producer is pinned to ONE broker process, so the
            per-producer cache (advanced ONLY on confirmed commits) is EXACT.

        (2) cached-`_HEAD` manifest scan (cache MISS, `authoritative=False`):
            TOP-DOWN early-exit over the small manifest, then SEED the cache.

        (3) AUTHORITATIVE LIST scan (`authoritative=True`): reads the bucket
            tail directly so a commit in a chunk above a stale `_HEAD` is never
            missed (the stale-cache OUT_OF_ORDER livelock + false-ACCEPT
            double-write). Used by the produce handler's raise-path re-check.
            Re-seeds the cache.

        The MAX committed `last_seq` IS the last committed sequence (in-order
        commit: the gate only accepts `first_seq == last+1`).

        Sub-lineage aware. When sub-lineage
        write is enabled (`_sublineage_write_enabled`), an idempotent producer's
        commits land in THIS core's per-shard `_sublineage_manifest`, NOT the
        consolidated `_manifest`. So the manifest scan (tiers 2 + 3) routes to the
        ACTIVE lineage (`_active_recover_manifest` — the sub-lineage manifest when
        enabled, else the consolidated manifest, BYTE-IDENTICAL flag-OFF). The
        in-process cache (tier 1) is unaffected (it is keyed on the producer, not
        the lineage). NOTE: a producer whose source-shard tail has already FOLDED
        into `_base` (its chunks retired from the sub-lineage) is recovered by the
        DATA-PLANE `_base` fallback (`KafkaDataBroker`, which holds the cloneable
        store needed to reach `<part>/_lineage/_base`) — this leaf scan recovers
        the producer's UN-FOLDED tail, which is the common idempotent-retry case
        (a churn-retry races the still-live sub-lineage, not a folded prefix)."""
        if not authoritative:
            var cidx = self._cached_producer_seq_idx(producer_id)
            if cidx >= 0:
                return self._producer_last_seq[cidx]
        # Route the scan to the ACTIVE lineage. Flag-ON scans this writer's
        # per-shard `_sublineage_manifest` (the floor + fail-soft walk tolerates
        # a folded/retired prefix); flag-OFF scans the consolidated `_manifest`
        # with the loop below.
        if self._sublineage_write_enabled and self._sublineage_manifest:
            return self._recover_seq_in_sublineage(producer_id, authoritative)
        var head: ManifestHead
        if authoritative:
            head = self._manifest.read_head_authoritative()
        else:
            head = self._manifest.read_head()
        if head.chunk_seq < Int64(0):
            return Int64(-1)
        # Scan TOP-DOWN, early-exit on the first chunk for this producer (its
        # latest commit is near the tail → O(1)-ish, avoiding the O(N) full
        # replay per produce). Seed the in-process cache on a hit.
        # FLOORED at `_LOG_START` (one GET): a chunk below it is retired, or a
        # refused reaped-slot win (#486) that was never committed, so a producer
        # match there would be a false DUPLICATE.
        var floor = self._manifest.read_log_start_seq()
        var seq = head.chunk_seq
        while seq >= floor:
            var raw = self._manifest.read_chunk(seq)
            var mb = ManifestBody.decode(raw)
            if mb.producer_id == producer_id:
                self.note_committed_seq(producer_id, mb.last_seq)
                return mb.last_seq
            seq -= Int64(1)
        return Int64(-1)

    def _recover_seq_in_sublineage(
        mut self, producer_id: Int64, authoritative: Bool
    ) raises -> Int64:
        """Scan THIS writer's per-shard `_sublineage_manifest`
        TOP-DOWN for `producer_id`'s last committed seq (the max committed
        `last_seq` == the last committed sequence; in-order commit). Walks
        `[log_start_seq, head]` so a folded/retired prefix is never read, and is
        fail-soft on a chunk reaped mid-walk (the fold's retire-tombstone race).
        Returns -1 if the producer has no UN-FOLDED chunk in this sub-lineage (its
        commits may have folded into `_base` — the data-plane `_base` fallback
        recovers that case). Seeds the in-process cache on a hit. ONLY reached
        when sub-lineage write is enabled (the caller gated on the flag); the
        flag-OFF path keeps the consolidated-manifest loop above."""
        ref manifest = self._sublineage_manifest.value()
        var head: ManifestHead
        if authoritative:
            head = manifest.read_head_authoritative()
        else:
            head = manifest.read_head()
        if head.chunk_seq < Int64(0):
            return Int64(-1)
        var ls = manifest.read_log_start()
        var floor = ls.log_start_seq if ls.log_start_seq >= Int64(0) else Int64(0)
        var seq = head.chunk_seq
        while seq >= floor:
            try:
                var raw = manifest.read_chunk(seq)
                var mb = ManifestBody.decode(raw)
                if mb.producer_id == producer_id:
                    self.note_committed_seq(producer_id, mb.last_seq)
                    return mb.last_seq
            except e:
                if not _is_not_found_msg_bc(String(e)):
                    raise e^
                # Reaped/retired mid-walk (the fold's retire race) — skip.
            seq -= Int64(1)
        return Int64(-1)

    # -------------------------------------------------------------------------
    # Retention — pass + reap trigger over THIS partition's manifest.
    # -------------------------------------------------------------------------

    def retention_pass_on_partition(
        mut self, policy: RetentionPolicy, now_ms: Int64
    ) raises -> RetentionResult:
        """Run ONE retention pass over this partition's manifest:
        snapshot the head, evaluate the policy over the live chunks (excluding
        the active chunk), tombstone the out-of-policy oldest chunks, and
        advance the persisted log_start atomically. Returns the
        `RetentionResult`. Does NOT delete any object — the grace-gated
        `reap_partition` does that after the grace window. (Test/admin
        entrypoint; a deployment runs this on a background cadence)."""
        var ret_pass = RetentionPass[Self.Storage](policy)
        return ret_pass.run(self._manifest, now_ms)

    def reap_partition(
        mut self,
        now_ms: Int64,
        grace_ms: Int64 = Int64(60_000),
    ) raises -> ReapResult:
        """Reap (delete) every tombstoned chunk below the log start whose grace
        window has elapsed (`now_ms - schedule_ts >= grace_ms`). Idempotent.
        Returns the `ReapResult` (count reaped, tombstones skipped because their
        chunk is still live). Deletes the actual `.seg` segment objects (the durable data,
) AND the manifest chunks + tombstone markers. (Test/admin
        entrypoint; a deployment runs the ReapWorker on a background cadence).
        """
        var worker = ReapWorker[Self.Storage](grace_ms)
        return worker.run(self._segment_store, self._manifest, now_ms)


# =============================================================================
# Byte-estimate helper — a cheap upper-ish estimate of a RecordBatch's encoded
# size for the flush trigger. We do NOT encode to measure (that would double
# the work); the estimate sums per-column buffer lengths. Exactness is not
# required — the trigger only needs to fire in the right ballpark.
# =============================================================================


def _estimate_batch_bytes(rb: RecordBatch) raises -> Int:
    """Estimate the encoded byte size of `rb` (sum of column data lengths).
    Cheap and approximate — the flush trigger tolerates slack."""
    var total = 0
    var nc = rb.num_columns()
    for i in range(nc):
        total += rb.column_length(i) * 8  # ~8 bytes/value rough estimate
    # Per-batch IPC framing overhead (metadata + padding) — a flat add.
    total += 256
    return total
