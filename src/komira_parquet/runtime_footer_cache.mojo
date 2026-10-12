# =============================================================================
# ParquetMetadataCache: a session's cache of parsed Parquet footers
# =============================================================================
#
# One parsed footer per path for the life of the cache (a session), so a
# file read by many queries, or by many workers of one query, is fetched and
# parsed once. The same shape as DuckDB's ParquetFileMetadataCache, keyed by
# path.
#
# An entry holds:
#   * the parsed `FileMetaData`, behind an `ArcPointer`: the shared surface
#     (`get_or_parse_shared_via_fs`) hands each reader a refcount bump, the
#     value surface (`get_or_parse_via_fs`, the `MetadataCache` trait) a deep
#     copy;
#   * the raw preamble (file size, footer length and bytes), so a reader
#     built from the entry needs no storage round trip;
#   * on an mmap-backed file system, a pinned whole-file mapping (taken on the
#     first shared request, within the budget of `footer_pin_budget`), so the
#     mapping outlives a query: the next query neither maps nor unmaps it;
#   * on an mmap-backed file system, the file's identity (size, mtime, inode,
#     device) stamped before its bytes were read.
#
# Staleness. A file rewritten under a live cache with its footer AND its
# bytes pinned would be served as a consistent snapshot of the old file, with
# no error. So every hit on the shared surface over an mmap-backed file
# system re-stats the path (one `stat(2)` per file per query) and compares it
# with the stamped identity; any difference, a failed stat, or an mtime
# younger than the settle threshold (`FileIdentity` trusts an mtime only once
# it is older than the file system's timestamp resolution; 10 s by default)
# drops the pin and re-parses the entry in place. Other surfaces, and file
# systems that are not mmap-backed, serve the cached footer without a stat;
# `invalidate(path)` is the explicit way out for a caller that knows.
#
# The cache also remembers the speculative footer window per dataset
# (`FooterWindowHints`), and memoizes the flat per-row-group row counts of a
# path set (`resolve_rg_counts_via_fs`, for `row_window`).
#
# Not thread-safe: one owner mutates it. Readers built from it hold their own
# shares of the footer and the mapping and never touch the cache.
# =============================================================================

from std.memory import ArcPointer

from komira_async.ops.waker_sink import NoopSink
from komira_buffer.file_identity import DEFAULT_STALENESS_MIN_AGE_NS, FileIdentity, cached_entry_is_trustworthy
from komira_buffer.mmap_region import MmapRegion
from komira_collections.slab import Slab
from komira_fs.file_system import FileSystem
from komira_fs.footer_window_hints import FooterWindowHints
from komira_fs.local_fs import LocalFs
from komira_fs.metadata_cache import MetadataCache
from komira_parquet_api.metadata import ColumnChunk, FileMetaData, RowGroup, SchemaElement
from komira_parquet.file_reader import ParquetFilePreamble, read_parquet_preamble
from komira_parquet.footer_pin_budget import DEFAULT_MMAP_PIN_BYTE_CAP, resolve_mmap_pin_byte_cap
from komira_parquet.metadata_parser import parse_full_metadata


def _share_mmap(m: Optional[ArcPointer[MmapRegion]]) -> Optional[ArcPointer[MmapRegion]]:
    """A refcount bump on a pinned mapping, or None."""
    if m:
        return ArcPointer[MmapRegion](copy=m.value())
    return None


struct SharedParquetFooter(Movable, Deinitable):
    """What a reader needs from the cache, with no storage I/O: the parsed
    footer (shared), the raw preamble (shared) and, when the cache pins the
    file's mapping, a share of it.

    `mmap` is Some: the reader adopts this mapping instead of mapping the
    file itself, and the mapping outlives the query. None: no pin (a file
    system that is not mmap-backed, the budget declined the file, the map
    failed, or the caller asked for none), and the reader maps the file
    itself.
    """

    var meta: ArcPointer[FileMetaData]
    var preamble: ParquetFilePreamble
    var mmap: Optional[ArcPointer[MmapRegion]]

    def __init__(
        out self,
        var meta: ArcPointer[FileMetaData],
        var preamble: ParquetFilePreamble,
        var mmap: Optional[ArcPointer[MmapRegion]] = None,
    ):
        self.meta = meta^
        self.preamble = preamble^
        self.mmap = mmap^

    def mmap_share(self) -> Optional[ArcPointer[MmapRegion]]:
        """A refcount bump on the pinned mapping, or None."""
        return _share_mmap(self.mmap)


