# =============================================================================
# ScalarUdf -- Tier 3a: Class-based stateful scalar UDF trait
# =============================================================================
#
# Users implement this
# trait for reusable, stateful row transforms: compiled regex, ML model
# inference, connection pools, etc.
#
# Lifecycle:
#   1. User defines a struct implementing ScalarUdf.
#   2. Plan compiler stores a prototype instance.
#   3. At pipeline start, each worker gets a copy (via Copyable).
#      This is where per-worker initialization happens -- the copy
#      constructor can allocate scratch buffers, compile regexes, etc.
#   4. Worker calls evaluate(mut self, ...) per morsel. mut self gives
#      exclusive access to all struct fields.
#   5. On pipeline teardown, instances are destroyed (RAII).
#
# Contract:
#   - evaluate() MUST return a RecordBatch with exactly batch.num_rows rows.
#   - evaluate() MUST NOT panic (use raises for all failures).
#   - A stateless UDF is just a struct with no fields.
#
# Thread safety:
#   No Sync requirement. Workers own their instances exclusively.
#   Copyable enables per-worker copy; Movable enables transfer to workers.
#
# Heavy state:
#   For non-copyable state (ML models), hold an ArcPointer[T] field.
#   __copyinit__ bumps the reference count instead of deep-copying.
# =============================================================================

from komira_core.arrow.schema import RecordBatch, Schema


trait ScalarUdf(Movable, Copyable, Deinitable):
    """A user-defined scalar function: N rows in, N rows out.

    State lives in struct fields. Each worker gets its own copy via
    Copyable. The engine never shares an instance across workers.

    See module docstring for full lifecycle and contract documentation.
    """

    def name(self) -> String:
        """Human-readable name for error messages and EXPLAIN output."""
        ...

    def output_schema(self) -> Schema:
        """Schema of the output RecordBatch after this UDF."""
        ...

    def evaluate(mut self, batch: RecordBatch) raises -> RecordBatch:
        """Transform an input batch into an output batch.

        mut self gives exclusive access to all struct fields.
        Each worker owns its own instance -- no synchronization needed.

        Args:
            batch: Input RecordBatch (projected by input_columns if specified).

        Returns:
            Output RecordBatch with exactly batch.num_rows rows matching
            output_schema().
        """
        ...
