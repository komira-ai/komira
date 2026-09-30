"""`komira_core` — the Arrow-native core types the Komira engine is built on.

The foundational layer under every other engine package: the columnar
primitives (Column, Buffer, RecordBatch, and the Arrow-native value types),
the SIMD helpers the operators vectorize over, and the shared plan IR
(LogicalPlan, Expr, ScalarValue, AggExpr) the SDK builds and the compiler
lowers to a physical plan. Everything here is dependency-light and sits below
the engine, compiler, formats, and SDK tiers.
"""

from .simd_helpers import (
    _simd_sum,
    _simd_min,
    _simd_max,
    _simd_count_if,
    _simd_fill,
    _simd_iota,
    simd_add_arrays,
    simd_min_arrays,
    simd_max_arrays,
)
