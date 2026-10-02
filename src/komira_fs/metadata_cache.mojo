# =============================================================================
# komira_fs.metadata_cache — MetadataCache[T] trait
#
# =============================================================================
#
# Format-agnostic parsed-metadata cache. Generic over the parsed type T
# (e.g. parquet `FileMetaData`, future `OrcFileMetaData`, `ArrowIpcFooter`).
# v0.1 has one concrete impl (the parquet metadata cache); later
# versions may add `OrcMetadataCache`, `ArrowIpcMetadataCache`, etc., as drop-in
# same-shape conformers.
#
# Design parallel to `ReaderFactory`: one trait, one associated
# `T`, one `get_or_parse` entry point. The cache layer is the
# session-scoped amortization shape; the factory is the per-source
# construction shape.
#
# Sibling abstraction relationship: `MetadataCache[T]` carries
# the format-specific parsed metadata blob; `StatsProvider`
# carries the
# format-agnostic plan-time stats surface. v0.1 keeps both surfaces
# direct on `ParquetFileMetaData`; v0.2+ may unify when ORC + a second
# StatsProvider impl land.
#
# Design decision:
# `FileMetadata` format-agnostic projection is DROPPED — `StatsProvider`
# already covers planner needs; doubling the surface without doubling
# the value is rejected. v0.2 ORC: extend `StatsProvider` if needed
# rather than introducing a sibling abstraction.
#
# Pointer discipline:
#   * No UnsafePointer in any method signature.
#   * Conformers hold their cached metadata internally
#     (Slab[Entry] etc.); trait surface returns by-value
#     (Self.T.copy() on hit).
# =============================================================================

from komira_fs.file_system import FileSystem


trait MetadataCache(Movable, Deinitable):
    """Format-agnostic parsed-metadata cache trait.

    Associated type:
      comptime T: Movable & Copyable & Deinitable
        The parsed-format-metadata type. For the v0.1 conformer
        the parquet metadata cache,
        bound to `FileMetaData` (the existing
        `komira_parquet.metadata.FileMetaData`).

        `Copyable` because `get_or_parse_via_fs` returns `T.copy()` on
        cache hit (the cache is the canonical owner; callers get a
        copy). Preserves today's
        `ParquetMetadataCache.get_or_parse_via_fs` semantics.

    Pointer discipline: no UnsafePointer in any method signature.
    """

    comptime T: Movable & Copyable & Deinitable

    def get_or_parse_via_fs[FS: FileSystem](
        mut self,
        path: String,
        mut fs: FS,
    ) raises -> Self.T:
        """Cache HIT: return `T.copy()`. Cache MISS: route footer
        fetch through `fs.read_footer(path)` + `fs.file_size(path)`
        (the FileSystem metadata extensions), parse, stash, return.

        Mirrors today's
        `ParquetMetadataCache.get_or_parse_via_fs(path, fs)` exactly,
        modulo the result type being generic over `Self.T` instead of
        the concrete `FileMetaData`.
        """
        ...

    def invalidate(mut self, path: String) -> None:
        """Drop any cached entry for `path`. Used when the caller knows
        the file was rewritten/replaced (e.g. SDK `register_table`
        rewriting an Iceberg snapshot). Cold path."""
        ...

    def size(self) -> Int:
        """Number of cached entries (cold path; for testing /
        diagnostics). Mirrors today's
        `ParquetMetadataCache.size`."""
        ...

    def miss_count(self) -> Int:
        """Cumulative miss counter; preserved from today's
        `ParquetMetadataCache.miss_count()`. Cold path."""
        ...

    def hit_count_for(self, path: String) -> Int:
        """Per-path hit counter; preserved from today's
        `ParquetMetadataCache.hit_count_for(path)`. Cold path."""
        ...
