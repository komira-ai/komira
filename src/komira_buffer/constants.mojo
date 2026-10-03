# =============================================================================
# Hardware Constants -- resolved at compile time for the target platform
# =============================================================================
#
# We compile for the exact hardware we run on.
# All SIMD widths are comptime -- the compiler generates specialized code
# for the target architecture (e.g., AVX-512, ARM NEON).
# =============================================================================

from std.sys import simd_width_of, num_physical_cores


# SIMD lane counts per data type -- compile-time constants.
comptime SIMD_WIDTH_F64 = simd_width_of[DType.float64]()
comptime SIMD_WIDTH_F32 = simd_width_of[DType.float32]()
comptime SIMD_WIDTH_I64 = simd_width_of[DType.int64]()
comptime SIMD_WIDTH_I32 = simd_width_of[DType.int32]()
comptime SIMD_WIDTH_I16 = simd_width_of[DType.int16]()
comptime SIMD_WIDTH_I8 = simd_width_of[DType.int8]()
comptime SIMD_WIDTH_U8 = simd_width_of[DType.uint8]()
comptime SIMD_WIDTH_U64 = simd_width_of[DType.uint64]()

# CPU topology.
comptime NUM_CORES = num_physical_cores()

# Memory hierarchy constants.
comptime CACHE_LINE_BYTES = 64  # ARM and x86-64

# Conservative morsel-size fallback. Production code MUST resolve morsel
# sizes via `ctx.<tier>_morsel_rows(schema)` on `EngineContext` (the
# tier-aware auto-derive routes through `MorselSizingPolicy` and the
# detected `HardwareProfile`). This constant is retained only for
# primitive constructors (e.g. `BatchMorselSource`, `ScanSource`,
# `MorselScheduler`) where ctx is not threaded; those callers receive an
# explicit value from any production code path. Test code that needs a
# deterministic fixture-size constant may still reference this.
comptime DEFAULT_MORSEL_ROWS = 65536  # 64K rows per morsel (fallback only)
