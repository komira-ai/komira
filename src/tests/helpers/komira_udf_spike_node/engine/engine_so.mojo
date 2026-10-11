# =============================================================================
# FFI-BOUNDARY: the one export of conform_engine.so, the Mojo conformance
# harness as a library a Node script's addon runs (engine_host.c).
# =============================================================================
# komira_udf_spike_node_conform(runtime_path, cases_dir, report_buf, cap) runs the
# conformance suite of komira_udf_spike_abi (the cases the Node runtime runs,
# node_cases.mojo) against the runtime library at runtime_path and writes the
# report as NUL-terminated text into `report_buf`; it returns 0, or 1 with the error
# as the text. The four arguments belong to the caller (engine_host.c): two
# NUL-terminated strings, read and copied here, and a buffer of `cap` bytes
# that this function writes at most `cap` bytes of, the NUL included. No
# pointer is kept past the call.
#
# The runtime library is dlopened by the harness and is, in the process, the
# library node already loaded as an addon: it posts every call to the
# JavaScript thread of its environment, so this function must run on a thread
# of the engine's, never on that JavaScript thread.
# =============================================================================

from komira_udf_spike_abi._cabi import Void, read_cstr
from komira_udf_spike_abi.conform import run_suite
from komira_udf_spike_node.node_cases import node_cases


@export
def komira_udf_spike_node_conform(runtime_path: Void, cases_dir: Void, report_buf: Void, cap: Int64) abi("C") -> Int32:
    var text = String("")
    var rc = Int32(0)
    try:
        var cases = node_cases(read_cstr(cases_dir))
        var report = run_suite(read_cstr(runtime_path), cases)
        text = String(report)
    except e:
        text = String("UDF_CONFORM_ERROR: ") + String(e)
        rc = 1
    var b = text.as_bytes()
    var n = len(b)
    var room = Int(cap) - 1
    if room < 0:
        # No room for even the NUL: nothing is written.
        return rc
    if n > room:
        n = room
    # SAFETY: `report_buf` is a buffer of `cap` bytes the caller owns for this call;
    # n + 1 <= cap bytes are written.
    var d = report_buf.bitcast[UInt8]()
    for k in range(n):
        d[k] = b[k]
    d[n] = 0
    return rc
