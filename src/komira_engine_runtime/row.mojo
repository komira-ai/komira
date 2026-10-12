# =============================================================================
# Row -- Single-row view into a RecordBatch
# =============================================================================
#
# Per an internal doc Rev 3.1 Sections 1.2 and 3.4. Row provides
# named column access for a single row within a RecordBatch. Used by element-wise
# map (Tier 2) and ScalarUdf implementations that want per-row access.
#
# Design:
#   Row is a lightweight view (batch borrow + column names + row index).
#   It does NOT own data. The batch borrow is a Pointer[RecordBatch, origin]
#   whose origin is the batch's own, so a Row cannot outlive its batch.
#
#   Column access is by name via get_f64/get_i64/get_string. Type-specific
#   accessors provide direct typed access without intermediate Column copies.
#
# Column tracking:
#   Row records accessed column names in _accessed_names. The plan compiler
#   uses this set (from a probe row on the first morsel) to determine which
#   columns to project from the source. This is the runtime column detection
#   described in Section 3.4.
# =============================================================================

from std.sys import size_of
from std.collections import Set

from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_buffer.heap_region import HeapRegion


struct Row[origin: Origin[mut=False]](Copyable, Movable):
    """Single-row view into a RecordBatch.

    Provides named column access for a single row. The Row borrows from a
    RecordBatch through a `Pointer[RecordBatch, origin]`: the `origin`
    parameter is the batch's own borrow, so the compiler rejects a Row that
    would outlive its batch. Spell the type without arguments (`Row`) in a
    signature and the origin is inferred per call.

    Fields:
        _batch: Tracked borrow of the parent RecordBatch.
        _col_names: Column names from the schema (shared across all Rows).
        _num_cols: Number of columns in the parent batch.
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
        """Create a Row view at the given index.

        Args:
            batch: The parent batch. Borrowed for the lifetime of the Row.
            col_names: Column names from the schema. Copied into Row.
            row: Zero-based row index within the batch.
        """
        self._batch = Pointer(to=batch)
        self._col_names = col_names.copy()
        self._num_cols = batch.num_columns()
        self._row = row
        self._accessed_names = Set[String]()

    @staticmethod
    def from_batch_with_names(
        ref [Self.origin] batch: RecordBatch,
        col_names: List[String],
        row: Int,
    ) -> Self:
        """Create a Row using pre-cached column names.

        Hot-path factory: avoids re-walking the schema on every row.
        Callers (e.g. ClosureUdfF64.evaluate) cache `col_names` once
        per batch and pass it for every row.

        Args:
            batch: The RecordBatch to create a view into.
            col_names: Pre-cached column names.
            row: Zero-based row index.

        Returns:
            A new Row.
        """
        return Self(batch, col_names, row)

    @always_inline
    def row_index(self) -> Int:
        """Return the row index within the parent batch."""
        return self._row

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
        raise Error("Row: no column named '" + col_name + "'")

    def get_f64(mut self, col_name: String) raises -> Float64:
        """Read a Float64 value by column name.

        Args:
            col_name: The column name to look up.

        Returns:
            The Float64 value at this row for the named column.

        Raises:
            Error if the column is not found.
        """
        self._accessed_names.add(col_name)
        var idx = self._column_index(col_name)
        ref col = self._batch[].column_at(idx)
        var offset = col._offset
        # Z.4c: typed element access via MmapAlignedBuffer.get_typed (replaces
        # bitcast[Scalar[DType.float64]]() + offset + self._row deref).
        return Float64(
            col._data.get_typed[Scalar[DType.float64]](
                offset + self._row
            )
        )

    def get_i64(mut self, col_name: String) raises -> Int64:
        """Read an Int64 value by column name.

        Args:
            col_name: The column name to look up.

        Returns:
            The Int64 value at this row for the named column.

        Raises:
            Error if the column is not found.
        """
        self._accessed_names.add(col_name)
        var idx = self._column_index(col_name)
        ref col = self._batch[].column_at(idx)
        var offset = col._offset
        # Z.4c: typed element access via MmapAlignedBuffer.get_typed.
        return Int64(
            col._data.get_typed[Scalar[DType.int64]](
                offset + self._row
            )
        )

    def get_i32(mut self, col_name: String) raises -> Int32:
        """Read an Int32 value by column name.

        Args:
            col_name: The column name to look up.

        Returns:
            The Int32 value at this row for the named column.

        Raises:
            Error if the column is not found.
        """
        self._accessed_names.add(col_name)
        var idx = self._column_index(col_name)
        ref col = self._batch[].column_at(idx)
        var offset = col._offset
        # Z.4c: typed element access via MmapAlignedBuffer.get_typed.
        return Int32(
            col._data.get_typed[Scalar[DType.int32]](
                offset + self._row
            )
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
        """Return the set of column names accessed so far.

        Used by the plan compiler for column projection detection.
        """
        return self._accessed_names.copy()
