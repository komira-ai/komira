# =============================================================================
# Line-range parallel materializer regression tests.
# =============================================================================
#
# Guards `materialize_jsonl_to_batch_parallel` (columnar_materializer.mojo):
#   - Partition boundary logic (`_compute_jsonl_line_ranges`): correct
#     `\n`-anchored half-open ranges, full coverage, empty-partition merge,
#     non-`\n`-terminated file.
#   - Byte-identical equivalence: the parallel path produces row-for-row
#     identical output to the single-thread `materialize_jsonl_to_batch`
#     over the SAME bytes + schema, across worker counts.
#
# The parallel path falls back to single-thread below
# `_MIN_PARALLEL_JSONL_BYTES` (4 MiB), so the equivalence test builds a
# >4 MiB synthetic JSONL stream to actually exercise the fork-join +
# concat path. The boundary-logic tests call the partition helper directly
# on small inputs.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_jsonl.columnar_materializer import (
    materialize_jsonl_to_batch,
    materialize_jsonl_to_batch_parallel,
    _compute_jsonl_line_ranges,
)
from komira_jsonl.schema_inference import (
    infer_jsonl_schema,
    infer_jsonl_schema_parallel,
)


def _three_col_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("id"), ArrowType.INT64, True))
    sb.add_field(Field(String("name"), ArrowType.STRING, True))
    sb.add_field(Field(String("active"), ArrowType.BOOL, True))
    return sb.build()


# =============================================================================
# Test 1 — partition boundary logic (the disjointness key).
# =============================================================================


def test_partition_ranges_newline_anchored() raises:
    """`_compute_jsonl_line_ranges` produces `\\n`-anchored half-open ranges
    that fully cover the input with no record straddling a boundary."""
    print("T1: partition boundary logic")

    # 8 records, each 8 bytes incl trailing '\n': "{\"a\":N}\n"
    var input = String(
        '{"a":0}\n{"a":1}\n{"a":2}\n{"a":3}\n'
        + '{"a":4}\n{"a":5}\n{"a":6}\n{"a":7}\n'
    )
    var bytes = input.as_bytes()
    var n = len(bytes)
    assert_equal(n, 64)

    var los = List[Int]()
    var his = List[Int]()
    _compute_jsonl_line_ranges(bytes, n, 4, los, his)
    var k = len(los)
    assert_true(k >= 1)
    assert_equal(len(los), len(his))

    # Coverage: first lo is 0, last hi is n, contiguous.
    assert_equal(los[0], 0)
    assert_equal(his[k - 1], n)
    for w in range(k - 1):
        assert_equal(his[w], los[w + 1])
    # Every partition start (after partition 0) sits immediately after a
    # '\n' (byte before lo is 0x0A) — no record straddles a boundary.
    for w in range(1, k):
        assert_equal(Int(bytes[los[w] - 1]), 0x0A)


def test_partition_ranges_no_interior_newline() raises:
    """A single record (no interior `\\n`) collapses to one partition."""
    print("T2: single-record collapse")
    var input = String('{"a":1}\n')
    var bytes = input.as_bytes()
    var los = List[Int]()
    var his = List[Int]()
    _compute_jsonl_line_ranges(bytes, len(bytes), 8, los, his)
    assert_equal(len(los), 1)
    assert_equal(los[0], 0)
    assert_equal(his[0], len(bytes))


def test_partition_ranges_not_newline_terminated() raises:
    """A file NOT ending in `\\n` still has its final bytes covered by the
    last partition's `hi == n`."""
    print("T3: non-newline-terminated coverage")
    # 3 records; last has NO trailing '\n'.
    var input = String('{"a":1}\n{"a":2}\n{"a":3}')
    var bytes = input.as_bytes()
    var n = len(bytes)
    var los = List[Int]()
    var his = List[Int]()
    _compute_jsonl_line_ranges(bytes, n, 3, los, his)
    var k = len(los)
    # Last partition reaches EOF so the final un-terminated record is
    # included.
    assert_equal(his[k - 1], n)
    assert_equal(los[0], 0)


# =============================================================================
# Test 4 — byte-identical equivalence (single-thread vs parallel).
# =============================================================================


