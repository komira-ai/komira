# =============================================================================
# footer_cache -- one shared, locked cache of parsed Parquet footers
# =============================================================================
#
# `FooterCache` is the cache the SQL binder and lowering's inputs share. A copy
# of a `FooterCache` is another handle on the same state (a reference-count
# bump), so a `ParquetFooters` given to `bind_statement` and the cache lowering's
# inputs are built from are one cache, and a file's footer is read from storage
# once however many lookups and handles there are.
#
# One footer per path, for the life of the cache. A lookup (`footer`, `summary`)
# never stats the file and never re-reads a footer it holds, so the footer the binder saw is the
# footer lowering reads even when the file is rewritten between the two. That is
# why this is not `komira_parquet.ParquetMetadataCache`'s shared surface: over
# a local file system that surface revalidates each hit and re-parses an entry
# whose file changed or is younger than its settle threshold, which would let
# bind and lowering see two versions of one file. What this cache stores with
# each footer is the file's identity (size, modification time, inode, device),
# stamped before the bytes were read, and `changed_since_read` is how a caller
# asks whether the file at a path is still that one (the one place this cache
# stats a file after the first read) (the source's check at
# open, design section 3.4). `invalidate` is the explicit way to forget a path.
#
# It reads a footer with the reader `komira_parquet` already has
# (`ParquetFileReader.open_metadata_only` and `parse_full_metadata`), keeps the
# parsed `FileMetaData` behind an `ArcPointer` (a lookup is a reference-count
# bump, not a copy), and sits behind a `SpinMutex`, because the binder's trait
# methods take `self`, not `mut self`.
#
# KNOWN LIMITS. (1) The cache is unbounded: one full `FileMetaData` per path for
# the life of the cache, found by a linear scan under the lock. A cap with
# eviction conflicts with one version per path; `EngineContext` must not hold
# this cache uncapped for a long-lived session (a per-query pin is the likely
# shape). (2) The lock is held across the file read and the parse, so a lookup
# waits behind another path's slow read. (3) The identity check is a field
# comparison (`same_file_as`); it does not apply the settle rule of
# `komira_buffer.file_identity`, so a same-size rewrite within the timestamp
# tick of a file younger than the settle window can go unseen.
#
# Errors name the file: a path that is not there, a file too short to be
# Parquet, a file whose footer does not parse, a footer the flat-schema reader
# refuses are each an `Error` whose text starts `parquet footer '<path>': `. A
# failed read caches nothing: the next lookup reads again.
# =============================================================================

from std.memory import ArcPointer

from komira_arrow.schema import Schema, SchemaBuilder
from komira_async.ops.waker_sink import NoopSink
from komira_buffer.file_identity import FileIdentity
from komira_fs.local_fs import LocalFs
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.decode_helpers import field_from_schema_element
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_api.types import FieldRepetitionType
from komira_sync import SpinMutex

comptime _MIN_PARQUET_BYTES = 12
"""Leading magic, footer length and trailing magic."""


def footer_error(path: String, reason: String) -> String:
    """The text of every error this package raises about one file."""
    return "parquet footer '" + path + "': " + reason


struct FooterSummary(Movable):
    """A footer's row count and its flat Arrow schema. `Schema` is move-only,
    so `take_schema` moves it out."""

    var row_count: Int
    var _schema: Optional[Schema]

    def __init__(out self, row_count: Int, var schema: Schema):
        self.row_count = row_count
        self._schema = Optional[Schema](schema^)

    def take_schema(mut self) -> Schema:
        return self._schema.take()


def _summarize(path: String, meta: FileMetaData) raises -> FooterSummary:
    """The row count and Arrow schema of `meta`, flat files only: a footer with
    no schema, a negative `num_rows`, or (after the root) a group or repeated
    element is refused, naming the file."""
    if len(meta.schema) == 0:
        raise Error(footer_error(path, "no schema in the footer"))
    if meta.num_rows < 0:
        raise Error(
            footer_error(
                path, "negative num_rows (" + String(meta.num_rows) + ")"
            )
        )
    for c in range(1, len(meta.schema)):
        ref e = meta.schema[c]
        var repeated = False
        if e.repetition_type:
            repeated = e.repetition_type.value() == FieldRepetitionType.REPEATED
        if e.num_children > 0 or repeated:
            raise Error(
                footer_error(
                    path,
                    "column '" + e.name
                    + "' is nested or repeated; only flat files are read",
                )
            )
    var sb = SchemaBuilder()
    for c in range(1, len(meta.schema)):
        sb.add_field(field_from_schema_element(meta.schema[c]))
    return FooterSummary(meta.num_rows, sb.build())


