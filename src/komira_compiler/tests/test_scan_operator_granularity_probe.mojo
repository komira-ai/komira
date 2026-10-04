# =============================================================================
# test_scan_operator_granularity_probe.mojo  (a probe)
#
# MEASURE filter-eval throughput at the OPERATOR-eval granularity (2048 vs 4096
# vs 30000 rows) DECOUPLED from the decode granularity (CHUNK_ROWS=30000,
# syscall-avoidance). The question: does evaluating the WHERE filter over
# L1d-resident sub-vectors (~2048 rows, 128KB Apple-Silicon L1d) beat
# evaluating it over the whole 30000-row decode chunk?
#
# This is a PROBE, not a performance gate: it prints a throughput table only
# when run with `--probe`, and otherwise checks correctness alone.
#
# Method: build ONE int batch of N=300000 rows (10x the chunk), then time
# evaluate_filter_narrowed over it sliced into K-row sub-vectors for K in
# {2048, 4096, 30000}. The predicate is `c0 >= 25` (a filtered-scan shape,
# ~50% selectivity). Each K is run for many iterations; report ns/row.
# =============================================================================

from std.testing import TestSuite, assert_true
from std.time import perf_counter_ns

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.schema import (
    Schema, Field, SchemaBuilder, RecordBatch, RecordBatchBuilder,
)
from komira_core.arrow.column import Column
from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.col_expr import col, lit
from komira_core.plan.expr import Expr
from komira_compiler.conjunction import evaluate_filter_narrowed


comptime PROBE_ROWS: Int = 300_000


def _make_int_batch(n_rows: Int) raises -> RecordBatch:
    var c0 = PrimitiveArray[DType.int64].allocate(n_rows)
    var c1 = PrimitiveArray[DType.int64].allocate(n_rows)
    var p0 = c0._typed_ptr_mut()
    var p1 = c1._typed_ptr_mut()
    for i in range(n_rows):
        p0.store[width=1](i, Scalar[DType.int64](i % 50))
        p1.store[width=1](i, Scalar[DType.int64](100 + (i % 7)))
    var b = RecordBatchBuilder.with_capacity(2)
    var sb = SchemaBuilder()
    sb.add_field(Field("c0", ArrowType.INT64, False))
    sb.add_field(Field("c1", ArrowType.INT64, False))
    b.add_column(Column.from_primitive[DType.int64](c0^))
    b.add_column(Column.from_primitive[DType.int64](c1^))
    return b.build(sb.build())


def _time_granularity(k: Int, total_target: Int) raises -> Tuple[Int, Int]:
    """Build a K-row batch and run evaluate_filter_narrowed over it enough times
    to cover ~`total_target` rows. Returns (ns_elapsed, total_rows_evaluated).
    Isolating the per-row filter cost at each granularity surfaces the L1d-
    residency effect (a 2048-row INT batch fits L1d; a 30000-row one spills)."""
    var batch = _make_int_batch(k)
    var passes = (total_target + k - 1) // k
    var survivors = 0
    var t0 = perf_counter_ns()
    for _it in range(passes):
        var sel = evaluate_filter_narrowed(batch, col("c0") >= 25)
        survivors += sel.length()
        _ = sel^
    var t1 = perf_counter_ns()
    _ = batch^
    if survivors < 0:
        raise Error("impossible")
    return (Int(t1 - t0), passes * k)


def test_scan_operator_granularity_probe() raises:
    var target = PROBE_ROWS * 40  # ~12M rows evaluated per granularity.
    # Warm-up (JIT + page-fault the working set) before the timed runs.
    _ = _time_granularity(2048, PROBE_ROWS)
    _ = _time_granularity(4096, PROBE_ROWS)
    _ = _time_granularity(30000, PROBE_ROWS)
    var r2048 = _time_granularity(2048, target)
    var r4096 = _time_granularity(4096, target)
    var r30000 = _time_granularity(30000, target)
    print("[SCAN-GRANULARITY-PROBE] target_rows=", target)
    print("  K=2048   ns/row=", Float64(r2048[0]) / Float64(r2048[1]),
          " total_ms=", r2048[0] // 1_000_000)
    print("  K=4096   ns/row=", Float64(r4096[0]) / Float64(r4096[1]),
          " total_ms=", r4096[0] // 1_000_000)
    print("  K=30000  ns/row=", Float64(r30000[0]) / Float64(r30000[1]),
          " total_ms=", r30000[0] // 1_000_000)
    assert_true(True, "probe ran")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
