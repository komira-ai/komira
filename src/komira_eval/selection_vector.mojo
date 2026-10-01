# =============================================================================
# komira_eval.selection_vector — RE-EXPORT SHIM.
# =============================================================================
#
# `RowSelectionVector` + `load_via_sel` + their constants are core-layer
# (they depend ONLY on `komira_core.arrow.primitive_array.PrimitiveArray`) and
# are imported by `komira_core` itself, so they live at
# `komira_core.eval.selection_vector_row` (komira_core must not depend on
# komira_eval). This file is a thin RE-EXPORT SHIM so the external consumers
# (`from komira_eval.selection_vector import RowSelectionVector` /
# `load_via_sel` / `STANDARD_VECTOR_SIZE`) are BYTE-UNCHANGED. The re-export
# is the EXACT same symbol (NO re-wrapping) — type identity is preserved so
# monomorphization / codegen does not drift.
#
# Two surfaces are re-exported:
#
# 1. The legacy `SelectionVector` (re-exported from
#    `komira_core.eval.selection_vector`). PrimitiveArray[DType.int32]-
#    backed, allocation-per-call, supports from_bool_mask / compose / gather.
#    Used by ~10 sites today (`komira_compiler.conjunction`,
#    `komira_engine_operators.fused_pipeline`, the streaming dispatch
#    layer, etc.). UNCHANGED — never moved (it already lived in core).
#
# 2. `RowSelectionVector` + `load_via_sel` + `STANDARD_VECTOR_SIZE` +
# `HIGH_SELECTIVITY_THRESHOLD` — the row-mode shape, now in core
#    (relocated to core).
# =============================================================================

from komira_core.eval.selection_vector import SelectionVector
from komira_core.eval.selection_vector_row import (
    RowSelectionVector,
    load_via_sel,
    STANDARD_VECTOR_SIZE,
    HIGH_SELECTIVITY_THRESHOLD,
)
