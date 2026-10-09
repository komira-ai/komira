# The Python worker runtime's numbers, measured inside the engine loop
# (native/drive.c, through drive.mojo): one JSON object on stdout.
#
# usage: bench_main <runtime library> <variant label> <run id>
#
# For each workload, at 1, 4 and 16 engine threads (each thread its own
# context, so its own worker process):
#   - rows: the per-row pure-Python function, 8192-row batches;
#   - numpy: the numpy batch function, 8192-row batches;
#   - closure: the cloudpickled closure over the 16 MiB model, 8192-row
#     batches;
#   - overhead: the per-row function on 1-row batches, the cost of one
#     round trip;
# and, at 1 thread, the numpy function at 1, 1024, 8192 and 65536 rows per
# batch (the copy cost as batches grow).
# Warm-up runs until three consecutive window medians of 10 calls agree
# within 2% (at most 200 calls; the count is reported). Each row: rows/s over
# the measured phase, per thread, and the efficiency rows/s(N) / (N x
# rows/s(1)); call_batch latency (min, median, p90, max, timed around the
# table entry alone); CPU of the engine and of the workers over wall time,
# `noisy` when that is under 0.8 x wall x min(N, CPUs); involuntary
# switches; the cgroup's cpu.max and throttling over the phase; memory of
# the context workers (PSS, USS, RSS) and of the control worker or zygote,
# taken with every context open and one batch done; cold start per context
# (open_context to the end of its first batch) and for the engine (open to
# the first run's first batch); and every call of the run split in three,
# per call: the engine's side of the proxy (serializing, copying the reply
# out, decoding), the transport (request sent to reply read, less the
# worker's time: the socket, the wake-ups) and the worker (from reading the
# request to sending the reply: decoding, the adapter, user code, encoding).

from std.sys import argv

from komira_json import JsonValue, parse_json_value
from komira_udf_spike_python_worker.drive import Driver
from komira_udf_spike_python_worker.report import call_split, num, per_thread, processes, text
from komira_udf_spike_python_worker.workloads import closure, fahrenheit_np, fahrenheit_rows

comptime ROWS = 8192
comptime BUILD = "bench program mojo -O3 (mojo_binary default); engine loop and proxy C -O2; worker CPython 3.13"


def _q(s: String) -> String:
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


def _quantile(var xs: List[Int], q: Float64) -> Int:
    if len(xs) == 0:
        return 0
    sort(xs)
    return xs[Int(q * Float64(len(xs) - 1) + 0.5)]


