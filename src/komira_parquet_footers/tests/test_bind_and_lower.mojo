# =============================================================================
# bind_statement and lower over real footers, through one cache
# =============================================================================
#
# A Parquet file written in the test (1000 rows, row groups of 300; x INT64
# not null = 2i+1, y INT64 nullable, s STRING) is registered with
# `register_parquet_table` or named by `read_parquet(...)`, bound with
# `bind_statement(stmt, catalog, footers)` and lowered with inputs built from
# the same `ParquetFooters`.
#
# What each test proves, and the defect it catches:
#   * test_register_takes_the_schema_from_the_footer: the catalog schema is the
#     footer's (three columns, names and types); a file that does not read
#     registers nothing and the error names the file. Catches a registration
#     that keeps a hand-written schema, and one that registers before reading.
#   * test_bind_and_lower_a_registered_table_read_the_footer_once:
#     `SELECT sum(x) FROM t WHERE y < 5` binds, lowers to two segments (the
#     aggregation, then the collect) whose first has `card_estimate_rows` 1000,
#     the footer's, and the file was read from storage once for registration,
#     binding and lowering together. Catches inputs read from a second copy of
#     the footer, and statistics that never reach lowering (the estimate would
#     be 0).
#   * test_bind_and_lower_a_read_parquet_relation_read_the_footer_once: the same
#     query over `read_parquet('<path>')`: the binder's footer read and
#     lowering's inputs are one read.
#   * test_the_inputs_hold_the_footer_statistics: the scan facts carry the row
#     count 1000, x's min 1 and max 1999 over all four row groups, and y's null
#     count 100.
#   * test_a_registered_schema_that_disagrees_is_refused_by_name: a different
#     column count, name, type or nullability is refused by `check_catalog_table`
#     and by `add_catalog_scan`, naming table, file and column; the matching
#     registration passes. Catches a scan lowered on facts of a file the plan
#     was not bound to.
#   * test_a_file_rewritten_between_bind_and_lowering_is_refused: after
#     binding, the file is replaced by a 7-row one; the scan inputs and a new
#     bind are refused naming the file (not built on the 1000-row footer the
#     plan was bound against), and after invalidate the new file is read.
#   * test_add_parquet_scan_refuses_a_replaced_file_itself and
#     test_column_null_count_refuses_a_replaced_file_itself: each function called
#     directly on a file replaced after its footer was cached refuses, naming the
#     file and saying it was replaced (no other call refuses first).
#   * test_parametric_types_are_compared_by_their_parameters: a DECIMAL(20,2)
#     file against registered (20,2), (20,3) and (18,2).
#   * test_nullability_is_exact_in_both_directions, test_swapped_column_order_is_refused,
#     test_check_catalog_table_refuses_what_it_cannot_check (unknown table, an
#     in-memory table, a two-file table naming both files).
#   * test_binding_a_missing_or_text_file_names_the_file: `read_parquet` of an
#     absent file and of a text file fail `bind_statement` with an error naming
#     the path.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_host_profile.host_profile import reference_host_profile
from komira_lowering.lower import lower
from komira_lowering.lowered_plan import LoweringInputs
from komira_parquet_api.types import CompressionCodec
from komira_parquet_footers.lowering_facts import (
    add_catalog_scan,
    add_parquet_scan,
    add_read_parquet_scan,
)
from komira_parquet_footers.parquet_footers import (
    ParquetFooters,
    check_catalog_table,
    register_parquet_table,
)
from komira_parquet_writer import write_record_batch_to_parquet_bytes
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir
from komira_sql.sql_binder import bind_statement
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant
from komira_sql.sql_catalog import CatalogTable, SqlCatalog
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


def _batch(n: Int) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    var x = PrimitiveArray[DType.int64].allocate(n)
    var y = PrimitiveArray[DType.int64].allocate_nullable(n)
    var s = List[String]()
    for i in range(n):
        x.set(i, Int64(2 * i + 1))
        y.set(i, Int64(i % 10))
        if i % 10 == 3:
            y._set_null(i)
        s.append(String("k") + String(i % 4))
    sb.add_field(Field("x", ArrowType.INT64, False))
    b.add_column(Column.from_primitive[DType.int64](x))
    sb.add_field(Field("y", ArrowType.INT64, True))
    b.add_column(Column.from_primitive[DType.int64](y))
    sb.add_field(Field("s", ArrowType.STRING, False))
    b.add_column(Column.from_string(StringArray.from_strings(s)))
    return b.build(sb.build())


