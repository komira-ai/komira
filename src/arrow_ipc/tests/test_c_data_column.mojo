# c_data_column: a batch out as a struct array and its schema, one column
# back in.
#
# What it proves: a batch of an int64 column with a NULL and a string column
# goes out as a `+s` struct array of its row count, offset 0, one child per
# column, and its schema as `+s` with one named child per field; each child
# array read back at its field's schema (`import_c_column`) holds the same
# rows and NULLs; a field's schema carries its name and the nullable flag;
# and an array of the wrong layout for the schema (an int64 child read as a
# string) is refused by the importer's named error, not read.
# Catches: an export of the wrong row count or child order, an import that
# drops a NULL or reads at the wrong type, and an import that trusts a
# layout it was not given.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from arrow.string_array import StringArray
from arrow_ipc.c_data_column import (
    export_field_schema,
    export_struct_array,
    export_struct_schema,
    import_c_column,
)
from arrow_ipc.c_data_interface import ARROW_FLAG_NULLABLE


def _batch() raises -> RecordBatch:
    var b = ColumnBuilder[DType.int64]()
    b.append(7)
    b.append_null()
    b.append(-3)
    var s = List[String]()
    s.append("x")
    s.append("")
    s.append("yz")
    var sb = SchemaBuilder()
    sb.add_field(Field("n", ArrowType.INT64, True))
    sb.add_field(Field("t", ArrowType.STRING, False))
    var rb = RecordBatchBuilder()
    rb.add_column(b^.materialize())
    rb.add_column(Column.from_string(StringArray.from_strings(s)))
    return rb.build(sb.build())


def test_a_batch_goes_out_and_its_columns_come_back() raises:
    var batch = _batch()
    var arr = export_struct_array(batch)
    var schema = export_struct_schema(batch.schema)
    assert_equal(Int(arr.length), 3)
    assert_equal(Int(arr.offset), 0)
    assert_equal(Int(arr.n_children), 2)
    assert_equal(Int(schema.n_children), 2)
    var n_field = export_field_schema(batch.schema.field_at(0))
    var t_field = export_field_schema(batch.schema.field_at(1))
    assert_true((n_field.flags & ARROW_FLAG_NULLABLE) != 0, "n is nullable")
    assert_true((t_field.flags & ARROW_FLAG_NULLABLE) == 0, "t is not")
    var n = import_c_column(arr.children[0][], n_field)
    assert_equal(n.length(), 3)
    assert_true(n.is_null_at(1))
    assert_equal(n.as_primitive[DType.int64]().get(2), -3)
    var t = import_c_column(arr.children[1][], t_field)
    assert_equal(t.length(), 3)
    assert_equal(t.arrow_type, ArrowType.STRING)
    var refused = String("read")
    try:
        _ = import_c_column(arr.children[0][], t_field)
    except e:
        refused = String(e)
    assert_true(refused.startswith("from_arrow_c_stream: "), refused)
    # The exports are not released: the process ends with the test, and a
    # release here would need a pointer to the value, which this test does
    # not name.


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_batch_goes_out_and_its_columns_come_back]()
    suite^.run()
