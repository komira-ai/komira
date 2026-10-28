# =============================================================================
# test_top_n_state_column_native_transparency.mojo
#
# Bridge round-trip gate for the output shape of the top_n_state breaker. It builds
# a RecordBatch shaped like that breaker's output by hand (no operator state is
# reached: this package depends on no operator), moves it through
# column_native_from_record_batch and record_batch_from_column_native, and
# asserts the result is byte-equal to the input. It proves the bridge keeps
# values, validity, offsets and schema flags for this shape; it does not prove
# that an operator's column-native result equals its RecordBatch result.
#
# This breaker drains FULL ROWS [k0..kK-1, payload0..payloadM-1]. The bridge
# transparency below covers its representative output shapes: composite keys +
# multiple Int64 payloads, and a STRING payload (var-width region).
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field

from komira_arrow_ipc.record_batch_compare import record_batch_byte_equal

from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)


def test_bridge_byte_identical_fullrow_multi_payload() raises:
    """Full-row top-N output [k0 Int64, k1 Int64, p0 Int64, p1 Int64] round-trips
    byte-identical through the breaker-output bridge."""

    def build() raises -> RecordBatch:
        var s = SchemaBuilder()
        s.add_field(Field(String("k0"), ArrowType.INT64, True))
        s.add_field(Field(String("k1"), ArrowType.INT64, True))
        s.add_field(Field(String("p0"), ArrowType.INT64, True))
        s.add_field(Field(String("p1"), ArrowType.INT64, True))
        var schema = s.build()
        var l0: List[Scalar[DType.int64]] = [1, 1, 2, 2]
        var l1: List[Scalar[DType.int64]] = [9, 8, 7, 6]
        var p0: List[Scalar[DType.int64]] = [100, 200, 300, 400]
        var p1: List[Scalar[DType.int64]] = [11, 22, 33, 44]
        var c0 = Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(l0)
        )
        var c1 = Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(l1)
        )
        var cp0 = Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(p0)
        )
        var cp1 = Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(p1)
        )
        return RecordBatch.from_typed_columns_4(schema^, c0^, c1^, cp0^, cp1^)

    var golden = build()
    var to_bridge = build()
    var native = column_native_from_record_batch(to_bridge^)
    assert_true(native.num_columns() == 4, "col count preserved")
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "TopN full-row bridge (2 keys + 2 payloads) must be byte-identical",
    )


def test_bridge_byte_identical_fullrow_string_payload() raises:
    """Full-row top-N output with a STRING payload (var-width) round-trips
    byte-identical — exercises the THSPLC var-width region path the full-row
    breaker carries as a payload column."""

    def build() raises -> RecordBatch:
        var s = SchemaBuilder()
        s.add_field(Field(String("k0"), ArrowType.INT64, True))
        s.add_field(Field(String("name"), ArrowType.STRING, True))
        var schema = s.build()
        var l0: List[Scalar[DType.int64]] = [3, 1, 2, 4]
        var c0 = Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(l0)
        )
        var names: List[String] = [
            String("gamma"),
            String("alpha"),
            String(""),
            String("delta"),
        ]
        var scol = Column.from_string(StringArray.from_strings(names))
        return RecordBatch.from_typed_columns_2(schema^, c0^, scol^)

    var golden = build()
    var to_bridge = build()
    var native = column_native_from_record_batch(to_bridge^)
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "TopN full-row bridge (key + string payload) must be byte-identical",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
