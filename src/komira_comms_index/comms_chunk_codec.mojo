# =============================================================================
# komira_comms_index/comms_chunk_codec.mojo
#   Comms index: the generic chunk-body codecs.
# =============================================================================
#
# This file is the chunk-body codec layer of the package. The rest of what the
# index needs (the CAS-manifest append and lifecycle, the `_HEAD` create-CAS
# pointer, the conditional store) is reused from `komira_objectstore.cas_manifest`;
# see comms_index.mojo.
#
# -----------------------------------------------------------------------------
# THE ONE GENERIC BODY KIND — `KeyedDelta` (the no-leakage decision)
# -----------------------------------------------------------------------------
# Calendar item changes, mail flag and expunge changes and chat room events all
# share ONE last-writer-wins-per-key shape, so the index carries a SINGLE generic
# record and lets each comms type plug its own `key`/`value` BYTES in —
# exactly the CAS-manifest "opaque chunk body" discipline applied one layer up:
#
#   KeyedDelta { op: PUT | TOMBSTONE, key: bytes, value: bytes, seq: i64 }
#
#   * `key`   — the identity the read-fold folds on (last-writer-wins). The
#               comms type owns its meaning: mail = the UID bytes; calendar =
#               the item-leaf; chat = the event-id. The fold NEVER interprets
#               key bytes; it only compares them for equality.
#   * `value` — the opaque per-type payload the comms server later decodes:
#               mail FlagDelta = the flag bitset; calendar = (etag,dtstart,
#               dtend); chat RoomEvent = (ciphertext_leaf, sender, ts). The
#               substrate round-trips `value` VERBATIM — it is none of our
#               business, exactly like the CAS chunk body below us.
#   * `op`    — PUT (set/overwrite this key's value) or TOMBSTONE (remove this
#               key — a per-item tombstone: a calendar remove or a mail
#               expunge). An
#               append-only event-log (chat) simply never emits TOMBSTONE.
#   * `seq`   — the producer-assigned monotone sequence FOR THIS KEY's deltas.
#               The read-fold uses it as the last-writer-wins tiebreak so two
#               deltas for one key fold deterministically regardless of the
#               manifest chunk order they are read in. (The manifest chunk_seq
#               is the GLOBAL total order; `seq` is the per-record tiebreak the
#               caller controls — e.g. a STORE that races a DELETE.)
#
# This is the "mutable bit" the package test exercises: set a
# flag (PUT value=1) then unset it (PUT value=0, higher seq) folds to the
# latest — the substrate proves the LWW fold without any flag vocabulary.
#
# -----------------------------------------------------------------------------
# Encapsulation
# -----------------------------------------------------------------------------
#   * No pointer in any signature (the whole surface is value /
#     `List[UInt8]` / POD, like cas_manifest.mojo's body codecs).
#   * No wildcard origins and no partial move through a pointer.
#   * `KeyedDelta` carries owned `List[UInt8]` fields and is a stack value the
#     fold holds; it is never an element of a byte slab. The fold's live state
#     is a plain `List[_FoldEntry]`, not a `Slab[T]` (comms_index.mojo).
#
# Wire encoding mirrors cas_manifest.mojo (LE ints; no JSON on the hot path):
#   [ op: u8 ][ seq: i64 LE ][ key_len: i64 LE ][ key bytes... ]
#   [ value_len: i64 LE ][ value bytes... ]
# =============================================================================


# =============================================================================
# Op discriminant — PUT (set/overwrite) vs TOMBSTONE (remove)
# =============================================================================

comptime DELTA_OP_PUT: UInt8 = 0
comptime DELTA_OP_TOMBSTONE: UInt8 = 1


@always_inline
def delta_op_name(op: UInt8) -> StaticString:
    if op == DELTA_OP_PUT:
        return "PUT"
    if op == DELTA_OP_TOMBSTONE:
        return "TOMBSTONE"
    return "Unknown"


