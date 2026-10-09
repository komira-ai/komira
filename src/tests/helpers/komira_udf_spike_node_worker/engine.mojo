# =============================================================================
# FFI-BOUNDARY: the engine loop over N engine threads (native/engine_loop.c),
# behind a value API.
# =============================================================================
# run() loads a UDF runtime library, loads one UDF and drives it on N engine
# threads (pthreads started in C, on which no Mojo code runs), and returns
# the C side's report, one JSON object, as a String; the tests and the bench
# read it with komira_json.
#
# Who owns and frees each pointer:
#   - the C strings passed in (the library path, the entry, the format):
#     zeroed blocks of this file, freed right after the call that reads
#     them; the C side copies nothing it keeps past the call.
#   - the report: malloc'd by kudfw_engine_run, copied here by read_cstr,
#     then freed by kudfw_engine_free, once.
# =============================================================================

from std.ffi import external_call

from komira_udf_spike_abi._cabi import Void, free_zeroed, read_cstr, zeroed

comptime CHECK_ROWS = 0
"""Outputs are checked for their row count only."""
comptime CHECK_AFFINE = 1
"""Every output value must equal a * x + b for its input x."""
comptime CHECK_SAME = 2
"""Every output value must equal its input."""

comptime _REPORT_LIMIT = 1 << 26


def _cstr(s: String) -> Void:
    """A NUL-terminated copy of `s` in a zeroed block; free with free_zeroed.

    # SAFETY: the block is len + 1 zeroed bytes; the copy writes len.
    """
    var b = s.as_bytes()
    var p = zeroed(len(b) + 1)
    var d = p.bitcast[UInt8]()
    for k in range(len(b)):
        d[k] = b[k]
    return p


@fieldwise_init
struct Workload(Copyable, Movable):
    """One UDF and how to drive it: `threads` engine threads, each with its
    own context and instance, warming up for at most `warm_max` batches,
    then at least `samples` timed batches of `rows` rows, for at least
    `min_ms` milliseconds. The one argument has format
    `fmt` ("g" float64: 0.5 * row - 40; "l" int64: the constant `a`); the
    result has the same format, checked by `check` against a * x + b."""

    var entry: String
    var shape: UInt32
    var fmt: String
    var threads: Int
    var rows: Int
    var warm_max: Int
    var samples: Int
    var min_ms: Int
    var check: Int
    var a: Float64
    var b: Float64


def run(library: String, w: Workload) -> String:
    """The engine loop's JSON report of `w` on the runtime at `library`."""
    var lib = _cstr(library)
    var entry = _cstr(w.entry)
    var fmt = _cstr(w.fmt)
    var p = external_call["kudfw_engine_run", Void](
        lib, entry, w.shape, fmt, Int64(w.threads), Int64(w.rows), Int64(w.warm_max), Int64(w.samples),
        Int64(w.min_ms), Int64(w.check), w.a, w.b,
    )
    free_zeroed(lib)
    free_zeroed(entry)
    free_zeroed(fmt)
    var out = read_cstr(p, _REPORT_LIMIT)
    external_call["kudfw_engine_free", NoneType](p)
    return out^
