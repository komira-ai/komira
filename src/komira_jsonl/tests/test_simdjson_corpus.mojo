# =============================================================================
# JSONL corpus walk: Stage 1 and Stage 2 over whole files.
# =============================================================================
#
# Each fixture under tests/fixtures/jsonl_corpus/ has one of the shapes of
# the newline-delimited files in the simdjson-data corpus:
#   - mixed_objects.jsonl: a pretty-printed object spanning several lines,
#     a top-level `null`, and flat objects with nested arrays and non-ASCII
#     strings. Stage 2 yields one row per top-level object (4).
#   - array_lines.jsonl: one top-level array per line, then an empty line.
#     Stage 2 materializes only top-level objects, so it yields 0 rows.
#   - array_rows_wide.jsonl: a header array and 400 array rows carrying
#     escapes, `\/`, non-ASCII text, nulls and nested arrays. 0 rows.
#
# For each file the test asserts that Stage 1 (`build_structural_index`)
# succeeds, that Stage 2 (`materialize_jsonl_to_batch`) returns the
# expected row count, and that a key absent from every record is an
# all-null column. The fixtures are declared as test data and opened by
# their repository path from the test's working directory.
# =============================================================================

from std.io import FileHandle
from std.testing import assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_jsonl.structural_index import build_structural_index


comptime _FIXTURES = "src/komira_jsonl/tests/fixtures/jsonl_corpus/"


def _read_file_bytes(path: String) raises -> List[UInt8]:
    """Read a file fully into a List[UInt8]."""
    var f = FileHandle(path, "r")
    _ = f.seek(0, 2)  # SEEK_END
    var file_size = Int(f.seek(0, 1))
    _ = f.seek(0, 0)  # SEEK_SET
    var raw = f.read_bytes(file_size)
    f.close()
    return raw^


def _schema_one(name: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.STRING, True))
    return sb.build()


def _walk(name: String, expected_rows: Int) raises:
    """Stage 1 then Stage 2 over one fixture, with a key that no record
    carries: the batch has `expected_rows` rows, all null."""
    var path = String(_FIXTURES) + name
    var bytes = _read_file_bytes(path)
    if len(bytes) == 0:
        raise Error("fixture is empty: " + path)
    var idx = build_structural_index(bytes)
    _ = idx
    var batch = materialize_jsonl_to_batch(
        bytes, _schema_one(String("_phantom_key"))
    )
    assert_equal(batch._num_rows, expected_rows, name + ": rows")
    assert_equal(
        batch.column_at(0).null_count(), expected_rows, name + ": nulls"
    )
    print("  OK", name, "bytes=", len(bytes), "rows=", batch._num_rows)


def test_mixed_objects() raises:
    _walk(String("mixed_objects.jsonl"), 4)
    # A key every object carries: 4 rows, none null.
    var bytes = _read_file_bytes(String(_FIXTURES) + "mixed_objects.jsonl")
    var batch = materialize_jsonl_to_batch(bytes, _schema_one(String("player")))
    assert_equal(batch._num_rows, 4)
    assert_equal(batch.column_at(0).null_count(), 0)


def test_array_lines() raises:
    _walk(String("array_lines.jsonl"), 0)


def test_array_rows_wide() raises:
    _walk(String("array_rows_wide.jsonl"), 0)


def main() raises:
    print("test_simdjson_corpus: JSONL corpus walk")
    test_mixed_objects()
    test_array_lines()
    test_array_rows_wide()
    print("test_simdjson_corpus: PASSED")
