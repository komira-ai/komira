# =============================================================================
# sql/sql_bind_parquet.mojo
#   The parquet facts the binder reads, asked of a caller-supplied reader
#   before binding starts.
# =============================================================================
#
# The binder opens no parquet file (a `read_csv`, `read_json`, `read_avro` or `read_orc`
# relation still reads its file through `sql_tvf_bind` while binding). Two of
# its answers depend on parquet footers: the schema of a
# `read_parquet('path')` relation (the files it names and their Hive partition
# columns, as one `ParquetSource`), and whether a column of a parquet relation
# holds no NULL (which lets a NOT IN subquery drop its run-time NULL checks).
# `collect_parquet_facts` walks a parsed statement once, asks the caller's
# `SqlParquetFooters` for exactly those facts, and returns them as a
# `ParquetFacts` value the binder reads while it binds. The resolved source is
# kept per (path text, `hive_partitioning` mode), so the same path read under
# two modes holds two sources.
#
# Null counts are asked for only when the statement holds a NOT IN subquery,
# only for parquet relations, and per FILE: each file of a `read_parquet`
# relation's resolved source, and each path of a catalog table's source. A file
# path that itself holds a glob character (`*`, `?`, `[`) is skipped. A column
# is known NULL-free only when every file records a count of 0; a Hive
# partition column is in no file, so it never has a count and is never known
# NULL-free. A null count the reader cannot give (it raises, or returns None) is
# recorded as unknown, which makes the binder keep the run-time NULL checks.
# A relation the reader cannot give raises, as the binder would have.
#
# An `iceberg_scan('path', ...)` relation is asked of the reader the same way
# (`SqlParquetFooters.iceberg_relation`), once per (path text, `allow_moved_paths`,
# `snapshot_from_id`), and held as the `SourceVariant` the reader returned: its
# files are not named by a footer but by the table's metadata, so no
# `ParquetSource` describes it. The reader's source says its own schema. The
# kind is not a parquet kind (`is_parquet_tvf_kind` is False for it), and a null
# count is never asked of its files.

from arrow.schema import Schema
from scan_source.parquet_source import ParquetSource
from scan_source.source_variant import SOURCE_VARIANT_PARQUET, SourceVariant
from sql.sql_ast import (
    SelectStmt, SqlStatement, TVF_AVRO, TVF_CSV, TVF_ICEBERG, TVF_JSON, TVF_ORC,
    SUBQ_NOT_IN,
)
from sql.sql_catalog import SqlCatalog, catalog_relation_schema


trait SqlParquetFooters:
    """The parquet footer reads a binding needs, implemented by the caller."""

    def footer_schema(self, path: String) raises -> Schema:
        """The schema of the parquet file at `path`."""
        ...

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        """The number of NULLs in `column` of the parquet file at `path`, summed
        over every row group; None when some row group records no count."""
        ...

    def parquet_relation(
        self, path: String, hive_partitioning: UInt8
    ) raises -> ParquetSource:
        """The source a `read_parquet(path)` relation scans: the files `path`
        names (a file or a glob, listed and sorted) and their Hive partition
        columns per `hive_partitioning` (a `HIVE_PARTITIONING_*` mode)."""
        ...

    def iceberg_relation(
        self,
        path: String,
        allow_moved_paths: Bool,
        snapshot_id: Optional[Int64],
    ) raises -> SourceVariant:
        """The source an `iceberg_scan(path, ...)` relation scans: the Iceberg
        table at `path` (a `*.metadata.json` file, or a table directory),
        pinned to snapshot `snapshot_id` or, when None, the current one, with
        stored file paths rewritten under the table's root when
        `allow_moved_paths`. The source's own schema is the relation's schema.

        A reader that does not read Iceberg tables need not override this: the
        default refuses by name."""
        raise Error(
            "SQL bind error: iceberg_scan('" + path + "') needs a binder that"
            " reads Iceberg tables"
        )


@fieldwise_init
struct NoParquetFooters(SqlParquetFooters):
    """A reader for callers that bind no `read_parquet` relation: every schema
    read raises, and every null count is unknown."""

    def footer_schema(self, path: String) raises -> Schema:
        raise Error(
            "SQL bind error: read_parquet('" + path + "') needs a parquet"
            " footer reader, and this binding was given none"
        )

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        return None

    def parquet_relation(
        self, path: String, hive_partitioning: UInt8
    ) raises -> ParquetSource:
        raise Error(
            "SQL bind error: read_parquet('" + path + "') needs a parquet"
            " footer reader, and this binding was given none"
        )


def path_has_glob(path: String) -> Bool:
    """`path` holds a glob character (`*`, `?` or `[`)."""
    return path.find("*") >= 0 or path.find("?") >= 0 or path.find("[") >= 0


