# =============================================================================
# GroupRef / GroupColumn -- Per-group row view for AggregateUdf
# =============================================================================
#
# Per an internal doc Rev 3.1 Section 4.2. GroupRef provides
# named column access for a single row within a group, following the Pandas
# apply() pattern. AggregateUdf.accumulate() receives a GroupRef.
#
# Design:
#   GroupRef is a lightweight view (batch borrow + row index). It does NOT
#   own data. The batch borrow is a Pointer[RecordBatch, origin] whose origin
#   is the batch's own, so a GroupRef cannot outlive its batch.
#
#   Column access is by name via __getitem__("col"). The returned GroupColumn
#   provides typed accessors (as_f64, as_i64, as_string).
#
# Column tracking:
#   GroupRef records accessed column names in _accessed_names. The plan compiler
#   uses this set to determine which columns to project from the source.
# =============================================================================

from std.sys import size_of
from std.collections import Set

from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# GroupColumn -- typed access to a single column value at a given row
# =============================================================================

struct GroupColumn[origin: Origin[mut=False]](Movable, Copyable):
    """Typed accessor for a single column value within a group row.

    Provides as_f64(), as_i64(), as_string() for type-safe value extraction.
    This is a view: it borrows the parent batch through a
    `Pointer[RecordBatch, origin]`, so it cannot outlive the batch.

    Fields:
        _batch: Tracked borrow of the parent RecordBatch.
        _col: Column index within the batch.
        _row: Row index within the batch.
    """

    var _batch: Pointer[RecordBatch, Self.origin]
    var _col: Int
    var _row: Int

    def __init__(
        out self, ref [Self.origin] batch: RecordBatch, col: Int, row: Int
    ):
        """Create a GroupColumn view.

        Args:
            batch: The parent batch. Borrowed for the lifetime of the view.
            col: Zero-based column index within the batch.
            row: Zero-based row index within the batch.
        """
        self._batch = Pointer(to=batch)
        self._col = col
        self._row = row

    def as_f64(self) raises -> Float64:
        """Read the value as Float64.

        Returns:
            The Float64 value at this row.

        Raises:
            Error if the column is not a float64 type.
        """
        ref col = self._batch[].column_at(self._col)
        if col.arrow_type != ArrowType.FLOAT64:
            raise Error(
                "GroupColumn.as_f64: column type is "
                + String(col.arrow_type)
                + ", expected FLOAT64"
            )
        var offset = col._offset
        return Float64(col._data.get_typed[Scalar[DType.float64]](offset + self._row))

    def as_i64(self) raises -> Int64:
        """Read the value as Int64.

        Returns:
            The Int64 value at this row.

        Raises:
            Error if the column is not an int64 type.
        """
        ref col = self._batch[].column_at(self._col)
        if col.arrow_type != ArrowType.INT64:
            raise Error(
                "GroupColumn.as_i64: column type is "
                + String(col.arrow_type)
                + ", expected INT64"
            )
        var offset = col._offset
        return Int64(col._data.get_typed[Scalar[DType.int64]](offset + self._row))

    def as_i32(self) raises -> Int32:
        """Read the value as Int32.

        Returns:
            The Int32 value at this row.

        Raises:
            Error if the column is not an int32 type.
        """
        ref col = self._batch[].column_at(self._col)
        if col.arrow_type != ArrowType.INT32:
            raise Error(
                "GroupColumn.as_i32: column type is "
                + String(col.arrow_type)
                + ", expected INT32"
            )
        var offset = col._offset
        return Int32(col._data.get_typed[Scalar[DType.int32]](offset + self._row))

    def as_string(self) raises -> String:
        """Read the value as String.

        Returns:
            The String value at this row.

        Raises:
            Error if the column is not a string type.
        """
        ref col = self._batch[].column_at(self._col)
        var str_arr = col.as_string()
        return str_arr.get(self._row)


# =============================================================================
# GroupRef -- per-group row view for AggregateUdf.accumulate()
# =============================================================================

struct GroupRef[origin: Origin[mut=False]](Movable, Copyable):
    """Per-group row view for AggregateUdf.accumulate().

    Provides named column access via get("col_name"). Returns a
    GroupColumn for typed value extraction.

    GroupRef is a lightweight view. It borrows the parent batch through a
    `Pointer[RecordBatch, origin]`, so it cannot outlive the batch. Spell the
    type without arguments (`GroupRef`) in a signature and the origin is
    inferred per call.

    Fields:
        _batch: Tracked borrow of the parent RecordBatch.
        _col_names: Column names from the schema.
        _num_cols: Number of columns.
        _row: Row index within the batch.
        _accessed_names: Set of column names accessed so far.
    """

    var _batch: Pointer[RecordBatch, Self.origin]
    var _col_names: List[String]
    var _num_cols: Int
    var _row: Int
    var _accessed_names: Set[String]

    def __init__(
        out self,
        ref [Self.origin] batch: RecordBatch,
        col_names: List[String],
        row: Int,
    ):
        """Create a GroupRef view at the given row index.

        Args:
            batch: The parent batch. Borrowed for the lifetime of the view.
            col_names: Column names from the schema. Copied into GroupRef.
            row: Zero-based row index within the batch.
        """
        self._batch = Pointer(to=batch)
        self._col_names = col_names.copy()
        self._num_cols = batch.num_columns()
        self._row = row
        self._accessed_names = Set[String]()

    @staticmethod
    def from_batch(ref [Self.origin] batch: RecordBatch, row: Int) -> Self:
        """Create a GroupRef from a RecordBatch and row index.

        Convenience factory that reads the column names from the batch.

        Args:
            batch: The RecordBatch to create a view into.
            row: Zero-based row index.

        Returns:
            A new GroupRef.
        """
        var num_cols = batch.num_columns()
        var col_names = List[String]()
        for c in range(num_cols):
            col_names.append(batch.schema.field_name(c))
        return Self(batch, col_names, row)

    @staticmethod
    def from_batch_with_names(
        ref [Self.origin] batch: RecordBatch,
        col_names: List[String],
        row: Int,
    ) -> Self:
        """Create a GroupRef using pre-cached column names.

        Hot-path factory: avoids re-walking the schema on every row.
        Callers (e.g. AggUdafBridge.update_batch) cache `col_names`
        once per batch and pass it for every row.

        Args:
            batch: The RecordBatch to create a view into.
            col_names: Pre-cached column names (avoids re-walking schema).
            row: Zero-based row index.

        Returns:
            A new GroupRef.
        """
        return Self(batch, col_names, row)

    def _column_index(self, col_name: String) raises -> Int:
        """Look up the column index by name.

        Args:
            col_name: The column name to search for.

        Returns:
            Zero-based column index.

        Raises:
            Error if the column is not found.
        """
        for i in range(self._num_cols):
            if self._col_names[i] == col_name:
                return i
        raise Error("GroupRef: no column named '" + col_name + "'")

    def get(mut self, col_name: String) raises -> GroupColumn[Self.origin]:
        """Get a typed column accessor by name.

        Records the column name for column tracking (projection detection).

        Args:
            col_name: The column name to look up.

        Returns:
            A GroupColumn accessor for the named column at this row.

        Raises:
            Error if the column is not found.
        """
        self._accessed_names.add(col_name)
        var idx = self._column_index(col_name)
        return GroupColumn(self._batch[], idx, self._row)

    @always_inline
    def row_index(self) -> Int:
        """Return the row index within the parent batch."""
        return self._row

    def accessed_column_names(self) -> Set[String]:
        """Return the set of column names accessed so far.

        Used by the plan compiler for column projection detection.
        """
        return self._accessed_names.copy()
