# =============================================================================
# CteMorselSource unit tests (Phase 5b)
# =============================================================================
#
# Covers an internal doc Rev 4.3 §4.3 + §7
# Phase 5b. Tests:
#   1. Single-consumer: register a batch, resolve via CteMorselSource,
#      drain to EOF.
#   2. Multi-consumer: TWO CteMorselSource instances reference the same
#      registered handle; both drain independently and see the full
#      batch (1000 rows each).
#   3. EOF stability after drain.
#   4. Capability defaults match BatchMorselSource (all False).
#
# Follows the Phase 5a fixture idiom (single-column INT64 batch,
# `_build_int64_batch`). No on-disk fixtures.
# =============================================================================

from std.memory import ArcPointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)

from komira_op_sources.cte_morsel_source import CteMorselSource
from komira_scan_source.compiler_registry import InMemoryRegistry


# =============================================================================
# Helpers
# =============================================================================


def _build_int64_batch(var values: List[Int64]) raises -> RecordBatch:
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = values[i]
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.int64](arr^))
    return b.build(sb.build())


def _range_batch(n: Int) raises -> RecordBatch:
    var vs = List[Int64]()
    for i in range(n):
        vs.append(Int64(i))
    return _build_int64_batch(vs^)


def _drain_total_rows(mut src: CteMorselSource) raises -> Int:
    var total = 0
    while True:
        var opt = src.next_morsel(0)
        if not opt:
            return total
        total += opt.value().num_rows()


# =============================================================================
# Test 1: single consumer
# =============================================================================


def test_single_consumer() raises:
    # Register BEFORE wrapping in ArcPointer. ArcPointer[] gives an
    # immutable ref only; `register` takes `mut self`. The contract is:
    # all registration happens on the owning driver, the Arc is handed
    # to the consumer, drops run at end-of-scope.
    var reg = InMemoryRegistry()
    reg.register(String("cte_x"), _range_batch(1000))
    var reg_arc = ArcPointer[InMemoryRegistry](reg^)

    var src = CteMorselSource(String("cte_x"), reg_arc, morsel_rows=300)
    var total = _drain_total_rows(src)
    if total != 1000:
        raise "single: expected 1000 rows, got " + String(total)

    # After drain: partition_hint should equal pre-split morsel count
    # (ceil(1000/300) = 4), row_count_hint == 1000.
    if src.partition_hint() != 4:
        raise "single: partition_hint expected 4, got " + String(src.partition_hint())
    if src.row_count_hint() != 1000:
        raise "single: row_count_hint expected 1000, got " + String(src.row_count_hint())

    # Cleanup: source and ArcPointer drop at end of scope -- the registry
    # is freed when the last Arc reference goes away.
    _ = src^
    print("test_single_consumer OK")


# =============================================================================
# Test 2: multi-consumer -- two independent CteMorselSource instances
# over the same registered batch both drain in full.
# =============================================================================


def test_multi_consumer() raises:
    var reg = InMemoryRegistry()
    reg.register(String("shared"), _range_batch(1000))
    var reg_arc = ArcPointer[InMemoryRegistry](reg^)

    # Each consumer deep-copies the batch out of the registry
    # independently (the _copy_batch path inside CteMorselSource).
    # Copying the ArcPointer bumps the refcount -- both consumers
    # share the same underlying registry.
    var a = CteMorselSource(String("shared"), reg_arc, morsel_rows=250)
    var b = CteMorselSource(String("shared"), reg_arc, morsel_rows=250)

    var rows_a = _drain_total_rows(a)
    var rows_b = _drain_total_rows(b)

    if rows_a != 1000:
        raise "multi: consumer A expected 1000 rows, got " + String(rows_a)
    if rows_b != 1000:
        raise "multi: consumer B expected 1000 rows, got " + String(rows_b)

    _ = a^
    _ = b^
    print("test_multi_consumer OK")


# =============================================================================
# Test 3: EOF stability
# =============================================================================


def test_eof_stable() raises:
    var reg = InMemoryRegistry()
    reg.register(String("small"), _range_batch(10))
    var reg_arc = ArcPointer[InMemoryRegistry](reg^)

    var src = CteMorselSource(String("small"), reg_arc, morsel_rows=10)
    _ = src.next_morsel(0)  # take the only morsel
    for _ in range(5):
        var opt = src.next_morsel(0)
        if opt:
            raise "EOF: expected None after drain"

    _ = src^
    print("test_eof_stable OK")


# =============================================================================
# Test 4: capability defaults (all False -- Phase 5b mirrors 5a)
# =============================================================================


def test_capabilities_default() raises:
    var reg = InMemoryRegistry()
    reg.register(String("caps"), _range_batch(4))
    var reg_arc = ArcPointer[InMemoryRegistry](reg^)

    var src = CteMorselSource(String("caps"), reg_arc, morsel_rows=2)
    var caps = src.capabilities()
    if caps.supports_projection:
        raise "Phase 5b: supports_projection must be False"
    if caps.supports_decode_filter:
        raise "Phase 5b: supports_decode_filter must be False"
    if caps.supports_dict_preservation:
        raise "Phase 5b: supports_dict_preservation must be False"
    if caps.supports_dynamic_filter:
        raise "Phase 5b: supports_dynamic_filter must be False"
    if caps.supports_row_group_pruning:
        raise "Phase 5b: supports_row_group_pruning must be False"
    if caps.supports_bypass_columns:
        raise "Phase 5b: supports_bypass_columns must be False"
    if caps.supports_as_source:
        raise "Phase 5b: supports_as_source must be False"

    _ = src^
    print("test_capabilities_default OK")


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    test_single_consumer()
    test_multi_consumer()
    test_eof_stable()
    test_capabilities_default()
    print("All CteMorselSource (Phase 5b) tests PASS")
