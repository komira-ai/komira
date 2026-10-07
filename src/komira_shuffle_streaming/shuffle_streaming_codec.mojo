# =============================================================================
# komira_shuffle_streaming/shuffle_streaming_codec.mojo
#   The wire codec the ShuffleWriteSink writes and the ShuffleReadSource reads:
#   an Int64 (key, value) row <-> the shuffle's opaque key/payload bytes.
# =============================================================================
#
# Multi-segment streaming. The shuffle seal
# protocol is BODY-AGNOSTIC (komira_shuffle sink.mojo header): the producer's `.seg`
# carries an opaque `[len: i64 LE][payload]` frame per row, and the seal only
# tracks the dense (offset, len, row_count) slices. So the sink and the source
# must agree on the KEY codec (the partition driver) + the PAYLOAD codec (the
# round-tripped value) — that agreement lives HERE, in ONE module both import,
# so the round-trip is correctness-transparent (mirrors komira_shuffle codec's
# "the wire format is the contract, not the symbol" decision).
#
# The MVP row is an Int64 (key, value) pair (the windowed-agg delta shape:
# group_key + count). The key bytes drive `HashPartitioner`; the value payload is
# the 8 LE bytes the consumer decodes back into the value column. A richer
# columnar body drops in later with no seal change — the codec is
# the only thing that changes, and it stays in this one shared module.
#
# Pointer discipline: ZERO UnsafePointer. Pure byte-list value transforms; no
# struct fields, no slabs, no wildcard origins.
# =============================================================================


def _i64_to_le_bytes(v: Int64) -> List[UInt8]:
    """8 little-endian bytes of an Int64 (two's-complement reinterpret via
    UInt64). The canonical 8-byte LE codec the broker offset / stream cursor
    use, reused here so a key/value round-trips byte-identically."""
    var out = List[UInt8]()
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8(Int((u >> UInt64(8 * i)) & UInt64(0xFF))))
    return out^


def _i64_from_le_bytes(bytes: List[UInt8]) raises -> Int64:
    """Inverse of `_i64_to_le_bytes`: read the first 8 LE bytes back into an
    Int64. Raises on truncation (a corrupt/short payload)."""
    if len(bytes) < 8:
        raise Error(
            "shuffle_streaming_codec: payload too short for an Int64 ("
            + String(len(bytes))
            + " bytes, need 8)"
        )
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[i])) << UInt64(8 * i)
    return Int64(u)


def encode_key_bytes(key: Int64) -> List[UInt8]:
    """Encode an Int64 shuffle key into its partition-driving bytes (8 LE). The
    `HashPartitioner` folds these bytes through FNV-1a-64 to a partition id."""
    return _i64_to_le_bytes(key)


def encode_value_payload(value: Int64) -> List[UInt8]:
    """Encode an Int64 row value into the opaque payload bytes (8 LE) the
    producer's `.seg` round-trips to the consumer verbatim."""
    return _i64_to_le_bytes(value)


def decode_value_payload(payload: List[UInt8]) raises -> Int64:
    """Decode a per-row payload (8 LE bytes) back into its Int64 value — the
    inverse of `encode_value_payload`. Raises on truncation."""
    return _i64_from_le_bytes(payload)
