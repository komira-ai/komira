# =============================================================================
# komira_search_catalog/split_summary.mojo
#   The catalog record for one published search split, and its binary codec.
# =============================================================================
#
# A `SplitSummary` is the body of one manifest chunk in an index's split
# catalog (see metastore.mojo). It is encoded with a small fixed binary
# envelope rather than JSON, so this layer needs no serialization library:
# little-endian i64 fields plus length-prefixed byte and string slots, the
# same framing `komira_objectstore.cas_manifest` uses for its own records.
#
# The envelope grows only by appending length-prefixed slots at the tail. A
# reader that predates a slot stops before it; a reader that knows the slot
# reads it only when bytes remain. So adding a field needs no version bump.
#
# Every type here is plain owned data (String, Array, List, Int64): no
# pointers and no shared buffers.
# =============================================================================


# -----------------------------------------------------------------------------
# Little-endian i64 and length-prefixed slots.
# -----------------------------------------------------------------------------


@always_inline
def _put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


@always_inline
def _get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(bytes):
        raise Error(
            "metastore: truncated i64 at offset " + String(off) + " (corrupt)"
        )
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


def _put_lp_bytes(mut out: List[UInt8], data: List[UInt8]):
    """Length-prefixed byte slot: [len i64 LE][bytes]. Empty -> just len 0."""
    _put_i64_le(out, Int64(len(data)))
    for i in range(len(data)):
        out.append(data[i])


def _put_lp_str(mut out: List[UInt8], s: String):
    """Length-prefixed string slot: [len i64 LE][utf8 bytes]."""
    var b = s.as_bytes()
    _put_i64_le(out, Int64(len(b)))
    for i in range(len(b)):
        out.append(b[i])


def _get_lp_bytes(bytes: List[UInt8], mut off: Int) raises -> List[UInt8]:
    """Read a length-prefixed byte slot and advance `off`. Raises on a
    negative or out-of-range length."""
    var n = Int(_get_i64_le(bytes, off))
    off += 8
    if n < 0:
        raise Error("metastore: negative length-prefix (corrupt)")
    if off + n > len(bytes):
        raise Error(
            "metastore: truncated length-prefixed field ("
            + String(off + n)
            + " > "
            + String(len(bytes))
            + "; corrupt)"
        )
    var out = List[UInt8]()
    for i in range(n):
        out.append(bytes[off + i])
    off += n
    return out^


def _get_lp_str(bytes: List[UInt8], mut off: Int) raises -> String:
    """Read a length-prefixed string slot and advance `off`."""
    var raw = _get_lp_bytes(bytes, off)
    var s = String("")
    for i in range(len(raw)):
        s += chr(Int(raw[i]))
    return s^


# -----------------------------------------------------------------------------
# SplitSummary
# -----------------------------------------------------------------------------