def _put(file_name: String, data: List[UInt8]) raises -> String:
    var path = test_tmpdir() + "/" + file_name
    var fh = open(path, "w")
    fh.write_bytes(Span(data))
    fh.close()
    return path^


def _write_table(file_name: String) raises -> String:
    var bytes = write_record_batch_to_parquet_bytes(
        _batch(1000), CompressionCodec.UNCOMPRESSED, max_rows_per_rg=300
    )
    return _put(file_name, bytes)


comptime _QUERY = "SELECT sum(x) FROM t WHERE y < 5"


def test_register_takes_the_schema_from_the_footer() raises:
    var path = _write_table("bl_register.parquet")
    var footers = ParquetFooters()
    var catalog = SqlCatalog()
    register_parquet_table(catalog, "t", path, footers)
    var schema = catalog.schema_of("t")
    assert_equal(schema.num_columns(), 3)
    assert_equal(schema.field_name(0), "x")
    assert_true(schema.field_arrow_type(1) == ArrowType.INT64)
    assert_true(schema.field_arrow_type(2) == ArrowType.STRING)
    var bad = _put("bl_register_text.parquet", List[UInt8](length=100, fill=65))
    with assert_raises(contains="bl_register_text.parquet"):
        register_parquet_table(catalog, "u", bad, footers)
    assert_false(catalog.has("u"))


def test_bind_and_lower_a_registered_table_read_the_footer_once() raises:
    var path = _write_table("bl_table.parquet")
    var footers = ParquetFooters()
    var catalog = SqlCatalog()
    register_parquet_table(catalog, "t", path, footers)
    var bound = bind_statement(parse_sql(tokenize(_QUERY)), catalog, footers)
    var plan = bound.take_plan()
    var inputs = LoweringInputs()
    add_catalog_scan(inputs, catalog, "t", footers)
    var lowered = lower(plan, reference_host_profile("test-build"), inputs)
    # The aggregation's segment and the collect that reads its output.
    assert_equal(len(lowered.segments), 2)
    assert_equal(lowered.segments[0].card_estimate_rows, 1000)
    assert_equal(footers.cache().read_count(), 1)


def test_bind_and_lower_a_read_parquet_relation_read_the_footer_once() raises:
    var path = _write_table("bl_tvf.parquet")
    var footers = ParquetFooters()
    var catalog = SqlCatalog()
    var sql = String("SELECT sum(x) FROM read_parquet('") + path + "') WHERE y < 5"
    var bound = bind_statement(parse_sql(tokenize(sql)), catalog, footers)
    assert_equal(footers.cache().read_count(), 1)
    var plan = bound.take_plan()
    var inputs = LoweringInputs()
    add_read_parquet_scan(inputs, footers, path)
    var lowered = lower(plan, reference_host_profile("test-build"), inputs)
    # The aggregation's segment and the collect that reads its output.
    assert_equal(len(lowered.segments), 2)
    assert_equal(lowered.segments[0].card_estimate_rows, 1000)
    assert_equal(footers.cache().read_count(), 1)


def test_the_inputs_hold_the_footer_statistics() raises:
    var path = _write_table("bl_stats.parquet")
    var footers = ParquetFooters()
    var schema = footers.footer_schema(path)
    var inputs = LoweringInputs()
    add_parquet_scan(inputs, footers, path, schema)
    assert_equal(len(inputs.scans), 1)
    ref facts = inputs.scans[0]
    assert_true(Bool(facts.stats))
    ref stats = facts.stats.value()
    assert_equal(stats.row_count, 1000)
    var x = stats.find_column("x")
    assert_true(x >= 0)
    ref xs = stats.column_stats[x]
    assert_true(Bool(xs.min_value))
    assert_true(Bool(xs.max_value))
    assert_true(xs.min_value.value() == ScalarValue.from_int64(1))
    assert_true(xs.max_value.value() == ScalarValue.from_int64(1999))
    var y = stats.find_column("y")
    assert_true(y >= 0)
    assert_true(Bool(stats.column_stats[y].null_count))
    assert_equal(stats.column_stats[y].null_count.value(), 100)
    assert_equal(len(facts.dict_encoded_columns), 0)


