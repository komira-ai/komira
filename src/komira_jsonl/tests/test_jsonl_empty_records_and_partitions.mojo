# =============================================================================
# test_jsonl_empty_records_and_partitions.mojo -- one empty record per `{}`
# line; the with-partitions parallel materializer
# =============================================================================
#
# What each test catches:
#   - test_empty_objects_inferred: `infer_jsonl_schema` on `{}` lines gives
#     a zero-column schema. The defect: the batch builder's zero-column
#     branch returned 0 rows, so every `{}` record was dropped silently.
#     Now each `{}` line is one empty record (1 row for `{}`, 2 for
#     `{}\n{}`, blank lines still skipped).
#   - test_zero_column_schema_counts_rows: a given schema with no fields
#     over non-empty objects reads one row per object.
#   - test_zero_column_parallel_and_streaming: the same through the
#     parallel materializer and the streaming reader, whose per-partition
#     and per-chunk batches are concatenated (the concat summed nothing for
#     zero-column batches).
#   - test_zero_column_with_partitions: the with-partitions materializer
#     over a zero-field schema reads one row per object across its
#     partitions (the third caller of the same part concat).
#   - test_with_partitions: `materialize_jsonl_to_batch_parallel_with_partitions`
#     fed the partitions and per-partition indices of
#     `infer_jsonl_schema_parallel_into` reads every row in order, and an
#     error in a later partition names its line in the file (dropping the
#     bytes before the partition would number it within the partition).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Schema, SchemaBuilder, Field

from komira_json_index.structural_index import JsonlPartitions, StructuralIndex
from komira_jsonl.columnar_materializer import (
    materialize_jsonl_to_batch,
    materialize_jsonl_to_batch_parallel,
    materialize_jsonl_to_batch_parallel_with_partitions,
)
from komira_jsonl.schema_inference import (
    infer_jsonl_schema,
    infer_jsonl_schema_parallel_into,
)
from komira_jsonl.streaming_source import read_jsonl_streamed_to_one_batch
from komira_runtime_paths import test_tmpdir


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _no_fields() -> Schema:
    var sb = SchemaBuilder()
    return sb.build()


def _rows_inferred(text: String) raises -> Int:
    var b = _bytes_of(text)
    var schema = infer_jsonl_schema(Span(b))
    assert_equal(schema.num_columns(), 0, "schema of " + text)
    var batch = materialize_jsonl_to_batch(Span(b), schema^)
    assert_equal(batch.num_columns(), 0)
    return batch.num_rows()


def test_empty_objects_inferred() raises:
    print("T1: one empty record per {} line")
    assert_equal(_rows_inferred(String("{}")), 1)
    assert_equal(_rows_inferred(String("{}\n")), 1)
    assert_equal(_rows_inferred(String("{}\n{}")), 2)
    assert_equal(_rows_inferred(String("{}\n\n { } \n{}\n")), 3)
    assert_equal(_rows_inferred(String("")), 0)


def test_zero_column_schema_counts_rows() raises:
    print("T2: a zero-field schema reads one row per object")
    var b = _bytes_of(String('{"x":1}\n{"y":[2,{"q":3}]}\n\n{"z":{}}\n'))
    var batch = materialize_jsonl_to_batch(Span(b), _no_fields())
    assert_equal(batch.num_columns(), 0)
    assert_equal(batch.num_rows(), 3)


def _big(n_rows: Int, bad_row: Int, bad: String) -> String:
    var b = String("")
    for i in range(n_rows):
        if i == bad_row:
            b += bad + "\n"
        else:
            b += '{"a":' + String(i) + ',"pad":"' + String(i * 7919) + '"}\n'
    return b^


def test_zero_column_parallel_and_streaming() raises:
    print("T3: zero-column rows survive the partition and chunk concat")
    var n = 150000
    var b = _bytes_of(_big(n, -1, String("")))
    assert_true(len(b) > 4 * 1024 * 1024)
    var par = materialize_jsonl_to_batch_parallel(Span(b), _no_fields(), 8)
    assert_equal(par.num_rows(), n, "parallel")
    assert_equal(par.num_columns(), 0, "parallel")
    assert_equal(par.schema.num_columns(), 0, "parallel")
    var path = test_tmpdir() + "/zero_cols.jsonl"
    with open(path, "w") as f:
        f.write(_big(1000, -1, String("")))
    var st = read_jsonl_streamed_to_one_batch(path, _no_fields(), 256)
    assert_equal(st.num_rows(), 1000, "streaming")
    assert_equal(st.num_columns(), 0, "streaming")


def _partitions_of(b: List[UInt8], mut schema_out: Schema) raises -> JsonlPartitions:
    var parts = JsonlPartitions(List[Int](), List[Int](), List[StructuralIndex]())
    schema_out = infer_jsonl_schema_parallel_into(Span(b), parts, 8)
    return parts^


def test_zero_column_with_partitions() raises:
    print("T5: zero-column rows survive the with-partitions concat")
    var n = 150000
    var b = _bytes_of(_big(n, -1, String("")))
    var inferred = Schema()
    var parts = _partitions_of(b, inferred)
    assert_true(len(parts.indices) > 1, "the input must split into partitions")
    var batch = materialize_jsonl_to_batch_parallel_with_partitions(
        Span(b), _no_fields(), parts^
    )
    assert_equal(batch.num_columns(), 0)
    assert_equal(batch.num_rows(), n)


def test_with_partitions() raises:
    print("T4: the with-partitions materializer")
    var n = 150000
    var b = _bytes_of(_big(n, -1, String("")))
    var schema = Schema()
    var parts = _partitions_of(b, schema)
    assert_true(len(parts.indices) > 1, "the input must split into partitions")
    var batch = materialize_jsonl_to_batch_parallel_with_partitions(Span(b), schema^, parts^)
    assert_equal(batch.num_rows(), n)
    var ids = batch.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(ids.get(0)), 0)
    assert_equal(Int(ids.get(n // 2)), n // 2)
    assert_equal(Int(ids.get(n - 1)), n - 1)
    # A non-object line in the last partition (inference skips it; the read
    # refuses it) is named by its line in the file.
    var bad = _bytes_of(_big(n, 145000, String("[145000]")))
    var schema2 = Schema()
    var parts2 = _partitions_of(bad, schema2)
    assert_true(len(parts2.indices) > 1, "the input must split into partitions")
    var msg = String()
    try:
        var out = materialize_jsonl_to_batch_parallel_with_partitions(Span(bad), schema2^, parts2^)
        _ = out^
    except e:
        msg = String(e)
    assert_true("line 145001:" in msg and "not a JSON object" in msg, "with-partitions: " + msg)


def main() raises:
    print("test_jsonl_empty_records_and_partitions")
    var failed = 0
    try:
        test_empty_objects_inferred()
    except e:
        print("FAIL T1:", e)
        failed += 1
    try:
        test_zero_column_schema_counts_rows()
    except e:
        print("FAIL T2:", e)
        failed += 1
    try:
        test_zero_column_parallel_and_streaming()
    except e:
        print("FAIL T3:", e)
        failed += 1
    try:
        test_with_partitions()
    except e:
        print("FAIL T4:", e)
        failed += 1
    try:
        test_zero_column_with_partitions()
    except e:
        print("FAIL T5:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("test_jsonl_empty_records_and_partitions: PASSED")