struct _FooterEntry(Movable):
    """One cached footer. `parse_count` counts the parses of this path (1
    unless revalidation re-parsed it); `hit_count` the lookups served from
    the entry (a populate is not a hit). `identity` is invalid on a file
    system that is not mmap-backed, and never consulted there."""

    var path: String
    var file_size: Int
    var metadata: ArcPointer[FileMetaData]
    var preamble: ParquetFilePreamble
    var parse_count: Int
    var hit_count: Int
    var mmap: Optional[ArcPointer[MmapRegion]]
    var identity: FileIdentity

    def __init__(
        out self,
        var path: String,
        file_size: Int,
        var metadata: ArcPointer[FileMetaData],
        var preamble: ParquetFilePreamble,
        var mmap: Optional[ArcPointer[MmapRegion]],
        identity: FileIdentity,
        parse_count: Int = 1,
        hit_count: Int = 0,
    ):
        self.path = path^
        self.file_size = file_size
        self.metadata = metadata^
        self.preamble = preamble^
        self.parse_count = parse_count
        self.hit_count = hit_count
        self.mmap = mmap^
        self.identity = identity


struct _RgCountsEntry(Copyable, Movable):
    """The flat per-row-group row counts of an ordered path set. `key` is
    the full set (count and newline-joined paths), not a hash, so a hit can
    never serve another set's counts."""

    var key: String
    var rg_counts: List[Int]

    def __init__(out self, var key: String, var rg_counts: List[Int]):
        self.key = key^
        self.rg_counts = rg_counts^