def _registered(
    path: String,
    name0: String,
    type1: ArrowType,
    null1: Bool,
    count: Int,
) -> SqlCatalog:
    """A catalog whose table `t` names `path` under the schema described: the
    file's schema is x INT64 not null, y INT64 nullable, s STRING not null."""
    var sb = SchemaBuilder()
    sb.add_field(Field(name0, ArrowType.INT64, False))
    sb.add_field(Field("y", type1, null1))
    if count == 3:
        sb.add_field(Field("s", ArrowType.STRING, False))
    var catalog = SqlCatalog()
    catalog.add_parquet("t", path, sb.build())
    return catalog^


def test_a_registered_schema_that_disagrees_is_refused_by_name() raises:
    var path = _write_table("bl_mismatch.parquet")
    var footers = ParquetFooters()
    var good = _registered(path, "x", ArrowType.INT64, True, 3)
    check_catalog_table(good, "t", footers)
    var inputs = LoweringInputs()
    add_catalog_scan(inputs, good, "t", footers)
    assert_equal(len(inputs.scans), 1)

    var short = _registered(path, "x", ArrowType.INT64, True, 2)
    with assert_raises(contains="2 columns, the file has 3"):
        check_catalog_table(short, "t", footers)

    var renamed = _registered(path, "z", ArrowType.INT64, True, 3)
    with assert_raises(contains="column 0 is registered as 'z', the file has 'x'"):
        check_catalog_table(renamed, "t", footers)

    var retyped = _registered(path, "x", ArrowType.FLOAT64, True, 3)
    with assert_raises(contains="column 'y' is registered as"):
        check_catalog_table(retyped, "t", footers)

    var strict = _registered(path, "x", ArrowType.INT64, False, 3)
    with assert_raises(contains="column 'y' is registered not null"):
        check_catalog_table(strict, "t", footers)

    var refused = LoweringInputs()
    with assert_raises(contains="bl_mismatch.parquet"):
        add_catalog_scan(refused, renamed, "t", footers)
    assert_equal(len(refused.scans), 0)


def test_a_file_rewritten_between_bind_and_lowering_is_refused() raises:
    var path = _write_table("bl_rewrite.parquet")
    var footers = ParquetFooters()
    var catalog = SqlCatalog()
    register_parquet_table(catalog, "t", path, footers)
    var bound = bind_statement(parse_sql(tokenize(_QUERY)), catalog, footers)
    _ = bound.take_plan()
    var small = write_record_batch_to_parquet_bytes(
        _batch(7), CompressionCodec.UNCOMPRESSED
    )
    _ = _put("bl_rewrite.parquet", small)
    assert_true(footers.cache().changed_since_read(path))
    var inputs = LoweringInputs()
    with assert_raises(contains="bl_rewrite.parquet"):
        add_catalog_scan(inputs, catalog, "t", footers)
    with assert_raises(contains="bl_rewrite.parquet"):
        add_read_parquet_scan(inputs, footers, path)
    assert_equal(len(inputs.scans), 0)
    # Binding again over the replaced file is refused too, not bound on v1.
    with assert_raises(contains="bl_rewrite.parquet"):
        _ = bind_statement(
            parse_sql(tokenize("SELECT x FROM read_parquet('" + path + "')")),
            SqlCatalog(),
            footers,
        )
    # Invalidating the path reads the new file.
    footers.cache().invalidate(path)
    assert_equal(footers.footer_schema(path).num_columns(), 3)
    assert_equal(footers.cache().summary(path).row_count, 7)


def test_add_parquet_scan_refuses_a_replaced_file_itself() raises:
    # Called directly, with the footer already cached and no other call
    # between the replacement and this one.
    var path = _write_table("bl_direct.parquet")
    var footers = ParquetFooters()
    var schema = footers.footer_schema(path)
    _ = _put("bl_direct.parquet", write_record_batch_to_parquet_bytes(
        _batch(7), CompressionCodec.UNCOMPRESSED
    ))
    var inputs = LoweringInputs()
    with assert_raises(contains="replaced after its footer was read"):
        add_parquet_scan(inputs, footers, path, schema)
    assert_equal(len(inputs.scans), 0)


def test_column_null_count_refuses_a_replaced_file_itself() raises:
    var path = _write_table("bl_nulls_replaced.parquet")
    var footers = ParquetFooters()
    assert_equal(footers.column_null_count(path, "y").value(), 100)
    _ = _put("bl_nulls_replaced.parquet", write_record_batch_to_parquet_bytes(
        _batch(7), CompressionCodec.UNCOMPRESSED
    ))
    with assert_raises(contains="bl_nulls_replaced.parquet"):
        _ = footers.column_null_count(path, "y")
    with assert_raises(contains="replaced after its footer was read"):
        _ = footers.column_null_count(path, "y")


