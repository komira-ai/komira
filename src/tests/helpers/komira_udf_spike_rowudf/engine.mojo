# =============================================================================
# FFI-BOUNDARY: the row-UDF engine loop over N engine threads
# (native/row_engine.c), behind a value API.
# =============================================================================
# RowEngine opens a UDF runtime library and keeps it until it is dropped;
# run() loads one ROW UDF with a read set and drives it on N engine threads
# (pthreads started in C, on which no Mojo code runs), returning a RowReport
# of values.
#
# Who owns and frees each pointer:
#   - the engine handle (struct engine): native/row_engine.c's, created by
#     rowe_open and freed by rowe_close in RowEngine.__del__, which shuts the
#     runtime down first. Held here as a Word that only this file reads
#     through.
#   - a run handle (struct run): created by rowe_run and freed by
#     rowe_run_free before run() returns, once every field is copied out.
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

    def __del__(deinit self):
        external_call["rowe_close", NoneType](self._e.p)


def _get(r: Word, thread: Int32, field: Int32) -> Int64:
    return external_call["rowe_get", Int64](r.p, thread, field)