def _assert_batches_equal(
    ref expected: RecordBatch, ref actual: RecordBatch
) raises:
    assert_equal(actual._num_rows, expected._num_rows)
    assert_equal(actual.num_columns(), expected.num_columns())

    # Col 0 INT64 id.
    var ea = expected.column_at(0).as_primitive[DType.int64]()
    var aa = actual.column_at(0).as_primitive[DType.int64]()
    for r in range(expected._num_rows):
        assert_equal(Int(aa.get(r)), Int(ea.get(r)))

    # Col 1 STRING name.
    var es = expected.column_at(1).as_string()
    var as_ = actual.column_at(1).as_string()
    for r in range(expected._num_rows):
        assert_equal(String(as_.get(r)), String(es.get(r)))

    # Col 2 BOOL active.
    var eb = expected.column_at(2).as_boolean()
    var ab = actual.column_at(2).as_boolean()
    for r in range(expected._num_rows):
        assert_equal(ab.get(r), eb.get(r))


def test_parallel_equals_single_thread() raises:
    """Over a >4 MiB stream (so the parallel fork-join + concat actually
    runs), the parallel path is row-for-row identical to single-thread."""
    print("T4: parallel == single-thread (multi-partition)")

    # Build a >4 MiB JSONL stream: each record is ~32 bytes; ~150k records
    # gives ~4.8 MiB. Distinct id per row so cross-partition ordering is
    # verifiable; alternating bool; distinct names.
    var b = String("")
    var n_rows = 150000
    for i in range(n_rows):
        var act = "true" if (i % 2 == 0) else "false"
        b += '{"id":' + String(i) + ',"name":"row' + String(i) + '","active":' + act + '}\n'
    var input = b
    var bytes = input.as_bytes()
    assert_true(len(bytes) > 4 * 1024 * 1024)

    var single = materialize_jsonl_to_batch(bytes, _three_col_schema())
    # Force a multi-worker run.
    var par = materialize_jsonl_to_batch_parallel(
        bytes, _three_col_schema(), 8
    )

    assert_equal(single._num_rows, n_rows)
    _assert_batches_equal(single, par)

    # Spot-check ordering is preserved across partition boundaries: first,
    # a mid-file row, and last.
    var par_id = par.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(par_id.get(0)), 0)
    assert_equal(Int(par_id.get(n_rows // 2)), n_rows // 2)
    assert_equal(Int(par_id.get(n_rows - 1)), n_rows - 1)


def test_parallel_inference_equals_serial() raises:
    """Over a >4 MiB stream, `infer_jsonl_schema_parallel` produces a
    byte-identical Schema (same field names, order, and Arrow types) to the
    serial `infer_jsonl_schema`. Exercises the line-range partial-schema
    lattice merge."""
    print("T5: parallel inference == serial inference")

    # >4 MiB stream with mixed types: int id, string name, bool flag, AND a
    # float that only APPEARS on rows >50% of the file — verifies the
    # cross-partition lattice merge (int→float promotion across slices) and
    # late-appearing columns get the right insertion position.
    var b = String("")
    var n_rows = 160000
    for i in range(n_rows):
        var flag = "true" if (i % 3 == 0) else "false"
        b += '{"id":' + String(i) + ',"name":"r' + String(i) + '","flag":' + flag
        # `score` is an int in the first half, a float in the second half —
        # the merge must promote the column to FLOAT64.
        if i < n_rows // 2:
            b += ',"score":' + String(i % 100) + '}\n'
        else:
            b += ',"score":' + String(i % 100) + '.5}\n'
    var input = b
    var bytes = input.as_bytes()
    assert_true(len(bytes) > 4 * 1024 * 1024)

    var serial = infer_jsonl_schema(bytes)
    var par = infer_jsonl_schema_parallel(bytes, 8)

    assert_equal(par.num_columns(), serial.num_columns())
    for c in range(serial.num_columns()):
        assert_equal(
            String(par.field_name(c)), String(serial.field_name(c))
        )
        assert_true(par.field_arrow_type(c) == serial.field_arrow_type(c))


def main() raises:
    print("test_read_json_parallel — parallel materializer suite")
    test_partition_ranges_newline_anchored()
    test_partition_ranges_no_interior_newline()
    test_partition_ranges_not_newline_terminated()
    test_parallel_equals_single_thread()
    test_parallel_inference_equals_serial()
    print("test_read_json_parallel — all tests PASSED")
