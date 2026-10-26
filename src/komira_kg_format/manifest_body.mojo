# =============================================================================
# manifest_body -- the snapshot manifest chunk body and its codec.
# =============================================================================
#
# `KgManifestBody` is the payload of one chunk of the content-addressed manifest
# lineage (the manifest store treats the body as opaque bytes; its meaning lives
# here). One chunk per snapshot: the body maps each table name to the
# content-addressed Parquet object key, the table's schema version and its row
# count, and records the embedding dimension of the graph. A snapshot may omit
# empty tables, so `table_count` varies. The snapshot id is the chunk's sequence
# number; the body carries no id of its own.
#
# Layout, little-endian, format version 2:
#   [ format_version: i64 ]
#   [ embedding_dim: i64 ]                   # components per embedding, > 0
#   [ table_count: i64 ]
#   repeated table_count times:
#     [ name_len: i64 ][ name bytes... ]     # UTF-8: "episodes", "edges", ...
#     [ key_len: i64 ][ object_key bytes... ]# UTF-8
#     [ schema_version: i64 ]
#     [ row_count: i64 ]
#
# Format version 1 had no `embedding_dim` field (the dimension was fixed at
# 1536 by the schemas). The decoder still reads it and reports the default
# dimension, so a lineage written before the dimension was recorded stays
# readable; the encoder writes version 2 only.
#
# Decoding is strict: a truncated body, an unknown version, a negative count or
# length, a non-positive dimension, a name or key that is not UTF-8, and bytes
# left over after the last table are all errors, never a partial value.
#
# Encode and decode are pure value transforms; no pointer appears anywhere.
# =============================================================================

from .embedding import DEFAULT_EMBEDDING_DIM
from .utf8_check import bytes_are_utf8


# The format version the encoder writes and the decoder reads. Bumping it is a
# manifest-body format change.
comptime KG_SNAPSHOT_FORMAT_VERSION: Int64 = 2

# The oldest format version the decoder still reads (no embedding dimension).
comptime KG_SNAPSHOT_FORMAT_VERSION_MIN: Int64 = 1


@always_inline
def _put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8(Int((u >> UInt64(8 * i)) & UInt64(0xFF))))


def _put_str(mut out: List[UInt8], s: String):
    var b = s.as_bytes()
    _put_i64_le(out, Int64(len(b)))
    for j in range(len(b)):
        out.append(b[j])


@always_inline
def _get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off < 0 or off + 8 > len(bytes):
        raise Error("KgManifestBody: truncated i64 at " + String(off))
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


def _get_str(bytes: List[UInt8], mut off: Int, what: String) raises -> String:
    """Read a length-prefixed UTF-8 string at `off` and advance past it."""
    var n = Int(_get_i64_le(bytes, off))
    off += 8
    if n < 0:
        raise Error(
            "KgManifestBody.decode: negative length " + String(n) + " for " + what
        )
    if n > len(bytes) - off:
        raise Error("KgManifestBody.decode: truncated " + what)
    var buf = List[UInt8](capacity=n)
    for i in range(n):
        buf.append(bytes[off + i])
    off += n
    if not bytes_are_utf8(Span(buf)):
        raise Error("KgManifestBody.decode: " + what + " is not valid UTF-8")
    return String(unsafe_from_utf8=Span(buf))


@fieldwise_init
struct KgTableEntry(Copyable, Movable):
    """One snapshot table reference: a name, the object it is pinned at, its
    schema version and its row count.

    Fields:
        name: The table name ("entities", "edges", ...).
        object_key: The content-addressed Parquet object key the snapshot pins
            this table at.
        schema_version: The table's schema version; a reader refuses a version
            it does not understand.
        row_count: Rows in the table object (a diagnostic and pruning hint).
    """

    var name: String
    var object_key: String
    var schema_version: Int64
    var row_count: Int64


