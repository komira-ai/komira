# =============================================================================
# komira_broker/manifest_body.mojo
#   The broker's manifest chunk body type + codec (leaf — no broker-core dep).
# =============================================================================
#
# `ManifestBody` is the broker's domain payload that rides inside the opaque
# CAS-manifest chunk body (the trait carries no offset/segment vocabulary;
# the meaning lives here, above the
# trait). It is a LEAF type with no dependency on `broker_core`, so BOTH
# `broker_core` (the producer flush path) AND `retention` (the retention pass)
# import it WITHOUT a circular dependency.
#
# Layout (little-endian), BACKWARD-COMPATIBLE:
#   [ record_count: i64 ][ crc32: u32 ][ key_len: i64 ][ key bytes... ]
#   [ segment_bytes: i64 ][ creation_ts_ms: i64 ]   ← retention trailer (optional)
#   [ producer_id: i64 ][ producer_epoch: i64 ]     ← producer trailer (optional)
#   [ first_seq: i64 ][ last_seq: i64 ]             ← producer trailer (cont.)
#   [ marker_type: i64 ][ txn_id_len: i64 ][ txn_id bytes... ] ← txn trailer (opt)
# An OLD legacy body stops after `key`; a retention body stops after the
# retention trailer; a producer body stops after the producer trailer; decode
# defaults each missing trailer
# (marker_type=0 NOT_A_MARKER, txn_id="" non-transactional, producer fields -1),
# so legacy / retention / producer / txn bodies all decode by the SAME path.
#
# Transactions: the txn trailer carries the
# transaction tag a chunk was written under. `txn_id` is the transactional-id
# ("" == non-transactional, the at-least-once / idempotent-only path). A normal
# in-transaction data chunk has `marker_type == MARKER_NONE` and a non-empty
# `txn_id` (it is a txn-open chunk — durable but invisible until its txn's
# control object reads Complete). A COMMIT/ABORT control-batch MARKER chunk has
# `marker_type == MARKER_COMMIT / MARKER_ABORT` and the txn_id of the txn it
# closes (record_count 0 — a marker carries no data records). The `producer_epoch`
# field doubles as the epoch-equality fence input for txn chunks.
#
# Idempotent producer: the producer trailer
# folds the per-(producer_id, partition) sequence state INTO this manifest
# chunk body so it is committed in the SAME `If-None-Match` append that links
# the segment (cas_manifest `_append_inner`). This is the atomic-durability
# invariant: the producer's sequence advances exactly once ⟺ the segment
# becomes visible. A broker that PUTs the .seg then dies BEFORE the append
# leaves no producer body, so the retry is correctly treated as the first
# attempt (no double-write, no false-dedup). `producer_id == -1` means the
# segment was produced by a NON-idempotent producer (no sequence state).
#
# Encapsulation: POD-ish (Int64/UInt32 + one owned String). ZERO UnsafePointer
# in any signature; encode/decode are pure value transforms.
# =============================================================================


# transaction marker types — what kind of transactional chunk this body describes.
comptime MARKER_NONE: Int64 = 0  # a normal chunk (data; txn_id may still be set)
comptime MARKER_COMMIT: Int64 = 1  # a COMMIT control-batch marker
comptime MARKER_ABORT: Int64 = 2  # an ABORT control-batch marker


@always_inline
def _mb_put_u32_le(mut out: List[UInt8], v: UInt32):
    for i in range(4):
        out.append(UInt8(Int((v >> UInt32(8 * i)) & UInt32(0xFF))))


@always_inline
def _mb_put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8(Int((u >> UInt64(8 * i)) & UInt64(0xFF))))


@always_inline
def _mb_get_u32_le(bytes: List[UInt8], off: Int) raises -> UInt32:
    if off + 4 > len(bytes):
        raise Error("manifest body: truncated u32 at " + String(off))
    var u = UInt32(0)
    for i in range(4):
        u |= UInt32(Int(bytes[off + i])) << UInt32(8 * i)
    return u


@always_inline
def _mb_get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(bytes):
        raise Error("manifest body: truncated i64 at " + String(off))
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