def is_parquet_tvf_kind(kind: UInt8) -> Bool:
    """A TVF of kind `kind` is read through a parquet footer: every kind but the
    CSV, JSON, Avro and ORC readers (whose schemas `sql_tvf_bind` infers or reads
    from the file) and
    `iceberg_scan` (whose files the table's metadata names)."""
    return (
        kind != TVF_CSV
        and kind != TVF_JSON
        and kind != TVF_AVRO
        and kind != TVF_ORC
        and kind != TVF_ICEBERG
    )


def parquet_relation_schema(source: ParquetSource) -> Schema:
    """The columns a scan of `source` yields: the files' data columns, then the
    Hive partition columns."""
    return catalog_relation_schema(source)


struct ParquetFacts(Movable):
    """Resolved relations by (path, mode), and null counts by (file path,
    column), as read by `collect_parquet_facts`."""

    var _rel_paths: List[String]
    var _rel_modes: List[UInt8]
    var _rel_sources: List[ParquetSource]
    var _count_paths: List[String]
    var _count_columns: List[String]
    var _counts: List[Optional[Int]]
    var _ice_paths: List[String]
    var _ice_moved: List[Bool]
    var _ice_snapshots: List[Optional[Int64]]
    var _ice_sources: List[SourceVariant]

    def __init__(out self):
        self._rel_paths = List[String]()
        self._rel_modes = List[UInt8]()
        self._rel_sources = List[ParquetSource]()
        self._count_paths = List[String]()
        self._count_columns = List[String]()
        self._counts = List[Optional[Int]]()
        self._ice_paths = List[String]()
        self._ice_moved = List[Bool]()
        self._ice_snapshots = List[Optional[Int64]]()
        self._ice_sources = List[SourceVariant]()

    def has_relation(self, path: String, mode: UInt8) -> Bool:
        for i in range(len(self._rel_paths)):
            if self._rel_paths[i] == path and self._rel_modes[i] == mode:
                return True
        return False

    def add_relation(mut self, path: String, mode: UInt8, var source: ParquetSource):
        """Record the source of `path` read under `mode`; a pair already
        recorded keeps its first."""
        if self.has_relation(path, mode):
            return
        self._rel_paths.append(path)
        self._rel_modes.append(mode)
        self._rel_sources.append(source^)

    def source_of(self, path: String, mode: UInt8) raises -> ParquetSource:
        """A copy of the source recorded for `path` under `mode`. Raises when
        none was recorded."""
        for i in range(len(self._rel_paths)):
            if self._rel_paths[i] == path and self._rel_modes[i] == mode:
                return self._rel_sources[i].copy()
        raise Error(
            "SQL bind error: no parquet footer was read for '" + path + "'"
        )

    def schema_of(self, path: String, mode: UInt8) raises -> Schema:
        """The scan schema (`parquet_relation_schema`) of the source recorded
        for `path` under `mode`. Raises when none was recorded."""
        return parquet_relation_schema(self.source_of(path, mode))

    def _iceberg_index(
        self, path: String, moved: Bool, snapshot: Optional[Int64]
    ) -> Int:
        """The index of the Iceberg relation recorded for the key, or -1."""
        for i in range(len(self._ice_paths)):
            if self._ice_paths[i] != path or self._ice_moved[i] != moved:
                continue
            ref held = self._ice_snapshots[i]
            if not held and not snapshot:
                return i
            if held and snapshot and held.value() == snapshot.value():
                return i
        return -1

    def has_iceberg(
        self, path: String, moved: Bool, snapshot: Optional[Int64]
    ) -> Bool:
        return self._iceberg_index(path, moved, snapshot) >= 0

    def add_iceberg(
        mut self,
        path: String,
        moved: Bool,
        snapshot: Optional[Int64],
        var source: SourceVariant,
    ):
        """Record the source of the Iceberg relation `(path, moved, snapshot)`;
        a key already recorded keeps its first."""
        if self.has_iceberg(path, moved, snapshot):
            return
        self._ice_paths.append(path)
        self._ice_moved.append(moved)
        self._ice_snapshots.append(snapshot)
        self._ice_sources.append(source^)

    def iceberg_source_of(
        self, path: String, moved: Bool, snapshot: Optional[Int64]
    ) raises -> SourceVariant:
        """A copy of the source recorded for the Iceberg relation `(path,
        moved, snapshot)`. Raises when none was recorded."""
        var i = self._iceberg_index(path, moved, snapshot)
        if i < 0:
            raise Error(
                "SQL bind error: no Iceberg table was read for '" + path + "'"
            )
        return self._ice_sources[i].copy()

    def has_null_count(self, path: String, column: String) -> Bool:
        for i in range(len(self._count_paths)):
            if self._count_paths[i] == path and self._count_columns[i] == column:
                return True
        return False

    def add_null_count(mut self, path: String, column: String, count: Optional[Int]):
        """Record `column`'s null count in `path`; a pair already recorded keeps
        its first."""
        if self.has_null_count(path, column):
            return
        self._count_paths.append(path)
        self._count_columns.append(column)
        self._counts.append(count)

    def null_count(self, path: String, column: String) -> Optional[Int]:
        """`column`'s null count in `path`, or None when unknown or never read."""
        for i in range(len(self._count_paths)):
            if self._count_paths[i] == path and self._count_columns[i] == column:
                return self._counts[i]
        return None


