# =============================================================================
# JSONL corpus walk: Stage 1 and Stage 2 over whole files.
# =============================================================================
#
# Each fixture under tests/fixtures/jsonl_corpus/ has one of the shapes of
# the newline-delimited files in the simdjson-data corpus:
#   - mixed_objects.jsonl: a pretty-printed object spanning lines 1-6, a
#     top-level `null` on line 7, then three flat objects with nested
#     arrays and non-ASCII strings (lines 8-10).
#   - array_lines.jsonl: one top-level array per line, then an empty line.
#   - array_rows_wide.jsonl: a header array and 400 array rows carrying
#     escapes, `\/`, non-ASCII text, nulls and nested arrays.
#
# For each file the test asserts that Stage 1 (`build_structural_index`)
# succeeds. Stage 2 (`materialize_jsonl_to_batch`) reads JSONL, one object
# per line, so it refuses each whole file naming its first bad line: line 1
# of mixed_objects (the object does not end on its line) and line 1 of the
# array files (not an object); before the fix these returned 4, 0 and 0
# rows without an error. The three flat objects of mixed_objects, read on
# their own, are three rows with every `player` set, and a key absent from
# every record is an all-null column. The fixtures are declared as test
# data and opened by their repository path from the test's working
# directory.
# =============================================================================

from std.io import FileHandle
from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_json_index.structural_index import build_structural_index


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


def _refused(name: String, line: Int, word: String) raises:
    """Stage 1 then Stage 2 over one fixture: Stage 1 succeeds, Stage 2
    raises naming `line` and saying `word`."""
    var path = String(_FIXTURES) + name
    var bytes = _read_file_bytes(path)
    if len(bytes) == 0:
        raise Error("fixture is empty: " + path)
    var idx = build_structural_index(bytes)
    _ = idx
    var msg = String()
    var refused = False
    try:
        var batch = materialize_jsonl_to_batch(
            bytes, _schema_one(String("_phantom_key"))
        )
        _ = batch^
    except e:
        refused = True
        msg = String(e)
    assert_true(refused, name + ": not refused")
    var want = String("line ") + String(line) + ":"
    assert_true(want in msg, name + ": " + msg)
    assert_true(word in msg, name + ": " + msg)
    print("  OK", name, "bytes=", len(bytes), "refused:", msg)


def test_mixed_objects() raises:
    _refused(String("mixed_objects.jsonl"), 1, "does not end on its line")
    # Lines 8-10, the three flat objects, read on their own.
    var bytes = _read_file_bytes(String(_FIXTURES) + "mixed_objects.jsonl")
    var lf = 0
    var start = 0
    for i in range(len(bytes)):
        if bytes[i] == UInt8(0x0A):
            lf += 1
            if lf == 7:
                start = i + 1
                break
    var tail = Span(bytes)[start:]
    var batch = materialize_jsonl_to_batch(tail, _schema_one(String("player")))
    assert_equal(batch._num_rows, 3)
    assert_equal(batch.column_at(0).null_count(), 0)
    var phantom = materialize_jsonl_to_batch(
        tail, _schema_one(String("_phantom_key"))
    )
    assert_equal(phantom._num_rows, 3)
    assert_equal(phantom.column_at(0).null_count(), 3)


def test_array_lines() raises:
    _refused(String("array_lines.jsonl"), 1, "not a JSON object")


def test_array_rows_wide() raises:
    _refused(String("array_rows_wide.jsonl"), 1, "not a JSON object")


def main() raises:
    print("test_simdjson_corpus: JSONL corpus walk")
    test_mixed_objects()
    test_array_lines()
    test_array_rows_wide()
    print("test_simdjson_corpus: PASSED")
