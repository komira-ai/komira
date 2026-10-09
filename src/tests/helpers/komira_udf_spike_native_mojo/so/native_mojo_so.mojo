# =============================================================================
# FFI-BOUNDARY: the one export of the native_mojo UDF library.
# =============================================================================
# komira_udf_native_init_v1 is the symbol the native runtime resolves in a
# native UDF library (docs/design/udf_runtime_interface.md section 1.2). It
# returns the table komira_udf_spike_native_mojo.native_init builds. The
# three pointers belong to the caller (the host struct, the rt out-slot, the
# error struct) and are passed through.
# =============================================================================

from komira_udf_spike_abi._cabi import Void
from komira_udf_spike_native_mojo import native_init


@export
def komira_udf_native_init_v1(host: Void, rt: Void, err: Void) abi("C") -> Void:
    return native_init(host, rt, err)