# =============================================================================
# KeyedDelta — the one generic, per-type-agnostic delta record
# =============================================================================


struct KeyedDelta(Copyable, Movable, Deinitable):
    """One last-writer-wins delta over an opaque (key, value) the comms type
    owns. The substrate folds on `key` (equality only) and breaks LWW ties on
    `seq`; `value` is round-tripped verbatim. `op` is PUT (set) or TOMBSTONE
    (remove). POD-of-owned-bytes — a stack value, never a byte-slab element."""

    var op: UInt8
    var seq: Int64
    var key: List[UInt8]
    var value: List[UInt8]

    def __init__(
        out self,
        op: UInt8,
        seq: Int64,
        var key: List[UInt8],
        var value: List[UInt8],
    ):
        self.op = op
        self.seq = seq
        self.key = key^
        self.value = value^

    @staticmethod
    def put(seq: Int64, var key: List[UInt8], var value: List[UInt8]) -> KeyedDelta:
        """A PUT delta — set/overwrite `key`'s value (the mutable-bit hot path:
        flag flip, cursor advance, calendar add/update, chat event append)."""
        return KeyedDelta(DELTA_OP_PUT, seq, key^, value^)

    @staticmethod
    def tombstone(seq: Int64, var key: List[UInt8]) -> KeyedDelta:
        """A TOMBSTONE delta — remove `key` (calendar REMOVE / mail EXPUNGE).
        Carries an empty value; the fold drops the key at read + GCs at
        compaction. An append-only event-log (chat) never emits this."""
        return KeyedDelta(DELTA_OP_TOMBSTONE, seq, key^, List[UInt8]())

    @always_inline
    def is_tombstone(self) -> Bool:
        return self.op == DELTA_OP_TOMBSTONE


# =============================================================================
# LE int framing (mirrors cas_manifest.mojo's `_put_i64_le` / `_get_i64_le` —
# re-derived here so komira_comms_index does NOT import a private helper out of
# komira_objectstore; the wire is identical LE).
# =============================================================================


@always_inline
def _put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


@always_inline
def _get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(bytes):
        raise Error(
            "comms_chunk_codec: truncated i64 at offset " + String(off)
        )
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


# =============================================================================
# encode_keyed_delta / decode_keyed_delta — the single-record body codec
# =============================================================================
#
# This is the consumer "chunk body" the CAS-manifest carries opaquely. A delta
# chunk is ONE KeyedDelta (record_count=1 at the manifest layer — the manifest
# offset semantics are unused; comms keys by the delta's key, the chunk_seq is
# the durable global total-order / sync-token).


def encode_keyed_delta(d: KeyedDelta) -> List[UInt8]:
    """Encode one KeyedDelta into the comms chunk body (LE framing)."""
    var out = List[UInt8]()
    out.append(d.op)
    _put_i64_le(out, d.seq)
    _put_i64_le(out, Int64(len(d.key)))
    for i in range(len(d.key)):
        out.append(d.key[i])
    _put_i64_le(out, Int64(len(d.value)))
    for i in range(len(d.value)):
        out.append(d.value[i])
    return out^


def decode_keyed_delta(body: List[UInt8]) raises -> KeyedDelta:
    """Decode one KeyedDelta from a comms chunk body. Fail-loud on truncation
    (a torn chunk must never silently fold an empty key/value)."""
    if len(body) < 1:
        raise Error("comms_chunk_codec: empty delta body")
    var op = body[0]
    var seq = _get_i64_le(body, 1)
    var key_len = Int(_get_i64_le(body, 9))
    if key_len < 0 or 17 + key_len > len(body):
        raise Error("comms_chunk_codec: key length exceeds body size")
    var key = List[UInt8]()
    for i in range(key_len):
        key.append(body[17 + i])
    var val_off = 17 + key_len
    var val_len = Int(_get_i64_le(body, val_off))
    if val_len < 0 or val_off + 8 + val_len > len(body):
        raise Error("comms_chunk_codec: value length exceeds body size")
    var value = List[UInt8]()
    for i in range(val_len):
        value.append(body[val_off + 8 + i])
    return KeyedDelta(op, seq, key^, value^)


