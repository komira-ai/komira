# =============================================================================
# sql_catalog and sql_udf_catalog: in-memory tables, the FROM-less relation,
# the UDF door and every refusal class of a UDF name
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch:
#   1. add_in_memory(name, Table) binds a chunked table chunk for chunk (the
#      scan reports every row) under the lower-folded name, and a ZERO-chunk
#      table still binds one zero-row batch built from its schema, so the
#      scan's source has the table's columns. (catches: the zero-chunk arm
#      removed, which makes from_record_batches raise on an empty Slab)
#   2. add_in_memory(name, RecordBatch) is the one-chunk form of the same
#      registration, and table_of returns a copy of the registered triple.
#      (catches: the batch overload binding under the unfolded name)
#   3. from_less_relation_schema / from_less_relation_scan: one INT64
#      column named FROM_LESS_COLUMN, not nullable, and one row.
#      (catches: a zero-row or two-row FROM-less relation)
#   4. SqlCatalog.declare_udf forwards to its SqlUdfCatalog.
#   5. Each class of UDF name SQL cannot carry is refused with its own
#      message, quoting the name as registered: an empty name, a fast-path
#      aggregate, a statistical aggregate, a ranking window, a grammar form,
#      a reserved word, a builtin that lowers; a refusal row is admitted.
#      (catches: a class tested against the display name instead of the
#      folded key, so `SUM` would be admitted)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.table import Table
from komira_plan_expr.declared_scalar_udf import DeclaredScalarUdf

from komira_sql.sql_udf_catalog import SqlUdfCatalog, refuse_undeclarable_udf_name
from komira_sql.sql_catalog import (
    SqlCatalog,
    FROM_LESS_COLUMN,
    from_less_relation_schema,
    from_less_relation_scan,
)


@fieldwise_init
struct _TestUdf(DeclaredScalarUdf):
    comptime IN_TYPE: ArrowType = ArrowType.FLOAT64
    comptime OUT_TYPE: ArrowType = ArrowType.INT64

    var _name: String
    var _handle: Int

    def handle(self) -> Int:
        return self._handle

    def name(self) -> String:
        return self._name.copy()


def _schema_k() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    return sb.build()


def _batch(n: Int) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.set(i, Scalar[DType.int64](i))
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_primitive(arr^))
    return b.build(_schema_k())


def _refused(name: String) raises -> String:
    try:
        refuse_undeclarable_udf_name(name)
    except e:
        return String(e)
    raise Error("admitted: '" + name + "'")


def test_in_memory_tables_bind_every_chunk_and_the_empty_table() raises:
    var cat = SqlCatalog()
    var chunks = List[RecordBatch]()
    chunks.append(_batch(3))
    chunks.append(_batch(2))
    cat.add_in_memory(String("Two_Chunks"), Table.from_chunks(chunks^, _schema_k()))
    assert_true(cat.has(String("two_chunks")))
    var scan = cat.build_scan(String("TWO_CHUNKS"))
    assert_equal(scan.scan_data_ref().source.kind_name(), "in_memory")
    assert_equal(scan.scan_data_ref().source.estimate_rows(), 5)
    assert_equal(scan.output_schema.field_name(0), "k")
    # A table with no chunks still knows its schema.
    cat.add_in_memory(String("empty"), Table.from_chunks(List[RecordBatch](), _schema_k()))
    var e = cat.build_scan(String("EMPTY"))
    assert_equal(e.scan_data_ref().source.estimate_rows(), 0)
    assert_equal(e.scan_data_ref().source.schema().num_columns(), 1)
    assert_equal(e.scan_data_ref().source.schema().field_name(0), "k")
    assert_equal(e.output_schema.num_columns(), 1)


def test_single_batch_registration_and_table_of() raises:
    var cat = SqlCatalog()
    cat.add_in_memory(String("One"), _batch(4))
    var t = cat.table_of(String("ONE"))
    assert_equal(t.name, "one")
    assert_equal(t.schema.field_name(0), "k")
    assert_equal(t.source.estimate_rows(), 4)
    assert_equal(t.source.kind_name(), "in_memory")
    assert_equal(cat.schema_of(String("one")).num_columns(), 1)
    assert_false(cat.has(String("two")))


def test_from_less_relation_is_one_int64_row() raises:
    var s = from_less_relation_schema()
    assert_equal(s.num_columns(), 1)
    assert_equal(s.field_name(0), String(FROM_LESS_COLUMN))
    assert_true(s.field_arrow_type(0) == ArrowType.INT64)
    assert_false(s.field_nullable(0))
    var plan = from_less_relation_scan()
    assert_true(plan.is_scan())
    assert_equal(plan.scan_data_ref().source.estimate_rows(), 1)
    assert_equal(plan.output_schema.field_name(0), String(FROM_LESS_COLUMN))


def test_catalog_declare_udf_forwards_to_its_udf_catalog() raises:
    var cat = SqlCatalog()
    assert_equal(cat.udfs.num_declared(), 0)
    cat.declare_udf(_TestUdf(String("Affine"), 7))
    assert_equal(cat.udfs.num_declared(), 1)
    var e = cat.udfs.resolve(String("AFFINE")).value().copy()
    assert_equal(e.display_name, "Affine")
    assert_equal(e.handle, 7)
    assert_true(e.in_type == ArrowType.FLOAT64)
    assert_true(e.out_type == ArrowType.INT64)
    try:
        cat.declare_udf(_TestUdf(String(""), 8))
        raise Error("declared an empty name")
    except err:
        assert_true("registered with an EMPTY name" in String(err), String(err))
    assert_equal(cat.udfs.num_declared(), 1)


def test_every_undeclarable_name_class_has_its_own_refusal() raises:
    var m = _refused(String(""))
    assert_true("registered with an EMPTY name" in m, m)
    m = _refused(String("SUM"))
    assert_true("'SUM' is a built-in AGGREGATE, and the SQL parser turns `SUM(x)`" in m, m)
    m = _refused(String("mean"))
    assert_true("'mean' is a built-in AGGREGATE, and the SQL parser" in m, m)
    m = _refused(String("Median"))
    assert_true("'Median' is the name of a built-in AGGREGATE, which the binder refuses" in m, m)
    m = _refused(String("rank"))
    assert_true("'rank' is a built-in ranking WINDOW function" in m, m)
    m = _refused(String("Extract"))
    assert_true("'Extract' is SQL GRAMMAR, not a function name" in m, m)
    m = _refused(String("try_cast"))
    assert_true("'try_cast' is SQL GRAMMAR" in m, m)
    m = _refused(String("NOT"))
    assert_true("'NOT' is a RESERVED WORD in SQL" in m, m)
    m = _refused(String("distinct"))
    assert_true("'distinct' is a RESERVED WORD" in m, m)
    m = _refused(String("Coalesce"))
    assert_true("'Coalesce' is a built-in scalar function THE BINDER LOWERS" in m, m)
    assert_true("SELECT Coalesce(x)" in m, m)
    # Free names and refusal rows return normally.
    refuse_undeclarable_udf_name(String("my_udf"))
    refuse_undeclarable_udf_name(String("NextAfter"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
