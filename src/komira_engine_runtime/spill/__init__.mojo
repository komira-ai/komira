"""`komira_engine_runtime.spill`: the spill layer. It holds `fnv1a`, the 64-bit
FNV-1a hash the spill formats checksum with; `thsplc` and `thsplc_header`, the
THSPLC column codec for a RecordBatch; and `column_native_shims`, the bridges
between RecordBatch and ColumnNativeBatch."""
