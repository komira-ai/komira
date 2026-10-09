# =============================================================================
# komira_sql/sql_bind_parquet.mojo
#   The parquet facts the binder reads, asked of a caller-supplied reader
#   before binding starts.
# =============================================================================
#
# The binder opens no file. Two of its answers depend on parquet footers: the
# schema of a `read_parquet('path')` relation, and whether a column of a
# parquet relation holds no NULL (which lets a NOT IN subquery drop its
# run-time NULL checks). `collect_parquet_facts` walks a parsed statement
# once, asks the caller's `SqlParquetFooters` for exactly those facts, and
# returns them as a `ParquetFacts` value the binder reads while it binds.
#
# Null counts are asked for only when the statement holds a NOT IN subquery,
# only for parquet relations, and never for a path holding a glob character
# (`*`, `?`, `[`): one file's statistics say nothing about the others a glob
# names. A null count the reader cannot give (it raises, or returns None) is
# recorded as unknown, which makes the binder keep the run-time NULL checks.
# A schema the reader cannot give raises, as the binder would have.

from komira_arrow.schema import Schema
from komira_scan_source.source_variant import SOURCE_VARIANT_PARQUET
from komira_sql.sql_ast import (
    SelectStmt, SqlStatement, TVF_AVRO, TVF_CSV, TVF_JSON, SUBQ_NOT_IN,
)
from komira_sql.sql_catalog import SqlCatalog


trait SqlParquetFooters:
    """The parquet footer reads a binding needs, implemented by the caller."""

    def footer_schema(self, path: String) raises -> Schema:
        """The schema of the parquet relation at `path` (a file or a glob)."""
        ...

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        """The number of NULLs in `column` of the parquet file at `path`, summed
        over every row group; None when some row group records no count."""
        ...


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


def path_has_glob(path: String) -> Bool:
    """`path` holds a glob character (`*`, `?` or `[`)."""
    return path.find("*") >= 0 or path.find("?") >= 0 or path.find("[") >= 0


def is_parquet_tvf_kind(kind: UInt8) -> Bool:
    """A TVF of kind `kind` is read through a parquet footer: every kind but the
    CSV, JSON and Avro readers (whose schemas `sql_tvf_bind` infers)."""
    return kind != TVF_CSV and kind != TVF_JSON and kind != TVF_AVRO


struct ParquetFacts(Movable):
    """Footer schemas by path, and null counts by (path, column), as read by
    `collect_parquet_facts`."""

    var _schema_paths: List[String]
    var _schemas: List[Schema]
    var _count_paths: List[String]
    var _count_columns: List[String]
    var _counts: List[Optional[Int]]

    def __init__(out self):
        self._schema_paths = List[String]()
        self._schemas = List[Schema]()
        self._count_paths = List[String]()
        self._count_columns = List[String]()
        self._counts = List[Optional[Int]]()

    def has_schema(self, path: String) -> Bool:
        for i in range(len(self._schema_paths)):
            if self._schema_paths[i] == path:
                return True
        return False

    def add_schema(mut self, path: String, var schema: Schema):
        """Record `path`'s schema; a path already recorded keeps its first."""
        if self.has_schema(path):
            return
        self._schema_paths.append(path)
        self._schemas.append(schema^)

    def schema_of(self, path: String) raises -> Schema:
        """A copy of `path`'s recorded schema. Raises when none was recorded."""
        for i in range(len(self._schema_paths)):
            if self._schema_paths[i] == path:
                return self._schemas[i].copy()
        raise Error(
            "SQL bind error: no parquet footer was read for '" + path + "'"
        )

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
    """Record the null count of every column of `schema` in `path`, unknown
    where the reader raises. A glob path records nothing."""
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
            if not is_parquet_tvf_kind(rel.tvf_kind):
                continue
            var path = rel.tvf_path.value()
            if not facts.has_schema(path):
                facts.add_schema(path, footers.footer_schema(path))
            if want_counts:
                var schema = facts.schema_of(path)
                _record_counts(facts, path, schema, footers)
        elif want_counts and catalog.has(rel.name):
            var t = catalog.table_of(rel.name)
            if t.source.tag != SOURCE_VARIANT_PARQUET:
                continue
            ref ps = t.source._parquet.value()
            for p in range(len(ps.paths)):
                _record_counts(facts, String(ps.paths[p]), t.schema, footers)
    for i in range(len(stmt.ctes)):
        _collect_select(stmt.ctes[i].body, catalog, footers, want_counts, facts)
    for i in range(len(stmt.subqueries)):
        _collect_select(
            stmt.subqueries[i].body, catalog, footers, want_counts, facts
        )


def collect_parquet_facts[P: SqlParquetFooters](
    stmt: SqlStatement, catalog: SqlCatalog, footers: P
) raises -> ParquetFacts:
    """Every parquet fact binding `stmt` against `catalog` reads: the footer
    schema of each `read_parquet` relation, and, when `stmt` holds a NOT IN
    subquery, each column's null count in every non-glob file of each parquet
    relation (a `read_parquet` relation or a catalog table whose source is
    parquet)."""
    var facts = ParquetFacts()
    _collect_select(
        stmt.query, catalog, footers, _stmt_has_not_in(stmt.query), facts
    )
    return facts^