struct ParquetMetadataCache(MetadataCache, Movable, Deinitable):
    """A session's parsed Parquet footers, by path. See the module header.

    Lookup is a linear scan of the entries (a session reads few distinct
    files per query). The counters are the cache's observable behaviour and
    are what its tests assert on.
    """

    comptime T = FileMetaData

    var _entries: Slab[_FooterEntry]
    var _miss_count: Int
    var _deep_copy_count: Int
    var _shared_clone_count: Int
    var _rg_counts_cache: List[_RgCountsEntry]
    var _rg_counts_cache_hits: Int
    var _rg_counts_cache_misses: Int
    var _row_window_footer_reads: Int
    var _window_hints: FooterWindowHints
    var _mmap_pin_byte_cap: Int
    var _mmap_pinned_bytes: Int
    var _mmap_pin_count: Int
    var _mmap_pin_declined: Int
    var _mmap_pin_failed: Int
    var _mmap_revalidate_min_age_ns: Int
    var _revalidate_stat_count: Int
    var _revalidate_drop_count: Int

    def __init__(
        out self,
        mmap_pin_byte_cap: Int = DEFAULT_MMAP_PIN_BYTE_CAP,
        mmap_revalidate_min_age_ns: Int = DEFAULT_STALENESS_MIN_AGE_NS,
    ):
        """A cache whose pins total at most `mmap_pin_byte_cap` bytes, which
        trusts an mtime older than `mmap_revalidate_min_age_ns` (0 trusts
        any mtime; for tests)."""
        self._entries = Slab[_FooterEntry]()
        self._miss_count = 0
        self._deep_copy_count = 0
        self._shared_clone_count = 0
        self._rg_counts_cache = List[_RgCountsEntry]()
        self._rg_counts_cache_hits = 0
        self._rg_counts_cache_misses = 0
        self._row_window_footer_reads = 0
        self._window_hints = FooterWindowHints()
        self._mmap_pin_byte_cap = mmap_pin_byte_cap
        self._mmap_pinned_bytes = 0
        self._mmap_pin_count = 0
        self._mmap_pin_declined = 0
        self._mmap_pin_failed = 0
        self._mmap_revalidate_min_age_ns = mmap_revalidate_min_age_ns
        self._revalidate_stat_count = 0
        self._revalidate_drop_count = 0

    @staticmethod
    def ram_sized(override_bytes: Int = 0) -> ParquetMetadataCache:
        """A cache whose pin budget is sized to this machine
        (`resolve_mmap_pin_byte_cap`), or is `override_bytes` when that is
        positive."""
        return ParquetMetadataCache(mmap_pin_byte_cap=resolve_mmap_pin_byte_cap(override_bytes))

    # --- lookup and populate ------------------------------------------------

    def _find(self, path: String) -> Int:
        for i in range(self._entries.len()):
            if self._entries[i].path == path:
                return i
        return -1

    def _read_entry[FS: FileSystem](
        mut self, path: String, mut fs: FS, identity: FileIdentity
    ) raises -> _FooterEntry:
        """One preamble fetch (with the window this dataset has taught the
        hints) and its parse, as an unpinned entry. Counts a miss."""
        self._miss_count += 1
        var preamble = read_parquet_preamble[FS](fs, path, self._window_hints.suggest(path))
        self._window_hints.observe(path, preamble.metadata_length + 8)
        var metadata = parse_full_metadata(preamble.metadata_bytes.view_range_ro(0, preamble.metadata_length))
        var size = preamble.file_size
        return _FooterEntry(
            String(path),
            size,
            ArcPointer[FileMetaData](metadata^),
            preamble^,
            Optional[ArcPointer[MmapRegion]](None),
            identity,
        )

    def _ensure_index_via_fs[FS: FileSystem](mut self, path: String, mut fs: FS) raises -> Int:
        """The entry of `path`, read and parsed on a miss. No copy."""
        var idx = self._find(path)
        if idx >= 0:
            return idx
        # Stamp the identity BEFORE reading: a rewrite between the stat and
        # the read leaves an older identity beside newer bytes, and the next
        # revalidation re-reads. Stamped after, a torn read would pass.
        var ident = FileIdentity()
        comptime if FS.IS_MMAP_BACKED:
            ident = FileIdentity.stat_path(path)
        self._entries.append(self._read_entry[FS](path, fs, ident))
        return self._entries.len() - 1

    def get_or_parse_via_fs[FS: FileSystem](mut self, path: String, mut fs: FS) raises -> FileMetaData:
        """A deep copy of the footer of `path`, read through `fs` on a miss.
        The `MetadataCache` surface."""
        var misses = self._miss_count
        var idx = self._ensure_index_via_fs[FS](path, fs)
        if self._miss_count == misses:
            self._entries[idx].hit_count += 1
        self._deep_copy_count += 1
        return self._entries[idx].metadata[].copy()

    def get_or_parse(mut self, path: String) raises -> FileMetaData:
        """`get_or_parse_via_fs` over the local file system."""
        var fs = LocalFs[NoopSink].new()
        return self.get_or_parse_via_fs(path, fs)

    def get_or_parse_summary_via_fs[FS: FileSystem](
        mut self, path: String, mut fs: FS, mut out_schema_elements: List[SchemaElement]
    ) raises -> Int:
        """The footer's `num_rows`, with a copy of its schema appended to
        `out_schema_elements`. Copies no row group."""
        var misses = self._miss_count
        var idx = self._ensure_index_via_fs[FS](path, fs)
        if self._miss_count == misses:
            self._entries[idx].hit_count += 1
        ref meta = self._entries[idx].metadata[]
        for i in range(len(meta.schema)):
            out_schema_elements.append(meta.schema[i].copy())
        return meta.num_rows

    def get_or_parse_shared_via_fs[FS: FileSystem](
        mut self, path: String, mut fs: FS, pin_mmap: Bool = True
    ) raises -> SharedParquetFooter:
        """Shares of the footer, the preamble and (with `pin_mmap`, on an
        mmap-backed file system, within the budget) the pinned mapping.

        On a hit over an mmap-backed file system the entry is revalidated
        first (see the module header); a revalidation that re-parses counts
        as a miss, not a hit.
        """
        var misses = self._miss_count
        var idx = self._ensure_index_via_fs[FS](path, fs)
        comptime if FS.IS_MMAP_BACKED:
            if self._miss_count == misses:
                self._revalidate_entry_via_fs[FS](idx, path, fs)
        var mmap_pin = Optional[ArcPointer[MmapRegion]](None)
        comptime if FS.IS_MMAP_BACKED:
            if pin_mmap:
                mmap_pin = self._ensure_mmap_pin(idx, path)
        if self._miss_count == misses:
            self._entries[idx].hit_count += 1
        self._shared_clone_count += 1
        return SharedParquetFooter(
            ArcPointer[FileMetaData](copy=self._entries[idx].metadata),
            self._entries[idx].preamble.share(),
            mmap_pin^,
        )

    # --- the mapping pin and revalidation -----------------------------------

    def _ensure_mmap_pin(mut self, idx: Int, path: String) -> Optional[ArcPointer[MmapRegion]]:
        """A share of entry `idx`'s pinned mapping, mapping the file on the
        first request. None when the budget declines the file or the map
        fails: a pin is an optimisation and never fails a read (the caller
        maps the file itself)."""
        if self._entries[idx].mmap:
            return _share_mmap(self._entries[idx].mmap)
        var size = self._entries[idx].file_size
        if size <= 0 or self._mmap_pinned_bytes + size > self._mmap_pin_byte_cap:
            self._mmap_pin_declined += 1
            return None
        try:
            # Ranges are advised as a reader borrows them, as the file
            # reader's own mapping does: a scan reads the columns it projects.
            var arc = ArcPointer[MmapRegion](MmapRegion.open_readonly(path, advise_whole_file=False))
            var out = ArcPointer[MmapRegion](copy=arc)
            self._entries[idx].mmap = Optional[ArcPointer[MmapRegion]](arc^)
            self._mmap_pinned_bytes += size
            self._mmap_pin_count += 1
            return out^
        except:
            self._mmap_pin_failed += 1
            return None

    def _release_pin(mut self, idx: Int):
        """Drop the cache's share of entry `idx`'s mapping. A reader still
        holding a share keeps the mapping alive until it is done."""
        if self._entries[idx].mmap:
            self._mmap_pinned_bytes = max(0, self._mmap_pinned_bytes - self._entries[idx].file_size)
            self._entries[idx].mmap = Optional[ArcPointer[MmapRegion]](None)

    def _revalidate_entry_via_fs[FS: FileSystem](mut self, idx: Int, path: String, mut fs: FS) raises:
        """Re-stat `path`; unless the cached entry is still trustworthy,
        release its pin, forget the row-count memo, and re-read and re-parse
        it in place (the other entries are untouched)."""
        var current = FileIdentity.stat_path(path)
        self._revalidate_stat_count += 1
        if cached_entry_is_trustworthy(self._entries[idx].identity, current, self._mmap_revalidate_min_age_ns):
            return
        self._revalidate_drop_count += 1
        self._release_pin(idx)
        self._rg_counts_cache = List[_RgCountsEntry]()
        # The identity sampled before the read, as on a populate.
        var fresh = self._read_entry[FS](path, fs, current)
        fresh.parse_count = self._entries[idx].parse_count + 1
        fresh.hit_count = self._entries[idx].hit_count
        self._entries[idx] = fresh^

    # --- the row-window helpers ---------------------------------------------

    def rg_num_rows_via_fs[FS: FileSystem](mut self, path: String, mut fs: FS, mut out_counts: List[Int]) raises:
        """Append the row count of each row group of `path`. Copies no
        footer."""
        var idx = self._ensure_index_via_fs[FS](path, fs)
        ref meta = self._entries[idx].metadata[]
        for r in range(len(meta.row_groups)):
            out_counts.append(meta.row_groups[r].num_rows)

    def stripped_footer_via_fs[FS: FileSystem](mut self, path: String, mut fs: FS) raises -> FileMetaData:
        """A copy of the footer with the schema and each row group's
        `num_rows` and `total_byte_size`, and no column chunks: for a reader
        that never decodes the file."""
        var idx = self._ensure_index_via_fs[FS](path, fs)
        ref meta = self._entries[idx].metadata[]
        var schema = List[SchemaElement]()
        for i in range(len(meta.schema)):
            schema.append(meta.schema[i].copy())
        var rgs = List[RowGroup]()
        for r in range(len(meta.row_groups)):
            rgs.append(RowGroup(List[ColumnChunk](), meta.row_groups[r].total_byte_size, meta.row_groups[r].num_rows))
        return FileMetaData(meta.version, schema^, meta.num_rows, rgs^)

    @staticmethod
    def _rg_counts_key(paths: List[String]) -> String:
        var key = String(len(paths))
        for i in range(len(paths)):
            key += "\n"
            key += paths[i]
        return key^

    def resolve_rg_counts_via_fs[FS: FileSystem](
        mut self, paths: List[String], mut fs: FS, mut out_counts: List[Int]
    ) raises:
        """Append the per-row-group row counts of the ordered `paths`, file
        by file: what `row_window.resolve_row_group_window` takes. Memoized
        by the path set, so a repeat reads no footer."""
        var key = Self._rg_counts_key(paths)
        for i in range(len(self._rg_counts_cache)):
            if self._rg_counts_cache[i].key == key:
                self._rg_counts_cache_hits += 1
                out_counts.extend(self._rg_counts_cache[i].rg_counts.copy())
                return
        self._rg_counts_cache_misses += 1
        var counts = List[Int]()
        for p in range(len(paths)):
            self._row_window_footer_reads += 1
            self.rg_num_rows_via_fs[FS](paths[p], fs, counts)
        out_counts.extend(counts.copy())
        self._rg_counts_cache.append(_RgCountsEntry(key^, counts^))

    # --- invalidation -------------------------------------------------------

    def invalidate(mut self, path: String) -> None:
        """Drop the entry of `path` and its pin, and the row-count memo (a
        rewritten file may change its row groups). The other entries keep
        their footers, pins and identities."""
        self._rg_counts_cache = List[_RgCountsEntry]()
        var idx = self._find(path)
        if idx < 0:
            return
        self._release_pin(idx)
        var kept = Slab[_FooterEntry]()
        for i in range(self._entries.len()):
            if i == idx:
                continue
            ref e = self._entries[i]
            kept.append(
                _FooterEntry(
                    e.path.copy(),
                    e.file_size,
                    ArcPointer[FileMetaData](copy=e.metadata),
                    e.preamble.share(),
                    _share_mmap(e.mmap),
                    e.identity,
                    e.parse_count,
                    e.hit_count,
                )
            )
        self._entries = kept^

    # --- counters -----------------------------------------------------------

    def size(self) -> Int:
        """Cached entries."""
        return self._entries.len()

    def miss_count(self) -> Int:
        """Footer reads and parses, re-parses by revalidation included."""
        return self._miss_count

    def hit_count_for(self, path: String) -> Int:
        """Lookups of `path` served from its entry; 0 for an unknown path."""
        var idx = self._find(path)
        return self._entries[idx].hit_count if idx >= 0 else 0

    def parse_count_for(self, path: String) -> Int:
        """Parses of `path`'s current entry; 0 for an unknown path."""
        var idx = self._find(path)
        return self._entries[idx].parse_count if idx >= 0 else 0

    def deep_copy_count(self) -> Int:
        """Footer deep copies the value surface returned."""
        return self._deep_copy_count

    def shared_clone_count(self) -> Int:
        """Footer shares (refcount bumps) the shared surface returned."""
        return self._shared_clone_count

    def mmap_pinned_bytes(self) -> Int:
        """Bytes of file mapping pinned now: the cache's address-space cost
        between queries."""
        return self._mmap_pinned_bytes

    def mmap_pin_count(self) -> Int:
        """Mappings the cache has made. Stays 1 for one file read N times."""
        return self._mmap_pin_count

    def mmap_pin_declined(self) -> Int:
        """Pins the budget refused."""
        return self._mmap_pin_declined

    def mmap_pin_failed(self) -> Int:
        """Pins whose map failed (out of descriptors or address space)."""
        return self._mmap_pin_failed

    def mmap_pin_byte_cap(self) -> Int:
        return self._mmap_pin_byte_cap

    def mmap_revalidate_min_age_ns(self) -> Int:
        return self._mmap_revalidate_min_age_ns

    def revalidate_stat_count(self) -> Int:
        """Stats the revalidation has made: one per shared hit."""
        return self._revalidate_stat_count

    def revalidate_drop_count(self) -> Int:
        """Entries the revalidation re-parsed."""
        return self._revalidate_drop_count

    def footer_window_for(self, path: String) -> Int:
        """The speculative footer window a read of `path` would use now."""
        return self._window_hints.suggest(path)

    def footer_window_adaptations(self) -> Int:
        """How often a dataset's learned window was raised."""
        return self._window_hints.adaptation_count()

    def row_window_rg_counts_cache_hits(self) -> Int:
        return self._rg_counts_cache_hits

    def row_window_rg_counts_cache_misses(self) -> Int:
        return self._rg_counts_cache_misses

    def row_window_resolver_footer_reads(self) -> Int:
        """Per-file footer lookups `resolve_rg_counts_via_fs` made (memo
        misses only)."""
        return self._row_window_footer_reads
