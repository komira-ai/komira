# =============================================================================
# delta_body -- the chunk bodies of the delta layer: one ingest's diff, the
#   chain head and the exact-name index that rides each delta.
# =============================================================================
#
# A snapshot is a base plus an ordered chain of deltas. Three chunk bodies of
# the manifest lineage describe it (the manifest store treats each as opaque
# bytes; their meaning lives here):
#
#   KgManifestBody (manifest_body)  the base: every table, whole
#   KgDeltaBody                     one ingest's diff: for each changed table
#                                   the key of a small delta object (the rows
#                                   added or superseded since the parent),
#                                   and the name-index entries it adds
#   KgChainBody                     the head: the base's chunk sequence number
#                                   and the delta sequence numbers in apply
#                                   order
#
# A reader rebuilds a snapshot as the base with the deltas applied in order.
# Compaction is a rewrite of the head alone: a new base and an empty delta
# list. The head chunk that was current at some time still resolves its own
# base and deltas, so a reader that pinned that snapshot id keeps reading it.
#
# The name index (`KgNameIndexBody`) is the `{normalized_name -> id}` entries a
# single delta adds. It is stored inline in the delta so the entries and the
# rows they refer to become visible at one linearization point, never one
# without the other. A reader folds the deltas' entries in order; a later entry
# for the same normalized name wins.
#
# Which kind of chunk a body is, is told by the format version in its first
# eight bytes, and each kind has its own: the base uses
# `KG_SNAPSHOT_FORMAT_VERSION` (2), the chain head `KG_CHAIN_FORMAT_VERSION`
# (3) and the delta `KG_DELTA_FORMAT_VERSION` (4). No two kinds share a version,
# so no body of one kind can decode as another, whatever its length, and
# `kg_chunk_is_chain_head` reads the difference between the head kinds.
#
# Layouts, little-endian:
#
#   KgDeltaBody
#     [ format_version: i64 = 4 ]
#     [ table_count: i64 ]
#     repeated table_count times:
#       [ name_len ][ name ]  [ key_len ][ object_key ]  [ schema_version ][ row_count ]
#     [ name index: [ count: i64 ] repeated: [ len ][ normalized_name ][ id: i64 ] ]
#
#   KgChainBody
#     [ format_version: i64 = 3 ] [ base_seq: i64 ] [ delta_count: i64 ]
#     repeated delta_count times: [ delta_seq: i64 ]
#
# A table that did not change is absent from a delta. Decoding is strict, as
# for the manifest body: a truncated body, an unknown version, a negative count,
# length, sequence number, schema version or row count, a count larger than the
# bytes can hold, a string that is not UTF-8, a table named twice and bytes left
# after the last field are errors, never a partial value.
#
# Every type is a value (Int64, String, List); no pointer appears anywhere.
# =============================================================================

from .manifest_body import KG_SNAPSHOT_FORMAT_VERSION
from .wire import get_i64_le, get_str, put_i64_le, put_str


# The format version of a chain head. Distinct from KG_SNAPSHOT_FORMAT_VERSION
# so the first eight bytes of a head chunk tell a chain from a base-only
# manifest, and from KG_DELTA_FORMAT_VERSION so a delta is never a chain.
comptime KG_CHAIN_FORMAT_VERSION: Int64 = 3

# The format version of a delta body. Distinct from the other two chunk kinds:
# an empty delta and a chain of no deltas are both 24 bytes, and a delta with
# one table of the right lengths is the length of a chain, so only the version
# can tell them apart.
comptime KG_DELTA_FORMAT_VERSION: Int64 = 4


@fieldwise_init
struct KgDeltaTableEntry(Copyable, Movable):
    """One changed table in a delta: the delta object that holds its rows.

    Fields:
        name: The table name.
        object_key: The content-addressed key of the delta object (the rows
            added or superseded for this table since the parent).
        schema_version: The table's schema version.
        row_count: Rows in the delta object (a diagnostic).
    """

    var name: String
    var object_key: String
    var schema_version: Int64
    var row_count: Int64


