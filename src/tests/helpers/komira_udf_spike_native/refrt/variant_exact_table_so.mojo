# =============================================================================
# FFI-BOUNDARY: the one export of the variant_exact_table shared library.
# =============================================================================
# The C native UDF library with one change (native/variant_lib.c names it),
# through komira_udf_variant_exact_table_init_v1.
# The three pointers belong to the caller (the host struct, the rt
# out-slot, the error struct) and are passed through untouched; the table
# returned is the library's static data.
# =============================================================================

from std.ffi import external_call

# SAFETY: the three pointers are passed through to the C init, never read here.
comptime Void = UnsafePointer[NoneType, MutUntrackedOrigin]


@export
def komira_udf_native_init_v1(host: Void, rt: Void, err: Void) abi("C") -> Void:
    return external_call["komira_udf_variant_exact_table_init_v1", Void](host, rt, err)
