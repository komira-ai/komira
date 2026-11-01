# =============================================================================
# parquet_footer -- plan-time Parquet footer reads (row count and Arrow schema)
# =============================================================================
#
# What a plan builder needs to resolve a Parquet relation it has not opened:
# the file's row count and its Arrow schema, read from the footer alone. No
# data page is touched and nothing here executes a plan.
#
#   * `read_parquet_row_count(path)`: the footer's `num_rows`.
#   * `read_parquet_footer(path)`: `(row_count, schema)` from one open and one
#     light parse (the header and the flat schema list, stopping before
#     `row_groups`).
#   * `read_parquet_footer_with_cache(path, cache)` and
#     `read_parquet_footer_with_cache_via_fs(path, fs, cache)`: the same
#     summary, served from a session's `ParquetMetadataCache`; the second reads
#     a cache miss through the given file system (an object store).
#
# Flat files only: a schema holding a group (nested) column or a repeated
# column is refused, never read as a flat one. A footer with no schema, or with
# a negative `num_rows`, is refused too. A footer that omits `num_rows` but
# has a schema reads as 0 rows: the light parse cannot tell an absent field
# from a zero.
#
# `ParquetFooterSummary` carries the pair. `Schema` is move-only, so the
# summary holds it in an `Optional` and `take_schema()` moves it out.
# =============================================================================

from komira_arrow.schema import Schema

from komira_async.ops.waker_sink import NoopSink
from komira_fs.file_system import FileSystem
from komira_fs.local_fs import LocalFs
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.footer_header import parse_metadata_header_and_schema
from komira_parquet.parquet_source_helpers import _build_schema_from_elements
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet.thrift_compact import parse_metadata_summary
from komira_parquet_api.metadata import SchemaElement
from komira_parquet_api.types import FieldRepetitionType


def _check_footer(row_count: Int, schema_elements: List[SchemaElement]) raises:
    """Refuse a footer this module cannot read as a flat file: no schema, a
    negative `num_rows`, or (after the root) a group or repeated element."""
    if len(schema_elements) == 0:
        raise Error("parquet footer: no schema in the footer")
    _check_row_count(row_count)
    for c in range(1, len(schema_elements)):
        ref e = schema_elements[c]
        var repeated = False
        if e.repetition_type:
            repeated = e.repetition_type.value() == FieldRepetitionType.REPEATED
        if e.num_children > 0 or repeated:
            raise Error(
                "parquet footer: column '"
                + e.name
                + "' is nested or repeated; only flat files are read"
            )


def _check_row_count(row_count: Int) raises:
    if row_count < 0:
        raise Error(
            "parquet footer: negative num_rows (" + String(row_count) + ")"
        )


# =============================================================================
# read_parquet_row_count -- footer-only Parquet row count
# =============================================================================
#
# Reads the Parquet file footer (FileMetaData) and returns the total row count
# across all row groups. Only the trailing metadata bytes are touched, never
# any data pages, so the cost does not grow with the file.
#
# Errors surface as `raises`; a caller that can do without a row count catches
# them.
# =============================================================================
def read_parquet_row_count(path: String) raises -> Int:
    """Read a Parquet file footer and return the total row count.

    Opens the file, validates the PAR1 magic, parses the Thrift-encoded
    FileMetaData, and returns the `num_rows` field (the sum of `num_rows`
    across all row groups). Only the footer is touched -- no data pages
    are read. Cost is O(metadata_size), which is independent of file size
    and typically a few KB.

    Args:
        path: Path to the Parquet file.

    Returns:
        Total row count as the footer records it.

    Raises:
        Error if the file cannot be opened, the magic bytes are invalid,
        the metadata length is malformed, or Thrift parsing fails.
    """
    var reader = ParquetFileReader[LocalFs[NoopSink]].open_metadata_only(path)
    var summary = parse_metadata_summary(
        reader.metadata_bytes.view_range_ro(0, reader.metadata_length)
    )
    if summary.num_schema_elements == 0:
        raise Error("parquet footer: no schema in the footer")
    _check_row_count(summary.num_rows)
    return summary.num_rows


# =============================================================================
# read_parquet_footer -- single-call (row_count, schema) extractor
# =============================================================================
#
# Unifies `read_parquet_row_count` (the footer summary parse, `num_rows` only)
# and the Arrow schema build from the parsed schema elements into a single
# open-and-parse-once entry: one read sequence, one Thrift parse, both pieces
# returned.
#
# Cost: O(metadata_size); identical to `read_parquet_row_count` plus the
# fixed-size Thrift schema-list walk.
# =============================================================================


struct ParquetFooterSummary(Movable):
    """Minimal (row_count, schema) bundle returned from a single footer read.

    `Schema` is Movable-only (not Copyable), so a tuple return of
    `(Int, Schema)` is awkward. A 2-field struct moves cleanly and the
    caller destructures via `.row_count` / `.take_schema()` (the latter is
    the standard Optional-take idiom for the Movable field).
    """

    var row_count: Int
    var _schema: Optional[Schema]

    def __init__(out self, row_count: Int, var schema: Schema):
        self.row_count = row_count
        self._schema = Optional[Schema](schema^)

    def take_schema(mut self) -> Schema:
        """Move the Schema out. Idempotent in the same sense as
        `Optional.take()` — calling twice after the first take is an
        error (the Optional is None)."""
        return self._schema.take()