@fieldwise_init
struct KgNameIndexEntry(Copyable, Movable):
    """One exact-name index entry.

    Fields:
        normalized_name: The name after the host's normalization.
        nid: The id of the node the name resolves to.
    """

    var normalized_name: String
    var nid: Int64


struct KgNameIndexBody(Copyable, Movable):
    """The `{normalized_name -> id}` entries one delta adds.

    A reader folds every delta's entries in apply order into one map, later
    entries winning, so an exact-name match resolves without loading the
    entities table.
    """

    var entries: List[KgNameIndexEntry]

    def __init__(out self):
        """An index with no entries."""
        self.entries = List[KgNameIndexEntry]()

    def __init__(out self, var entries: List[KgNameIndexEntry]):
        """An index holding `entries`, moved in."""
        self.entries = entries^

    @always_inline
    def num_entries(self) -> Int:
        """The number of entries."""
        return len(self.entries)

    def add(mut self, var normalized_name: String, nid: Int64):
        """Append one entry."""
        self.entries.append(KgNameIndexEntry(normalized_name^, nid))

    def encode(self) -> List[UInt8]:
        """Encode to the wire form (a count, then each name and id)."""
        var out = List[UInt8]()
        self.encode_into(out)
        return out^

    def encode_into(self, mut out: List[UInt8]):
        """Append the wire form to `out`."""
        put_i64_le(out, Int64(len(self.entries)))
        for i in range(len(self.entries)):
            ref e = self.entries[i]
            put_str(out, e.normalized_name)
            put_i64_le(out, e.nid)

    @staticmethod
    def decode(bytes: List[UInt8], mut off: Int) raises -> KgNameIndexBody:
        """Decode an index starting at `off` and advance `off` past it.

        Raises:
            On a truncated body, a negative count, a count the remaining bytes
            cannot hold, or a name that is not UTF-8.
        """
        var who = String("KgNameIndexBody.decode")
        var count = Int(get_i64_le(bytes, off, who))
        off += 8
        if count < 0:
            raise Error(who + ": negative entry count " + String(count))
        # Each entry is at least 16 bytes (a length and an id).
        if count > (len(bytes) - off) // 16:
            raise Error(who + ": truncated entry list")
        var entries = List[KgNameIndexEntry]()
        for _ in range(count):
            var name = get_str(bytes, off, who, "normalized name")
            var nid = get_i64_le(bytes, off, who)
            off += 8
            entries.append(KgNameIndexEntry(name^, nid))
        return KgNameIndexBody(entries^)


