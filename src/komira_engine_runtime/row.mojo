# =============================================================================
# Row -- Single-row view into a RecordBatch
# =============================================================================
#
# Row provides named column access for a single row within a RecordBatch. Used
# by element-wise map and scalar UDF implementations that want per-row access.
#
# Design:
#   Row is a lightweight view (batch borrow + row index). It does NOT own data
#   and holds no copy of the column names: a name is resolved against the
#   batch's schema on each access, so building a Row per row costs no
#   allocation. The batch borrow is a Pointer[RecordBatch, origin] whose origin
#   is the batch's own, so a Row cannot outlive its batch.
#
#   Column access is by name via get_f64/get_i64/get_i32/get_string. Each typed
#   accessor checks the column's type and that the row is inside the column,
#   and raises otherwise. The value returned is the stored slot; the validity
#   bitmap is not consulted, so a null slot reads as whatever the buffer holds.
#
# Column tracking:
#   Row records accessed column names in _accessed_names. A caller can run a
#   probe row over the first morsel and read the set to learn which columns an
#   expression touches.
# =============================================================================

from std.collections import Set

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch


struct Row[origin: Origin[mut=False]](Copyable, Movable):
    """Single-row view into a RecordBatch.

    Provides named column access for a single row. The Row borrows from a
    RecordBatch through a `Pointer[RecordBatch, origin]`: the `origin`
    parameter is the batch's own borrow, so the compiler rejects a Row that
    would outlive its batch. Spell the type without arguments (`Row`) in a
    signature and the origin is inferred per call.

    Fields:
        _batch: Tracked borrow of the parent RecordBatch.
        _num_cols: Number of columns in the parent batch.
        _row: Row index within the batch.
        _accessed_names: Set of column names accessed so far.
    """

    var _batch: Pointer[RecordBatch, Self.origin]
    var _num_cols: Int
    var _row: Int
    var _accessed_names: Set[String]

    def __init__(out self, ref [Self.origin] batch: RecordBatch, row: Int):
        """Create a Row view at the given index.

        Args:
            batch: The parent batch. Borrowed for the lifetime of the Row.
            row: Zero-based row index within the batch.
        """
        self._batch = Pointer(to=batch)
        self._num_cols = batch.num_columns()
        self._row = row
        self._accessed_names = Set[String]()

    @always_inline
    def row_index(self) -> Int:
        """Return the row index within the parent batch."""
        return self._row

    def _column_index(self, col_name: String) raises -> Int:
        """Look up the column index by name in the batch's schema.

        Args:
            col_name: The column name to search for.

        Returns:
            Zero-based column index.

        Raises:
            Error if the column is not found.
        """
        for i in range(self._num_cols):
            if self._batch[].schema.field_name(i) == col_name:
                return i
        raise Error("Row: no column named '" + col_name + "'")

    def _checked_column_index(
        mut self, col_name: String, expected: ArrowType, accessor: String
    ) raises -> Int:
        """Record the access, resolve the name and check type and row range."""
        self._accessed_names.add(col_name)
        var idx = self._column_index(col_name)
        ref col = self._batch[].column_at(idx)
        if col.arrow_type != expected:
            raise Error(
                "Row."
                + accessor
                + ": column '"
                + col_name
                + "' has type "
                + String(col.arrow_type)
                + ", expected "
                + String(expected)
            )
        if self._row < 0 or self._row >= col.length():
            raise Error(
                "Row."
                + accessor
                + ": row "
                + String(self._row)
                + " is outside column '"
                + col_name
                + "' of length "
                + String(col.length())
            )
        return idx

    def get_f64(mut self, col_name: String) raises -> Float64:
        """Read a Float64 value by column name.

        Args:
            col_name: The column name to look up.

        Returns:
            The Float64 value at this row for the named column.

        Raises:
            Error if the column is not found, is not FLOAT64, or the row is
            outside the column.
        """
        var idx = self._checked_column_index(
            col_name, ArrowType.FLOAT64, "get_f64"
        )
        ref col = self._batch[].column_at(idx)
        return Float64(
            col._data.get_typed[Scalar[DType.float64]](col._offset + self._row)
        )

    def get_i64(mut self, col_name: String) raises -> Int64:
        """Read an Int64 value by column name.

        Args:
            col_name: The column name to look up.

        Returns:
            The Int64 value at this row for the named column.

        Raises:
            Error if the column is not found, is not INT64, or the row is
            outside the column.
        """
        var idx = self._checked_column_index(
            col_name, ArrowType.INT64, "get_i64"
        )
        ref col = self._batch[].column_at(idx)
        return Int64(
            col._data.get_typed[Scalar[DType.int64]](col._offset + self._row)
        )

    def get_i32(mut self, col_name: String) raises -> Int32:
        """Read an Int32 value by column name.

        Args:
            col_name: The column name to look up.

        Returns:
            The Int32 value at this row for the named column.

        Raises:
            Error if the column is not found, is not INT32, or the row is
            outside the column.
        """
        var idx = self._checked_column_index(
            col_name, ArrowType.INT32, "get_i32"
        )
        ref col = self._batch[].column_at(idx)
        return Int32(
            col._data.get_typed[Scalar[DType.int32]](col._offset + self._row)
        )

    def get_string(mut self, col_name: String) raises -> String:
        """Read a String value by column name.

        Args:
            col_name: The column name to look up.

        Returns:
            The String value at this row for the named column.

        Raises:
            Error if the column is not found or is not a string type.
        """
        self._accessed_names.add(col_name)
        var idx = self._column_index(col_name)
        ref col = self._batch[].column_at(idx)
        var str_arr = col.as_string()
        return str_arr.get(self._row)

    def accessed_column_names(self) -> Set[String]:
        """Return the set of column names accessed so far."""
        return self._accessed_names.copy()
