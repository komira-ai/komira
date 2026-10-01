# =============================================================================
# komira_eval.row_format — slow-path row-format substrate
# =============================================================================
#
# What lives here:
#   * RowBlock  — packed-row primitive (fixed cells + var blob) with the
#                 full ~24 encoder/decoder method set.
#   * RowLayout — per-segment runtime descriptor (held by RBS under
#                 Optional[OwnedPointer[RowLayout]]).
#   * ColDescriptor — TrivialRegisterPassable per-column metadata.
#   * RowHashAggTable — slow-arm of `_HashAggVariant`; agg-major
#                       upsert_batch dispatch ladder.
#   * RowJoinBuildTable + RowJoinProbeState — slow-path JBT/JPS.
#   * RowSortBuffer — slow-path SortBuffer.
#   * RowDistinctState — slow-path DistinctState.
#   * route_breaker_shape — fast-vs-slow routing predicate for
#                            SDK lowering integration.
#   * _HashAggVariant + _JoinProbeVariant alias — slow-arm carriers.
#
# Encapsulation: this package follows the same `komira_eval` -> {core}
# dep edge (no new edge); zero UnsafePointer in
# public sigs / zero wildcard origin / zero unsafe_from_address.
# =============================================================================

from komira_eval.row_format.row_block import (
    RowBlock,
    RowLayout,
    ColDescriptor,
    RowHashAggTable,
    _HashAggVariant,
    _HashAggVariantPlaceholderArm,
    COL_FIXED,
    COL_VAR_STRING,
    COL_VAR_BINARY,
    COL_DECIMAL128,
    COL_LIST,
    COL_STRUCT,
    serialize_struct_record,
    struct_record_is_null,
    struct_record_field_null,
    struct_record_fixed_field,
    struct_record_string_field,
    DT_I64,
    DT_F64,
    DT_I32,
    DT_F32,
    DT_I16,
    DT_I8,
    DT_U8,
    DT_U16,
    DT_U32,
    DT_U64,
    DT_DATE32,
    DT_DECIMAL128,
    DT_STRING,
    DT_BOOL,
    DT_DATE64,
    DT_TIMESTAMP_NS,
    DT_TIMESTAMP_US,
    DT_TIMESTAMP_MS,
    DT_TIMESTAMP_S,
    DT_BINARY,
    DT_LIST,
    DT_STRUCT,
    AGG_SUM_I64,
    AGG_SUM_F64,
    AGG_COUNT,
    AGG_MIN_I64,
    AGG_MAX_I64,
    AGG_MIN_F64,
    AGG_MAX_F64,
    AGG_AVG_F64,
)

from komira_eval.row_format.row_output import (
    RowOutput,
    RowOutputLayout,
    bridge_row_output_to_record_batch,
)

from komira_eval.row_format.row_sink import (
    RowSink,
)


from komira_eval.row_format.row_sort import (
    RowSortBuffer,
    SORT_ASC,
    SORT_DESC,
)

from komira_eval.row_format.row_sort_perm import (
    RowPermComparator,
    stable_insertion_sort_perm,
)






# -----------------------------------------------------------------------------
# Row-TYPED comptime layout substrate (a sibling of the untyped
# RowLayout).
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Composite-key encoding primitive + small-batch narrow-agg
# kernel. The composite-key block (`CompositeKey[NBYTES]`) treats a
# composite-≥3 key as ONE contiguous byte block — single memcmp-style
# compare + single xxh3 hash. `CompositeKeyDef[*Keys]`
# is the single-variadic-pack shape descriptor (no arity-clone). The
# `narrow_agg_fold` kernel is the L1-resident <128-row scalar-tight fold.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Comptime-unrolled batch wrappers on RowLayoutTyped (an extension module;
# mirrors the `Predicate.eval[W]` Pattern B fan-out).
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Comptime-unrolled per-row encode/decode (row<->bytes serialize)
# wrappers on RowLayoutTyped. Distinct from the batch fold/read wrappers above:
# these serialize/deserialize a row's field set to/from a contiguous byte
# buffer (the spill-format entry points).
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Native Mojo struct `RowSlot[*Fields]` substrate for the row-IO
# base case (CSV / JSONL / Avro). Distinct from RowLayoutTyped, which
# wraps RowBlock byte storage (hash-agg state cells); RowSlot uses
# compiler-laid-out fields (the storage IS the descriptor) + a runtime
# `FileFieldBinding[N]` for out-of-order schema/file field mapping.

# -----------------------------------------------------------------------------





# -----------------------------------------------------------------------------
# Row-native filter (RowExprBoolEvaluator) + project (RowProjects[*Picks])
# comptime substrate. The engine-side `RowHashAggSegment` lives in
# `komira_engine_operators` and delegates combine to
# `RowHashAggTable.combine` (above).
# -----------------------------------------------------------------------------
from komira_eval.row_format.row_evaluator import (
    RowExprBoolEvaluator,
    selected_row_indices,
    ROW_PRED_GT,
    ROW_PRED_LE,
    ROW_PRED_EQ,
    ROW_PRED_LT,
    ROW_PRED_GE,
    ROW_PRED_NE,
)

