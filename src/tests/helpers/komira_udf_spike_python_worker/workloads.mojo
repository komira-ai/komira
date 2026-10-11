# The workloads the tests and the bench give native/drive.c, as its
# `key=value` configuration lines. Each names a fixture: of the in-process
# runtime's modules (pyrt/udf_fixtures.py, pyrt/udf_np.py), of this
# package's (pyworker/udf_worker_*.py), or the closure the producer captured
# (producer/make_closure.py); the engine loop knows no runtime and no
# language.

from komira_udf_spike_abi.contract import FORM_VALUE, SHAPE_MAP_BATCHES_COLUMN, SHAPE_SCALAR

from .drive import CHECK_AFFINE, CHECK_COUNTER, CHECK_NONE


def _kv(k: String, v: String) -> String:
    return k + "=" + v + "\n"


def workload(
    entry: String, shape: Int, arg_fmt: String, result_fmt: String, threads: Int, rows: Int, batches: Int,
    check: Int, a: Float64, b: Float64, base: Float64, step: Float64, warmup_fixed: Int = 0, warmup_cap: Int = 200,
) -> String:
    var s = _kv("entry", entry) + _kv("shape", String(shape)) + _kv("arg_fmt", arg_fmt)
    s += _kv("result_fmt", result_fmt) + _kv("threads", String(threads)) + _kv("rows", String(rows))
    s += _kv("batches", String(batches)) + _kv("check", String(check)) + _kv("a", String(a)) + _kv("b", String(b))
    s += _kv("base", String(base)) + _kv("step", String(step)) + _kv("warmup_fixed", String(warmup_fixed))
    return s + _kv("warmup_cap", String(warmup_cap))


def fahrenheit_rows(threads: Int, rows: Int, batches: Int, warmup_fixed: Int = 0) -> String:
    """(1) The per-row pure-Python function, checked value by value."""
    return workload(
        "udf_fixtures:fahrenheit_rows", Int(SHAPE_SCALAR), "g", "g", threads, rows, batches, CHECK_AFFINE, 1.8, 32.0,
        -40.0, 0.25, warmup_fixed,
    )


def fahrenheit_np(threads: Int, rows: Int, batches: Int, warmup_fixed: Int = 0) -> String:
    """(2) The numpy batch function, checked value by value."""
    return workload(
        "udf_np:fahrenheit_np", Int(SHAPE_MAP_BATCHES_COLUMN), "g", "g", threads, rows, batches, CHECK_AFFINE, 1.8,
        32.0, -40.0, 0.25, warmup_fixed,
    )


def closure(threads: Int, rows: Int, batches: Int, code_root: String, sha256: String, warmup_fixed: Int = 0) -> String:
    """(3) The closure over the model, a VALUE: x * 1.8 + 32 with the 1.8
    read from the model."""
    var s = workload(
        "score", Int(SHAPE_MAP_BATCHES_COLUMN), "g", "g", threads, rows, batches, CHECK_AFFINE, 1.8, 32.0, -40.0,
        0.25, warmup_fixed,
    )
    return s + _kv("form", String(FORM_VALUE)) + _kv("code_root", code_root) + _kv("code_sha256", sha256)


def counter(entry: String, threads: Int, batches: Int) -> String:
    """One int64 row per batch, recorded as a counter (first, last, rising)."""
    return workload(entry, Int(SHAPE_SCALAR), "l", "l", threads, 1, batches, CHECK_COUNTER, 0.0, 0.0, 0.0, 0.0, 1)


def abort_on_3(rows: Int) -> String:
    """Rows 0, 1, 2, ...: the worker aborts on the row whose value is 3."""
    return workload(
        "udf_worker_fixtures:abort_on_3", Int(SHAPE_SCALAR), "l", "l", 1, rows, 0, CHECK_NONE, 1.0, 0.0, 0.0, 1.0, 0
    )


def keep_then_drop(rows: Int, batches: Int) -> String:
    """x * 2 over numpy, keeping a view of each of the first 30 inputs."""
    return workload(
        "udf_worker_np:keep_then_drop", Int(SHAPE_MAP_BATCHES_COLUMN), "g", "g", 1, rows, batches, CHECK_AFFINE, 2.0,
        0.0, 0.0, 1.0, 1,
    )
