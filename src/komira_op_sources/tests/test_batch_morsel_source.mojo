# =============================================================================
# BatchMorselSource unit tests (Phase 5a)
# =============================================================================
#
# Covers an internal doc Rev 4.3 §4.3 (source
# contract) + §7 Phase 5a. Tests:
#   1. Single-threaded drain yields every morsel exactly once, then EOF.
#   2. Multi-worker concurrent pull visits every morsel exactly once
#      (row-count and partition_id invariants under a real fork-join).
#   3. EOF behavior: repeated next_morsel after exhaustion keeps returning
#      None.
#   4. Capability defaults match the Phase 5a advertised set (all False --
#      data is already materialized; as_source not yet implemented).
#   5. `partition_hint()` == pre-split morsel count; `row_count_hint()` ==
#      original batch row count; `output_schema()` matches input field list.
#   6. Monomorphization gate -- a generic driver parameterized on
#      MorselSourceImpl compiles over BatchMorselSource, matching the
#      MockMorselSource pattern.
#
# Uses a locally constructed INT64 single-column RecordBatch fixture
# (mirrors test_parquet_collect_sink.mojo's `_build_int64_batch`) so no
# on-disk fixture is needed.
# =============================================================================

# Test 2's whole claim is the SINGLE-PASS contract under CONCURRENT pullers:
# that `next_morsel`'s atomic cursor hands each of the 40 morsels to exactly
# one of N racing workers. Drain it serially and `total_pulls == 40` still
# holds while proving nothing about the race, so the workers are real threads,
# run through `komira_fork_join`.
from komira_fork_join import ForkJoinBody, fork_join
from komira_atomic_alias import AtomicI64

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

from komira_op_sources.batch_morsel_source import BatchMorselSource
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_source import MorselSourceImpl


# =============================================================================
# Helpers
# =============================================================================


def _build_int64_batch(var values: List[Int64]) raises -> RecordBatch:
    """Build a single-column INT64 RecordBatch from `values`.

    Mirrors the helper in test_parquet_collect_sink.mojo so tests across
    the engine package produce identical fixture shapes.
    """
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
    """Build an n-row INT64 batch with values [0, n)."""
    var vs = List[Int64]()
    for i in range(n):
        vs.append(Int64(i))
    return _build_int64_batch(vs^)


# =============================================================================
# Generic driver -- proves BatchMorselSource monomorphizes cleanly as
# MorselSourceImpl (same pattern as test_mock_source.drive_source).
# =============================================================================


def drive_source[S: MorselSourceImpl](var source: S, n_pulls: Int) raises -> Int:
    var src = source^
    var got = 0
    for _ in range(n_pulls):
        var m = src.next_morsel(0)
        if m:
            got += 1
        _ = m^
    return got


# =============================================================================
# Test 1: single-threaded drain -- visit all morsels, then EOF
# =============================================================================


def test_single_thread_drain() raises:
    var batch = _range_batch(1000)
    # morsel_rows = 300 -> ceil(1000/300) = 4 morsels of sizes 300,300,300,100
    var src = BatchMorselSource(batch^, morsel_rows=300)

    if src.partition_hint() != 4:
        raise "partition_hint expected 4, got " + String(src.partition_hint())
    if src.row_count_hint() != 1000:
        raise "row_count_hint expected 1000, got " + String(src.row_count_hint())

    var total_rows = 0
    var pulls = 0
    while True:
        var opt = src.next_morsel(0)
        if not opt:
            break
        total_rows += opt.value().num_rows()
        pulls += 1

    if pulls != 4:
        raise "expected 4 non-None pulls, got " + String(pulls)
    if total_rows != 1000:
        raise "expected total_rows 1000, got " + String(total_rows)

    print("test_single_thread_drain OK")


# =============================================================================
# Test 2: multi-worker concurrent pull -- every morsel delivered once
# =============================================================================


struct _PullAccum:
    """Shared row and pull counters.

    Both are Atomic, so every worker adds to them without a lock and the
    driver can assert the global invariant after the join barrier.
    """

    var total_rows: AtomicI64
    var total_pulls: AtomicI64

    def __init__(out self):
        self.total_rows = AtomicI64(0)
        self.total_pulls = AtomicI64(0)


