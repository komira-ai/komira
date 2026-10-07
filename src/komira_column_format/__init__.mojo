"""`komira_column_format` -- the column-format storage of the engine's untyped tables.

Per-column contiguous fixed-width slot buffers, variable-width descriptor cells
with per-column payload heaps, and per-column validity bitmaps
(`ColumnFormatStorage`). The grouping, join and sort kernels of the operator
packages keep their keys and payloads in this storage.

It depends on `komira_arrow`, `komira_buffer`, `komira_collections` and
`komira_simd` only.

Public API: import directly from sub-modules. No facade.
"""
