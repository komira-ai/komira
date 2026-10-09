"""The bench report the `report_demo` test writes, with fixed numbers.

At N=1, 65536 rows in 32.768 ms are 2000000 rows/s; at N=4, 262144 rows in
65.536 ms are 4000000 rows/s, an efficiency of 0.50, and 200 ms of CPU time
is under 0.8 x 65.536 ms x 4, so that line is flagged noisy. The host has 8
CPUs, so N=16 is not measured. Each row has its own latency quantiles and
warm-up count, so a table that shows one row's under another's line differs
from the golden table.
"""

REPORT = {
    "schema": "komira-bench-report-1",
    "host": {
        "cpus": 8,
        "cpu_model": "fixture cpu",
        "cpu_max": "max 100000",
        "loadavg": [0.25, 0.5, 1.0],
        "nr_throttled_delta": 0,
        "throttled_usec_delta": 0,
    },
    "build": {"opt_levels": {"engine": "3", "driver": "1"}, "coverage": False, "versions": {"python": "3.13"}},
    "rows": [
        {
            "variant": "fixture",
            "function": "per_batch",
            "threads": 1,
            "rows": 65536,
            "batches": 8,
            "calls": 8,
            "wall_ns": 32768000,
            "cpu_user_ns": 30000000,
            "cpu_sys_ns": 2768000,
            "invol_ctx_switches": 1,
            "memory": {"rss_delta_per_thread": 2097152},
            "latency_ns": {"warmup_discarded": 3, "samples": 30, "min": 4000000, "median": 4096000, "p90": 4200000, "max": 4500000},
        },
        {
            "variant": "fixture",
            "function": "per_batch",
            "threads": 4,
            "rows": 262144,
            "batches": 32,
            "calls": 32,
            "wall_ns": 65536000,
            "cpu_user_ns": 200000000,
            "cpu_sys_ns": 0,
            "invol_ctx_switches": 9,
            "memory": {"rss_delta_per_thread": 1048576},
            "latency_ns": {"warmup_discarded": 5, "samples": 40, "min": 6000000, "median": 8192000, "p90": 9000000, "max": 9500000},
        },
    ],
}
