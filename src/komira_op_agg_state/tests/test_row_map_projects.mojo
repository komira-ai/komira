# =============================================================================
# test_row_map_projects.mojo — RowMapProjects[m]: one output column per field
# of the map's output struct, named after the field, one value per survivor
# =============================================================================
#
# The map `_price` turns an `Order{price, qty}` row into `Priced{margin,
# bucket}`. Over a 4-row batch with survivors [0, 2, 3]:
#
#   - the result has exactly 2 columns, named `margin` and `bucket` (the
#     output struct's own field names, not out0 / out1);
#   - it has 3 rows, in survivor order, and row j of each column is field k of
#     m(row survivors[j]) -- so a column built from the wrong field, the wrong
#     survivor or the wrong input column shows as a wrong value;
#   - an empty survivor list yields the 2 named columns with 0 rows;
#   - pdescribe() is the nonzero 2049 (0 would make the stage skip the map),
#     the slot default-constructs, and bind() accepts any resolver.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, Schema
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_udf.column_resolver import ColumnResolver
from komira_op_agg_state.row_map_projects import RowMapProjects


@fieldwise_init
struct Order(Copyable, Movable, AutoKomiraSchema):
    var price: Float64
    var qty: Int64


@fieldwise_init
struct Priced(Copyable, Movable, AutoKomiraSchema):
    var margin: Float64
    var bucket: Int64


def _price(row: Order) -> Priced:
    return Priced(row.price * 0.5 - 1.0, row.qty * 10 + 7)


def _batch() raises -> RecordBatch:
    var prices = PrimitiveArray[DType.float64].allocate(4)
    var qtys = PrimitiveArray[DType.int64].allocate(4)
    var p: List[Float64] = [Float64(10.0), Float64(20.0), Float64(30.0), Float64(40.0)]
    var q: List[Int64] = [Int64(1), Int64(2), Int64(3), Int64(4)]
    for i in range(4):
        prices.set(i, p[i])
        qtys.set(i, q[i])
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.float64](prices^))
    b.add_column(Column.from_primitive[DType.int64](qtys^))
    return b.build(
        Schema.from_fields_2(
            Field("price", DType.float64, False), Field("qty", DType.int64, False)
        )
    )


def test_emits_one_named_column_per_output_field() raises:
    var batch = _batch()
    var bv = BatchView(batch)
    var slot = RowMapProjects[_price]()
    var survivors: List[Int] = [0, 2, 3]
    var out = slot.emit_projected(bv, survivors)
    assert_equal(out.num_columns(), 2)
    assert_equal(out.num_rows(), 3)
    var mi = out.column_by_name("margin")
    var bi = out.column_by_name("bucket")
    assert_equal(mi, 0)
    assert_equal(bi, 1)
    var m = out.column_at(mi)._data.view_typed_ro[DType.float64]()
    var k = out.column_at(bi)._data.view_typed_ro[DType.int64]()
    # Rows 0, 2, 3: price 10, 30, 40; qty 1, 3, 4.
    assert_equal(m[0], Float64(4.0))
    assert_equal(m[1], Float64(14.0))
    assert_equal(m[2], Float64(19.0))
    assert_equal(k[0], Int64(17))
    assert_equal(k[1], Int64(37))
    assert_equal(k[2], Int64(47))


def test_no_survivors_gives_named_empty_columns() raises:
    var batch = _batch()
    var bv = BatchView(batch)
    var slot = RowMapProjects[_price].make_default()
    var none: List[Int] = []
    var out = slot.emit_projected(bv, none)
    assert_equal(out.num_columns(), 2)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.column_by_name("bucket"), 1)


def test_discriminator_default_and_bind() raises:
    assert_equal(RowMapProjects[_price].pdescribe(), 2049)
    assert_true(RowMapProjects[_price].pdescribe() != 0)
    var slot = RowMapProjects[_price].make_default()
    var r = ColumnResolver()
    slot.bind(r)
    assert_equal(RowMapProjects[_price].ARITY, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