struct KgManifestBody(Movable):
    """A decoded snapshot manifest body: the embedding dimension and, per table
    present, `{object_key, schema_version, row_count}`.

    `format_version` is the version the body was read at (a fresh body carries
    `KG_SNAPSHOT_FORMAT_VERSION`); `encode` always writes the current version.
    `embedding_dim` is the number of components of every embedding in the graph;
    a writer checks each vector against it (`check_embedding_dim`) and a reader
    unpacks cells with it (`unpack_embedding_checked`). `tables` holds one entry
    per table present, in the order the writer appended them (not sorted).
    """

    var format_version: Int64
    var embedding_dim: Int
    var tables: List[KgTableEntry]

    def __init__(out self):
        """An empty body at the current format and the default dimension."""
        self.format_version = KG_SNAPSHOT_FORMAT_VERSION
        self.embedding_dim = DEFAULT_EMBEDDING_DIM
        self.tables = List[KgTableEntry]()

    def __init__(out self, var tables: List[KgTableEntry]):
        """A body at the default dimension holding `tables`."""
        self.format_version = KG_SNAPSHOT_FORMAT_VERSION
        self.embedding_dim = DEFAULT_EMBEDDING_DIM
        self.tables = tables^

    def __init__(
        out self, embedding_dim: Int, var tables: List[KgTableEntry]
    ) raises:
        """A body for a graph of `embedding_dim`-component embeddings.

        Args:
            embedding_dim: Components per embedding; must be more than zero.
            tables: The table references, moved in.
        """
        if embedding_dim <= 0:
            raise Error(
                "KgManifestBody: embedding dimension must be positive, got "
                + String(embedding_dim)
            )
        self.format_version = KG_SNAPSHOT_FORMAT_VERSION
        self.embedding_dim = embedding_dim
        self.tables = tables^

    @always_inline
    def num_tables(self) -> Int:
        """The number of tables the snapshot references."""
        return len(self.tables)

    def add_table(
        mut self,
        var name: String,
        var object_key: String,
        schema_version: Int64,
        row_count: Int64,
    ):
        """Append one table reference (write side)."""
        self.tables.append(
            KgTableEntry(name^, object_key^, schema_version, row_count)
        )

    def resolve(self, name: String) raises -> KgTableEntry:
        """The entry for `name`; raises if the snapshot omits that table."""
        for i in range(len(self.tables)):
            if self.tables[i].name == name:
                return self.tables[i].copy()
        raise Error(
            "KgManifestBody.resolve: table not present in snapshot: " + name
        )

    def has_table(self, name: String) -> Bool:
        """True iff the snapshot references a table called `name`."""
        for i in range(len(self.tables)):
            if self.tables[i].name == name:
                return True
        return False

    def check_embedding_dim(self, dim: Int) raises:
        """Refuse a vector of `dim` components if the graph's dimension differs.

        A writer calls this with the length of every vector it is about to
        store, so one graph never holds vectors of two sizes.

        Args:
            dim: The component count of the vector to store.
        """
        if dim != self.embedding_dim:
            raise Error(
                "KgManifestBody: embedding dimension "
                + String(dim)
                + " does not match the graph's "
                + String(self.embedding_dim)
            )

    def encode(self) -> List[UInt8]:
        """Encode to the little-endian wire form (format version 2)."""
        var out = List[UInt8]()
        _put_i64_le(out, KG_SNAPSHOT_FORMAT_VERSION)
        _put_i64_le(out, Int64(self.embedding_dim))
        _put_i64_le(out, Int64(len(self.tables)))
        for i in range(len(self.tables)):
            ref e = self.tables[i]
            _put_str(out, e.name)
            _put_str(out, e.object_key)
            _put_i64_le(out, e.schema_version)
            _put_i64_le(out, e.row_count)
        return out^

    @staticmethod
    def decode(bytes: List[UInt8]) raises -> KgManifestBody:
        """Decode the wire form of format version 1 or 2.

        Raises on a truncated body, an unknown version, a negative count or
        length, a non-positive dimension, a name or key that is not UTF-8, or
        bytes left after the last table.
        """
        var fmt = _get_i64_le(bytes, 0)
        if fmt < KG_SNAPSHOT_FORMAT_VERSION_MIN or fmt > KG_SNAPSHOT_FORMAT_VERSION:
            raise Error(
                "KgManifestBody.decode: unsupported snapshot format version "
                + String(fmt)
                + " (this build understands "
                + String(KG_SNAPSHOT_FORMAT_VERSION_MIN)
                + " to "
                + String(KG_SNAPSHOT_FORMAT_VERSION)
                + ")"
            )
        var off = 8
        var dim = DEFAULT_EMBEDDING_DIM
        if fmt >= 2:
            var d = _get_i64_le(bytes, off)
            off += 8
            if d <= 0 or d > Int64(2147483647):
                raise Error(
                    "KgManifestBody.decode: invalid embedding dimension "
                    + String(d)
                )
            dim = Int(d)
        var table_count = Int(_get_i64_le(bytes, off))
        off += 8
        if table_count < 0:
            raise Error(
                "KgManifestBody.decode: negative table_count "
                + String(table_count)
            )
        # Each entry is at least 32 bytes (two lengths, two i64), so a count
        # the remaining bytes cannot hold is refused before anything is
        # allocated for it.
        if table_count > (len(bytes) - off) // 32:
            raise Error("KgManifestBody.decode: truncated table list")
        var tables = List[KgTableEntry]()
        for _ in range(table_count):
            var name = _get_str(bytes, off, "table name")
            var key = _get_str(bytes, off, "object_key")
            var schema_version = _get_i64_le(bytes, off)
            off += 8
            var row_count = _get_i64_le(bytes, off)
            off += 8
            tables.append(
                KgTableEntry(name^, key^, schema_version, row_count)
            )
        if off != len(bytes):
            raise Error(
                "KgManifestBody.decode: "
                + String(len(bytes) - off)
                + " trailing bytes after the last table"
            )
        var body = KgManifestBody(dim, tables^)
        body.format_version = fmt
        return body^