def _decimal_file(file_name: String) raises -> String:
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    var d = Decimal128Array.allocate_nullable(4, 20, 2)
    for i in range(4):
        d.set_i128(i, SIMD[DType.int128, 1](i * 100 + 7))
    sb.add_field(Field.decimal128("d", 20, 2, False))
    b.add_column(Column.from_decimal128(d))
    var bytes = write_record_batch_to_parquet_bytes(
        b.build(sb.build()), CompressionCodec.UNCOMPRESSED
    )
    return _put(file_name, bytes)


def _one_column_catalog(path: String, var field: Field) -> SqlCatalog:
    var sb = SchemaBuilder()
    sb.add_field(field^)
    var catalog = SqlCatalog()
    catalog.add_parquet("t", path, sb.build())
    return catalog^


def test_parametric_types_are_compared_by_their_parameters() raises:
    var path = _decimal_file("bl_decimal.parquet")
    var footers = ParquetFooters()
    check_catalog_table(
        _one_column_catalog(path, Field.decimal128("d", 20, 2, False)),
        "t",
        footers,
    )
    with assert_raises(contains="decimal(20, 3)"):
        check_catalog_table(
            _one_column_catalog(path, Field.decimal128("d", 20, 3, False)),
            "t",
            footers,
        )
    with assert_raises(contains="decimal(18, 2)"):
        check_catalog_table(
            _one_column_catalog(path, Field.decimal128("d", 18, 2, False)),
            "t",
            footers,
        )


def test_nullability_is_exact_in_both_directions() raises:
    var path = _write_table("bl_null.parquet")
    var footers = ParquetFooters()
    # The file has x not null and y nullable.
    var nullable_x = _registered_nullable_x(path)
    with assert_raises(contains="column 'x' is registered nullable"):
        check_catalog_table(nullable_x, "t", footers)
    var not_null_y = _registered(path, "x", ArrowType.INT64, False, 3)
    with assert_raises(contains="column 'y' is registered not null"):
        check_catalog_table(not_null_y, "t", footers)


def _registered_nullable_x(path: String) -> SqlCatalog:
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, True))
    sb.add_field(Field("y", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, False))
    var catalog = SqlCatalog()
    catalog.add_parquet("t", path, sb.build())
    return catalog^


def test_swapped_column_order_is_refused() raises:
    var path = _write_table("bl_order.parquet")
    var sb = SchemaBuilder()
    sb.add_field(Field("y", ArrowType.INT64, True))
    sb.add_field(Field("x", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, False))
    var catalog = SqlCatalog()
    catalog.add_parquet("t", path, sb.build())
    with assert_raises(contains="column 0 is registered as 'y', the file has 'x'"):
        check_catalog_table(catalog, "t", ParquetFooters())


def test_check_catalog_table_refuses_what_it_cannot_check() raises:
    var footers = ParquetFooters()
    var catalog = SqlCatalog()
    with assert_raises(contains="unknown table"):
        check_catalog_table(catalog, "nope", footers)
    catalog.add_in_memory("mem", _batch(3))
    with assert_raises(contains="not a Parquet table"):
        check_catalog_table(catalog, "mem", footers)
    # A table naming two files: both are named.
    var a = _write_table("bl_multi_a.parquet")
    var b = _write_table("bl_multi_b.parquet")
    var src = ParquetSource(a.copy(), _batch(1).schema.copy())
    src.paths.append(b.copy())
    catalog._tables.append(
        CatalogTable("multi", _batch(1).schema.copy(), SourceVariant(src^))
    )
    with assert_raises(contains="bl_multi_a.parquet"):
        check_catalog_table(catalog, "multi", footers)
    with assert_raises(contains="bl_multi_b.parquet"):
        check_catalog_table(catalog, "multi", footers)


def test_binding_a_missing_or_text_file_names_the_file() raises:
    var footers = ParquetFooters()
    var catalog = SqlCatalog()
    var absent = test_tmpdir() + "/bl_absent.parquet"
    with assert_raises(contains="bl_absent.parquet"):
        _ = bind_statement(
            parse_sql(tokenize("SELECT x FROM read_parquet('" + absent + "')")),
            catalog,
            footers,
        )
    var text = _put("bl_text.parquet", List[UInt8](length=100, fill=65))
    with assert_raises(contains="bl_text.parquet"):
        _ = bind_statement(
            parse_sql(tokenize("SELECT x FROM read_parquet('" + text + "')")),
            catalog,
            footers,
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