def _stmt_has_not_in(stmt: SelectStmt) -> Bool:
    """`stmt`'s subquery table holds a NOT IN subquery. The parser parks every
    subquery of a statement, those inside its CTE bodies included, in the
    top-level statement's flat table."""
    for i in range(len(stmt.subqueries)):
        if stmt.subqueries[i].kind == SUBQ_NOT_IN:
            return True
    return False


def _record_counts[P: SqlParquetFooters](
    mut facts: ParquetFacts, path: String, schema: Schema, footers: P
):
    """Record the null count of every column of `schema` in the file `path`,
    unknown where the reader raises. A path holding a glob character records
    nothing."""
    if path_has_glob(path):
        return
    for c in range(schema.num_columns()):
        var col = String(schema.field_name(c))
        if facts.has_null_count(path, col):
            continue
        var count: Optional[Int] = None
        try:
            count = footers.column_null_count(path, col)
        except:
            count = None
        facts.add_null_count(path, col, count)


def _collect_select[P: SqlParquetFooters](
    stmt: SelectStmt,
    catalog: SqlCatalog,
    footers: P,
    want_counts: Bool,
    mut facts: ParquetFacts,
) raises:
    for i in range(len(stmt.from_tables)):
        ref rel = stmt.from_tables[i]
        if rel.tvf_path:
            if rel.tvf_kind == TVF_ICEBERG:
                var ice_path = rel.tvf_path.value()
                var moved = rel.tvf_opts.allow_moved_paths
                var snapshot = rel.tvf_opts.snapshot_from_id
                if not facts.has_iceberg(ice_path, moved, snapshot):
                    facts.add_iceberg(
                        ice_path,
                        moved,
                        snapshot,
                        footers.iceberg_relation(ice_path, moved, snapshot),
                    )
                continue
            if not is_parquet_tvf_kind(rel.tvf_kind):
                continue
            var path = rel.tvf_path.value()
            var mode = rel.tvf_opts.hive_partitioning
            if not facts.has_relation(path, mode):
                facts.add_relation(
                    path, mode, footers.parquet_relation(path, mode)
                )
            if want_counts:
                var src = facts.source_of(path, mode)
                var file_schema = src.schema()
                for p in range(len(src.paths)):
                    _record_counts(
                        facts, String(src.paths[p]), file_schema, footers
                    )
        elif want_counts and catalog.has(rel.name):
            var t = catalog.table_of(rel.name)
            if t.source.tag != SOURCE_VARIANT_PARQUET:
                continue
            ref ps = t.source._parquet.value()
            if not ps.fs_descriptor.is_local():
                # The footers read the local file system only: an object key
                # of a bucket is not a local path, so its counts stay unknown.
                continue
            var file_schema = ps.schema()
            for p in range(len(ps.paths)):
                _record_counts(facts, String(ps.paths[p]), file_schema, footers)
    for i in range(len(stmt.ctes)):
        _collect_select(stmt.ctes[i].body, catalog, footers, want_counts, facts)
    for i in range(len(stmt.subqueries)):
        _collect_select(
            stmt.subqueries[i].body, catalog, footers, want_counts, facts
        )


def collect_parquet_facts[P: SqlParquetFooters](
    stmt: SqlStatement, catalog: SqlCatalog, footers: P
) raises -> ParquetFacts:
    """Every parquet fact binding `stmt` against `catalog` reads: the resolved
    source of each `read_parquet` relation under its mode, the source of each
    `iceberg_scan` relation under its options, and, when `stmt`
    holds a NOT IN subquery, each data column's null count in every file of
    each parquet relation (a `read_parquet` relation's files or a catalog
    table's paths whose source is parquet)."""
    var facts = ParquetFacts()
    _collect_select(
        stmt.query, catalog, footers, _stmt_has_not_in(stmt.query), facts
    )
    return facts^
