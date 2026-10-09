# =============================================================================
# FFI-BOUNDARY: the engine loop of native/drive.c, behind a value API.
# =============================================================================
# Driver opens a UDF runtime library and keeps it until close(); run() takes
# one workload as `key=value` lines and returns the loop's JSON report, which
# Report parses.
#
# Who owns and frees each pointer:
#   - the engine handle (struct engine): native/drive.c's, created by
#     kpw_open, freed by kpw_close in Driver.close (or __del__), which shuts
#     the runtime down first. Held as a Word only this file reads through.
#   - a report string: created by kpw_run, copied here by read_cstr and
#     freed by kpw_free before run() returns.
#   - C strings passed in (the library path, the configuration): zeroed
#     blocks freed right after the call; the C side copies what it keeps.
# =============================================================================

from std.ffi import external_call

from komira_json import JsonValue, parse_json_value
from komira_udf_spike_abi._cabi import Void, Word, free_zeroed, read_cstr, zeroed

comptime CHECK_NONE = 0
comptime CHECK_AFFINE = 1
"""Every output value must equal a * x + b for its input x."""
comptime CHECK_COUNTER = 2
"""Outputs are int64: the first and last value per thread, and whether each
value exceeded the one before it."""

comptime _REPORT_LIMIT = 1 << 24


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


def pid_alive(pid: Int) -> Bool:
    """Whether a process with this pid exists (kill(pid, 0))."""
    return external_call["kpw_pid_alive", Int32](Int32(pid)) != 0


def self_pid() -> Int:
    return Int(external_call["kpw_self_pid", Int32]())


struct Driver(Movable):
    """One runtime library, opened and initialized, shut down by close()."""

    var _e: Word
    var _open: Bool

    def __init__(out self, path: String):
        var p = _cstr(path)
        self._e = Word(external_call["kpw_open", Void](p))
        free_zeroed(p)
        self._open = True

    def status(self) -> Int32:
        return external_call["kpw_status", Int32](self._e.p)

    def message(self) -> String:
        return read_cstr(external_call["kpw_message", Void](self._e.p))

    def run(mut self, config: String) raises -> JsonValue:
        """One workload (native/drive.c, parse_config), its JSON report."""
        var c = _cstr(config)
        var r = external_call["kpw_run", Void](self._e.p, c)
        free_zeroed(c)
        var text = read_cstr(r, _REPORT_LIMIT)
        external_call["kpw_free", NoneType](r)
        return parse_json_value(text)

    def close(mut self):
        """Shuts the runtime down: every worker it started is gone after."""
        if self._open:
            external_call["kpw_close", NoneType](self._e.p)
            self._open = False

    def __del__(deinit self):
        if self._open:
            external_call["kpw_close", NoneType](self._e.p)
