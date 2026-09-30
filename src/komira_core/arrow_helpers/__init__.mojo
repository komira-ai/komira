# =============================================================================
# komira_core.arrow_helpers — pure Arrow data-manipulation utilities
# =============================================================================
#
# These live in core so `komira_parquet` can import them without taking a
# dependency on the engine (which would close an engine↔parquet cycle).
#
# Modules:
#   * batch_slice          — _slice_batch_first_n / _slice_batch_range /
#                            _split_into_morsel_slots (LIMIT, TopN,
#                            morsel-split helpers)
#   * streaming_concat     — _concat_rg_batches_into_one /
#                            _concat_variable_width_batches /
#                            _concat_two_batches (multi-way / pairwise
#                            RecordBatch concat)
#
# These modules touch only `komira_core.arrow.*` and
# `komira_core.helpers.*`. They have no engine-internal dependencies.
# =============================================================================

from .batch_slice import (
    _slice_batch_first_n,
    _slice_batch_range,
    _split_into_morsel_slots,
)
from .streaming_concat import (
    _concat_rg_batches_into_one,
    _concat_variable_width_batches,
    _concat_variable_width_batches_pairwise,
    _concat_two_batches,
    _concat_string_columns_multi,
    _concat_fixed_columns_multi,
    _concat_fixed_column_into_range,
    _build_fixed_validity,
    _sum_fixed_null_count,
    _arrow_type_byte_width,
)
