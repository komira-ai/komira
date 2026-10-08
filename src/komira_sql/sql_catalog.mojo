# =============================================================================
# komira_sql/sql_catalog.mojo
#   The minimal catalog the SQL binder resolves table names against.
# =============================================================================
#
# A `SqlCatalog` maps a table name -> (schema, SourceVariant). This is the
# minimal surface an SDK `read_parquet` / in-memory table satisfies:
#   - `add_in_memory(name, table)`  binds a resident `Table` -- ONE result object,
#                                   CHUNKED INSIDE -- as an InMemorySource, chunk
#                                   for chunk. THE PRIMARY.
#   - `add_in_memory(name, batch)`  the single-batch convenience over it, exactly as
#                                   `InMemorySource.from_record_batch` is the
#                                   convenience over `from_record_batches`.
#   - `add_parquet(name, path, schema)` binds a parquet path as a ParquetSource.
#   - `schema_of(name)`   resolves a table's schema (for column binding).
#   - `build_scan(name)`  builds the PLAN_SCAN node (copies the source + schema).
#
# `SourceVariant` and `Schema` are both Movable+Copyable, so the catalog copies
# a table's source into each scan (no move-out-of-container gymnastics), and a
# parquet table produces a scan byte-identical to the SDK's `read_parquet` path.
# Resolution is case-insensitive (DuckDB-ish dialect).
# =============================================================================

from komira_arrow.schema import Schema, SchemaBuilder, Field, RecordBatchBuilder
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.table import Table
from komira_collections.slab import Slab
from komira_scan_source.source_variant import SourceVariant
from komira_scan_source.in_memory_source import InMemorySource
from komira_scan_source.parquet_source import ParquetSource
from komira_plan_ir.logical_plan import LogicalPlan
from komira_plan_expr.declared_scalar_udf import DeclaredScalarUdf

from komira_sql.sql_udf_catalog import SqlUdfCatalog, SqlUdfEntry


@fieldwise_init
struct CatalogTable(Copyable, Movable):
    """One registered table: a name + its schema + its data source."""

    var name: String  # stored lower-cased for case-insensitive resolution
    var schema: Schema
    var source: SourceVariant


