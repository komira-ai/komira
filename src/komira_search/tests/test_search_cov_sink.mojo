# =============================================================================
# test_search_cov_sink.mojo: the sink's refusals (schema, call order) and the
# index core's refusal of a fast-field column it cannot read.
# =============================================================================
#
#   1. init_sink refuses a schema without the text field, one without the
#      _source field, and a column named "__fieldnorm__" (the reserved
#      doc-length field).
#   2. accept_batch and finish refuse to run before init_sink; take_split_bytes
#      refuses to run before finish.
#   3. IndexCore.add_documents refuses an INT8 fast-field spec (no typed
#      reader for it) rather than read it through a wider width.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray

from komira_search.analyzer import AnalyzerConfig, FIELD_CLASS_NUMERIC
from komira_search.sink import IndexCore, SearchSink
from komira_search.fast_fields import FastFieldSpec


def _sink() -> SearchSink:
    return SearchSink(
        String("b"), String("p"), String("i"), String("body"),
        Array[UInt8, 16](fill=8),
    )


def _schema(names: List[String]) raises -> Schema:
    var sb = SchemaBuilder()
    for n in names:
        sb.add_field(Field(n, ArrowType.STRING, False))
    return sb.build()


def test_01_init_sink_refusals() raises:
    var s1 = _sink()
    with assert_raises(contains="text field 'body' not found in schema"):
        s1.init_sink(_schema([String("text"), String("_source")]))
    var s2 = _sink()
    with assert_raises(contains="_source field '_source' not found in schema"):
        s2.init_sink(_schema([String("body"), String("src")]))
    var s3 = _sink()
    with assert_raises(contains="'__fieldnorm__' is a reserved name"):
        s3.init_sink(
            _schema([String("body"), String("_source"), String("__fieldnorm__")])
        )
    # The same schema without the reserved column is accepted.
    var s4 = _sink()
    s4.init_sink(_schema([String("body"), String("_source"), String("tag")]))


def test_02_call_order_refusals() raises:
    var s = _sink()
    with assert_raises(contains="accept_batch: init_sink was not called"):
        s.accept_batch(RecordBatch())
    with assert_raises(contains="finish: init_sink was not called"):
        s.finish()
    with assert_raises(contains="take_split_bytes: finish() was not called"):
        _ = s.take_split_bytes()
    assert_equal(s.split_bytes_len(), 0, "2: nothing produced")


def test_03_index_core_refuses_int8_fast_field() raises:
    var specs = List[FastFieldSpec]()
    specs.append(
        FastFieldSpec(
            String("small"), 2, FIELD_CLASS_NUMERIC, ArrowType.INT8.type_id,
            DType.int8,
        )
    )
    var core = IndexCore.create(String("body"), AnalyzerConfig.text("body"), specs^)
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("small", ArrowType.INT8, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(3)
    rb.add_column(Column.from_string(StringArray.from_strings([String("a b")])))
    rb.add_column(Column.from_string(StringArray.from_strings([String("s")])))
    var small: List[Int8] = [7]
    rb.add_column(
        Column.from_primitive[DType.int8](PrimitiveArray[DType.int8].from_list(small))
    )
    var batch = rb.build(schema^)
    with assert_raises(contains="fast-field column 'small' has storage DType int8"):
        core.add_documents(batch^, 0, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
