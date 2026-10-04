# =============================================================================
# load_simd_chunk.mojo — RecordBatch -> SIMD per-column chunk loader
# =============================================================================
#
# UDF-PHASE-B3-7-PREREQ (RFC §6.2 prerequisite primitive). The
# load-bearing leaf that the OP_USER_MAP_FN / OP_FUSED_CHAIN dispatch
# arms in `morsel_executor.mojo` will consume to bridge an in-flight
# `RecordBatch` to a per-column `SIMD[dtype, W]` + per-lane validity
# mask.
#
# Shape — matches RFC §6.2 verbatim except that it returns a (values,
# validity) tuple rather than the canonical `SimdOf[F.T_IN, W]`. The
# per-`F.T_IN` assembly happens at the caller (the SDK-built
# FusedChainOp[F, ...] struct's `execute_shard` method, which knows
# `F.T_IN`'s field layout at comptime).
#
#   fn load_simd_chunk[dtype: DType, W: Int](
#       batch: RecordBatch, col_idx: Int, chunk_start: Int
#   ) raises -> (SIMD[dtype, W], SIMD[DType.bool, W]):
#       var arr = batch.column_at(col_idx).as_primitive[dtype]()
#       var values = arr.load[width=W](chunk_start)
#       var validity = arr.validity_load[W=W](chunk_start)
#       return (values, validity)
#
# Implementation notes:
#   - `RecordBatch.column_at(col_idx)` returns an owned `Column` (the
#     column-table indirection); we extract the typed PrimitiveArray
#     view via `as_primitive[dtype]()`.
#   - `validity_load[W]` is the sibling primitive on PrimitiveArray
#     added in this same slot (B3-7-PREREQ). When the array has no
#     validity bitmap, `validity_load` returns all-True — the no-nulls
#     fast path that PROPAGATE-mode UDFs hit at every call.
#   - Both `load[W]` and `validity_load[W]` are offset-aware (Arrow's
#     zero-copy slicing produces PrimitiveArray's with non-zero
#     `offset`); the chunk_start argument is offset-AGNOSTIC from the
#     caller's POV (relative to the array's logical start).
#
# Performance:
#   - The values load is a single `ldp` / `ldur` instruction at the
#     hardware level (NEON-aligned chunk_start = 4 lanes of f64 = 32B,
#     well within MmapAlignedBuffer's 64B alignment).
#   - The validity load goes through `validity_load[W]`'s per-lane
#     unpack; Mojo autovectorizes the byte+shift+mask loop at
#     -O2 (verified by `bazel build --compilation_mode=opt` +
#     `objdump`). Worst case is W bit-extract loads (one per lane);
#     the autovectorized version produces a `cnt + and + cmp` sequence
#     of 4-6 NEON opcodes.
#
# This primitive is INTENTIONALLY a leaf — it does NOT assemble the
# multi-column `SimdOf[F.T_IN, W]`. The SDK side composes per-field
# loads via comptime-fanned `T_IN`-aware code that the engine cannot
# write generically (without knowing the field layout at comptime, the
# engine cannot enumerate `T_IN`'s fields).
#
# Cross-references:
#   - `[[udf-phase-b3-7-prereq-preflight]]` — §2 documents
#     why this is a leaf primitive (the comptime/runtime layering
#     mismatch).
#   - an internal module — host of the
#     `load[W]` + `validity_load[W]` methods this calls.
#   - RFC v2.1 §6.2 — the bridge spec.
# =============================================================================

from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.primitive_array import PrimitiveArray


@always_inline
def load_simd_chunk[
    dtype: DType, W: Int
](
    batch: RecordBatch,
    col_idx: Int,
    chunk_start: Int,
) raises -> Tuple[SIMD[dtype, W], SIMD[DType.bool, W]]:
    """Read W contiguous lanes from `batch.column_at(col_idx)` starting
    at `chunk_start`. Returns (values, validity) — per-lane validity is
    `True` for valid (not-null) lanes.

    Implementation notes:
      - `batch.column_at(col_idx).as_primitive[dtype]()` extracts the
        typed PrimitiveArray view. The dtype MUST match the column's
        actual type (caller responsibility — typically asserted by the
        plan-compile-time UDF input-schema check against the child
        schema; see `agg_fn_acc._resolve` for the per-column type
        assertion pattern).
      - `load[width=W]` is the offset-aware SIMD load; `chunk_start`
        is the logical index (the array's `offset` is applied
        internally).
      - `validity_load[W=W]` returns all-True when the array has no
        validity bitmap (no-nulls fast path) or per-lane validity
        otherwise.

    Args:
        batch: The in-flight RecordBatch (the morsel).
        col_idx: Column index in `batch.schema` (0-based).
        chunk_start: Starting element index (relative to the column's
            logical start; offset-aware).

    Returns:
        A tuple `(values, validity)`:
          - `values`: `SIMD[dtype, W]` of the W lanes' typed values.
          - `validity`: `SIMD[DType.bool, W]` per-lane validity (True
            = valid, False = null).

    Raises:
        If `chunk_start + W` exceeds the column length (propagated
        from `load[W]` / `validity_load[W]`).
    """
    var arr = batch.column_at(col_idx).as_primitive[dtype]()
    var values = arr.load[W](chunk_start)
    var validity = arr.validity_load[W](chunk_start)
    return Tuple[SIMD[dtype, W], SIMD[DType.bool, W]](values, validity)