@fieldwise_init
struct SplitSummary(Copyable, Movable, Deinitable):
    """One live split's catalog entry: the body of one manifest chunk.

    Fields filled by every writer:
      version:     payload schema version (`SPLIT_SUMMARY_VERSION`).
      split_uuid:  the split's 16-byte identity, taken from its footer.
      doc_count:   number of documents in the split.
      byte_size:   size of the uploaded split object.
      min_doc_id:  smallest document id in the split.
      max_doc_id:  largest document id in the split.
      index_name:  the index the split belongs to.
      field_name:  the indexed field.
      object_key:  where the split object lives
                   (`<prefix>/<index>/splits/<uuid>.split`).

    Reserved slots. Writers that do not use them leave them empty or 0, and a
    later writer can fill them without a schema bump:
      delete_gen_ref: reference to a sibling deletion-generation object.
      bloom_sketch:   a pruning sketch.
      minmax_sketch:  a numeric min/max sketch.
      cardinality:    a distinct-term estimate.

    Compaction slots, encoded only for a merged split:
      merge_ops:         0 for a split written by ingest, > 0 for a split
                         produced by compaction. A merge policy uses it to
                         avoid re-merging already-merged splits forever.
      merge_input_uuids: the 16-byte UUIDs of the splits this merged split
                         absorbed, flattened (16 * n bytes). Readers hide any
                         live split listed here while the merged split is live,
                         so the window between publishing a merge and retiring
                         its inputs never counts a document twice. Empty for an
                         ingest split.
    """

    var version: UInt8
    var split_uuid: Array[UInt8, 16]
    var doc_count: Int64
    var byte_size: Int64
    var min_doc_id: Int64
    var max_doc_id: Int64
    var index_name: String
    var field_name: String
    var object_key: String
    var delete_gen_ref: String
    var bloom_sketch: List[UInt8]
    var minmax_sketch: List[UInt8]
    var cardinality: Int64
    var merge_ops: Int64
    var merge_input_uuids: List[UInt8]

    @always_inline
    def is_merged(self) -> Bool:
        """True iff compaction produced this split (merge_ops > 0)."""
        return self.merge_ops > Int64(0)

    def num_merge_inputs(self) -> Int:
        """How many input split UUIDs this merged split absorbed."""
        return len(self.merge_input_uuids) // 16

    def merge_input_at(self, i: Int) raises -> Array[UInt8, 16]:
        """The i-th absorbed input split UUID. Raises when out of range."""
        var n = self.num_merge_inputs()
        if i < 0 or i >= n:
            raise Error(
                "SplitSummary.merge_input_at: index "
                + String(i)
                + " out of range [0, "
                + String(n)
                + ")"
            )
        var u = Array[UInt8, 16](fill=UInt8(0))
        for k in range(16):
            u[k] = self.merge_input_uuids[i * 16 + k]
        return u^


comptime SPLIT_SUMMARY_VERSION: UInt8 = 1
"""The SplitSummary payload schema version. Bumped only for a layout change
that is not an appended slot."""


@fieldwise_init
struct LiveSplitEntry(Copyable, Movable, Deinitable):
    """A live split's summary paired with the manifest `chunk_seq` it was
    published at.

    A compactor that merges a set of splits must then retire exactly the
    chunks it merged. `list_live_splits` drops the sequence numbers, so
    `list_live_splits_with_seq` returns these pairs instead."""

    var chunk_seq: Int64
    var summary: SplitSummary


def make_split_summary(
    var split_uuid: Array[UInt8, 16],
    doc_count: Int64,
    byte_size: Int64,
    min_doc_id: Int64,
    max_doc_id: Int64,
    var index_name: String,
    var field_name: String,
    var object_key: String,
) -> SplitSummary:
    """Build the summary for a split written by ingest: the version stamped,
    the reserved slots empty, and no merge inputs."""
    return SplitSummary(
        version=SPLIT_SUMMARY_VERSION,
        split_uuid=split_uuid^,
        doc_count=doc_count,
        byte_size=byte_size,
        min_doc_id=min_doc_id,
        max_doc_id=max_doc_id,
        index_name=index_name^,
        field_name=field_name^,
        object_key=object_key^,
        delete_gen_ref=String(""),
        bloom_sketch=List[UInt8](),
        minmax_sketch=List[UInt8](),
        cardinality=Int64(0),
        merge_ops=Int64(0),
        merge_input_uuids=List[UInt8](),
    )


def make_merged_split_summary(
    var split_uuid: Array[UInt8, 16],
    doc_count: Int64,
    byte_size: Int64,
    min_doc_id: Int64,
    max_doc_id: Int64,
    var index_name: String,
    var field_name: String,
    var object_key: String,
    merge_ops: Int64,
    var merge_input_uuids: List[UInt8],
) -> SplitSummary:
    """Build the summary for a split produced by compaction: the ingest fields
    plus `merge_ops` (> 0) and the flattened UUIDs of the absorbed inputs."""
    return SplitSummary(
        version=SPLIT_SUMMARY_VERSION,
        split_uuid=split_uuid^,
        doc_count=doc_count,
        byte_size=byte_size,
        min_doc_id=min_doc_id,
        max_doc_id=max_doc_id,
        index_name=index_name^,
        field_name=field_name^,
        object_key=object_key^,
        delete_gen_ref=String(""),
        bloom_sketch=List[UInt8](),
        minmax_sketch=List[UInt8](),
        cardinality=Int64(0),
        merge_ops=merge_ops,
        merge_input_uuids=merge_input_uuids^,
    )