struct _DrainBody[so: MutOrigin, ao: MutOrigin](ForkJoinBody):
    """One worker: drain the shared source until EOF.

    The source and the accumulator are shared by safe pointers; every mutation
    of the source's cursor is atomic, and so is every accumulator update.
    `fork_join` joins every thread before it returns, so both outlive the
    workers.
    """

    var src: Pointer[BatchMorselSource, Self.so]
    var accum: Pointer[_PullAccum, Self.ao]

    def __init__(
        out self,
        src: Pointer[BatchMorselSource, Self.so],
        accum: Pointer[_PullAccum, Self.ao],
    ):
        self.src = src
        self.accum = accum

    def run(self, tid: Int) raises:
        # Drains until EOF. The atomic cursor + single-pass contract means
        # every worker converges to None eventually.
        while True:
            var opt = self.src[].next_morsel(tid)
            if not opt:
                break
            _ = self.accum[].total_rows.fetch_add(Int64(opt.value().num_rows()))
            _ = self.accum[].total_pulls.fetch_add(Int64(1))


def test_concurrent_pull() raises:
    var batch = _range_batch(10_000)
    # morsel_rows = 256 -> 40 morsels (last one short)
    var src = BatchMorselSource(batch^, morsel_rows=256)

    var expected_morsels = src.partition_hint()  # 40
    if expected_morsels != 40:
        raise "setup check: expected 40 morsels, got " + String(expected_morsels)

    var accum = _PullAccum()

    # 8 workers is overkill for 40 morsels; chosen to force contention
    # on the atomic cursor (every claim lands on a distinct slot, but
    # the contention proves fetch_add serializes correctly).
    comptime N_PULL_WORKERS: Int = 8
    var body = _DrainBody(Pointer(to=src), Pointer(to=accum))
    fork_join(body, N_PULL_WORKERS)

    var got_rows = Int(accum.total_rows.load())
    var got_pulls = Int(accum.total_pulls.load())

    if got_rows != 10_000:
        raise "concurrent: expected total_rows 10000, got " + String(got_rows)
    if got_pulls != 40:
        raise "concurrent: expected 40 total pulls, got " + String(got_pulls)

    print("test_concurrent_pull OK")


# =============================================================================
# Test 3: EOF stability -- repeated pulls after exhaustion stay None
# =============================================================================


def test_eof_stable() raises:
    var batch = _range_batch(10)
    var src = BatchMorselSource(batch^, morsel_rows=10)  # 1 morsel
    _ = src.next_morsel(0)  # take the only morsel
    for _ in range(5):
        var opt = src.next_morsel(0)
        if opt:
            raise "EOF stability: expected None after drain, got a morsel"
    print("test_eof_stable OK")


# =============================================================================
# Test 4: capabilities default (Phase 5a: all False)
# =============================================================================


def test_capabilities_default() raises:
    var batch = _range_batch(4)
    var src = BatchMorselSource(batch^, morsel_rows=2)
    var caps = src.capabilities()
    if caps.supports_projection:
        raise "Phase 5a: supports_projection must be False"
    if caps.supports_decode_filter:
        raise "Phase 5a: supports_decode_filter must be False"
    if caps.supports_dict_preservation:
        raise "Phase 5a: supports_dict_preservation must be False"
    if caps.supports_dynamic_filter:
        raise "Phase 5a: supports_dynamic_filter must be False"
    if caps.supports_row_group_pruning:
        raise "Phase 5a: supports_row_group_pruning must be False"
    if caps.supports_bypass_columns:
        raise "Phase 5a: supports_bypass_columns must be False"
    if caps.supports_as_source:
        raise "Phase 5a: supports_as_source must be False (lands in 5c/5d)"
    print("test_capabilities_default OK")


# =============================================================================
# Test 5: output_schema mirrors input schema field list
# =============================================================================


def test_output_schema() raises:
    var batch = _range_batch(8)
    var src = BatchMorselSource(batch^, morsel_rows=4)
    var schema = src.output_schema()
    if schema.num_columns() != 1:
        raise "output_schema: expected 1 column, got " + String(schema.num_columns())
    if schema.field_name(0) != "v":
        raise "output_schema: expected field 'v', got " + schema.field_name(0)
    if schema.field_arrow_type(0) != ArrowType.INT64:
        raise "output_schema: expected INT64 field type"
    print("test_output_schema OK")


# =============================================================================
# Test 6: generic monomorphization gate
# =============================================================================


def test_monomorphization() raises:
    var batch = _range_batch(50)
    var src = BatchMorselSource(batch^, morsel_rows=20)  # 3 morsels
    var got = drive_source(src^, 10)  # 3 valid pulls, 7 None -> got == 3
    if got != 3:
        raise "generic driver: expected 3 non-None pulls, got " + String(got)
    print("test_monomorphization OK")


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    test_single_thread_drain()
    test_concurrent_pull()
    test_eof_stable()
    test_capabilities_default()
    test_output_schema()
    test_monomorphization()
    print("All BatchMorselSource (Phase 5a) tests PASS")