# =============================================================================
# encode_compacted_base / decode_compacted_base — the LSM base-split codec
# =============================================================================
#
# The compaction (comms_index.compact) folds the live delta tail into ONE
# immutable base chunk: the merged last-writer-wins state, a self-describing
# run of `(seq, key, value)` survivor records (tombstoned keys are DROPPED at
# compaction — their removal is now permanent, the LSM tombstone-GC). This is
# the per-type "compaction body"; it is generic
# because it is just a directory of the SAME KeyedDelta survivors (all PUT —
# a base never carries a tombstone, the removal already happened).
#
# Layout (LE framing):
#   [ COMMS_BASE_VERSION: u8 ][ num_entries: i64 LE ]
#   then num_entries x [ seq: i64 LE ][ key_len ][ key ][ value_len ][ value ]
#
# A base is itself stored as a manifest chunk (record_count=1), so read_state
# folds [base, deltas...] uniformly. The base's chunk_seq is the compaction
# watermark `_HEAD` advances past.

comptime COMMS_BASE_VERSION: UInt8 = 1


def encode_compacted_base(survivors: List[KeyedDelta]) -> List[UInt8]:
    """Encode the merged survivors into one immutable base-split body. Every
    survivor is a PUT (a base never carries a tombstone — the removal already
    GC'd the key). `seq` is preserved so a delta appended AFTER the base (with
    a higher seq) still wins the LWW fold against the base entry."""
    var out = List[UInt8]()
    out.append(COMMS_BASE_VERSION)
    _put_i64_le(out, Int64(len(survivors)))
    for i in range(len(survivors)):
        ref s = survivors[i]
        _put_i64_le(out, s.seq)
        _put_i64_le(out, Int64(len(s.key)))
        for j in range(len(s.key)):
            out.append(s.key[j])
        _put_i64_le(out, Int64(len(s.value)))
        for j in range(len(s.value)):
            out.append(s.value[j])
    return out^


def decode_compacted_base(body: List[UInt8]) raises -> List[KeyedDelta]:
    """Decode the base-split body into its survivor KeyedDeltas (all PUT). The
    read-fold replays these FIRST (lowest precedence), then the delta tail on
    top (LWW by seq)."""
    if len(body) < 1:
        raise Error("comms_chunk_codec: empty base body")
    if body[0] != COMMS_BASE_VERSION:
        raise Error(
            "comms_chunk_codec: base version mismatch (got "
            + String(Int(body[0]))
            + ", want "
            + String(Int(COMMS_BASE_VERSION))
            + ")"
        )
    var n = Int(_get_i64_le(body, 1))
    var out = List[KeyedDelta]()
    var off = 9
    for _ in range(n):
        var seq = _get_i64_le(body, off)
        off += 8
        var key_len = Int(_get_i64_le(body, off))
        off += 8
        if key_len < 0 or off + key_len > len(body):
            raise Error("comms_chunk_codec: base key length overruns body")
        var key = List[UInt8]()
        for i in range(key_len):
            key.append(body[off + i])
        off += key_len
        var val_len = Int(_get_i64_le(body, off))
        off += 8
        if val_len < 0 or off + val_len > len(body):
            raise Error("comms_chunk_codec: base value length overruns body")
        var value = List[UInt8]()
        for i in range(val_len):
            value.append(body[off + i])
        off += val_len
        out.append(KeyedDelta(DELTA_OP_PUT, seq, key^, value^))
    return out^


# =============================================================================
# Convenience: encode a key/value from a String (the comms servers key on
# strings — UID-as-decimal, item-leaf, event-id — so the round-trip is ergonomic).
# These are PURE helpers; the substrate never interprets the bytes.
# =============================================================================


@always_inline
def key_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


@always_inline
def bytes_equal(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True