struct _CacheState(Movable, Deinitable):
    """What every handle of a `FooterCache` reaches. The mutex guards all of
    it."""

    var mutex: SpinMutex
    var paths: List[String]
    var metas: List[ArcPointer[FileMetaData]]
    var identities: List[FileIdentity]
    var reads: Int
    var hits: List[Int]

    def __init__(out self):
        self.mutex = SpinMutex()
        self.paths = List[String]()
        self.metas = List[ArcPointer[FileMetaData]]()
        self.identities = List[FileIdentity]()
        self.reads = 0
        self.hits = List[Int]()

    def index_of(self, path: String) -> Int:
        for i in range(len(self.paths)):
            if self.paths[i] == path:
                return i
        return -1

    def load(mut self, path: String) raises -> ArcPointer[FileMetaData]:
        """The parsed footer of `path`, read on a miss. The caller holds the
        mutex."""
        var at = self.index_of(path)
        if at >= 0:
            self.hits[at] += 1
            return ArcPointer[FileMetaData](copy=self.metas[at])
        # Stamped before the read: a rewrite between the stat and the read
        # leaves an older identity beside newer bytes, and reads as changed.
        var ident = FileIdentity.stat_path(path)
        if not ident.valid:
            raise Error(footer_error(path, "no such file, or it cannot be read"))
        if ident.size < _MIN_PARQUET_BYTES:
            raise Error(
                footer_error(
                    path,
                    "not a Parquet file: "
                    + String(ident.size)
                    + " bytes, and a Parquet file has at least "
                    + String(_MIN_PARQUET_BYTES),
                )
            )
        try:
            var reader = ParquetFileReader[LocalFs[NoopSink]].open_metadata_only(
                path
            )
            var meta = parse_full_metadata(
                reader.metadata_bytes.view_range_ro(0, reader.metadata_length)
            )
            self.reads += 1
            self.paths.append(path)
            self.identities.append(ident)
            self.hits.append(0)
            self.metas.append(ArcPointer[FileMetaData](meta^))
            return ArcPointer[FileMetaData](copy=self.metas[len(self.metas) - 1])
        except e:
            raise Error(
                footer_error(path, "not a readable Parquet file: " + String(e))
            )


struct FooterCache(Copyable, Movable):
    """A shared, locked cache of parsed Parquet footers; a copy is another
    handle on the same cache."""

    var _state: ArcPointer[_CacheState]

    def __init__(out self):
        self._state = ArcPointer[_CacheState](_CacheState())

    def footer(self, path: String) raises -> ArcPointer[FileMetaData]:
        """A share of the parsed footer of the file `path`: read and parsed on
        the first lookup, served from the cache after. This lookup does NOT
        check that the file is unchanged (`changed_since_read` does; the
        callers in `parquet_footers` and `lowering_facts` call it).

        Raises:
            Error naming `path` when it is not a file, is shorter than a
            Parquet file can be, or its footer does not read.
        """
        var st = ArcPointer[_CacheState](copy=self._state)
        ref s = st[]
        s.mutex.lock()
        try:
            var meta = s.load(path)
            s.mutex.unlock()
            return meta^
        except e:
            s.mutex.unlock()
            raise Error(String(e))

    def summary(self, path: String) raises -> FooterSummary:
        """The footer's row count and its schema as an Arrow `Schema` (flat
        files only), from the same cached read as `footer`. Like `footer`, it
        does not check that the file is unchanged.

        Raises:
            Error naming `path`, as `footer`, or when the schema is nested or
            repeated, has no columns, or `num_rows` is negative.
        """
        var meta = self.footer(path)
        return _summarize(path, meta[])

    def read_count(self) -> Int:
        """Footers read from storage and parsed so far, by this cache and
        every handle on it."""
        var st = ArcPointer[_CacheState](copy=self._state)
        ref s = st[]
        s.mutex.lock()
        var n = s.reads
        s.mutex.unlock()
        return n

    def lookup_count(self, path: String) -> Int:
        """Lookups of `path` served from the cache (the first read is not
        one); 0 for a path never read."""
        var st = ArcPointer[_CacheState](copy=self._state)
        ref s = st[]
        s.mutex.lock()
        var at = s.index_of(path)
        var n = s.hits[at] if at >= 0 else 0
        s.mutex.unlock()
        return n

    def changed_since_read(self, path: String) raises -> Bool:
        """True when the file at `path` is no longer the one whose footer was
        cached: its size, modification time, inode or device differ, or it
        cannot be stat'ed now.

        Raises:
            Error naming `path` when no footer of it was ever cached.
        """
        var st = ArcPointer[_CacheState](copy=self._state)
        ref s = st[]
        s.mutex.lock()
        var at = s.index_of(path)
        if at < 0:
            s.mutex.unlock()
            raise Error(footer_error(path, "no footer was read for this file"))
        var stamped = s.identities[at]
        s.mutex.unlock()
        return not stamped.same_file_as(FileIdentity.stat_path(path))

    def invalidate(self, path: String):
        """Forget `path`: the next lookup reads the file again. Footers already
        handed out stay valid."""
        var st = ArcPointer[_CacheState](copy=self._state)
        ref s = st[]
        s.mutex.lock()
        var at = s.index_of(path)
        if at >= 0:
            _ = s.paths.pop(at)
            _ = s.metas.pop(at)
            _ = s.identities.pop(at)
            _ = s.hits.pop(at)
        s.mutex.unlock()
