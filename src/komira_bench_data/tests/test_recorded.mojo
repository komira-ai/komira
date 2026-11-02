# The recorded checksums: how a record fills a manifest and what is refused.
#
# What each test proves:
# - test_a_record_fills_size_sha_and_rows: a record for a path sets that file's
#   size, sha256 and (where the manifest did not know it) row count, leaves
#   every other file alone, and the verifier then calls a matching file
#   VERIFIED where it said UNRECORDED.
# - test_a_record_for_another_path_is_ignored: records of another dataset's
#   files change nothing.
# - test_a_malformed_or_contradicting_record_is_refused: a short or upper-case
#   sha256, a negative size, a path recorded twice, a size that differs from
#   the manifest's (ClickBench's recorded size), a row count that differs from
#   the manifest's.
# - test_the_printed_line_has_the_form_the_table_takes: the exact text of
#   `recorded_line`, with and without a row count.
# - test_every_record_belongs_to_a_supported_manifest: a record whose path is
#   in no supported manifest (a typo in a pasted line) fails here.
from std.os import makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_crypto import hex_lower_array_32, sha256
from komira_runtime_paths import test_tmpdir

from komira_bench_data import (
    DatasetFile,
    DatasetManifest,
    FILE_UNRECORDED,
    FILE_VERIFIED,
    RecordedFile,
    UNRECORDED_ROWS,
    apply_recorded,
    recorded_files,
    recorded_line,
    supported_manifests,
    verify_dataset,
)

comptime _SHA: String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def _files() -> List[DatasetFile]:
    var files = List[DatasetFile]()
    files.append(DatasetFile.unrecorded(String("tpch/sf10/region.parquet"), 5))
    files.append(DatasetFile.unrecorded(String("tpch/sf10/lineitem.parquet"), UNRECORDED_ROWS))
    return files^


def _one(path: String, bytes: Int, sha: String, rows: Int) -> List[RecordedFile]:
    var r = List[RecordedFile]()
    r.append(RecordedFile(path.copy(), bytes, sha.copy(), rows))
    return r^


def test_a_record_fills_size_sha_and_rows() raises:
    var files = _files()
    var recorded = _one(String("tpch/sf10/lineitem.parquet"), 1234, String(_SHA), 59_986_052)
    apply_recorded(files, recorded)
    assert_equal(files[1].expected_bytes, 1234)
    assert_equal(files[1].expected_sha256, String(_SHA))
    assert_equal(files[1].expected_rows, 59_986_052)
    assert_false(files[0].has_bytes())
    assert_false(files[0].has_sha256())
    assert_equal(files[0].expected_rows, 5)
    # a record without a row count keeps the manifest's
    var again = _files()
    apply_recorded(again, _one(String("tpch/sf10/region.parquet"), 99, String(_SHA), UNRECORDED_ROWS))
    assert_equal(again[0].expected_rows, 5)
    assert_equal(again[0].expected_bytes, 99)

    # the verifier now compares: the file is VERIFIED only when both match
    var dir = test_tmpdir() + "/recorded_verify"
    makedirs(dir + "/tpch/sf10", exist_ok=True)
    var content = String("region bytes")
    Path(dir + "/tpch/sf10/region.parquet").write_bytes(content.as_bytes())
    var one = List[DatasetFile]()
    one.append(DatasetFile.unrecorded(String("tpch/sf10/region.parquet"), 5))
    var before = verify_dataset(DatasetManifest(String("tpch"), String("sf10"), String(), one.copy()), dir)
    assert_equal(before.checks[0].status, FILE_UNRECORDED)
    apply_recorded(one, _one(String("tpch/sf10/region.parquet"), 12, hex_lower_array_32(sha256(content.as_bytes())), 5))
    var after = verify_dataset(DatasetManifest(String("tpch"), String("sf10"), String(), one^), dir)
    assert_equal(after.checks[0].status, FILE_VERIFIED)


def test_a_record_for_another_path_is_ignored() raises:
    var files = _files()
    apply_recorded(files, _one(String("tpch/sf1/region.parquet"), 1, String(_SHA), 5))
    assert_false(files[0].has_bytes())
    assert_false(files[1].has_sha256())


def test_a_malformed_or_contradicting_record_is_refused() raises:
    with assert_raises(contains="malformed record"):
        var f = _files()
        apply_recorded(f, _one(String("tpch/sf10/region.parquet"), 1, String("abc"), 5))
    with assert_raises(contains="malformed record"):
        var f = _files()
        apply_recorded(f, _one(String("tpch/sf10/region.parquet"), 1, String(_SHA).upper(), 5))
    with assert_raises(contains="malformed record"):
        var f = _files()
        apply_recorded(f, _one(String("tpch/sf10/region.parquet"), -1, String(_SHA), 5))
    var twice = _one(String("tpch/sf10/region.parquet"), 1, String(_SHA), 5)
    twice.append(RecordedFile(String("tpch/sf10/region.parquet"), 1, String(_SHA), 5))
    with assert_raises(contains="recorded twice"):
        var f = _files()
        apply_recorded(f, twice)
    var sized = List[DatasetFile]()
    sized.append(DatasetFile(String("clickbench/hits.parquet"), 14_779_976_446, String(), 99_997_497))
    with assert_raises(contains="size of clickbench/hits.parquet contradicts"):
        apply_recorded(sized, _one(String("clickbench/hits.parquet"), 14_779_976_447, String(_SHA), 99_997_497))
    with assert_raises(contains="row count of clickbench/hits.parquet contradicts"):
        apply_recorded(sized, _one(String("clickbench/hits.parquet"), 14_779_976_446, String(_SHA), 99_997_498))
    # the same size and rows as the manifest knows are accepted
    apply_recorded(sized, _one(String("clickbench/hits.parquet"), 14_779_976_446, String(_SHA), 99_997_497))
    assert_equal(sized[0].expected_sha256, String(_SHA))


def test_the_printed_line_has_the_form_the_table_takes() raises:
    assert_equal(
        recorded_line(String("tpch/sf1/region.parquet"), 1234, String(_SHA), 5),
        String('    out.append(RecordedFile("tpch/sf1/region.parquet", 1234, "') + String(_SHA) + String('", 5))'),
    )
    assert_equal(
        recorded_line(String("tpch/sf10/lineitem.parquet"), 7, String(_SHA), UNRECORDED_ROWS),
        String('    out.append(RecordedFile("tpch/sf10/lineitem.parquet", 7, "') + String(_SHA) + String('", -1))'),
    )


def test_every_record_belongs_to_a_supported_manifest() raises:
    var recorded = recorded_files()
    var all = supported_manifests()
    for r in range(len(recorded)):
        var found = False
        for i in range(len(all)):
            for j in range(len(all[i].files)):
                if all[i].files[j].path == recorded[r].path:
                    found = True
        assert_true(found, recorded[r].path + " is recorded but is in no supported manifest")
    # recorded_files() itself is accepted by the manifests built from it
    _ = supported_manifests()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