# -----------------------------------------------------------------------------
# Codec
# -----------------------------------------------------------------------------


def encode_split_summary(s: SplitSummary) -> List[UInt8]:
    """Encode to the fixed binary envelope. Layout (all ints LE):
      [version: u8]
      [split_uuid: 16 bytes]
      [doc_count, byte_size, min_doc_id, max_doc_id, cardinality: i64 x5]
      [index_name_len: i64][index_name bytes]
      [field_name_len: i64][field_name bytes]
      [object_key_len: i64][object_key bytes]
      [delete_gen_ref_len: i64][delete_gen_ref bytes]
      [bloom_len: i64][bloom_sketch bytes]
      [minmax_len: i64][minmax_sketch bytes]

    A merged split (merge_ops > 0) appends one more slot:
      [merge_ops: i64][merge_input_uuids_len: i64][merge_input_uuids bytes]
    An ingest split writes nothing extra, so its encoding is the same as it
    was before the compaction slot existed and older readers decode it
    unchanged.
    """
    var out = List[UInt8]()
    out.append(s.version)
    for i in range(16):
        out.append(s.split_uuid[i])
    _put_i64_le(out, s.doc_count)
    _put_i64_le(out, s.byte_size)
    _put_i64_le(out, s.min_doc_id)
    _put_i64_le(out, s.max_doc_id)
    _put_i64_le(out, s.cardinality)
    _put_lp_str(out, s.index_name)
    _put_lp_str(out, s.field_name)
    _put_lp_str(out, s.object_key)
    _put_lp_str(out, s.delete_gen_ref)
    _put_lp_bytes(out, s.bloom_sketch)
    _put_lp_bytes(out, s.minmax_sketch)
    if s.merge_ops > Int64(0):
        _put_i64_le(out, s.merge_ops)
        _put_lp_bytes(out, s.merge_input_uuids)
    return out^


def decode_split_summary(body: List[UInt8]) raises -> SplitSummary:
    """Inverse of `encode_split_summary`. Every read is bounds-checked, so a
    truncated or corrupt body raises instead of reading past the end."""
    # [version u8] + [uuid 16] = 17-byte minimum prefix.
    if len(body) < 17:
        raise Error(
            "decode_split_summary: body too short for header ("
            + String(len(body))
            + " < 17; corrupt)"
        )
    var version = body[0]
    var uuid = Array[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        uuid[i] = body[1 + i]
    var off = 17
    var doc_count = _get_i64_le(body, off)
    off += 8
    var byte_size = _get_i64_le(body, off)
    off += 8
    var min_doc_id = _get_i64_le(body, off)
    off += 8
    var max_doc_id = _get_i64_le(body, off)
    off += 8
    var cardinality = _get_i64_le(body, off)
    off += 8
    var index_name = _get_lp_str(body, off)
    var field_name = _get_lp_str(body, off)
    var object_key = _get_lp_str(body, off)
    var delete_gen_ref = _get_lp_str(body, off)
    var bloom_sketch = _get_lp_bytes(body, off)
    var minmax_sketch = _get_lp_bytes(body, off)
    # The compaction slot is present iff bytes remain; it needs at least the
    # 8-byte merge_ops.
    var merge_ops = Int64(0)
    var merge_input_uuids = List[UInt8]()
    if off + 8 <= len(body):
        merge_ops = _get_i64_le(body, off)
        off += 8
        merge_input_uuids = _get_lp_bytes(body, off)
        if len(merge_input_uuids) % 16 != 0:
            raise Error(
                "decode_split_summary: merge_input_uuids length "
                + String(len(merge_input_uuids))
                + " is not a multiple of 16 (corrupt)"
            )
    return SplitSummary(
        version=version,
        split_uuid=uuid^,
        doc_count=doc_count,
        byte_size=byte_size,
        min_doc_id=min_doc_id,
        max_doc_id=max_doc_id,
        index_name=index_name^,
        field_name=field_name^,
        object_key=object_key^,
        delete_gen_ref=delete_gen_ref^,
        bloom_sketch=bloom_sketch^,
        minmax_sketch=minmax_sketch^,
        cardinality=cardinality,
        merge_ops=merge_ops,
        merge_input_uuids=merge_input_uuids^,
    )
