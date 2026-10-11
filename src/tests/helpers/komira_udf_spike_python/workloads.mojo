# The workloads the threads tests and the bench drive through the engine
# loop (engine.mojo). Each names a fixture of pyrt/udf_fixtures.py or
# pyrt/udf_np.py; the engine itself knows no runtime and no language.

from komira_udf_spike_abi.contract import SHAPE_MAP_BATCHES_COLUMN, SHAPE_SCALAR
from komira_udf_spike_python.engine import CHECK_AFFINE, CHECK_COUNTER, CHECK_NONE, Workload


def fahrenheit_rows(threads: Int, rows: Int, warmup: Int, batches: Int) -> Workload:
    """The per-row pure-Python function, checked value by value."""
    return Workload(
        "udf_fixtures:fahrenheit_rows", SHAPE_SCALAR, "g", "g", threads, warmup, batches, rows, CHECK_AFFINE, 1.8,
        32.0, -40.0, 0.25,
    )


def fahrenheit_np(threads: Int, rows: Int, warmup: Int, batches: Int) -> Workload:
    """The numpy batch function, checked value by value."""
    return Workload(
        "udf_np:fahrenheit_np", SHAPE_MAP_BATCHES_COLUMN, "g", "g", threads, warmup, batches, rows, CHECK_AFFINE,
        1.8, 32.0, -40.0, 0.25,
    )


def call_counter(threads: Int, batches: Int) -> Workload:
    """One row per batch; each output is the module's row count in its
    interpreter."""
    return Workload(
        "udf_fixtures:call_counter", SHAPE_SCALAR, "l", "l", threads, 1, batches, 1, CHECK_COUNTER, 0.0, 0.0, 0.0,
        0.0,
    )


def spin(threads: Int, ms: Int) -> Workload:
    """One measured batch of one row per thread, spinning `ms` ms of CPU."""
    return Workload(
        "udf_fixtures:spin", SHAPE_SCALAR, "l", "l", threads, 1, 1, 1, CHECK_NONE, 0.0, 0.0, Float64(ms), 0.0
    )