def encode_manifest_body(
    object_key: String,
    record_count: Int64,
    crc32: UInt32,
    segment_bytes: Int64 = Int64(-1),
    creation_ts_ms: Int64 = Int64(-1),
    producer_id: Int64 = Int64(-1),
    producer_epoch: Int64 = Int64(-1),
    first_seq: Int64 = Int64(-1),
    last_seq: Int64 = Int64(-1),
    marker_type: Int64 = MARKER_NONE,
    txn_id: String = String(""),
) -> List[UInt8]:
    """The broker's manifest chunk body: the segment's object key + its record
    count + its CRC, PLUS (retention) the EXACT segment byte size and the
    creation wall-clock timestamp, PLUS (idempotence) the producer-sequence
    state — `producer_id` / `producer_epoch` / `first_seq` / `last_seq` — PLUS
    (transactions) the transaction tag — `marker_type` / `txn_id`.

    The retention fields are appended length-prefixed AFTER `object_key`; the
    producer fields are appended AFTER the retention trailer; the txn fields
    AFTER the producer trailer. An OLD 3-field body decodes with every trailer
    field defaulting to -1; a retention body decodes with the producer fields
    defaulting to -1; a producer
    body decodes with `marker_type == MARKER_NONE` and `txn_id == ""` (a
    non-transactional segment). The producer trailer makes the sequence
    advance atomic with the segment commit; the txn trailer makes the
    transaction tag (txn-open / COMMIT-marker / ABORT-marker) ride inside the
    same `If-None-Match` manifest append — so a marker is committed atomically
    and a txn-open chunk is self-describing for the read_committed filter."""
    var out = List[UInt8]()
    _mb_put_i64_le(out, record_count)
    _mb_put_u32_le(out, crc32)
    var kb = object_key.as_bytes()
    _mb_put_i64_le(out, Int64(len(kb)))
    for i in range(len(kb)):
        out.append(kb[i])
    _mb_put_i64_le(out, segment_bytes)
    _mb_put_i64_le(out, creation_ts_ms)
    # The producer-sequence trailer (folded into the atomic append).
    _mb_put_i64_le(out, producer_id)
    _mb_put_i64_le(out, producer_epoch)
    _mb_put_i64_le(out, first_seq)
    _mb_put_i64_le(out, last_seq)
    # transactions trailer (marker_type + length-prefixed txn_id).
    _mb_put_i64_le(out, marker_type)
    var tb = txn_id.as_bytes()
    _mb_put_i64_le(out, Int64(len(tb)))
    for i in range(len(tb)):
        out.append(tb[i])
    return out^


def chunk_has_segment(marker_type: Int64, object_key: String) -> Bool:
    """True iff a manifest chunk with this `marker_type` and `object_key` owns
    a `.seg` segment object: a data chunk (`marker_type == MARKER_NONE`) with a
    non-empty key.

    Every reader that GETs, DELETEs or re-records a chunk's `object_key`
    checks this first (through `ManifestBody.has_segment` or a cached copy of
    the same two fields). A COMMIT / ABORT marker, and any other marker type,
    has zero records and an empty key, so it owns no object. `Path.parse("")`
    does not raise: it is the bucket-root path, so a reader that skipped this
    check would GET or DELETE the bucket-root key.

    `record_count` is deliberately NOT part of the predicate: a flush of a
    zero-row RecordBatch commits a MARKER_NONE chunk with `record_count == 0`
    that still owns a real `.seg` object, which the reaper must delete. A
    MARKER_NONE body with an empty key is not written by any producer; it
    reports no segment rather than a read of the bucket-root key. Walks that
    keep a running offset still count a skipped chunk's `record_count`, so the
    offsets of later chunks never move.

    Compatibility: every reader MUST skip a chunk for which this is False. A
    binary older than this check GETs / DELETEs the bucket-root key for any
    marker chunk, so once any marker chunk exists in a manifest (a txn marker,
    or a future zero-record marker type, e.g. a takeover marker), a binary that
    includes this check is the rollback floor."""
    return marker_type == MARKER_NONE and object_key.byte_length() > 0


