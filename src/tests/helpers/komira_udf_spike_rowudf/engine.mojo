# =============================================================================
# FFI-BOUNDARY: the row-UDF engine loop over N engine threads
# (native/row_engine.c) and its single probing calls (native/row_probe.c),
# behind a value API.
# =============================================================================
# RowEngine opens a UDF runtime library and keeps it until it is dropped;
# run() loads one ROW UDF with a read set and drives it on N engine threads
# (pthreads started in C, on which no Mojo code runs), returning a RowReport
# of values. probe() makes one call on the calling thread with an argument
# struct broken in one place, or under a scripted host clock (Probe);
# misuse() calls one entry the way the ABI or the runtime refuses.
#
# Who owns and frees each pointer:
#   - the engine handle (struct engine): native/row_engine.c's, created by
#     rowe_open and freed by rowe_close in RowEngine.__del__, which shuts the
#     runtime down first. Held here as a Word that only this file reads
#     through.
#   - a run handle (struct run): created by rowe_run and freed by
#     rowe_run_free before run() returns, once every field is copied out.
#   - a probe or misuse handle (struct probe, struct misuse): created by
#     rowe_probe or rowe_misuse and freed by rowe_probe_free or
#     rowe_misuse_free before probe() or misuse() returns, once every field
#     is copied out.
#   - C strings this file passes: zeroed blocks freed right after the call
#     that reads them; the C side copies what it keeps.
#   - strings the C side returns: its own, copied here by read_cstr before
#     the handle is freed.
# =============================================================================

from std.ffi import external_call

from komira_udf_spike_abi._cabi import Void, Word, free_zeroed, read_cstr, zeroed

# rowe_get, run level (thread -1); the order of the C enum.
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
comptime _R_NR_THROTTLED: Int32 = 11
comptime _R_THROTTLED_USEC: Int32 = 12
comptime _R_LOADAVG_MILLI: Int32 = 13
comptime _R_WIDTH: Int32 = 14
comptime _R_READ_FIELDS: Int32 = 15
# per thread
comptime _T_STATUS: Int32 = 0
comptime _T_OPEN_CONTEXT_NS: Int32 = 1
comptime _T_OPEN_INSTANCE_NS: Int32 = 2
comptime _T_FIRST_CALL_NS: Int32 = 3
comptime _T_CALLS: Int32 = 4
comptime _T_ROWS: Int32 = 5
comptime _T_BAD_VALUES: Int32 = 6
comptime _T_EXPORTED: Int32 = 7
comptime _T_RELEASED: Int32 = 8
comptime _T_BYTES: Int32 = 9
comptime _T_WARMUP_CALLS: Int32 = 10
comptime _T_WARM_STABLE: Int32 = 11
comptime _T_SAMPLES: Int32 = 12


# Probe kinds: the order of native/row_engine.c's PK_* enum.
comptime PROBE_GOOD: Int32 = 0
comptime PROBE_SHORT_CHILD: Int32 = 1
comptime PROBE_NEG_LENGTH: Int32 = 2
comptime PROBE_STRUCT_OFFSET: Int32 = 3
comptime PROBE_NULL_CHILD: Int32 = 4
comptime PROBE_CHILD_BUFFERS: Int32 = 5
comptime PROBE_NEG_CHILD_OFFSET: Int32 = 6
comptime PROBE_NO_VALUES: Int32 = 7
comptime PROBE_NOT_CPU: Int32 = 8
comptime PROBE_CALL_SIZE: Int32 = 9
comptime PROBE_OTHER_THREAD: Int32 = 10
comptime PROBE_FOREIGN_CLOSE: Int32 = 11
comptime PROBE_NULL_CANCEL: Int32 = 12

