# =============================================================================
# komira_core.parsers — Shared byte-span parsing primitives.
# =============================================================================
#
# Reusable parsing primitives that operate directly on `Span[UInt8, _]`
# without intermediate `String` materialization. They live in the core
# layer so both the CSV reader and the row-typed CSV / JSONL / Avro decoders
# can reuse the SIMD-vectorized fast paths without a format package
# becoming a dependency of the lower expression-evaluation layer.
#
# Members:
#   - byte_span_numeric:
#       fast_parse_uint_8digit / fast_parse_uint_n_digits — Lemire-style
#         SIMD UInt64 parse from 1..16-digit ASCII span. Branchless
#         applicability gate + SIMD load + tree-of-muladds. ~4-6 ns/cell
#         vs ~15-25 ns/cell scalar on typical numeric columns.
#       fast_parse_int64_simple — Int64 over `[-9999999999999999, +9999999999999999]`
#         with optional leading sign. None on overflow / non-digit /
#         oversized.
#       fast_parse_float64_simple — Float64 over integer-shaped cells
#         (no '.' / no 'e'). Routes through int64 + cast. None on any
#         non-integer shape — caller falls back to scalar.
#
# Layering:
#   komira_core.parsers — leaf within komira_core. No external deps
#   beyond stdlib + komira_core itself.
#   The CSV reader re-exports the numeric primitives here for its own
#     consumers; ISO date/time/timestamp SIMD primitives stay with the CSV
#     reader (CSV-format-specific shapes).
#   The row-typed decoders call fast_parse_int64_simple /
#     fast_parse_float64_simple for the byte-span fast path; scalar
#     fallback on Optional.None.
#
# Encapsulation: all public functions take `Span[UInt8, _]` and return
# `Optional[T]` — no UnsafePointer crosses a module boundary. The
# internal SIMD loads use stdlib `SIMD[T, W]` value types.
# =============================================================================