@fieldwise_init
struct ManifestBody(Copyable, Movable, Deinitable):
    """Decoded broker manifest chunk body.

    `segment_bytes` = the EXACT encoded segment object size (`len(seg_bytes)`
    at flush size-based retention) — `-1` when decoded from an old
    legacy body. `creation_ts_ms` = the wall clock (ms) the segment was
    flushed at — `-1` when absent.

    Producer (idempotence) trailer:
      `producer_id`    — the idempotent producer that wrote this segment
                         (`-1` == non-idempotent producer / old body).
      `producer_epoch` — the producer's epoch at write time (zombie fence).
      `first_seq`      — base_sequence of the first record in the segment.
      `last_seq`       — sequence of the last record (`first_seq + n - 1`).

    Transaction trailer:
      `marker_type`    — MARKER_NONE (a data chunk), MARKER_COMMIT, or
                         MARKER_ABORT (a control-batch marker chunk).
      `txn_id`         — the transactional-id this chunk was written under
                         (`""` == non-transactional / at-least-once). A non-empty
                         txn_id on a data chunk means "txn-open" (invisible to
                         read_committed until the txn's control object reads
                         Complete + epoch matches); on a marker chunk it names
                         the txn the marker closes.

    Every numeric trailer field is -1-defaulted (marker_type 0-defaulted, txn_id
    ""-defaulted) so a legacy (3-field), a retention (5-field), a producer
    (9-field), and a txn body all decode by the SAME path. The producer trailer carries
    the per-(producer_id, partition) sequence state committed atomically with
    the segment; the txn trailer carries the transaction tag (see
    `encode_manifest_body`).
    """

    var record_count: Int64
    var crc32: UInt32
    var object_key: String
    var segment_bytes: Int64
    var creation_ts_ms: Int64
    var producer_id: Int64
    var producer_epoch: Int64
    var first_seq: Int64
    var last_seq: Int64
    var marker_type: Int64
    var txn_id: String

    def has_segment(self) -> Bool:
        """True iff this chunk owns a `.seg` segment object at `object_key`
        (see `chunk_has_segment`, the one predicate every reader uses)."""
        return chunk_has_segment(self.marker_type, self.object_key)

    @staticmethod
    def decode(bytes: List[UInt8]) raises -> ManifestBody:
        var record_count = _mb_get_i64_le(bytes, 0)
        var crc = _mb_get_u32_le(bytes, 8)
        var key_len = Int(_mb_get_i64_le(bytes, 12))
        if 20 + key_len > len(bytes):
            raise Error("ManifestBody.decode: truncated object_key")
        var key = String("")
        for i in range(key_len):
            key += chr(Int(bytes[20 + i]))
        # retention trailer: present iff there are >= 16 trailing bytes
        # past the key. Old (legacy) bodies stop at `20 + key_len` → both
        # default to -1 (retention's evaluate() skips the missing dimension).
        var trailer_at = 20 + key_len
        var segment_bytes = Int64(-1)
        var creation_ts_ms = Int64(-1)
        if trailer_at + 16 <= len(bytes):
            segment_bytes = _mb_get_i64_le(bytes, trailer_at)
            creation_ts_ms = _mb_get_i64_le(bytes, trailer_at + 8)
        # producer trailer: present iff there are >= 32 MORE trailing bytes
        # past the retention trailer. retention / legacy bodies stop earlier → producer
        # fields default to -1 (a non-idempotent segment).
        var producer_at = trailer_at + 16
        var producer_id = Int64(-1)
        var producer_epoch = Int64(-1)
        var first_seq = Int64(-1)
        var last_seq = Int64(-1)
        if producer_at + 32 <= len(bytes):
            producer_id = _mb_get_i64_le(bytes, producer_at)
            producer_epoch = _mb_get_i64_le(bytes, producer_at + 8)
            first_seq = _mb_get_i64_le(bytes, producer_at + 16)
            last_seq = _mb_get_i64_le(bytes, producer_at + 24)
        # transactions trailer: present iff there are >= 16 MORE bytes past
        # the producer trailer (marker_type i64 + txn_id_len i64), plus the txn_id
        # bytes. idempotent-producer / earlier bodies stop here → marker_type 0, txn_id "".
        var txn_at = producer_at + 32
        var marker_type = MARKER_NONE
        var txn_id = String("")
        if txn_at + 16 <= len(bytes):
            marker_type = _mb_get_i64_le(bytes, txn_at)
            var txn_id_len = Int(_mb_get_i64_le(bytes, txn_at + 8))
            var txn_start = txn_at + 16
            if txn_start + txn_id_len <= len(bytes):
                for i in range(txn_id_len):
                    txn_id += chr(Int(bytes[txn_start + i]))
        return ManifestBody(
            record_count,
            crc,
            key^,
            segment_bytes,
            creation_ts_ms,
            producer_id,
            producer_epoch,
            first_seq,
            last_seq,
            marker_type,
            txn_id^,
        )
