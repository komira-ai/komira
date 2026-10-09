# =============================================================================
# FFI-BOUNDARY: the engine's call loop over N engine threads
# (native/engine_loop.c), behind a value API.
# =============================================================================
# Engine opens a UDF runtime library and keeps it until it is dropped; run()
# loads one UDF and drives it on N engine threads (pthreads started in C, on
# which no Mojo code runs), returning a RunReport of values.
#
# Who owns and frees each pointer:
#   - the engine handle (struct engine): native/engine_loop.c's, created by
#     kudf_engine_open and freed by kudf_engine_close in Engine.__del__,
#     which shuts the runtime down first. Held here as a Word that only this
#     file reads through.
#   - a run handle (struct run): created by kudf_run or kudf_misuse and
#     freed by kudf_run_free before run() or misuse() returns, once every
#     field is copied out.
#   - C strings this file passes (the library path, the entry): zeroed
#     blocks freed right after the call that reads them; the C side copies
#     what it keeps.
#   - strings the C side returns (messages, the runtime id): its own,
#     copied here by read_cstr before the handle is freed.
# =============================================================================

from std.ffi import external_call

from komira_udf_spike_abi._cabi import Void, Word, free_zeroed, read_cstr, zeroed

# kudf_run_get, run level (thread -1); the order of the C enum.
comptime _R_STATUS: Int32 = 0
comptime _R_LOAD_NS: Int32 = 1
comptime _R_WALL_NS: Int32 = 2
comptime _R_CPU_USER_NS: Int32 = 3
comptime _R_CPU_SYS_NS: Int32 = 4
comptime _R_RSS_BEFORE: Int32 = 5
comptime _R_RSS_OPEN: Int32 = 6
comptime _R_CPUS: Int32 = 7
comptime _R_COLD_NS: Int32 = 8
comptime _R_THREADS: Int32 = 9
comptime _R_INVOLUNTARY: Int32 = 10
# per thread
comptime _T_STATUS: Int32 = 0
comptime _T_OPEN_CONTEXT_NS: Int32 = 1
comptime _T_OPEN_INSTANCE_NS: Int32 = 2
comptime _T_FIRST_CALL_NS: Int32 = 3
comptime _T_CALLS: Int32 = 4
comptime _T_ROWS: Int32 = 5
comptime _T_BAD_VALUES: Int32 = 6
comptime _T_FIRST_VALUE: Int32 = 7
comptime _T_LAST_VALUE: Int32 = 8
comptime _T_INCREASING: Int32 = 9
comptime _T_EXPORTED: Int32 = 10
comptime _T_RELEASED: Int32 = 11
comptime _T_SAMPLES: Int32 = 12

# kudf_misuse_get; the order of the C enum.
comptime _M_OPEN: Int32 = 0
comptime _M_FOREIGN_OPEN_INSTANCE: Int32 = 1
comptime _M_FOREIGN_CALL: Int32 = 2
comptime _M_FOREIGN_CALL_MOVED: Int32 = 3
comptime _M_FOREIGN_CLOSE_LOGS: Int32 = 4
comptime _M_OFFSET_CALL: Int32 = 5
comptime _M_OFFSET_CALL_MOVED: Int32 = 6
comptime _M_AFTER_CALL: Int32 = 7
comptime _M_AFTER_BAD_VALUES: Int32 = 8
comptime _M_EXPORTED: Int32 = 9
comptime _M_RELEASED: Int32 = 10

comptime CHECK_NONE: Int32 = 0
"""Outputs are checked for their row count and layout only."""
comptime CHECK_AFFINE: Int32 = 1
"""Every output value must equal a * x + b for its input x."""
comptime CHECK_COUNTER: Int32 = 2
"""Outputs are int64 counters: the first and last value, and whether each
value exceeded the one before it, are recorded per thread."""