struct KgDeltaBody(Movable):
    """One ingest's diff: the changed tables and the name-index entries it adds.

    `format_version` is always `KG_DELTA_FORMAT_VERSION`. `tables` holds one
    entry per changed table, in the order the writer added them.
    """

    var format_version: Int64
    var tables: List[KgDeltaTableEntry]
    var name_index: KgNameIndexBody

    def __init__(out self):
        """A delta that changes nothing."""
        self.format_version = KG_DELTA_FORMAT_VERSION
        self.tables = List[KgDeltaTableEntry]()
        self.name_index = KgNameIndexBody()

    def __init__(
        out self,
        var tables: List[KgDeltaTableEntry],
        var name_index: KgNameIndexBody,
    ):
        """A delta over `tables` and `name_index`, moved in."""
        self.format_version = KG_DELTA_FORMAT_VERSION
        self.tables = tables^
        self.name_index = name_index^

    @always_inline
    def num_tables(self) -> Int:
        """The number of changed tables."""
        return len(self.tables)

    def add_table(
        mut self,
        var name: String,
        var object_key: String,
        schema_version: Int64,
        row_count: Int64,
    ) raises:
        """Append one changed table (write side).

        Raises:
            If `schema_version` or `row_count` is negative, or the delta
            already names `name`.
        """
        if schema_version < 0:
            raise Error(
                "KgDeltaBody.add_table: negative schema_version "
                + String(schema_version)
            )
        if row_count < 0:
            raise Error(
                "KgDeltaBody.add_table: negative row_count " + String(row_count)
            )
        if self.has_table(name):
            raise Error("KgDeltaBody.add_table: table named twice: " + name)
        self.tables.append(
            KgDeltaTableEntry(name^, object_key^, schema_version, row_count)
        )

    def add_index_entry(mut self, var normalized_name: String, nid: Int64):
        """Append one name-index entry."""
        self.name_index.add(normalized_name^, nid)

    def has_table(self, name: String) -> Bool:
        """True iff the delta changes a table called `name`."""
        for i in range(len(self.tables)):
            if self.tables[i].name == name:
                return True
        return False

    def resolve(self, name: String) raises -> KgDeltaTableEntry:
        """The entry for `name`; raises if the delta does not change it."""
        for i in range(len(self.tables)):
            if self.tables[i].name == name:
                return self.tables[i].copy()
        raise Error("KgDeltaBody.resolve: table not present in delta: " + name)

    def encode(self) -> List[UInt8]:
        """Encode to the little-endian wire form (format version 4)."""
        var out = List[UInt8]()
        put_i64_le(out, self.format_version)
        put_i64_le(out, Int64(len(self.tables)))
        for i in range(len(self.tables)):
            ref e = self.tables[i]
            put_str(out, e.name)
            put_str(out, e.object_key)
            put_i64_le(out, e.schema_version)
            put_i64_le(out, e.row_count)
        self.name_index.encode_into(out)
        return out^

    @staticmethod
    def decode(bytes: List[UInt8]) raises -> KgDeltaBody:
        """Decode the wire form (format version 4 only).

        Raises:
            On any of the refusals the file header lists.
        """
        var who = String("KgDeltaBody.decode")
        var fmt = get_i64_le(bytes, 0, who)
        if fmt != KG_DELTA_FORMAT_VERSION:
            raise Error(
                who
                + ": unsupported delta format version "
                + String(fmt)
                + " (this build understands "
                + String(KG_DELTA_FORMAT_VERSION)
                + ")"
            )
        var table_count = Int(get_i64_le(bytes, 8, who))
        if table_count < 0:
            raise Error(who + ": negative table_count " + String(table_count))
        var off = 16
        # Each table entry is at least 32 bytes (two lengths, two i64).
        if table_count > (len(bytes) - off) // 32:
            raise Error(who + ": truncated table list")
        var delta = KgDeltaBody()
        # Names seen so far: a set, so a hostile count of tables costs linear
        # time (has_table scans).
        var seen = Dict[String, Bool]()
        for _ in range(table_count):
            var name = get_str(bytes, off, who, "table name")
            var key = get_str(bytes, off, who, "object_key")
            var schema_version = get_i64_le(bytes, off, who)
            off += 8
            var row_count = get_i64_le(bytes, off, who)
            off += 8
            if schema_version < 0:
                raise Error(
                    who + ": negative schema_version " + String(schema_version)
                )
            if row_count < 0:
                raise Error(who + ": negative row_count " + String(row_count))
            if name in seen:
                raise Error(who + ": table named twice: " + name)
            seen[name] = True
            delta.tables.append(
                KgDeltaTableEntry(name^, key^, schema_version, row_count)
            )
        delta.name_index = KgNameIndexBody.decode(bytes, off)
        if off != len(bytes):
            raise Error(
                who
                + ": "
                + String(len(bytes) - off)
                + " trailing bytes after the name index"
            )
        return delta^


