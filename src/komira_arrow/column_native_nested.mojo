# =============================================================================
# column_native_nested.mojo — column-native foundation: per-family
# refinement traits for nested (List / Struct) columns.
# =============================================================================
#
# DESIGN CONSTRAINT:
#   Nested types (List / Struct) need PER-FAMILY refinement traits, NOT a
#   uniform cell-return. A `List<T>` cell is a child SLICE (begin, end); a
#   `Struct{}` cell is a tuple of child columns. A single uniform "cell-return"
#   trait method is NOT expressible across conformers (a trait method
#   cannot return a borrowed slice-view uniformly). The (begin, end) + child_at
#   triple IS the Arrow list cell, addressed without materializing a view.
#
# Arrow nested layout (the spec the column-native body mirrors):
#   List<T>  = validity bitmap + Int32 offsets buffer + child VALUES buffer.
#              "list cell i" = child slice [offsets[i], offsets[i+1]).
#   Struct{} = validity bitmap + N child column buffers (one per field).
#              "struct cell i" = (child_0[i], child_1[i], ...).
#   nested-of-nested = recursive (the child of a List is itself a column).
#
# These traits REFINE BatchFormat: a generic driver over [F: ListColumnFormat]
# reads list cells without knowing the concrete conformer (and still
# monomorphizes per F = zero per-row vtable dispatch).
# =============================================================================

from komira_arrow.batch_format import BatchFormat


trait ListColumnFormat(BatchFormat):
    """Refinement for List<T> columns. The cell TYPE (a child slice) is
    expressed as (begin, end) + `child_at` — a single uniform cell-return is
    NOT expressible across conformers on 1.0.0b1 (poc_nested_encoding).

    All methods are keyed by `col_idx` (which list column in the batch) +
    `i` (which row) — a batch may carry several list columns alongside flat
    columns.
    """

    def cell_is_valid(self, col_idx: Int, i: Int) -> Bool:
        ...

    def cell_offset_begin(self, col_idx: Int, i: Int) -> Int:
        ...

    def cell_offset_end(self, col_idx: Int, i: Int) -> Int:
        ...

    def child_at[T: DType](self, col_idx: Int, child_pos: Int) -> Scalar[T]:
        ...


trait StructColumnFormat(BatchFormat):
    """Refinement for Struct{} columns. cell i = (child_0[i], child_1[i], ...);
    each child is itself a column addressed by (struct_col_idx, field_idx)."""

    def struct_field_count(self, col_idx: Int) -> Int:
        ...

    def struct_child_at[
        T: DType
    ](self, col_idx: Int, field_idx: Int, i: Int) -> Scalar[T]:
        ...