comptime CAP_THREADING: Int32 = 0
comptime CAP_GLOBAL_LOCK: Int32 = 1
comptime CAP_THREAD_AFFINE: Int32 = 2
comptime CAP_UDF_CLASS: Int32 = 3
comptime CAP_HOSTING: Int32 = 4
comptime CAP_SHAPES: Int32 = 5


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
    own context and instance, running `warmup` batches (the first is timed
    apart) and then `batches` measured batches of `rows` rows. The one
    argument is `arg_fmt` ("l" int64, "g" float64) with values base + step *
    row; the result is `result_fmt`; outputs are checked by `check`."""

    var entry: String
    var shape: UInt32
    var arg_fmt: String
    var result_fmt: String
    var threads: Int
    var warmup: Int
    var batches: Int
    var rows: Int
    var check: Int32
    var a: Float64
    var b: Float64
    var base: Float64
    var step: Float64


@fieldwise_init
struct ThreadReport(Copyable, Movable):
    var status: Int32
    var message: String
    var open_context_ns: Int64
    var open_instance_ns: Int64
    var first_call_ns: Int64
    var calls: Int64
    var rows: Int64
    var bad_values: Int64
    var first_value: Int64
    var last_value: Int64
    var increasing: Bool
    var exported: Int64
    var released: Int64
    var samples: List[Int64]
    """ns of each measured call_batch, in order."""


@fieldwise_init
struct RunReport(Copyable, Movable):
    var status: Int32
    var message: String
    var load_ns: Int64
    var wall_ns: Int64
    """The measured phase, from the barrier every thread passes once warm to
    the one each passes after its last measured batch."""
    var cpu_user_ns: Int64
    var cpu_sys_ns: Int64
    var rss_before: Int64
    var rss_open: Int64
    """Process RSS once every context, instance and first batch exist."""
    var cpus: Int64
    var cold_ns: Int64
    """Engine open (before dlopen) to the end of thread 0's first batch, for
    the engine's first run; -1 on later runs."""
    var threads: List[ThreadReport]
    var involuntary_switches: Int64

    def measured_rows(self) -> Int64:
        var n: Int64 = 0
        for t in self.threads:
            n += Int64(len(t.samples)) * (t.rows // t.calls if t.calls > 0 else 0)
        return n

    def rows_per_s(self) -> Float64:
        if self.wall_ns <= 0:
            return 0.0
        return Float64(self.measured_rows()) * 1e9 / Float64(self.wall_ns)

    def all_samples(self) -> List[Int64]:
        var out = List[Int64]()
        for t in self.threads:
            for s in t.samples:
                out.append(s)
        return out^


@fieldwise_init
struct MisuseReport(Copyable, Movable):
    """What a thread_affine runtime did with calls the contract forbids its
    host (Engine.misuse). Statuses are the table's; -1 is a step not
    reached."""

    var load_status: Int32
    var load_message: String
    var open_status: Int32
    """open_context then open_instance, on the owner thread."""
    var open_message: String
    var foreign_open_instance: Int32
    """open_instance on the owner's context, from another thread."""
    var foreign_open_instance_message: String
    var foreign_call: Int32
    """call_batch on the owner's instance, from another thread."""
    var foreign_call_message: String
    var foreign_call_moved: Bool
    var foreign_close_logs: Int64
    """Log lines the runtime wrote during close_instance and close_context
    from another thread."""
    var offset_call: Int32
    """call_batch on the owner thread with the argument struct at offset 1."""
    var offset_call_message: String
    var offset_call_moved: Bool
    var after_call: Int32
    """A valid call_batch on the owner thread after all of the above."""
    var after_call_message: String
    var after_bad_values: Int64
    var exported: Int64
    var released: Int64


def quantile(var xs: List[Int64], q: Float64) -> Int64:
    """The q-quantile (nearest rank) of xs; 0 for an empty list."""
    if len(xs) == 0:
        return 0
    sort(xs)
    var k = Int(q * Float64(len(xs) - 1) + 0.5)
    return xs[k]


struct Engine(Movable):
    """One runtime library, opened and initialized; shut down when dropped."""

    var _e: Word

    def __init__(out self, path: String):
        var p = _cstr(path)
        self._e = Word(external_call["kudf_engine_open", Void](p))
        free_zeroed(p)

    def status(self) -> Int32:
        return external_call["kudf_engine_status", Int32](self._e.p)

    def message(self) -> String:
        return read_cstr(external_call["kudf_engine_message", Void](self._e.p))

    def open_ns(self) -> Int64:
        return external_call["kudf_engine_open_ns", Int64](self._e.p)

    def runtime_id(self) -> String:
        return read_cstr(external_call["kudf_engine_runtime_id", Void](self._e.p))

    def cap(self, which: Int32) -> Int64:
        return external_call["kudf_engine_cap", Int64](self._e.p, which)

    def run(mut self, w: Workload) -> RunReport:
        var entry = _cstr(w.entry)
        var r = Word(
            external_call["kudf_run", Void](
                self._e.p, entry, Int32(w.shape), Int8(Int(w.arg_fmt.as_bytes()[0])),
                Int8(Int(w.result_fmt.as_bytes()[0])), Int32(w.threads), Int32(w.warmup), Int32(w.batches),
                Int64(w.rows), w.check, w.a, w.b, w.base, w.step,
            )
        )
        free_zeroed(entry)
        var threads = List[ThreadReport]()
        var n = Int(_get(r, -1, _R_THREADS))
        for t in range(n):
            var ti = Int32(t)
            var samples = List[Int64]()
            var ns = Int(_get(r, ti, _T_SAMPLES))
            for i in range(ns):
                samples.append(external_call["kudf_run_sample", Int64](r.p, ti, Int64(i)))
            threads.append(
                ThreadReport(
                    Int32(_get(r, ti, _T_STATUS)), read_cstr(external_call["kudf_run_message", Void](r.p, ti)),
                    _get(r, ti, _T_OPEN_CONTEXT_NS), _get(r, ti, _T_OPEN_INSTANCE_NS), _get(r, ti, _T_FIRST_CALL_NS),
                    _get(r, ti, _T_CALLS), _get(r, ti, _T_ROWS), _get(r, ti, _T_BAD_VALUES),
                    _get(r, ti, _T_FIRST_VALUE), _get(r, ti, _T_LAST_VALUE), _get(r, ti, _T_INCREASING) != 0,
                    _get(r, ti, _T_EXPORTED), _get(r, ti, _T_RELEASED), samples^,
                )
            )
        var out = RunReport(
            Int32(_get(r, -1, _R_STATUS)), read_cstr(external_call["kudf_run_message", Void](r.p, Int32(-1))),
            _get(r, -1, _R_LOAD_NS), _get(r, -1, _R_WALL_NS), _get(r, -1, _R_CPU_USER_NS),
            _get(r, -1, _R_CPU_SYS_NS), _get(r, -1, _R_RSS_BEFORE), _get(r, -1, _R_RSS_OPEN), _get(r, -1, _R_CPUS),
            _get(r, -1, _R_COLD_NS), threads^, _get(r, -1, _R_INVOLUNTARY),
        )
        external_call["kudf_run_free", NoneType](r.p)
        return out^

    def misuse(mut self, w: Workload) -> MisuseReport:
        """Opens a context and an instance of `w`'s UDF on this thread, then
        makes the calls the contract forbids (open_instance, call_batch,
        close_instance and close_context from another thread; an argument
        struct at a nonzero offset), one valid call of `w.rows` rows checked
        as `w` says, and closes here. For a thread_affine runtime."""
        var entry = _cstr(w.entry)
        var r = Word(
            external_call["kudf_misuse", Void](
                self._e.p, entry, Int32(w.shape), Int8(Int(w.arg_fmt.as_bytes()[0])),
                Int8(Int(w.result_fmt.as_bytes()[0])), Int64(w.rows), w.a, w.b, w.base, w.step,
            )
        )
        free_zeroed(entry)
        var out = MisuseReport(
            Int32(_get(r, -1, _R_STATUS)), read_cstr(external_call["kudf_run_message", Void](r.p, Int32(-1))),
            Int32(_m(r, _M_OPEN)), _m_message(r, _M_OPEN),
            Int32(_m(r, _M_FOREIGN_OPEN_INSTANCE)), _m_message(r, _M_FOREIGN_OPEN_INSTANCE),
            Int32(_m(r, _M_FOREIGN_CALL)), _m_message(r, _M_FOREIGN_CALL), _m(r, _M_FOREIGN_CALL_MOVED) == 1,
            _m(r, _M_FOREIGN_CLOSE_LOGS),
            Int32(_m(r, _M_OFFSET_CALL)), _m_message(r, _M_OFFSET_CALL), _m(r, _M_OFFSET_CALL_MOVED) == 1,
            Int32(_m(r, _M_AFTER_CALL)), _m_message(r, _M_AFTER_CALL), _m(r, _M_AFTER_BAD_VALUES),
            _m(r, _M_EXPORTED), _m(r, _M_RELEASED),
        )
        external_call["kudf_run_free", NoneType](r.p)
        return out^

    def __del__(deinit self):
        external_call["kudf_engine_close", NoneType](self._e.p)


def _get(r: Word, thread: Int32, field: Int32) -> Int64:
    return external_call["kudf_run_get", Int64](r.p, thread, field)


def _m(r: Word, field: Int32) -> Int64:
    return external_call["kudf_misuse_get", Int64](r.p, field)


def _m_message(r: Word, field: Int32) -> String:
    return read_cstr(external_call["kudf_misuse_message", Void](r.p, field))