struct KgChainBody(Copyable, Movable):
    """The head of the chain: a base chunk and the deltas applied over it.

    `base_seq` is the manifest chunk sequence number of the base
    (`KgManifestBody`); `delta_seqs` are the sequence numbers of the
    `KgDeltaBody` chunks in apply order. A chain just after compaction has no
    deltas.
    """

    var format_version: Int64
    var base_seq: Int64
    var delta_seqs: List[Int64]

    def __init__(out self, base_seq: Int64) raises:
        """A chain of `base_seq` alone.

        Raises:
            If `base_seq` is negative.
        """
        if base_seq < 0:
            raise Error(
                "KgChainBody: negative base_seq " + String(base_seq)
            )
        self.format_version = KG_CHAIN_FORMAT_VERSION
        self.base_seq = base_seq
        self.delta_seqs = List[Int64]()

    def __init__(out self, base_seq: Int64, var delta_seqs: List[Int64]) raises:
        """A chain of `base_seq` and `delta_seqs` (apply order), moved in.

        Raises:
            If a sequence number is negative.
        """
        if base_seq < 0:
            raise Error(
                "KgChainBody: negative base_seq " + String(base_seq)
            )
        for i in range(len(delta_seqs)):
            if delta_seqs[i] < 0:
                raise Error(
                    "KgChainBody: negative delta_seq " + String(delta_seqs[i])
                )
        self.format_version = KG_CHAIN_FORMAT_VERSION
        self.base_seq = base_seq
        self.delta_seqs = delta_seqs^

    @always_inline
    def num_deltas(self) -> Int:
        """The number of deltas over the base."""
        return len(self.delta_seqs)

    def append_delta(mut self, delta_seq: Int64) raises:
        """Append one delta sequence number (apply order).

        Raises:
            If `delta_seq` is negative.
        """
        if delta_seq < 0:
            raise Error(
                "KgChainBody.append_delta: negative delta_seq "
                + String(delta_seq)
            )
        self.delta_seqs.append(delta_seq)

    def encode(self) -> List[UInt8]:
        """Encode to the little-endian wire form (format version 3)."""
        var out = List[UInt8]()
        put_i64_le(out, self.format_version)
        put_i64_le(out, self.base_seq)
        put_i64_le(out, Int64(len(self.delta_seqs)))
        for i in range(len(self.delta_seqs)):
            put_i64_le(out, self.delta_seqs[i])
        return out^

    @staticmethod
    def decode(bytes: List[UInt8]) raises -> KgChainBody:
        """Decode the wire form (format version 3 only).

        Raises:
            On a truncated body, an unknown version, a negative sequence number
            or count, a count the remaining bytes cannot hold, or bytes left
            after the last sequence number.
        """
        var who = String("KgChainBody.decode")
        var fmt = get_i64_le(bytes, 0, who)
        if fmt != KG_CHAIN_FORMAT_VERSION:
            raise Error(
                who
                + ": unsupported chain format version "
                + String(fmt)
                + " (this build understands "
                + String(KG_CHAIN_FORMAT_VERSION)
                + ")"
            )
        var base_seq = get_i64_le(bytes, 8, who)
        if base_seq < 0:
            raise Error(who + ": negative base_seq " + String(base_seq))
        var delta_count = Int(get_i64_le(bytes, 16, who))
        if delta_count < 0:
            raise Error(who + ": negative delta_count " + String(delta_count))
        var off = 24
        if delta_count > (len(bytes) - off) // 8:
            raise Error(who + ": truncated delta list")
        var deltas = List[Int64](capacity=delta_count)
        for _ in range(delta_count):
            var seq = get_i64_le(bytes, off, who)
            off += 8
            if seq < 0:
                raise Error(who + ": negative delta_seq " + String(seq))
            deltas.append(seq)
        if off != len(bytes):
            raise Error(
                who
                + ": "
                + String(len(bytes) - off)
                + " trailing bytes after the last delta_seq"
            )
        return KgChainBody(base_seq, deltas^)


def kg_chunk_is_chain_head(bytes: List[UInt8]) raises -> Bool:
    """Whether a head chunk body is a `KgChainBody` (True) or a base-only
    `KgManifestBody` (False), read from its format version.

    A delta body is not a head chunk: its version (4) is refused.

    Raises:
        On a body shorter than eight bytes or a version that is neither.
    """
    var who = String("kg_chunk_is_chain_head")
    var fmt = get_i64_le(bytes, 0, who)
    if fmt == KG_CHAIN_FORMAT_VERSION:
        return True
    if fmt == KG_SNAPSHOT_FORMAT_VERSION:
        return False
    raise Error(
        who
        + ": unknown chunk format version "
        + String(fmt)
        + " (expected "
        + String(KG_SNAPSHOT_FORMAT_VERSION)
        + " base or "
        + String(KG_CHAIN_FORMAT_VERSION)
        + " chain)"
    )
