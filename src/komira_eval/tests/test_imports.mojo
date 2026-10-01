# =============================================================================
# Smoke test — verify package imports work from komira_arrow and komira_eval
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import PrimitiveArray, Bitmap, Schema, Field, RecordBatch
from komira_eval import eval_gt, eval_add, SelectionVector
from komira_eval import eval_lt, eval_eq, filter_to_indices
from komira_eval import eval_sub, eval_mul, eval_div
from komira_eval import eval_add_scalar, eval_mul_scalar
from komira_eval import eval_and, eval_or, eval_not
from komira_eval import eval_cast, bitmap_and, eval_gt_nullable
from komira_eval import eval_is_null, eval_is_not_null


def test_primitive_array_allocate() raises:
    """PrimitiveArray can be allocated and queried."""
    var arr = PrimitiveArray[DType.int32].allocate(10)
    assert_equal(arr.length, 10)
    assert_equal(arr.null_count, 0)
    for i in range(10):
        assert_equal(arr.get(i), Scalar[DType.int32](0))


def test_primitive_array_from_list() raises:
    """PrimitiveArray.from_list stores and retrieves values."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](10),
        Scalar[DType.int32](20),
        Scalar[DType.int32](30),
    ]
    var arr = PrimitiveArray[DType.int32].from_list(values)
    assert_equal(arr.length, 3)
    assert_equal(arr.get(0), Scalar[DType.int32](10))
    assert_equal(arr.get(1), Scalar[DType.int32](20))
    assert_equal(arr.get(2), Scalar[DType.int32](30))


def test_bitmap_create() raises:
    """Bitmap can be created and bits set/tested."""
    var bm = Bitmap.create(16)
    assert_equal(bm.length, 16)
    assert_false(bm.test(0))
    bm.set(0)
    assert_true(bm.test(0))
    assert_equal(bm.popcount(), 1)


def test_schema_and_field() raises:
    """Schema with Fields can be constructed and queried."""
    var schema = Schema.from_fields_2(
        Field("id", DType.int64, nullable=False),
        Field("val", DType.float64, nullable=True),
    )
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_name(0), "id")
    assert_equal(schema.field_dtype(1), DType.float64)
    assert_true(schema.field_nullable(1))


def test_eval_gt_import() raises:
    """Eval_gt works through package import."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](5),
        Scalar[DType.int32](10),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_gt[DType.int32](col, Scalar[DType.int32](3))
    assert_equal(result.length, 3)
    assert_false(Bool(result.get(0)))
    assert_true(Bool(result.get(1)))
    assert_true(Bool(result.get(2)))


def test_eval_add_import() raises:
    """Eval_add works through package import."""
    var left_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
    ]
    var right_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](10),
        Scalar[DType.int32](20),
    ]
    var left = PrimitiveArray[DType.int32].from_list(left_vals)
    var right = PrimitiveArray[DType.int32].from_list(right_vals)
    var result = eval_add[DType.int32](left, right)
    assert_equal(result.get(0), Scalar[DType.int32](11))
    assert_equal(result.get(1), Scalar[DType.int32](22))


def test_selection_vector_import() raises:
    """SelectionVector works through package import."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](5),
        Scalar[DType.int32](15),
        Scalar[DType.int32](25),
        Scalar[DType.int32](35),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var mask = eval_gt[DType.int32](col, Scalar[DType.int32](10))
    var sv = SelectionVector.from_bool_mask(mask)
    assert_equal(sv.length(), 3)
    var result = sv.gather[DType.int32](col)
    assert_equal(result.length, 3)
    assert_equal(Int(result.get(0)), 15)
    assert_equal(Int(result.get(1)), 25)
    assert_equal(Int(result.get(2)), 35)


def test_eval_cast_import() raises:
    """Eval_cast works through package import."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
        Scalar[DType.int32](3),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_cast[DType.int32, DType.float64](col)
    assert_equal(result.get(0), Scalar[DType.float64](1.0))
    assert_equal(result.get(1), Scalar[DType.float64](2.0))
    assert_equal(result.get(2), Scalar[DType.float64](3.0))


def test_record_batch_import() raises:
    """RecordBatch works through package import."""
    var values: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](100),
        Scalar[DType.int64](200),
    ]
    var batch = RecordBatch.from_columns_1(
        Schema.from_fields_1(
            Field("x", DType.int64, nullable=False),
        ),
        PrimitiveArray[DType.int64].from_list(values),
    )
    assert_equal(batch.num_rows(), 2)
    assert_equal(batch.column_value(0, 0), Scalar[DType.int64](100))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
