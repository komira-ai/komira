# =============================================================================
# ParquetNumRowsCache -- session-scoped (path, file_size) -> num_rows cache
# =============================================================================
#
# Stores ONLY `(path, file_size) -> num_rows`, for a caller that answers
# `SELECT COUNT(*) FROM read_parquet(path)` from the footer: the only piece of
# footer data it needs is the file-level `num_rows`.
#
# Why this is its own struct (not part of a full-footer cache):
#   - A full-footer cache materializes the whole `FileMetaData` (every
#     RowGroup x every ColumnChunk's Statistics), and copying a cached entry
#     out costs more again. For count(*) the hit path should be near-zero:
#     1 string compare + 1 size probe + Int copy. This struct delivers that.
#   - The miss inserts only `(path, file_size, num_rows)`, which is cheap.
#
# DuckDB reference: DuckDB's ObjectCache stores `ParquetFileMetadataCache`
# entries keyed on `file.path` with `(file_size)` validity. This struct
# follows the same pattern.
#
# Validity model: `(path, file_size)`. A file whose size matches but
# contents have changed in-place will return stale num_rows -- this is
# acceptable for query paths that do not mutate files in-place.
#
# Concurrency: NOT thread-safe. Mutated only from the thread that owns the
# session; worker threads never touch this cache.
#
# Eviction: unbounded. A session has O(num_distinct_parquet_paths) entries,
# which is small in practice; a path whose size changes is refreshed in
# place, never added twice.
# =============================================================================

from komira_collections.slab import Slab
from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.footer_header import parse_metadata_num_rows_only


# =============================================================================
# _NumRowsEntry -- one cached (path, file_size, num_rows) record
# =============================================================================


struct _NumRowsEntry(Movable, Copyable):
    """One cached (path, file_size) -> num_rows mapping.

    Fields:
        path:        Cache key (the Parquet file path).
        file_size:   File size at parse time. Used to invalidate cache
                     hits on size mismatch.
        num_rows:    Total `num_rows` from the file footer.
        parse_count: Number of times `path` was parsed: 1, plus one per
                     refresh after its size changed. Test hook.
        hit_count:   Number of times the cache returned this entry on
                     lookup (excluding the initial insert). Test hook.
    """

    var path: String
    var file_size: Int
    var num_rows: Int
    var parse_count: Int
    var hit_count: Int

    def __init__(
        out self,
        var path: String,
        file_size: Int,
        num_rows: Int,
    ):
        self.path = path^
        self.file_size = file_size
        self.num_rows = num_rows
        self.parse_count = 1
        self.hit_count = 0


# =============================================================================
# ParquetNumRowsCache -- light-weight (path, file_size) -> num_rows cache
# =============================================================================


