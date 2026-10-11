# =============================================================================
# page_index_cache — parsed page indexes, kept per (file, row group, column)
# =============================================================================
#
# `ParquetPageIndexCache` keeps each column chunk's parsed ColumnIndex and
# OffsetIndex, so a file's page indexes are read and parsed once however
# many filters and workers consult them. Page indexes are not part of the
# footer cache (`runtime_footer_cache`): a query that pushes no filter never
# reads them.
#
# `get_or_parse_indexes_copy` is the one entry point. It holds the cache's
# lock (`komira_sync.SpinMutex`) across the lookup, the read and parse of a
# miss, the insert, and the copy it returns, and releases it on every path,
# raises included. It returns copies, never references into the cache, so
# a later insert (which may move the entries) cannot invalidate what a
# caller holds. Entries are found by a linear scan: a scan touches a few
# columns of a few row groups.
# =============================================================================

from komira_fs.file_system import FileSystem
from komira_sync.spin_mutex import SpinMutex

from .file_reader import ParquetFileReader
from .page_index import ColumnIndex, OffsetIndex
from .page_index_parser import parse_column_index_int64, parse_offset_index


struct _PageIndexEntry(Copyable, Movable):
    """One column chunk's parsed indexes, keyed by (path, rg_idx,
    col_idx), with how often it was parsed (1) and returned on a hit."""

    var path: String
    var rg_idx: Int
    var col_idx: Int
    var column_index: ColumnIndex
    var offset_index: OffsetIndex
    var parse_count: Int
    var hit_count: Int

    def __init__(
        out self,
        var path: String,
        rg_idx: Int,
        col_idx: Int,
        var column_index: ColumnIndex,
        var offset_index: OffsetIndex,
    ):
        self.path = path^
        self.rg_idx = rg_idx
        self.col_idx = col_idx
        self.column_index = column_index^
        self.offset_index = offset_index^
        self.parse_count = 1
        self.hit_count = 0


struct _ParsedIndexes(Movable):
    """A copy of one chunk's (ColumnIndex, OffsetIndex), owned by the
    caller. Take each out once, or borrow them."""

    var _column_index: Optional[ColumnIndex]
    var _offset_index: Optional[OffsetIndex]

    def __init__(
        out self, var column_index: ColumnIndex, var offset_index: OffsetIndex
    ):
        self._column_index = column_index^
        self._offset_index = offset_index^

    def take_column_index(mut self) -> ColumnIndex:
        return self._column_index.take()

    def take_offset_index(mut self) -> OffsetIndex:
        return self._offset_index.take()

    def column_index_ref(ref self) -> ref [self._column_index._value] ColumnIndex:
        return self._column_index.value()

    def offset_index_ref(ref self) -> ref [self._offset_index._value] OffsetIndex:
        return self._offset_index.value()


struct ParquetPageIndexCache(Movable):
    """Parsed page indexes by (path, row group, column). See the module
    header for the locking."""

    var _entries: List[_PageIndexEntry]
    var _miss_count: Int
    var _lock: SpinMutex

    def __init__(out self):
        self._entries = List[_PageIndexEntry]()
        self._miss_count = 0
        self._lock = SpinMutex()

    def _find(self, path: String, rg_idx: Int, col_idx: Int) -> Int:
        """The entry's index, or -1. The caller holds the lock."""
        for i in range(len(self._entries)):
            ref e = self._entries[i]
            if e.rg_idx == rg_idx and e.col_idx == col_idx and e.path == path:
                return i
        return -1

    def size(self) -> Int:
        """The number of entries (read without the lock: for a caller with
        no concurrent lookup)."""
        return len(self._entries)

    def miss_count(self) -> Int:
        """How many lookups parsed (one per distinct chunk looked up)."""
        return self._miss_count

    def parse_count_for(self, path: String, rg_idx: Int, col_idx: Int) -> Int:
        """How many times that chunk's indexes were parsed (0 if never)."""
        var i = self._find(path, rg_idx, col_idx)
        return 0 if i < 0 else self._entries[i].parse_count

    def hit_count_for(self, path: String, rg_idx: Int, col_idx: Int) -> Int:
        """How many lookups of that chunk were served from the cache."""
        var i = self._find(path, rg_idx, col_idx)
        return 0 if i < 0 else self._entries[i].hit_count

    def invalidate(mut self, path: String):
        """Drop every entry of `path` (the file was rewritten)."""
        self._lock.lock()
        var kept = List[_PageIndexEntry]()
        for i in range(len(self._entries)):
            if self._entries[i].path != path:
                kept.append(self._entries[i].copy())
        self._entries = kept^
        self._lock.unlock()


def _lookup_or_parse[FS: FileSystem](
    mut cache: ParquetPageIndexCache,
    reader: ParquetFileReader[FS],
    path: String,
    rg_idx: Int,
    col_idx: Int,
    column_index_offset: Int,
    column_index_length: Int,
    offset_index_offset: Int,
    offset_index_length: Int,
) raises -> _ParsedIndexes:
    """`get_or_parse_indexes_copy`'s body; the caller holds the lock."""
    var at = cache._find(path, rg_idx, col_idx)
    if at >= 0:
        cache._entries[at].hit_count += 1
        ref e = cache._entries[at]
        return _ParsedIndexes(e.column_index.copy(), e.offset_index.copy())
    if column_index_length <= 0 or offset_index_length <= 0:
        raise Error(
            "page index cache: rg "
            + String(rg_idx)
            + " col "
            + String(col_idx)
            + " has an empty page index"
        )
    cache._miss_count += 1
    var ci_buf = reader.read_bytes(column_index_offset, column_index_length)
    var ci = parse_column_index_int64(ci_buf.view_range_ro(0, column_index_length))
    var oi_buf = reader.read_bytes(offset_index_offset, offset_index_length)
    var oi = parse_offset_index(oi_buf.view_range_ro(0, offset_index_length))
    if ci.num_pages != oi.num_pages:
        raise Error(
            "page index cache: rg "
            + String(rg_idx)
            + " col "
            + String(col_idx)
            + ": the ColumnIndex has "
            + String(ci.num_pages)
            + " pages and the OffsetIndex "
            + String(oi.num_pages)
        )
    var out = _ParsedIndexes(ci.copy(), oi.copy())
    cache._entries.append(_PageIndexEntry(String(path), rg_idx, col_idx, ci^, oi^))
    return out^


def get_or_parse_indexes_copy[FS: FileSystem](
    mut cache: ParquetPageIndexCache,
    reader: ParquetFileReader[FS],
    path: String,
    rg_idx: Int,
    col_idx: Int,
    column_index_offset: Int,
    column_index_length: Int,
    offset_index_offset: Int,
    offset_index_length: Int,
) raises -> _ParsedIndexes:
    """The (ColumnIndex, OffsetIndex) of column `col_idx` of row group
    `rg_idx` of `path`, from the cache or read (from the given file ranges
    of `reader`, which must be `path`'s) and parsed on a miss. Returns
    copies.

    Raises:
        Error if a length is not positive, a range is outside the file, a
        blob does not parse, or the two indexes disagree on the page count
        (the cache is left unchanged).
    """
    cache._lock.lock()
    try:
        var out = _lookup_or_parse(
            cache,
            reader,
            path,
            rg_idx,
            col_idx,
            column_index_offset,
            column_index_length,
            offset_index_offset,
            offset_index_length,
        )
        cache._lock.unlock()
        return out^
    except e:
        cache._lock.unlock()
        raise e^
