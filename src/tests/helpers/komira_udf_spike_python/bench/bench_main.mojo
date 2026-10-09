# The Python runtime's numbers, measured inside the engine loop
# (native/engine_loop.c, through engine.mojo): one JSON object on stdout.
#
# usage: bench_main <runtime library> <variant label> <run id>
#
# For each workload, at 1, 4 and 16 engine threads (each thread its own
# context and instance, opened on that thread), after a fixed number of
# warm-up batches per thread (the first timed apart):
#   - fahrenheit_rows: the per-row pure-Python function, 8192-row batches;
#   - fahrenheit_np: the numpy batch function, 8192-row batches (a status
#     and the runtime's error where numpy does not load);
#   - overhead: the per-row function on 1-row batches, the cost of one
#     crossing.
# Each row of the report: rows/s over the measured phase (from the barrier
# all threads pass once warm to the one each passes after its last batch),
# rows/s per thread, scaling efficiency rows/s(N) / (N x rows/s(1)), call_batch
# latency (min, median, p90, max over every thread's measured calls, timed
# around the table entry alone), process CPU over wall time, involuntary
# context switches, and memory per context as the process RSS delta over
# opening N contexts with their instances and one batch each, divided by N
# (labelled so: it is not PSS). Cold start is engine open (before dlopen)
# to the end of the first batch, on the first run of the process.

from std.sys import argv

from komira_udf_spike_python.engine import CAP_GLOBAL_LOCK, Engine, RunReport, Workload, quantile
from komira_udf_spike_python.workloads import fahrenheit_np, fahrenheit_rows

comptime ROWS = 8192
comptime WARMUP = 10
comptime BATCHES = 60
"""fahrenheit_rows: about 200 ms of measured calls per thread."""
comptime NP_WARMUP = 50
comptime NP_BATCHES = 2000
"""fahrenheit_np: about 60 ms per thread where numpy loads."""
comptime OVERHEAD_WARMUP = 500
comptime OVERHEAD_BATCHES = 20000
"""overhead: about 60 ms per thread, long against thread start skew."""
comptime BUILD = "bench program mojo -O3 (mojo_binary default); engine loop and runtime C -O2"


def _threads() -> List[Int]:
    return [1, 4, 16]


def _q(s: String) -> String:
    """`s` as a JSON string: quotes and backslashes escaped, control bytes
    as spaces, other bytes as they are."""
    var out = List[UInt8]()
    out.append(0x22)
    for b in s.as_bytes():
        if b == 0x22 or b == 0x5C:
            out.append(0x5C)
            out.append(b)
        elif b < 0x20:
            out.append(0x20)
        else:
            out.append(b)
    out.append(0x22)
    return String(from_utf8_lossy=Span(out))


def _median(xs: List[Int64]) -> Int64:
    return quantile(xs.copy(), 0.5)


def _row(name: String, rows_per_batch: Int, r: RunReport, base_rows_per_s: Float64) -> String:
    var n = len(r.threads)
    var ok = r.status == 0
    var s = String("{")
    s += '"workload": ' + _q(name) + ', "rows_per_batch": ' + String(rows_per_batch)
    s += ', "threads": ' + String(n) + ', "status": ' + _q("OK" if ok else "FAIL")
    if not ok:
        return s + ', "error": ' + _q(r.message) + "}"
    var rps = r.rows_per_s()
    var all = r.all_samples()
    var cpu = Float64(r.cpu_user_ns + r.cpu_sys_ns)
    var ctx = List[Int64]()
    var inst = List[Int64]()
    var first = List[Int64]()
    for t in r.threads:
        ctx.append(t.open_context_ns)
        inst.append(t.open_instance_ns)
        first.append(t.first_call_ns)
    var lanes = min(n, Int(r.cpus))
    s += ', "rows_per_s": ' + String(Int(rps)) + ', "rows_per_s_per_thread": ' + String(Int(rps / Float64(n)))
    if base_rows_per_s > 0:
        s += ', "efficiency": ' + String(rps / (Float64(n) * base_rows_per_s))
    s += ', "call_ns": {"min": ' + String(quantile(all.copy(), 0.0)) + ', "median": ' + String(_median(all))
    s += ', "p90": ' + String(quantile(all.copy(), 0.9)) + ', "max": ' + String(quantile(all.copy(), 1.0))
    s += ', "samples": ' + String(len(all)) + "}"
    s += ', "wall_ns": ' + String(r.wall_ns) + ', "cpu_over_wall": ' + String(cpu / Float64(r.wall_ns))
    s += ', "noisy": ' + ("true" if cpu < 0.8 * Float64(r.wall_ns) * Float64(lanes) else "false")
    s += ', "involuntary_switches": ' + String(r.involuntary_switches)
    s += ', "rss_delta_per_context_bytes": ' + String((r.rss_open - r.rss_before) // Int64(n))
    s += ', "open_context_ns_median": ' + String(_median(ctx)) + ', "open_instance_ns_median": ' + String(_median(inst))
    s += ', "first_call_ns_median": ' + String(_median(first))
    return s + "}"


def main() raises:
    var args = argv()
    if len(args) != 4:
        raise Error("usage: bench_main <runtime library> <variant label> <run id>")
    var e = Engine(String(args[1]))
    if e.status() != 0:
        raise Error("engine open: " + e.message())
    var rows = List[String]()
    var cold: Int64 = -1
    var cpus: Int64 = 0
    for w in range(3):
        var base: Float64 = 0
        for n in _threads():
            var name: String
            var load: Workload
            var rpb = ROWS
            if w == 0:
                name = "fahrenheit_rows"
                load = fahrenheit_rows(n, ROWS, WARMUP, BATCHES)
            elif w == 1:
                name = "fahrenheit_np"
                load = fahrenheit_np(n, ROWS, NP_WARMUP, NP_BATCHES)
            else:
                name = "overhead"
                rpb = 1
                load = fahrenheit_rows(n, 1, OVERHEAD_WARMUP, OVERHEAD_BATCHES)
            var r = e.run(load)
            if r.cold_ns >= 0:
                cold = r.cold_ns
            cpus = r.cpus
            if n == 1 and r.status == 0:
                base = r.rows_per_s()
            rows.append(_row(name, rpb, r, base))
    var out = String("{")
    out += '"run_id": ' + _q(String(args[3])) + ', "variant": ' + _q(String(args[2]))
    out += ', "runtime_id": ' + _q(e.runtime_id()) + ', "global_lock": ' + String(e.cap(CAP_GLOBAL_LOCK))
    out += ', "cpus": ' + String(cpus) + ', "open_ns": ' + String(e.open_ns())
    out += ', "cold_start_ns": ' + String(cold) + ', "build": ' + _q(BUILD) + ', "rows": ['
    for i in range(len(rows)):
        out += ("" if i == 0 else ", ") + rows[i]
    print(out + "]}")