# Misuse kinds: the order of native/row_probe.c's MU_* enum.
comptime MISUSE_CAPS_SMALL: Int32 = 0
comptime MISUSE_SPEC_SMALL: Int32 = 1
comptime MISUSE_ERR_SMALL: Int32 = 2
comptime MISUSE_ERR_NULL: Int32 = 3
comptime MISUSE_HOST_NULL: Int32 = 4
comptime MISUSE_HOST_SMALL: Int32 = 5
comptime MISUSE_HOST_MAJOR: Int32 = 6
comptime MISUSE_INIT_AGAIN: Int32 = 7
comptime MISUSE_ARGS_NULL: Int32 = 8
comptime MISUSE_ARGS_NO_FORMAT: Int32 = 9
comptime MISUSE_ARGS_LIST: Int32 = 10
comptime MISUSE_ARGS_NEGATIVE: Int32 = 11
comptime MISUSE_FIELD_NULL: Int32 = 12
comptime MISUSE_FIELD_NO_FORMAT: Int32 = 13
comptime MISUSE_FIELD_EMPTY: Int32 = 14
comptime MISUSE_FIELD_TWO_CHARS: Int32 = 15
comptime MISUSE_FIELD_CHILD: Int32 = 16
comptime MISUSE_FIELD_NO_NAME: Int32 = 17
comptime MISUSE_RESULT_NULL: Int32 = 18
comptime MISUSE_CODE: Int32 = 19
comptime MISUSE_FRAME_OPEN: Int32 = 20
comptime MISUSE_FRAME_NEXT: Int32 = 21
comptime MISUSE_AGG_OPEN: Int32 = 22
comptime MISUSE_AGG_UPDATE: Int32 = 23
comptime MISUSE_AGG_MERGE: Int32 = 24
comptime MISUSE_AGG_STATE: Int32 = 25
comptime MISUSE_AGG_FINISH: Int32 = 26
comptime MISUSE_LEAK: Int32 = 27
comptime MISUSE_SIGNALS: Int32 = 28
comptime MISUSE_FRAME_OPEN_RELEASED: Int32 = 29
comptime MISUSE_AGG_UPDATE_RELEASED: Int32 = 30


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


def _join(names: List[String]) -> String:
    var out = String("")
    for i in range(len(names)):
        if i > 0:
            out += ","
        out += names[i]
    return out


@fieldwise_init
struct RowWorkload(Copyable, Movable):
    """A ROW UDF over an input of float64 columns named `input`, of which the
    call passes `read_set` (the spec's argument struct). `threads` engine
    threads, each with its own context and instance, warm up in windows of
    `warm_window` calls until three window medians agree within 2% (at most
    `warm_cap` windows), then run `batches` measured batches of `rows` rows.
    Outputs must equal column `check_p` times column `check_q` (input names;
    "" leaves them unchecked)."""

    var entry: String
    var input: List[String]
    var read_set: List[String]
    var check_p: String
    var check_q: String
    var threads: Int
    var rows: Int
    var batches: Int
    var warm_window: Int
    var warm_cap: Int


@fieldwise_init
struct RowThread(Copyable, Movable):
    var status: Int32
    var message: String
    var open_context_ns: Int64
    var open_instance_ns: Int64
    var first_call_ns: Int64
    var calls: Int64
    var rows: Int64
    var bad_values: Int64
    var exported: Int64
    var released: Int64
    var bytes: Int64
    """Argument bytes exported to the runtime, over every call."""
    var warmup_calls: Int64
    var warm_stable: Bool
    var samples: List[Int64]
    """ns of each measured call_batch, in order."""