def read_parquet_footer(path: String) raises -> ParquetFooterSummary:
    """Read a Parquet file footer ONCE and return (row_count, schema).

    The plan-build path that needs only `num_rows` (the row count a scan
    node carries) and the Arrow `Schema` (the file's columns).

    LIGHT PARSE: calls `parse_metadata_header_and_schema`, which parses
    ONLY the FileMetaData header (`num_rows`) plus the flat `SchemaElement`
    list and SKIPS the `row_groups` field and the page/column/offset indexes
    entirely. It does NOT call `parse_full_metadata`, which walks every row
    group's every column chunk's `Statistics` struct.

    Cost: O(footer bytes up to and including the LAST of {`schema`,
    `num_rows`}) -- on every writer seen, the first ~200 bytes. Footer-only:
    no data pages touched, no row-group / column-chunk / statistics decode.

    That bound is bought by an early `break` in
    `parse_metadata_header_and_schema`, not by `_skip_field` being cheap:
    Thrift Compact has no length prefix for a struct, so skipping
    `row_groups` is a full recursive re-read of every nested field header.
    Removing the break leaves the values unchanged and brings that cost back.

    Args:
        path: Path to the Parquet file.

    Returns:
        A `ParquetFooterSummary` with `row_count` (the footer's `num_rows`) and an
        embedded Arrow `Schema` (moved out via `.take_schema()`).

    Flat files only: a schema with a group (nested) or repeated column is
    refused. The light parse stops before `row_groups`, so a garbage
    `row_groups` body does not fail here although the cached entry points
    (which parse the whole footer) raise on the same file.

    Raises:
        Error if the file cannot be opened, the magic bytes are invalid,
        the metadata length is malformed, Thrift parsing fails, the footer has
        no schema, `num_rows` is negative, or the schema is nested or
        repeated. A footer without a `num_rows` field reads as 0 rows.
    """
    var reader = ParquetFileReader[LocalFs[NoopSink]].open_metadata_only(path)
    var hs = parse_metadata_header_and_schema(
        reader.metadata_bytes.view_range_ro(0, reader.metadata_length)
    )
    var row_count = hs.num_rows
    _check_footer(row_count, hs.schema_elements)
    var schema = _build_schema_from_elements(hs.schema_elements)
    return ParquetFooterSummary(row_count, schema^)


# =============================================================================
# read_parquet_footer_with_cache -- the summary through a footer cache
# =============================================================================
#
# Cache-aware sibling of `read_parquet_footer(path)`. It routes through a
# session's `ParquetMetadataCache` (the full-FileMetaData cache), so a path
# read again costs no file read.
#
# Why this is its own helper (not a cache parameter on `read_parquet_footer`):
#   - `read_parquet_footer(path)` uses the light parse (header and flat schema
#     list only). The cache stores a FULL `FileMetaData`.
#   - On a cache HIT the full FileMetaData was already parsed by an earlier
#     call; both `num_rows` and the Arrow `Schema` come from it with no file
#     read.
#   - On a cache MISS this helper opens and parses the file (fully), inserts
#     the footer into the cache and returns the summary. The next call hits.
#
# The cache is a `mut` borrow.
# =============================================================================


def read_parquet_footer_with_cache(
    path: String,
    mut cache: ParquetMetadataCache,
) raises -> ParquetFooterSummary:
    """Read a Parquet file footer ONCE and return (row_count, schema), routing
    through a session's `ParquetMetadataCache`.

    It calls the cache's summary lookup, which appends a copy of the schema
    elements and returns `num_rows` without copying the row groups (every
    row group's every column's `Statistics`) that `get_or_parse(path)`
    would deep-copy. A hit and a miss count the same as a full lookup.

    A hit never re-checks the file: a file rewritten under a live cache is
    served stale (the old row count and schema) until `cache.invalidate(path)`.
    A miss parses the whole footer, so a garbage `row_groups` body raises here
    although the uncached `read_parquet_footer` (light parse) succeeds. Flat
    files only, as `read_parquet_footer`; a footer refused by that check may
    already sit in the cache and is refused again on every read.

    Args:
        path: Path to the Parquet file.
        cache: A `mut` borrow of the session's footer cache.

    Returns:
        A `ParquetFooterSummary` with `row_count` (the footer's `num_rows`) and an
        embedded Arrow `Schema` (moved out via `.take_schema()`).

    Raises:
        Error from the cache's lookup (file open / magic-byte / Thrift-parse
        errors). Mirrors `read_parquet_footer`'s contract.
    """
    var fs = LocalFs[NoopSink].new()
    var schema_elements = List[SchemaElement]()
    var row_count = cache.get_or_parse_summary_via_fs[LocalFs[NoopSink]](
        path, fs, schema_elements
    )
    _check_footer(row_count, schema_elements)
    var schema = _build_schema_from_elements(schema_elements)
    return ParquetFooterSummary(row_count, schema^)


def read_parquet_footer_with_cache_via_fs[FS: FileSystem](
    path: String,
    mut fs: FS,
    mut cache: ParquetMetadataCache,
) raises -> ParquetFooterSummary:
    """FS-aware sibling of `read_parquet_footer_with_cache`: the footer of a
    file on any file system (a data schema read from a representative leaf
    file on an object store, say) is fetched through `fs.read_footer` /
    `fs.file_size` by the cache's `get_or_parse_summary_via_fs[FS]`.

    Same `(row_count, schema)` summary contract and same cache hit/miss
    semantics as the local-file `read_parquet_footer_with_cache`; the only
    difference is the byte source for the cache-miss footer fetch.

    A hit never re-checks the file: a file rewritten under a live cache is
    served stale until `cache.invalidate(path)`. A miss parses the whole
    footer, so a garbage `row_groups` body raises here although the uncached
    `read_parquet_footer` succeeds. Flat files only.
    """
    var schema_elements = List[SchemaElement]()
    var row_count = cache.get_or_parse_summary_via_fs[FS](
        path, fs, schema_elements
    )
    _check_footer(row_count, schema_elements)
    var schema = _build_schema_from_elements(schema_elements)
    return ParquetFooterSummary(row_count, schema^)
