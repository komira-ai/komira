# =============================================================================
# komira_table_store/table_store_codec.mojo
#   RowVersion / WriteOp / CommitChunk encode+decode — the WAL wire format.
# =============================================================================
#
# The table-store correctness slice's row + version + commit-chunk
# encoding. Mirrors `komira_objectstore/cas_manifest.mojo`'s little-endian
# framing (no JSON on the hot path), in a
# POD-of-owned-bytes shape (op: UInt8, seq: Int64, key/value: List[UInt8]) —
# the documented reuse-safe trivially shape.
#
# Design: the table-store correctness-slice design
# §1 (row + version encoding) + §2 (WAL chunk format).
#
# -----------------------------------------------------------------------------
# Encapsulation / stale-reuse discipline (the repository pointer rules)
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any signature (the whole surface is
#     value / List[UInt8] / POD).
#   * ZERO wildcard origins / `unsafe_from_address` / `take_pointee`.
#   * `RowVersion` / `WriteOp` / `CommitChunk` are POD-of-owned-bytes STACK
#     values (Int64 / Int32 / Bool + List[UInt8]). They are stored in plain
#     `List`s, NEVER in a byte-backed `Slab` whose element owns an inner heap
#     field — so the stale-reuse byte-slab+wildcard trap is N/A by construction (§1.3).
#     `schema_version: Int32` is a plain POD scalar — no heap, no pointer.
#
# WAL FORMAT VERSION: the commit-chunk magic's trailing ASCII digit IS the
# format version (PG_COMMIT_FORMAT_VERSION). `decode_commit_chunk` parses it and
# REJECTS an unknown version (no silent misparse). Version 2 reserves a
# `schema_version: Int32` header slot so the WAL can evolve into columnar
# analytics later without a reformat (analytics convergence design §6 items 1+2).
# =============================================================================


# Write-op tags.
comptime PG_OP_PUT: UInt8 = 0
comptime PG_OP_TOMBSTONE: UInt8 = 1

# Commit-chunk magic ("PGCn" little-endian sanity guard). 'P'=0x50 'G'=0x47
# 'C'=0x43; the TRAILING ASCII DIGIT is a real FORMAT VERSION, not decoration.
# The first three bytes "PGC" are the lineage tag; the fourth byte ('1','2',...)
# is the format version. So the magic = `PG_COMMIT_MAGIC_PREFIX | (('0'+v) << 24)`.
#
# Version history:
#   v1 ("PGC1", 0x31434750): magic | snapshot_lsn | n_writes | WriteOp[]
#   v2 ("PGC2", 0x32434750): magic | snapshot_lsn | SCHEMA_VERSION(i32) |
#                            n_writes | WriteOp[]   (the row-image-contract slot;
#                            see convergence design §6 item 2)
#   v3 ("PGC3", 0x33434750): magic | snapshot_lsn | SCHEMA_VERSION(i32) |
#                            STAMP_LSN(i64) | n_writes | WriteOp[]
#                            (ADAPTIVE INDEX SHARDING Option-A S-b
#                             — the cross-WAL DML-LSN decoupling;
#                             see below)
#
# THE v3 STAMP_LSN SLOT (Option-A S-b, the cross-WAL DML-LSN decoupling):
# `commit_lsn` is normally the WAL slot a chunk won (the index fold stamps a row
# at `seq`). For a SHARDED secondary-index lineage that commits to its OWN WAL
# (`CasManifestStore` keyed by shard), the chunk wins a slot `S_shard` in the
# SHARD's WAL — a number meaningless in the HEAP's WAL. But invariant #3 (the
# per-lineage single-commit-LSN re-scope) requires every row of ONE DML to read
# at the SAME DML-LSN `L` (the slot the HEAP commit won). So a v3 chunk carries
# an EXPLICIT `stamp_lsn = L`: the index fold uses `stamp_lsn` (NOT `S_shard`) as
# the row's `commit_lsn`. This is the exact generalization of D1-b's
# `lo_lsn = MIN(input commit_lsn)`-explicit decoupling. A `stamp_lsn` of -1
# (`PG_STAMP_LSN_UNSET`, the default) means "absent — fold at the WAL seq" and
# encodes a byte-identical v2 chunk, so EVERY existing single-WAL caller (heap +
# k=1 index, group-commit, async-commit) is UNCHANGED on the wire.
#
# `decode_commit_chunk` parses the version digit out of the magic and REJECTS an
# unknown version with a clear typed error (it does NOT silently misparse a
# foreign / future layout). This is the flag-day insurance the LTAP analytics
# convergence (the analytics convergence design, §6 items
# 1+2) requires so the WAL format can evolve into columnar analytics later
# WITHOUT a reformat.

# The "PGC" lineage tag (low 24 bits): 'P'=0x50 'G'=0x47 'C'=0x43 -> LE 0x434750.
comptime PG_COMMIT_MAGIC_PREFIX: UInt32 = 0x434750

# The DEFAULT WAL commit-chunk format version (the trailing digit of the magic).
# Bumped 1 -> 2 when `schema_version` was reserved in the header (CHANGE 2). The
# default stays 2: a chunk with no explicit DML-LSN stamp (`stamp_lsn == -1`)
# encodes v2 byte-identically. Version 3 is emitted ONLY when a caller passes an
# explicit `stamp_lsn >= 0` (the Option-A S-b sharded-index path).
comptime PG_COMMIT_FORMAT_VERSION: UInt32 = 2

# The v3 format version — emitted ONLY when an explicit `stamp_lsn >= 0` is
# supplied (the Option-A S-b cross-WAL DML-LSN stamp). v3 carries an i64
# `stamp_lsn` slot after `schema_version`.
comptime PG_COMMIT_FORMAT_VERSION_V3: UInt32 = 3

# The full magic for the DEFAULT (v2) version: prefix | (('0' + version) << 24).
# '0' = 0x30, so version 2 -> 0x32 in the high byte -> 0x32434750 ("PGC2").
comptime PG_COMMIT_MAGIC: UInt32 = PG_COMMIT_MAGIC_PREFIX | (
    (UInt32(0x30) + PG_COMMIT_FORMAT_VERSION) << UInt32(24)
)

# The full magic for v3 ("PGC3", 0x33434750).
comptime PG_COMMIT_MAGIC_V3: UInt32 = PG_COMMIT_MAGIC_PREFIX | (
    (UInt32(0x30) + PG_COMMIT_FORMAT_VERSION_V3) << UInt32(24)
)

# The "no explicit DML-LSN stamp" sentinel: the chunk's rows fold at the WAL seq
# (the default single-WAL behavior). encode emits a v2 chunk for this value.
comptime PG_STAMP_LSN_UNSET: Int64 = -1


@always_inline
def _format_version_from_magic(magic: UInt32) raises -> UInt32:
    """Validate the "PGC" lineage prefix and return the format version digit.

    Raises if the low-24-bit lineage tag is not "PGC" (a corrupt / non-table-store
    chunk), or if the high byte is not an ASCII digit '0'..'9' (a garbage
    version byte). The caller then branches on the returned version and REJECTS
    any version it does not know how to decode — never silently misparses."""
    if (magic & UInt32(0x00FFFFFF)) != PG_COMMIT_MAGIC_PREFIX:
        raise Error(
            "table_store_codec: bad commit-chunk magic prefix (got "
            + String(Int(magic))
            + ', want "PGC" lineage '
            + String(Int(PG_COMMIT_MAGIC_PREFIX))
            + ")"
        )
    var digit = (magic >> UInt32(24)) & UInt32(0xFF)
    if digit < UInt32(0x30) or digit > UInt32(0x39):
        raise Error(
            "table_store_codec: commit-chunk magic version byte is not an ASCII"
            " digit (got " + String(Int(digit)) + ")"
        )
    return digit - UInt32(0x30)


# =============================================================================
# RowVersion — one immutable version in a key's chain (the visibility stamp).
# =============================================================================


@fieldwise_init
struct RowVersion(Copyable, Movable, Deinitable):
    """One immutable version of a key (§1.2). The begin-LSN-only stamp:
    `commit_lsn` is the commit chunk_seq that created this version (its
    "xmin"); the version's "xmax" is implicit — the `commit_lsn` of the NEXT
    chain entry (or +inf for the newest). `is_tombstone` marks a DELETE.

    POD-of-owned-bytes (Int64 + Bool + List[UInt8]) — reuse-safe trivially; stored in
    a plain `List[RowVersion]`, never a byte-slab element.

    Field layout:
      var commit_lsn: Int64     — the begin-LSN / xmin (the commit slot).
      var is_tombstone: Bool    — True => this version DELETES the key.
      var row: List[UInt8]      — the row image bytes (empty when tombstone).
    """

    var commit_lsn: Int64
    var is_tombstone: Bool
    var row: List[UInt8]


# =============================================================================
# WriteOp — one buffered mutation in a txn's write-set (PUT or TOMBSTONE).
# =============================================================================


@fieldwise_init
struct WriteOp(Copyable, Movable, Deinitable):
    """One buffered write in a txn's in-RAM write-set (§3.2). `op` is
    PG_OP_PUT | PG_OP_TOMBSTONE. The write-set is deduped by key (last write
    per key wins) at buffer time. POD-of-owned-bytes.

    Field layout:
      var op: UInt8             — PG_OP_PUT | PG_OP_TOMBSTONE.
      var key: List[UInt8]      — the primary key bytes.
      var row: List[UInt8]      — the row image bytes (empty for TOMBSTONE).
    """

    var op: UInt8
    var key: List[UInt8]
    var row: List[UInt8]


# =============================================================================
# Little-endian framing primitives (mirror cas_manifest `_put_i64_le` etc.)
# =============================================================================


@always_inline
def _put_u32_le(mut out: List[UInt8], v: UInt32):
    for i in range(4):
        out.append(UInt8((v >> UInt32(8 * i)) & UInt32(0xFF)))


@always_inline
def _get_u32_le(bytes: List[UInt8], off: Int) raises -> UInt32:
    if off + 4 > len(bytes):
        raise Error("table_store_codec: truncated u32 at offset " + String(off))
    var u = UInt32(0)
    for i in range(4):
        u |= UInt32(Int(bytes[off + i])) << UInt32(8 * i)
    return u


@always_inline
def _put_i32_le(mut out: List[UInt8], v: Int32):
    var u = UInt32(Int(v))
    for i in range(4):
        out.append(UInt8((u >> UInt32(8 * i)) & UInt32(0xFF)))


@always_inline
def _get_i32_le(bytes: List[UInt8], off: Int) raises -> Int32:
    if off + 4 > len(bytes):
        raise Error("table_store_codec: truncated i32 at offset " + String(off))
    var u = UInt32(0)
    for i in range(4):
        u |= UInt32(Int(bytes[off + i])) << UInt32(8 * i)
    return Int32(Int(u))


@always_inline
def _put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


@always_inline
def _get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(bytes):
        raise Error("table_store_codec: truncated i64 at offset " + String(off))
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


@always_inline
def _put_bytes_lp(mut out: List[UInt8], b: List[UInt8]):
    """Length-prefixed bytes: [ len: i64 LE ][ bytes... ]."""
    _put_i64_le(out, Int64(len(b)))
    for i in range(len(b)):
        out.append(b[i])


# =============================================================================
# CommitChunk encode / decode (§2 wire layout — format versions 2 + 3)
# =============================================================================
#
# v2 (DEFAULT — no explicit DML-LSN stamp):
#   off  0  [ magic         : u32 LE ]   # PG_COMMIT_MAGIC (incl. format version)
#   off  4  [ snapshot_lsn  : i64 LE ]   # the snapshot this txn read at (audit)
#   off 12  [ schema_version: i32 LE ]   # reserved row-image schema id (v2+);
#                                        #   written constant 0 in this slice.
#   off 16  [ n_writes      : i64 LE ]
#   off 24  repeat n_writes times — a WriteOp:
#       [ op       : u8   ]
#       [ key_len  : i64 LE ][ key bytes...   ]
#       [ row_len  : i64 LE ][ row bytes...   ]   # row_len == 0 for TOMBSTONE
#
# v3 (Option-A S-b — explicit DML-LSN stamp): IDENTICAL to v2 except an i64
# `stamp_lsn` slot is INSERTED after `schema_version`, shifting `n_writes` +
# the WriteOp body down 8 bytes:
#   off  0  [ magic         : u32 LE ]   # PG_COMMIT_MAGIC_V3
#   off  4  [ snapshot_lsn  : i64 LE ]
#   off 12  [ schema_version: i32 LE ]
#   off 16  [ stamp_lsn     : i64 LE ]   # the HEAP DML-LSN L (>= 0); the index
#                                        #   fold uses THIS, not the WAL seq.
#   off 24  [ n_writes      : i64 LE ]
#   off 32  repeat n_writes times — a WriteOp (same encoding as v2)
#
# `schema_version` sits right after `snapshot_lsn` so the fixed header stays
# laid out as [magic][snapshot_lsn][schema_version][...][n_writes]. It is
# RESERVED here (always 0) so the columnarizer can later decode WAL rows into
# typed columns keyed by this id WITHOUT a WAL reformat (convergence design §6
# item 2). `stamp_lsn` is the Option-A S-b cross-WAL DML-LSN (v3 only).
# -----------------------------------------------------------------------------

# Header byte offsets. Single source of truth for both the full decode and the
# keys-only fast-path decode. The fixed-prefix layout up through
# `schema_version` is shared by v2 and v3; `n_writes` + the WriteOp body sit at
# DIFFERENT offsets in v3 (the `stamp_lsn` slot shifts them down 8 bytes), so the
# decode resolves `_OFF_N_WRITES` / `_OFF_WRITES` per-version below.
comptime _OFF_SNAPSHOT_LSN: Int = 4
comptime _OFF_SCHEMA_VERSION: Int = 12
# v2: n_writes immediately follows schema_version.
comptime _OFF_N_WRITES: Int = 16
comptime _OFF_WRITES: Int = 24
# v3: an i64 stamp_lsn slot sits between schema_version and n_writes.
comptime _OFF_STAMP_LSN_V3: Int = 16
comptime _OFF_N_WRITES_V3: Int = 24
comptime _OFF_WRITES_V3: Int = 32

# The row-image schema id written by this correctness slice. The row stays
# opaque bytes at the storage layer (the row-image encoding contract lives in
# the SQL layer / columnarizer — see the design's "row-image encoding contract"
# subsection); 0 = "unschematized opaque row image" (degenerate-mode default).
comptime PG_SCHEMA_VERSION_UNSET: Int32 = 0


def encode_commit_chunk(
    snapshot_lsn: Int64,
    write_set: List[WriteOp],
    stamp_lsn: Int64 = PG_STAMP_LSN_UNSET,
) -> List[UInt8]:
    """Encode a txn's entire write-set + snapshot into one immutable commit
    chunk body. The whole body is ONE create-CAS object — atomicity by
    construction (§2).

    `stamp_lsn` (Option-A S-b, default `PG_STAMP_LSN_UNSET` = -1) — the explicit
    cross-WAL DML-LSN `L`. When `-1` (the default, EVERY single-WAL caller), this
    emits a v2 chunk that is BYTE-IDENTICAL to the pre-S-b format (the index/heap
    fold stamps rows at the WAL seq). When `>= 0` (a SHARDED secondary-index
    lineage committing to its own WAL), this emits a v3 chunk carrying `L` so the
    index fold stamps rows at `L` (the heap DML-LSN), NOT this shard WAL's slot —
    the invariant-#3 per-lineage single-commit-LSN re-scope.

    `schema_version` is RESERVED (written as `PG_SCHEMA_VERSION_UNSET` = 0) in
    this correctness slice: the row image stays opaque bytes at the storage
    layer, and the row-image encoding contract is owned by the SQL layer /
    columnarizer. Reserving the header slot now is the flag-day insurance that
    lets the columnarizer decode rows into typed columns later without a WAL
    reformat (convergence design §6 item 2)."""
    var out = List[UInt8]()
    if stamp_lsn < Int64(0):
        # v2 — no explicit stamp; byte-identical to the pre-S-b wire format.
        _put_u32_le(out, PG_COMMIT_MAGIC)
        _put_i64_le(out, snapshot_lsn)
        _put_i32_le(out, PG_SCHEMA_VERSION_UNSET)
        _put_i64_le(out, Int64(len(write_set)))
    else:
        # v3 — explicit DML-LSN stamp (the sharded-index cross-WAL path).
        _put_u32_le(out, PG_COMMIT_MAGIC_V3)
        _put_i64_le(out, snapshot_lsn)
        _put_i32_le(out, PG_SCHEMA_VERSION_UNSET)
        _put_i64_le(out, stamp_lsn)
        _put_i64_le(out, Int64(len(write_set)))
    for i in range(len(write_set)):
        ref w = write_set[i]
        out.append(w.op)
        _put_bytes_lp(out, w.key)
        _put_bytes_lp(out, w.row)
    return out^


@fieldwise_init
struct CommitChunk(Movable, Deinitable):
    """A decoded commit chunk: the snapshot the txn read at + its write-set.

    Field layout:
      var snapshot_lsn: Int64
      var schema_version: Int32      — the reserved row-image schema id (0 in
                                       this slice; see encode_commit_chunk).
      var stamp_lsn: Int64           — the Option-A S-b explicit cross-WAL DML-LSN
                                       (>= 0 for a v3 sharded-index chunk;
                                       `PG_STAMP_LSN_UNSET` = -1 for a v2 chunk =
                                       "fold at the WAL seq"). The fold reads THIS
                                       (when >= 0) as the row's commit_lsn.
      var write_set: List[WriteOp]   — plain List, reuse-safe trivially.
    """

    var snapshot_lsn: Int64
    var schema_version: Int32
    var stamp_lsn: Int64
    var write_set: List[WriteOp]


def _get_bytes_lp(bytes: List[UInt8], mut off: Int) raises -> List[UInt8]:
    """Read a length-prefixed byte string at `off`, advancing `off`."""
    var n = Int(_get_i64_le(bytes, off))
    off += 8
    if n < 0 or off + n > len(bytes):
        raise Error(
            "table_store_codec: truncated lp-bytes (len="
            + String(n)
            + ", off="
            + String(off)
            + ", size="
            + String(len(bytes))
            + ")"
        )
    var out = List[UInt8]()
    for i in range(n):
        out.append(bytes[off + i])
    off += n
    return out^


def decode_commit_chunk(body: List[UInt8]) raises -> CommitChunk:
    """Decode a commit chunk body back into its snapshot + schema_version +
    stamp_lsn + write-set. Validates the magic guard AND the format version: a
    corrupt / non-table-store chunk fails loud, and an UNKNOWN format version is
    REJECTED with a clear typed error rather than silently misparsed.

    v2 chunks decode with `stamp_lsn == PG_STAMP_LSN_UNSET` (-1 = "fold at the
    WAL seq"). v3 chunks carry an explicit `stamp_lsn >= 0` (the Option-A S-b
    cross-WAL DML-LSN)."""
    var magic = _get_u32_le(body, 0)
    # CHANGE 1: parse the format version out of the magic and branch on it. An
    # unknown version is rejected — we never misparse a foreign / future layout.
    var version = _format_version_from_magic(magic)
    if version != PG_COMMIT_FORMAT_VERSION and (
        version != PG_COMMIT_FORMAT_VERSION_V3
    ):
        raise Error(
            "table_store_codec: unsupported commit-chunk format version "
            + String(Int(version))
            + " (this build decodes versions "
            + String(Int(PG_COMMIT_FORMAT_VERSION))
            + " + "
            + String(Int(PG_COMMIT_FORMAT_VERSION_V3))
            + ")"
        )
    var snapshot_lsn = _get_i64_le(body, _OFF_SNAPSHOT_LSN)
    var schema_version = _get_i32_le(body, _OFF_SCHEMA_VERSION)
    # The fixed prefix up through schema_version is shared; n_writes + the
    # WriteOp body sit at a version-dependent offset (v3 inserts an i64 stamp).
    var stamp_lsn = PG_STAMP_LSN_UNSET
    var off_n_writes = _OFF_N_WRITES
    var off = _OFF_WRITES
    if version == PG_COMMIT_FORMAT_VERSION_V3:
        stamp_lsn = _get_i64_le(body, _OFF_STAMP_LSN_V3)
        off_n_writes = _OFF_N_WRITES_V3
        off = _OFF_WRITES_V3
    var n_writes = Int(_get_i64_le(body, off_n_writes))
    if n_writes < 0:
        raise Error(
            "table_store_codec: negative n_writes " + String(n_writes)
        )
    var write_set = List[WriteOp]()
    for _ in range(n_writes):
        if off + 1 > len(body):
            raise Error("table_store_codec: truncated WriteOp op tag")
        var op = body[off]
        off += 1
        var key = _get_bytes_lp(body, off)
        var row = _get_bytes_lp(body, off)
        write_set.append(WriteOp(op, key^, row^))
    return CommitChunk(snapshot_lsn, schema_version, stamp_lsn, write_set^)


def decode_commit_chunk_keys(body: List[UInt8]) raises -> List[List[UInt8]]:
    """Decode ONLY the keys touched by a commit chunk (the OCC fast-path scan
    — §3.4 reads other chunks' keys to intersect against our write-set). Skips
    the row payloads to avoid copying them on the conflict-check hot path.

    Routes through the SAME magic + format-version validation as
    `decode_commit_chunk` — an unknown version is rejected, not misparsed."""
    var magic = _get_u32_le(body, 0)
    var version = _format_version_from_magic(magic)
    if version != PG_COMMIT_FORMAT_VERSION and (
        version != PG_COMMIT_FORMAT_VERSION_V3
    ):
        raise Error(
            "table_store_codec: unsupported commit-chunk format version "
            + String(Int(version))
            + " in key-decode (this build decodes versions "
            + String(Int(PG_COMMIT_FORMAT_VERSION))
            + " + "
            + String(Int(PG_COMMIT_FORMAT_VERSION_V3))
            + ")"
        )
    var off_n_writes = _OFF_N_WRITES
    var off = _OFF_WRITES
    if version == PG_COMMIT_FORMAT_VERSION_V3:
        off_n_writes = _OFF_N_WRITES_V3
        off = _OFF_WRITES_V3
    var n_writes = Int(_get_i64_le(body, off_n_writes))
    if n_writes < 0:
        raise Error("table_store_codec: negative n_writes " + String(n_writes))
    var keys = List[List[UInt8]]()
    for _ in range(n_writes):
        if off + 1 > len(body):
            raise Error(
                "table_store_codec: truncated WriteOp op tag (key-decode)"
            )
        off += 1  # skip op tag
        var key = _get_bytes_lp(body, off)
        # skip the row payload
        var row_len = Int(_get_i64_le(body, off))
        off += 8 + row_len
        keys.append(key^)
    return keys^


# =============================================================================
# byte-key helpers (lexicographic order + equality) — used by the index/scan.
# =============================================================================


@always_inline
def bytes_eq(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


@always_inline
def bytes_cmp(a: List[UInt8], b: List[UInt8]) -> Int:
    """Total byte-lexicographic order: -1 if a<b, 0 if a==b, +1 if a>b. The
    store imposes this on keys (for `scan`); a prefix is less than its
    extension (shorter wins on a tie up to its length)."""
    var n = len(a)
    if len(b) < n:
        n = len(b)
    for i in range(n):
        if a[i] < b[i]:
            return -1
        if a[i] > b[i]:
            return 1
    if len(a) < len(b):
        return -1
    if len(a) > len(b):
        return 1
    return 0
