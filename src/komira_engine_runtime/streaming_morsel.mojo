# =============================================================================
# StreamingMorsel — A morsel with optional SelectionVector for zero-copy filter
# =============================================================================
#
# The streaming pipeline avoids materializing filtered rows. Instead, a
# SelectionVector tracks which rows are "active". Operators read through the
# SV and downstream sinks only consume active rows.
#
# When selection is None, ALL rows are active (fast path — no indirection).
#
# Reference: v0.3 Rust morsel.rs + pipeline_streaming_plan.md Phase 1
# =============================================================================

from komira_arrow.schema import RecordBatch
from komira_arrow.selection_vector import SelectionVector


struct StreamingMorsel(Movable):
    """A morsel of rows with an optional SelectionVector for lazy filtering.

    The batch contains ALL physical rows. The selection (when present) indicates
    which subset of those rows are "active" — i.e., passed all filters so far.
    Downstream operators and sinks must respect the selection.

    When selection is None, all rows in the batch are active. This is the
    common case for scans before any filter is applied.

    Fields:
        batch: The underlying RecordBatch holding column data (all physical rows).
        selection: Optional SelectionVector — indices of active rows. None means
            all rows are active.
        num_active: Number of active rows. Equals batch.num_rows() when selection
            is None, otherwise equals selection.length().
    """

    var batch: RecordBatch
    var selection: Optional[SelectionVector]
    var num_active: Int

    def __init__(out self, var batch: RecordBatch):
        """Create a StreamingMorsel with all rows active (no selection).

        Args:
            batch: The RecordBatch to wrap. Ownership is transferred.
        """
        self.num_active = batch.num_rows()
        self.batch = batch^
        self.selection = None

    def __init__(out self, var batch: RecordBatch, var sv: SelectionVector):
        """Create a StreamingMorsel with a pre-computed SelectionVector.

        Args:
            batch: The RecordBatch to wrap. Ownership is transferred.
            sv: The SelectionVector indicating active rows.
        """
        self.num_active = sv.length()
        self.batch = batch^
        self.selection = sv^

    @always_inline
    def all_active(self) -> Bool:
        """Return True when ALL rows in the batch are active (no SV)."""
        return not self.selection

    def set_selection(mut self, var sv: SelectionVector):
        """Replace the current selection with a new SelectionVector.

        Args:
            sv: The new SelectionVector. Ownership is transferred.
        """
        self.num_active = sv.length()
        self.selection = sv^

    def take_selection(mut self) -> SelectionVector:
        """Move the current selection out. Caller must set a new one or leave None.

        Precondition: self.selection is not None.
        """
        var sv = self.selection.unsafe_take()
        self.num_active = 0
        return sv^

    def clear_selection(mut self):
        """Remove the selection, marking all rows as active."""
        self.num_active = self.batch.num_rows()
        self.selection = None