struct SqlCatalog(Copyable, Movable):
    """The set of tables and the set of UDFs a SQL query may reference.

    ★ THE UDFs LIVE HERE RATHER THAN IN A SECOND CATALOG THREADED BESIDE THIS
    ONE, SO THE BINDER RESOLVES THEM WITH NO EXTRA PARAMETER.
    `_bind_scalar_call` — and every `_bind_scalar` above it — ALREADY carries a
    `catalog: SqlCatalog`, because table resolution needs it. A second catalog
    would be one more parameter on every expression-binding function.

    It is also what a SQL catalog IS: DuckDB's holds tables and functions in
    one namespace-scoped object, and the two are resolved by the same binder.
    """

    var _tables: List[CatalogTable]
    var udfs: SqlUdfCatalog
    """PUBLIC, because `declare_udf` below is a forwarder and the binder reads
    it directly. There is nothing to encapsulate: `SqlUdfCatalog`'s own
    invariants are enforced by ITS `declare`, which is the only writer."""

    def __init__(out self):
        self._tables = List[CatalogTable]()
        self.udfs = SqlUdfCatalog()

    def declare_udf[U: DeclaredScalarUdf](mut self, imm udf: U) raises:
        """★ THE SQL UDF DOOR. Expose an already-registered scalar UDF to SQL.

            var affine = ctx.register_scalar[affine_impl](String("affine"))
            cat.declare_udf(affine)
            run_sql(ctx, cat, String("SELECT affine(a) AS y FROM t"))

        ⛔ NO NAME ARGUMENT AND NO DTYPE ARGUMENT. Both would be restatements
        of facts the value already carries — see `SqlUdfCatalog.declare` and
        `komira_plan_expr/declared_scalar_udf.mojo`. Refuses an empty name, an
        aggregate's name, and the name of a builtin THE BINDER LOWERS.

        ⭐ A NAME THE ENGINE REFUSES TO *LOWER* IS DECLARABLE. The
        `FNK_REFUSED` rows in `sql_fn_table.mojo` are real DuckDB functions this
        engine declines to approximate; they build no `Expr`, so they shadow
        nothing, and `_bind_scalar_call` resolves a UDF declared under one of
        those names IN PLACE OF the refusal. That is the case where this door is
        worth most — declining to serve `geomean` and also declining to let the
        user serve it leaves them with nothing.
        """
        self.udfs.declare(udf)

    def add_in_memory(mut self, name: String, var table: Table) raises:
        """Register a resident `Table` under `name` -- THE PRIMARY REGISTRAR.

        ⭐ IT BINDS THE CHUNKS AS CHUNKS. `InMemorySource.from_record_batches`
        is itself the multi-batch PRIMARY ctor (`from_record_batch` is its
        documented single-batch convenience), so a chunked result registers
        segment-for-segment with NO concat. That is what makes this entry
        satisfy the one-result-type rule -- *the engine
        never concatenates to satisfy a type signature* -- at the CTAS arm
        (`sql_exec.run_bound_statement`), whose only claim on contiguity was
        this parameter's type. Nothing in the catalog reads across the result.

        ⚠ THE ZERO-CHUNK CASE IS HANDLED EXPLICITLY AND IT IS NOT AN EDGE.
        `from_record_batches` DERIVES its schema from `batches[0]` and RAISES
        on an empty Slab -- there is no batch to derive from. A `Table`
        carrying zero chunks still knows its schema (`Table.schema()` reads the
        stored `_schema`, not the chunks), so the schema is threaded separately
        and the source is bound over ONE zero-row batch built from it, via
        `RecordBatch.empty_from_schema`. That is the spelling
        `from_record_batches`' own docstring prescribes for "an empty in-memory
        relation with a known schema", and it is the shape this arm
        exists for: a bare `RecordBatch()` would report `num_columns() == 0`
        -- the PHYSICAL count -- and make a later `SELECT c FROM <name>` raise
        `Schema.column_index: no field named 'c'` on a query whose predicate
        merely matched nothing.

        Args:
            name: Table name; resolution is case-insensitive (stored lowered).
            table: The result to bind. Ownership transferred; its chunks are
                moved into the source, not copied.
        """
        var schema = table.schema().copy()
        var n = table.num_chunks()
        # ⭐ THE TRANSFER IS A MOVE, NOT A LOOP. `take_chunks()` hands back
        # a `Slab[RecordBatch]` and `from_record_batches` consumes exactly
        # that, so the segments go across by moving ONE value: no per-chunk
        # `RecordBatch` move and no fresh allocation.
        var sl = table.take_chunks()
        if n == 0:
            # ⛔ STILL ONE ZERO-ROW BATCH, NOT ZERO BATCHES -- see this
            # method's docstring. A bare empty source
            # reports `num_columns() == 0` (the PHYSICAL count) and makes a
            # later `SELECT c FROM <name>` raise `no field named 'c'` on a
            # query whose predicate merely matched nothing.
            sl.append(RecordBatch.empty_from_schema(schema.copy()))
        var src = SourceVariant(
            InMemorySource.from_record_batches(sl^, Optional(name.lower()))
        )
        self._tables.append(CatalogTable(name.lower(), schema^, src^))

    def add_in_memory(mut self, name: String, var batch: RecordBatch) raises:
        """Register a resident RecordBatch under `name` -- the SINGLE-BATCH
        CONVENIENCE over the `Table` overload above.

        Exactly the relationship `InMemorySource.from_record_batch` has to
        `from_record_batches`, and implemented the same way: `Table.from_batch`
        is the zero-cost wrap (no copy, no concat -- the batch is moved into a
        one-chunk table), so this overload is byte-identical to binding the
        batch directly and there is only ONE registration path to reason about.
        """
        self.add_in_memory(name, Table.from_batch(batch^))

    def add_parquet(mut self, name: String, path: String, var schema: Schema):
        """Register a parquet file under `name` (schema is the footer-read schema)."""
        var src = SourceVariant(ParquetSource(String(path), schema.copy(), None))
        self._tables.append(CatalogTable(name.lower(), schema^, src^))

    def _find(self, name: String) -> Int:
        var target = name.lower()
        for i in range(len(self._tables)):
            if self._tables[i].name == target:
                return i
        return -1

    def has(self, name: String) -> Bool:
        return self._find(name) >= 0

    def schema_of(self, name: String) raises -> Schema:
        var idx = self._find(name)
        if idx < 0:
            raise Error("SQL bind error: unknown table '" + name + "'")
        return self._tables[idx].schema.copy()

    def table_of(self, name: String) raises -> CatalogTable:
        """The registered (name, schema, source) triple for `name`.

        Looks `name` up through `_find`, the same lookup `build_scan` and
        `schema_of` use, and raises `SQL bind error: unknown table '<name>'`
        when no table is registered under it.

        Returns a COPY: `CatalogTable` is Copyable and the catalog keeps its
        own, as `build_scan` and `schema_of` do."""
        var idx = self._find(name)
        if idx < 0:
            raise Error("SQL bind error: unknown table '" + name + "'")
        ref t = self._tables[idx]
        return CatalogTable(t.name.copy(), t.schema.copy(), t.source.copy())

    def build_scan(self, name: String) raises -> LogicalPlan:
        var idx = self._find(name)
        if idx < 0:
            raise Error("SQL bind error: unknown table '" + name + "'")
        return LogicalPlan.scan_from_source(
            self._tables[idx].source.copy(), self._tables[idx].schema.copy()
        )


# =============================================================================
# ★ THE FROM-LESS SELECT's RELATION
# =============================================================================
#
# DuckDB v1.5.3 answers `SELECT 7/2` (no FROM) as ONE row: `(7 / 2)` = 3.5,
# `SELECT count(*)` = 1, `SELECT 1 WHERE 1 = 0` = no rows, and `SELECT *`
# refuses ("* expression without FROM clause"). The binder reads the parser's
# `FROM_LESS_RELATION` as this: an in-memory relation of exactly one row and
# one INT64 column the query never names. ⭐ An in-memory one-row leaf serves
# literal `+`, `/`, `//`, `abs`, `upper`, `sqrt`, a CAST and a string literal.

comptime FROM_LESS_COLUMN: String = "__komira_from_less_row"


def from_less_relation_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String(FROM_LESS_COLUMN), ArrowType.INT64, False))
    return sb.build()


def from_less_relation_scan() raises -> LogicalPlan:
    """The scan node of a FROM-less SELECT: ONE row, one INT64 column (0)."""
    var arr = PrimitiveArray[DType.int64].allocate(1)
    arr.set(0, Scalar[DType.int64](0))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive(arr^))
    var batch = rbb.build(from_less_relation_schema())
    var src = SourceVariant(InMemorySource.from_record_batch(batch^))
    return LogicalPlan.scan_from_source(src^, from_less_relation_schema())
