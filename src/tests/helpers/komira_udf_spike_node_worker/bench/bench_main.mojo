# The bench of the Node.js worker runtime: `bench <node_worker.so> <echo.so>
# <run_id>`, run by :bench (defs.bzl, udf_bench) in the directory that holds
# both libraries. Prints one JSON object: the run id and, per workload, the
# engine loop's report (native/engine_loop.c), which carries every timed
# sample, the CPU of the engine threads and of each worker process, each
# worker's memory and own counters, and the co-tenancy readings (cgroup
# cpu.max and throttling, load average, CPUs in the affinity mask).
#
# Workloads (udf/fahrenheit.ts, the user's module):
#   hop          `same`, one row per batch: the crossing alone;
#   row / batch  `fahrenheitRow` (per row) and `fahrenheitBatch` (over the
#                Arrow vector), 8192-row batches at N = 1, 4 and 16 engine
#                threads, and 1024 and 65536 rows at N = 1;
# and the in-process floor: the reference runtime echo.so (C, the same
# arithmetic) at 1 and 8192 rows and N = 1, 4, 16.

from std.sys import argv

from komira_udf_spike_abi.contract import SHAPE_MAP_BATCHES_COLUMN, SHAPE_SCALAR
from komira_udf_spike_node_worker.engine import CHECK_AFFINE, CHECK_SAME, Workload, run

comptime WARM = 600
comptime SAMPLES = 60
comptime MIN_MS = 500


def _one(mut out: String, mut first: Bool, label: String, lib: String, w: Workload):
    var rep = run(lib, w)
    if not first:
        out += ","
    first = False
    out += '{"label":"' + label + '","report":' + rep + "}"


def main() raises:
    var args = argv()
    if len(args) != 4:
        raise Error("usage: bench <node_worker.so> <echo.so> <run_id>")
    var node = String(args[1])
    var echo = String(args[2])
    var out = '{"run_id":"' + String(args[3]) + '","runs":['
    var first = True
    var col = SHAPE_MAP_BATCHES_COLUMN
    _one(out, first, "hop n=1", node, Workload("fahrenheit.mjs#same", col, "g", 1, 1, WARM, 200, MIN_MS, CHECK_SAME, 0.0, 0.0))
    _one(out, first, "echo hop n=1", echo, Workload("fahrenheit", col, "g", 1, 1, WARM, 200, MIN_MS, CHECK_AFFINE, 1.8, 32.0))
    for n in [1, 4, 16]:
        var t = String(n)
        _one(
            out, first, "row 8192 n=" + t, node,
            Workload("fahrenheit.mjs#fahrenheitRow", SHAPE_SCALAR, "g", n, 8192, WARM, SAMPLES, MIN_MS, CHECK_AFFINE, 1.8, 32.0),
        )
        _one(
            out, first, "batch 8192 n=" + t, node,
            Workload("fahrenheit.mjs#fahrenheitBatch", col, "g", n, 8192, WARM, SAMPLES, MIN_MS, CHECK_AFFINE, 1.8, 32.0),
        )
        _one(
            out, first, "echo 8192 n=" + t, echo,
            Workload("fahrenheit", col, "g", n, 8192, WARM, SAMPLES, MIN_MS, CHECK_AFFINE, 1.8, 32.0),
        )
    for rows in [1024, 65536]:
        var t = String(rows)
        _one(
            out, first, "row " + t + " n=1", node,
            Workload("fahrenheit.mjs#fahrenheitRow", SHAPE_SCALAR, "g", 1, rows, WARM, SAMPLES, MIN_MS, CHECK_AFFINE, 1.8, 32.0),
        )
        _one(
            out, first, "batch " + t + " n=1", node,
            Workload("fahrenheit.mjs#fahrenheitBatch", col, "g", 1, rows, WARM, SAMPLES, MIN_MS, CHECK_AFFINE, 1.8, 32.0),
        )
    out += "]}"
    print(out)