def _mem(r: JsonValue, role: String) raises -> String:
    """Mean PSS, USS and RSS (kB) of the processes of `role`."""
    var ps = processes(r, role)
    if len(ps) == 0:
        return "null"
    var pss = 0
    var uss = 0
    var rss = 0
    for p in ps:
        pss += num(p, "pss_kb")
        uss += num(p, "uss_kb")
        rss += num(p, "rss_kb")
    var n = len(ps)
    return (
        '{"n": ' + String(n) + ', "pss_kb": ' + String(pss // n) + ', "uss_kb": ' + String(uss // n)
        + ', "rss_kb": ' + String(rss // n) + "}"
    )


def _row(name: String, r: JsonValue, base: Float64, mut rps_out: Float64) raises -> String:
    var n = num(r, "threads")
    var rpb = num(r, "rows_per_batch")
    var s = '{"workload": ' + _q(name) + ', "rows_per_batch": ' + String(rpb) + ', "threads": ' + String(n)
    if num(r, "status") != 0:
        return s + ', "status": "FAIL", "error": ' + _q(text(r, "message")) + "}"
    var all = List[Int]()
    var cold = List[Int]()
    var ctx = List[Int]()
    var warm = 0
    var warmup = List[Int]()
    var rows = 0
    for t in per_thread(r):
        var sm = t.get("samples")
        for i in range(sm.array_len()):
            all.append(Int(sm.element_at(i).as_int64()))
        rows += sm.array_len() * rpb
        cold.append(num(t, "cold_ns"))
        ctx.append(num(t, "open_context_ns"))
        warmup.append(num(t, "warmup_calls"))
        if t.get("warm").as_bool():
            warm += 1
    var wall = Float64(num(r, "wall_ns"))
    var rps = Float64(rows) * 1e9 / wall if wall > 0 else 0.0
    rps_out = rps
    var cpu = Float64(num(r, "engine_cpu_user_ns") + num(r, "engine_cpu_sys_ns") + num(r, "workers_cpu_ns"))
    var lanes = min(n, num(r, "cpus"))
    s += ', "status": "OK", "rows_per_s": ' + String(Int(rps)) + ', "rows_per_s_per_thread": '
    s += String(Int(rps / Float64(n)))
    if base > 0:
        s += ', "efficiency": ' + String(rps / (Float64(n) * base))
    s += ', "call_ns": {"min": ' + String(_quantile(all.copy(), 0.0)) + ', "median": '
    s += String(_quantile(all.copy(), 0.5)) + ', "p90": ' + String(_quantile(all.copy(), 0.9))
    s += ', "max": ' + String(_quantile(all.copy(), 1.0)) + ', "samples": ' + String(len(all)) + "}"
    s += ', "wall_ns": ' + String(Int(wall)) + ', "cpu_over_wall": ' + String(cpu / wall)
    s += ', "workers_cpu_ns": ' + String(num(r, "workers_cpu_ns"))
    s += ', "noisy": ' + ("true" if cpu < 0.8 * wall * Float64(lanes) else "false")
    s += ', "involuntary_switches": ' + String(num(r, "involuntary_switches"))
    s += ', "nr_throttled_delta": ' + String(num(r, "nr_throttled_delta"))
    s += ', "throttled_us_delta": ' + String(num(r, "throttled_us_delta")) + ', "loadavg": ' + _q(text(r, "loadavg"))
    s += ', "warm_threads": ' + String(warm) + ', "warmup_calls_median": ' + String(_quantile(warmup^, 0.5))
    s += ', "context_workers": ' + _mem(r, "context") + ', "zygote": ' + _mem(r, "zygote")
    s += ', "control": ' + _mem(r, "control")
    s += ', "cold_ns_median": ' + String(_quantile(cold.copy(), 0.5)) + ', "cold_ns_max": '
    s += String(_quantile(cold^, 1.0)) + ', "open_context_ns_median": ' + String(_quantile(ctx^, 0.5))
    s += ', "load_ns": ' + String(num(r, "load_ns")) + ', "engine_cold_ns": ' + String(num(r, "engine_cold_ns"))
    var cs = call_split(r)
    if cs.calls > 0:
        s += ', "per_call_split_ns": {"calls": ' + String(cs.calls)
        s += ', "engine": ' + String((cs.call_ns - cs.wait_ns) // cs.calls)
        s += ', "transport": ' + String((cs.wait_ns - cs.worker_ns) // cs.calls)
        s += ', "worker": ' + String(cs.worker_ns // cs.calls) + "}"
    return s + "}"


def main() raises:
    var args = argv()
    if len(args) != 4:
        raise Error("usage: bench_main <runtime library> <variant label> <run id>")
    var info: JsonValue
    with open("closure/info.json", "r") as f:
        info = parse_json_value(f.read())
    var sha = text(info, "sha256")
    var d = Driver(String(args[1]))
    if d.status() != 0:
        raise Error("engine open: " + d.message())
    var rows = List[String]()
    var meta = String("")
    for w in range(4):
        var base: Float64 = 0
        for n in [1, 4, 16]:
            var name: String
            var cfg: String
            if w == 0:
                name = "rows"
                cfg = fahrenheit_rows(n, ROWS, 30)
            elif w == 1:
                name = "numpy"
                cfg = fahrenheit_np(n, ROWS, 200)
            elif w == 2:
                name = "closure"
                cfg = closure(n, ROWS, 200, "closure/good", sha)
            else:
                name = "overhead"
                cfg = fahrenheit_rows(n, 1, 2000)
            var r = d.run(cfg)
            if meta == "" and num(r, "status") == 0:
                meta = ', "runtime_id": ' + _q(text(r, "runtime_id")) + ', "cpus": ' + String(num(r, "cpus"))
                meta += ', "cpu_model": ' + _q(text(r, "cpu_model")) + ', "cgroup_cpu_max": '
                meta += _q(text(r, "cgroup_cpu_max")) + ', "engine_open_ns": ' + String(num(r, "open_ns"))
                meta += ', "engine_cold_ns": ' + String(num(r, "engine_cold_ns"))
            var rps: Float64 = 0
            rows.append(_row(name, r, base, rps))
            if n == 1:
                base = rps
    for size in [1, 1024, 8192, 65536]:
        var r = d.run(fahrenheit_np(1, size, 200))
        var rps: Float64 = 0
        rows.append(_row("numpy_batch_size", r, 0.0, rps))
    d.close()
    var out = '{"run_id": ' + _q(String(args[3])) + ', "variant": ' + _q(String(args[2])) + meta
    out += ', "closure_payload_bytes": ' + String(num(info, "payload_bytes")) + ', "build": ' + _q(BUILD)
    out += ', "rows": ['
    for i in range(len(rows)):
        out += ("" if i == 0 else ", ") + rows[i]
    print(out + "]}")
