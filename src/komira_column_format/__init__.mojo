"""`komira_column_format` -- the column-format storage of the engine's untyped tables.

Per-column contiguous fixed-width slot buffers, variable-width descriptor cells
with per-column payload heaps, and per-column validity bitmaps
(`ColumnFormatStorage`), plus the loader that turns one column of a record batch
into a SIMD chunk with its validity mask (`load_simd_chunk`). The grouping, join
and sort kernels of the operator packages keep their keys and payloads in this
storage.

It depends on `komira_core` only.

Public API: import directly from sub-modules. No facade.
"""