struct ParquetNumRowsCache(Movable, Deinitable):
    """Session-scoped cache of (path, file_size) -> num_rows.

    Lets a caller skip the footer read + parse on repeated
    `SELECT COUNT(*) FROM read_parquet(<same_path>)` within one session;
    the first call per path still pays the miss.

    Storage layout: `Slab[_NumRowsEntry]`. Linear scan keyed on
    `entry.path`; a session typically holds a handful of distinct paths.

    Lifetime: held by the session that owns it; drops with it.

    Concurrency: NOT thread-safe. See module-header comment.
    """

    var _entries: Slab[_NumRowsEntry]
    var _miss_count: Int
    """Total cache misses (= number of footer-num_rows parses). Test hook."""

    def __init__(out self):
        self._entries = Slab[_NumRowsEntry]()
        self._miss_count = 0

    def _find(self, path: String) -> Int:
        """Linear-scan lookup. Returns -1 on miss, else the slab index.

        # PERF: O(N) where N = num distinct paths cached. Typically <= 8.
        """
        for i in range(self._entries.len()):
            ref entry = self._entries[i]
            if entry.path == path:
                return i
        return -1

    def get_or_compute(mut self, path: String) raises -> Int:
        """Cache-hit-or-light-parse.

        Cache hit: return the cached num_rows. Validates that the cached
        entry's `file_size` still matches the on-disk file size via a
        cheap `open + seek-to-end` probe. On size mismatch the entry is
        refreshed in place (the file was rewritten -- DuckDB does the
        same).

        Cache miss: open the file, parse only the num_rows field from
        the footer (`parse_metadata_num_rows_only` — the route that pays
        neither the schema list nor the `ARROW:schema` byte search),
        insert into the cache, return.

        PERF (cache hit): O(N) string compare + 1 size probe + Int copy.
        """
        var idx = self._find(path)
        if idx >= 0:
            # Tentative hit: validate file_size via a cheap probe.
            ref entry_ref = self._entries[idx]
            var cached_size = entry_ref.file_size
            var cached_num_rows = entry_ref.num_rows
            # Probe the on-disk size; if changed, fall through to a fresh
            # parse + entry update.
            var current_size = _probe_file_size(path)
            if current_size == cached_size:
                entry_ref.hit_count = entry_ref.hit_count + 1
                return cached_num_rows
            _ = cached_num_rows  # unused on size-mismatch fallthrough

        # Cache miss (or size-mismatch refresh).
        self._miss_count = self._miss_count + 1
        var reader = ParquetFileReader[LocalFs[NoopSink]].open_metadata_only(path)
        var file_size = reader.file_size
        # `parse_metadata_num_rows_only`, NOT the header+schema parse: this
        # call site wants a row count and nothing else, and the header+schema
        # parse also builds the `SchemaElement` list and searches the footer
        # for `ARROW:schema`, which is O(footer) whenever the key is absent.
        # (`open_metadata_only` and not `open`: this reader wants the footer
        # and nothing else, and `open` would map the whole file.)
        var nr = parse_metadata_num_rows_only(
            reader.metadata_bytes.view_range_ro(0, reader.metadata_length)
        )
        var num_rows = nr.num_rows
        if idx >= 0:
            # Size changed: refresh the stale entry in place, so a later
            # lookup finds the new size instead of the stale entry.
            ref stale = self._entries[idx]
            stale.file_size = file_size
            stale.num_rows = num_rows
            stale.parse_count = stale.parse_count + 1
            return num_rows
        var entry = _NumRowsEntry(String(path), file_size, num_rows)
        self._entries.append(entry^)
        return num_rows

    @always_inline
    def size(self) -> Int:
        """Number of cached entries. Test hook."""
        return self._entries.len()

    @always_inline
    def miss_count(self) -> Int:
        """Total number of footer-num_rows parses paid (= cache misses).
        Test hook. Invariant for files that do not change:
        `miss_count == num_distinct_paths` (1 parse per file)."""
        return self._miss_count

    def hit_count_for(self, path: String) -> Int:
        """Number of times `path` was returned from cache. Test hook.
        Returns 0 on miss."""
        var idx = self._find(path)
        if idx < 0:
            return 0
        return self._entries[idx].hit_count

    def parse_count_for(self, path: String) -> Int:
        """Number of times `path` was parsed. Test hook. Returns 0 on miss."""
        var idx = self._find(path)
        if idx < 0:
            return 0
        return self._entries[idx].parse_count


# =============================================================================
# _probe_file_size -- cheap open + seek-to-end size probe
# =============================================================================
#
# The FileHandle is wholly contained inside this helper; no raw pointer or
# wildcard origin crosses the function boundary.
# =============================================================================


def _probe_file_size(path: String) raises -> Int:
    """Probe the on-disk size of `path` via `open + seek to the end`.

    Raises if the file cannot be opened. Returns the size in bytes.
    """
    var f = FileHandle(path, "r")
    _ = f.seek(0, 2)  # SEEK_END
    var size = Int(f.seek(0, 1))  # SEEK_CUR = tell
    f.close()
    return size
