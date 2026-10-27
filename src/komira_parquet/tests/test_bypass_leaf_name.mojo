# `_leaf_name` (bypass): the name of the `col_index`-th leaf of a schema that
# has a group, which has no column chunk and so does not count, and the empty
# name of an index past the last leaf.
from std.testing import TestSuite, assert_equal

from komira_parquet_api.metadata import FileMetaData, RowGroup, SchemaElement
from komira_parquet_api.types import FieldRepetitionType, ParquetType

from komira_parquet.bypass import _leaf_name


def _leaf(var name: String) -> SchemaElement:
    return SchemaElement(
        name^,
        Optional[ParquetType](ParquetType.INT32),
        repetition_type=Optional[FieldRepetitionType](FieldRepetitionType.REQUIRED),
    )


def _md() -> FileMetaData:
    var schema = List[SchemaElement]()
    schema.append(SchemaElement(String("root"), num_children=3))
    schema.append(_leaf("a"))
    schema.append(SchemaElement(String("g"), num_children=1))
    schema.append(_leaf("inner"))
    schema.append(_leaf("z"))
    return FileMetaData(version=2, schema=schema^, num_rows=0, row_groups=List[RowGroup]())


def test_a_group_does_not_take_a_leaf_index() raises:
    var md = _md()
    assert_equal(_leaf_name(md, 0), "a")
    assert_equal(_leaf_name(md, 1), "inner")
    assert_equal(_leaf_name(md, 2), "z")


def test_an_index_past_the_last_leaf_has_an_empty_name() raises:
    var md = _md()
    assert_equal(_leaf_name(md, 3), "")
    assert_equal(_leaf_name(md, -1), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