@fieldwise_init
struct RowReport(Copyable, Movable):
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
    var cpus: Int64
    var cold_ns: Int64
    var involuntary_switches: Int64
    var nr_throttled: Int64
    """cgroup cpu.stat nr_throttled over the measured phase; -1 unreadable."""
    var throttled_usec: Int64
    var loadavg_milli: Int64
    var width: Int64
    var read_fields: Int64
    var threads: List[RowThread]

    def measured_rows(self) -> Int64:
        var n: Int64 = 0
        for t in self.threads:
            n += Int64(len(t.samples)) * (t.rows // t.calls if t.calls > 0 else 0)
        return n

    def rows_per_s(self) -> Float64:
        if self.wall_ns <= 0:
            return 0.0
        return Float64(self.measured_rows()) * 1e9 / Float64(self.wall_ns)

    def bytes_per_row(self) -> Float64:
        """Argument bytes exported per row, over every call of every thread."""
        var b: Int64 = 0
        var r: Int64 = 0
        for t in self.threads:
            b += t.bytes
            r += t.rows
        return Float64(b) / Float64(r) if r > 0 else 0.0

    def all_samples(self) -> List[Int64]:
        var out = List[Int64]()
        for t in self.threads:
            for s in t.samples:
                out.append(s)
        return out^


def quantile(var xs: List[Int64], q: Float64) -> Int64:
    """The q-quantile (nearest rank) of xs; 0 for an empty list."""
    if len(xs) == 0:
        return 0
    sort(xs)
    var k = Int(q * Float64(len(xs) - 1) + 0.5)
    return xs[k]


@fieldwise_init
struct Probe(Copyable, Movable):
    """One probe call: the argument struct has `rows` rows (field 0 holds
    i + 1 at row i, field 1 holds 10 * (i + 1)) broken by `kind`. While it
    runs the host clock reads `clock0` + the number of reads so far; the
    read numbered `cancel_at` (0: none) sets the cancel flag, which
    `cancel_now` sets before the call; `deadline` is the call's (0: none)."""

    var entry: String
    var read_set: List[String]
    var kind: Int32
    var field: Int32
    """The field `kind` breaks: 0 or 1."""
    var rows: Int
    var clock0: Int64
    var deadline: Int64
    var cancel_at: Int64
    var cancel_now: Bool

    @staticmethod
    def of(entry: String, read_set: List[String], kind: Int32, rows: Int) -> Probe:
        return Probe(entry, read_set.copy(), kind, 1, rows, 0, 0, 0, False)


@fieldwise_init
struct ProbeResult(Copyable, Movable):
    var status: Int32
    var message: String
    var row: Int64
    var moved: Bool
    """call_batch cleared the host's args slot."""
    var released: Bool
    """The argument struct's release ran by the end of the probe."""
    var clock_reads: Int64
    var logs: Int64
    """Host log lines while the probe ran."""
    var open_status: Int32
    """PROBE_OTHER_THREAD: open_instance from the probing thread."""
    var open_message: String
    var open_row: Int64
    var reserved_zero: Bool
    """An OK output's device struct came back with zero reserved words."""
    var last_level: Int32
    """The level of the last host log line, by the probe's end."""
    var out_len: Int64
    var out_nulls: Int64
    var out: List[Float64]
    """The first (at most 8) output values; NaN for a null."""


@fieldwise_init
struct ChildOpen(Copyable, Movable):
    """open_in_child's report: the engine's status after open (init's code
    when it failed), init's error row (-1 unless it failed) and message."""

    var status: Int32
    var row: Int64
    var message: String


def open_in_child(dir: String, path: String) raises -> ChildOpen:
    """Opens and initializes the runtime library at `path` in a child
    process, after changing to `dir` when it is not empty
    (native/row_probe.c, rowe_open_in_child)."""
    var d = _cstr(dir)
    var p = _cstr(path)
    var h = Word(external_call["rowe_open_in_child", Void](d, p))
    free_zeroed(d)
    free_zeroed(p)
    if h.is_null():
        raise Error("UDF_HARNESS_CHILD: the child for " + path + " reported nothing")
    var c = ChildOpen(
        Int32(external_call["rowe_child_get", Int64](h.p, Int32(0))),
        external_call["rowe_child_get", Int64](h.p, Int32(1)),
        read_cstr(external_call["rowe_child_message", Void](h.p)),
    )
    external_call["rowe_child_free", NoneType](h.p)
    return c^


@fieldwise_init
struct Misuse(Copyable, Movable):
    """One misuse call: the status, the error's row and message, and a
    value the kind defines (native/row_probe.c, struct misuse)."""

    var status: Int32
    var row: Int64
    var value: Int64
    var message: String


struct RowEngine(Movable):
    """One runtime library, opened and initialized; shut down when dropped."""

    var _e: Word

    def __init__(out self, path: String):
        var p = _cstr(path)
        self._e = Word(external_call["rowe_open", Void](p))
        free_zeroed(p)

    def status(self) -> Int32:
        return external_call["rowe_status", Int32](self._e.p)

    def message(self) -> String:
        return read_cstr(external_call["rowe_message", Void](self._e.p))

    def open_ns(self) -> Int64:
        return external_call["rowe_open_ns", Int64](self._e.p)

    def runtime_id(self) -> String:
        return read_cstr(external_call["rowe_runtime_id", Void](self._e.p))

    def cpu_model(self) -> String:
        return read_cstr(external_call["rowe_host_fact", Void](self._e.p, Int32(0)))

    def cgroup_cpu_max(self) -> String:
        """The cgroup's cpu.max ("max 100000": no quota); "" unreadable."""
        return read_cstr(external_call["rowe_host_fact", Void](self._e.p, Int32(1)))

    def run(mut self, w: RowWorkload) -> RowReport:
        var entry = _cstr(w.entry)
        var input = _cstr(_join(w.input))
        var read = _cstr(_join(w.read_set))
        var p = _cstr(w.check_p)
        var q = _cstr(w.check_q)
        var r = Word(
            external_call["rowe_run", Void](
                self._e.p, entry, input, read, p, q, Int32(w.threads), Int64(w.rows), Int32(w.batches),
                Int32(w.warm_window), Int32(w.warm_cap),
            )
        )
        free_zeroed(entry)
        free_zeroed(input)
        free_zeroed(read)
        free_zeroed(p)
        free_zeroed(q)
        var threads = List[RowThread]()
        var n = Int(_get(r, -1, _R_THREADS))
        for t in range(n):
            var ti = Int32(t)
            var samples = List[Int64]()
            var ns = Int(_get(r, ti, _T_SAMPLES))
            for i in range(ns):
                samples.append(external_call["rowe_sample", Int64](r.p, ti, Int64(i)))
            threads.append(
                RowThread(
                    Int32(_get(r, ti, _T_STATUS)), read_cstr(external_call["rowe_run_message", Void](r.p, ti)),
                    _get(r, ti, _T_OPEN_CONTEXT_NS), _get(r, ti, _T_OPEN_INSTANCE_NS), _get(r, ti, _T_FIRST_CALL_NS),
                    _get(r, ti, _T_CALLS), _get(r, ti, _T_ROWS), _get(r, ti, _T_BAD_VALUES),
                    _get(r, ti, _T_EXPORTED), _get(r, ti, _T_RELEASED), _get(r, ti, _T_BYTES),
                    _get(r, ti, _T_WARMUP_CALLS), _get(r, ti, _T_WARM_STABLE) != 0, samples^,
                )
            )
        var out = RowReport(
            Int32(_get(r, -1, _R_STATUS)), read_cstr(external_call["rowe_run_message", Void](r.p, Int32(-1))),
            _get(r, -1, _R_LOAD_NS), _get(r, -1, _R_WALL_NS), _get(r, -1, _R_CPU_USER_NS),
            _get(r, -1, _R_CPU_SYS_NS), _get(r, -1, _R_RSS_BEFORE), _get(r, -1, _R_RSS_OPEN), _get(r, -1, _R_CPUS),
            _get(r, -1, _R_COLD_NS), _get(r, -1, _R_INVOLUNTARY), _get(r, -1, _R_NR_THROTTLED),
            _get(r, -1, _R_THROTTLED_USEC), _get(r, -1, _R_LOADAVG_MILLI), _get(r, -1, _R_WIDTH),
            _get(r, -1, _R_READ_FIELDS), threads^,
        )
        external_call["rowe_run_free", NoneType](r.p)
        return out^

    def probe(mut self, p: Probe) -> ProbeResult:
        var entry = _cstr(p.entry)
        var read = _cstr(_join(p.read_set))
        var h = Word(
            external_call["rowe_probe", Void](
                self._e.p, entry, read, p.kind, p.field, Int64(p.rows), p.clock0, p.deadline, p.cancel_at,
                Int32(1) if p.cancel_now else Int32(0),
            )
        )
        free_zeroed(entry)
        free_zeroed(read)
        var out = List[Float64]()
        var n = Int(_pget(h, 7))
        for i in range(min(n, 8)):
            out.append(external_call["rowe_probe_value", Float64](h.p, Int32(i)))
        var r = ProbeResult(
            Int32(_pget(h, 0)), read_cstr(external_call["rowe_probe_message", Void](h.p, Int32(0))), _pget(h, 1),
            _pget(h, 2) != 0, _pget(h, 3) != 0, _pget(h, 4), _pget(h, 5), Int32(_pget(h, 6)),
            read_cstr(external_call["rowe_probe_message", Void](h.p, Int32(1))), _pget(h, 9), _pget(h, 10) != 0,
            Int32(_pget(h, 11)), _pget(h, 7), _pget(h, 8), out^,
        )
        external_call["rowe_probe_free", NoneType](h.p)
        return r^

    def misuse(mut self, which: Int32) -> Misuse:
        var h = Word(external_call["rowe_misuse", Void](self._e.p, which))
        var m = Misuse(
            Int32(external_call["rowe_misuse_get", Int64](h.p, Int32(0))),
            external_call["rowe_misuse_get", Int64](h.p, Int32(1)),
            external_call["rowe_misuse_get", Int64](h.p, Int32(2)),
            read_cstr(external_call["rowe_misuse_message", Void](h.p)),
        )
        external_call["rowe_misuse_free", NoneType](h.p)
        return m^

    def shutdown_off_thread(mut self) -> Int64:
        """Shuts the runtime down from another thread; the log lines it wrote.
        The engine holds no runtime afterwards."""
        return external_call["rowe_shutdown_off_thread", Int64](self._e.p)

    def last_log_level(self) -> Int32:
        return external_call["rowe_last_log_level", Int32](self._e.p)

    def init_row(self) -> Int64:
        """The error row init returned, when it failed."""
        return external_call["rowe_init_row", Int64](self._e.p)

    def __del__(deinit self):
        external_call["rowe_close", NoneType](self._e.p)


def _get(r: Word, thread: Int32, field: Int32) -> Int64:
    return external_call["rowe_get", Int64](r.p, thread, field)


def _pget(h: Word, field: Int32) -> Int64:
    return external_call["rowe_probe_get", Int64](h.p, field)
