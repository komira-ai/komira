# =============================================================================
# batch_format.mojo — the column-native foundation: the universal BatchFormat
# trait + FormatKind comptime tag.
# =============================================================================
#
# This is the foundation contract for the column-native execution path.
# Conformers: ColumnNativeBatch, RowNativeBatch, StreamingBlobBatch.
#
# Two design constraints:
#   1. NO `where`-clause appears on ANY signature that touches a BatchFormat
#      parameter. `F: BatchFormat where F.format_kind()==COLUMN` COMPILES on
#      Mojo 1.0 but EVERY call site fails "lacking evidence to prove
#      correctness". The format-kind gate is `comptime if F.format_kind() ==
#      FormatKind.COLUMN` INSIDE a body, never a where-clause on a signature.
#   2. The trait surface is the COMMON subset every consumer needs regardless
#      of format. Format-specific cell access (column_unified, row read_fixed)
#      is a CONCRETE method on the conformer, consumed inside the per-format
#      driver — NOT a trait method.
#
# `FormatKind.ROW` IS NOT A ROW EXECUTION ENGINE. ROW here is the SPILL
# ENCODING the COLUMN engine writes (`row_sort_spill` -> `sort_spill_driver`,
# `row_hash_agg_spill` -> `agg_spill_driver`). Removing it breaks the
# columnar engine. FormatKind is a BATCH-level tag, never a plan-node one.
# =============================================================================


@fieldwise_init
struct FormatKind(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """Comptime tag identifying which native format an `F: BatchFormat` is.

    The BATCH-level tag (COLUMN/ROW/STREAMING_BLOB). `ROW` here is the
    SPILL ENCODING the COLUMN engine writes, NOT a row execution engine —
    see the banner at the top of this file.
    """

    var _value: UInt8

    comptime COLUMN = FormatKind(0)
    comptime ROW = FormatKind(1)
    comptime STREAMING_BLOB = FormatKind(2)

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def __ne__(self, other: Self) -> Bool:
        return self._value != other._value


trait BatchFormat(Movable, Deinitable):
    """Universal batch contract. Conformers: `ColumnNativeBatch`,
    `RowNativeBatch`, `StreamingBlobBatch`.

    The trait surface is the COMMON subset every consumer needs regardless of
    format. Format-specific cell access (`column_unified`, row `read_fixed`,
    `payload_view`) is NOT a trait method — it is a concrete method on the
    conformer, consumed inside the per-format driver.

    There are no `serialize_to_bytes` / `from_bytes` trait methods: the
    column spill format owns serialization, and a minimal trait keeps the
    conformer surface small.
    """

    @staticmethod
    def format_kind() -> FormatKind:
        """Comptime tag; inlines to a constant. Gates `comptime if` INSIDE the
        driver. NEVER a where-clause predicate (the compiler cannot prove it at
        the call site)."""
        ...

    def num_rows(self) -> Int:
        ...

    def schema_fingerprint(self) -> UInt64:
        ...

    @staticmethod
    def supports_zero_copy_export_to_arrow() -> Bool:
        """Comptime tag. True for ColumnNativeBatch; False for Row/Blob."""
        ...
