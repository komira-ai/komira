# =============================================================================
# FFI-BOUNDARY: c_data_column -- one batch out as a struct array, one column
# back in
# =============================================================================
#
# The Arrow C Data entry points a host of a UDF runtime calls
# (`udf_host`, docs/design/udf_runtime_interface.md section 4.4): the argument
# columns of one call go out as a struct array, the struct's schema and the
# result's field go out as schemas, and the column the runtime returns comes
# back in. Each is a public name for a builder or importer `c_data_stream`
# already holds for the Arrow C stream, so a column crosses both interfaces
# in the same layout:
#
#   export_struct_array   `_build_record_batch_array`: every column shared
#                         (an Arc count, never a copy) into the root's private
#                         state, so the export stays readable after `batch`
#                         is gone; its consumer calls `release` once
#   export_struct_schema  `_build_record_batch_schema_no_data`: a `+s` schema
#                         with one child per field
#   export_field_schema   `_build_column_schema_from_field`
#   import_c_column       `_import_child_column`: the array read at the type
#                         `schema` declares, every buffer byte copied, so
#                         nothing points into the producer's memory once it
#                         returns. The producer's array is not released here:
#                         its owner calls `consumer_release_c_array`.
#
# Nothing here holds a pointer across a call: the structs are values whose
# pointer fields the release protocol owns (c_data_interface's header).
# =============================================================================

from arrow.column import Column
from arrow.schema import Field, RecordBatch, Schema
from byte_buffer.heap_region import HeapRegion

from arrow_ipc.c_data_interface import CArrowArray, CArrowSchema
from arrow_ipc.c_data_stream import (
    _build_column_schema_from_field,
    _build_record_batch_array,
    _build_record_batch_schema_no_data,
    _import_child_column,
)


def export_struct_array(ref batch: RecordBatch) raises -> CArrowArray:
    """`batch` as a struct array (`+s`): `batch.num_rows()` rows, offset 0,
    one NULL validity buffer, one child per column in column order. The
    columns are shared, not copied; the consumer calls `release` once.

    Raises:
        The builder's error when a column's type does not cross the C Data
        Interface (`UnsupportedArrowCABIType`).
    """
    var schema = batch.schema.copy()
    return _build_record_batch_array(batch, schema)


def export_struct_schema(schema: Schema) raises -> CArrowSchema:
    """The `+s` schema of a struct whose children are `schema`'s fields, in
    order, each named and flagged nullable as its field is.

    Raises:
        As `export_struct_array`, for a field whose type does not cross.
    """
    return _build_record_batch_schema_no_data(schema)


def export_field_schema(field: Field) raises -> CArrowSchema:
    """The schema of one column of `field`'s type, name and nullability.

    Raises:
        As `export_struct_array`.
    """
    return _build_column_schema_from_field(field)


def import_c_column(
    ref array: CArrowArray, mut schema: CArrowSchema
) raises -> Column[HeapRegion]:
    """A copy of `array`, read at the type `schema` declares. `array` stays
    the producer's: its `release` is not called.

    Raises:
        The importer's error naming the layout it refuses: a buffer count
        that is not the type's, a NULL buffer that would hold bytes, a
        non-zero offset, or a type that does not cross.
    """
    # SAFETY: the importer reads the schema through a pointer because a
    # nested type's children are reached the same way; it is `schema`, a
    # live local of the caller for the whole call (its origin is that
    # argument's), read and never written or kept.
    var at = UnsafePointer(to=schema).unsafe_origin_cast[MutUntrackedOrigin]()
    return _import_child_column(array, at)
