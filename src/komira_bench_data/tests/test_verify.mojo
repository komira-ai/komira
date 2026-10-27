# The verifier, on real files in the test's scratch directory.
#
#   * test_sha256_of_file_matches_known_digests: "abc" and the empty file give
#     the published SHA-256 values.
#   * test_sha256_of_file_streams_across_chunk_boundaries: files of exactly one
#     chunk, one chunk plus a byte and two chunks and a half hash to the
#     one-shot digest of the same bytes (no byte dropped or counted twice at a
#     chunk edge).
#   * test_a_file_with_matching_size_and_checksum_is_verified.
#   * test_a_missing_file_and_a_directory_are_missing.
#   * test_a_truncated_file_fails_on_size_and_is_not_hashed.
#   * test_a_changed_byte_fails_on_checksum: same size, one byte flipped.
#   * test_unrecorded_values_are_reported_not_failed: present files with no
#     recorded size or checksum are usable but never verified, and the report
#     carries the observed values to record.
#   * test_a_recorded_checksum_without_a_size_still_gates.
#   * test_the_summary_counts_and_the_text: counts per status and the rendered
#     lines.
#   * test_arguments_are_checked: an empty cache directory, a path that would
#     leave the directory, and a trailing slash on the directory.
from std.os import makedirs
from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_crypto import sha256, hex_lower_array_32
from komira_runtime_paths import test_tmpdir

from komira_bench_data import (
    DatasetFile,
    DatasetManifest,
    FILE_MISSING,
    FILE_SHA_MISMATCH,
    FILE_SIZE_MISMATCH,
    FILE_UNRECORDED,
    FILE_VERIFIED,
    UNRECORDED_BYTES,
    UNRECORDED_ROWS,
    sha256_of_file,
    verify_dataset,
)

comptime _CHUNK: Int = 4 * 1024 * 1024
comptime _ABC: String = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
comptime _EMPTY: String = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


def _dir(name: String) raises -> String:
    var d = test_tmpdir() + "/verify_" + name
    makedirs(d, exist_ok=True)
    return d^


def _pattern(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((i * 31 + i // 251) % 256))
    return out^


def _put(dir: String, name: String, data: List[UInt8]) raises:
    Path(dir + "/" + name).write_bytes(Span(data))


def _hex(data: List[UInt8]) -> String:
    return hex_lower_array_32(sha256(Span(data)))


def _manifest(var files: List[DatasetFile]) -> DatasetManifest:
    return DatasetManifest(String("tpch"), String("sf1"), String(), files^)


def _file(path: String, size: Int, sha: String) -> DatasetFile:
    return DatasetFile(path.copy(), size, sha.copy(), UNRECORDED_ROWS)


def test_sha256_of_file_matches_known_digests() raises:
    var d = _dir("known")
    _put(d, "abc", List[UInt8]("abc".as_bytes()))
    _put(d, "empty", List[UInt8]())
    assert_equal(sha256_of_file(d + "/abc"), _ABC)
    assert_equal(sha256_of_file(d + "/empty"), _EMPTY)
    with assert_raises():
        _ = sha256_of_file(d + "/absent")


def test_sha256_of_file_streams_across_chunk_boundaries() raises:
    var d = _dir("chunks")
    var sizes: List[Int] = [_CHUNK, _CHUNK + 1, 2 * _CHUNK + _CHUNK // 2, _CHUNK - 1]
    for i in range(len(sizes)):
        var data = _pattern(sizes[i])
        var name = "f" + String(i)
        _put(d, name, data)
        assert_equal(sha256_of_file(d + "/" + name), _hex(data), "size " + String(sizes[i]))


def test_a_file_with_matching_size_and_checksum_is_verified() raises:
    var d = _dir("ok")
    var data = _pattern(1000)
    _put(d, "a.parquet", data)
    var files = List[DatasetFile]()
    files.append(_file("a.parquet", 1000, _hex(data)))
    var report = verify_dataset(_manifest(files^), d)
    assert_equal(len(report.checks), 1)
    assert_equal(report.checks[0].status, FILE_VERIFIED)
    assert_equal(report.checks[0].observed_bytes, 1000)
    assert_equal(report.checks[0].observed_sha256, _hex(data))
    assert_true(report.is_verified())
    assert_true(report.is_usable())


def test_a_missing_file_and_a_directory_are_missing() raises:
    var d = _dir("missing")
    makedirs(d + "/sub.parquet", exist_ok=True)
    var files = List[DatasetFile]()
    files.append(_file("gone.parquet", 5, _ABC))
    files.append(_file("sub.parquet", 5, _ABC))
    var report = verify_dataset(_manifest(files^), d)
    assert_equal(report.checks[0].status, FILE_MISSING)
    assert_equal(report.checks[0].observed_bytes, -1)
    assert_equal(report.checks[1].status, FILE_MISSING)
    assert_false(report.is_usable())
    assert_false(report.is_verified())


def test_a_truncated_file_fails_on_size_and_is_not_hashed() raises:
    var d = _dir("truncated")
    var data = _pattern(1000)
    var want = _hex(data)
    var cut = List[UInt8]()
    for i in range(999):
        cut.append(data[i])
    _put(d, "a.parquet", cut)
    var files = List[DatasetFile]()
    files.append(_file("a.parquet", 1000, want))
    var report = verify_dataset(_manifest(files^), d)
    assert_equal(report.checks[0].status, FILE_SIZE_MISMATCH)
    assert_equal(report.checks[0].observed_bytes, 999)
    assert_equal(report.checks[0].observed_sha256, "")
    assert_false(report.is_usable())


def test_a_changed_byte_fails_on_checksum() raises:
    var d = _dir("flipped")
    var data = _pattern(1000)
    var want = _hex(data)
    data[500] = data[500] ^ 1
    _put(d, "a.parquet", data)
    var files = List[DatasetFile]()
    files.append(_file("a.parquet", 1000, want))
    var report = verify_dataset(_manifest(files^), d)
    assert_equal(report.checks[0].status, FILE_SHA_MISMATCH)
    assert_equal(report.checks[0].observed_sha256, _hex(data))
    assert_true(report.checks[0].observed_sha256 != want)
    assert_false(report.is_usable())


def test_unrecorded_values_are_reported_not_failed() raises:
    var d = _dir("unrecorded")
    var data = _pattern(321)
    _put(d, "a.parquet", data)
    _put(d, "b.parquet", data)
    var files = List[DatasetFile]()
    files.append(DatasetFile.unrecorded(String("a.parquet"), 7))
    files.append(_file("b.parquet", 321, String()))
    var report = verify_dataset(_manifest(files^), d)
    for i in range(2):
        assert_equal(report.checks[i].status, FILE_UNRECORDED)
        assert_equal(report.checks[i].observed_bytes, 321)
        assert_equal(report.checks[i].observed_sha256, _hex(data))
    assert_true(report.is_usable())
    assert_false(report.is_verified())


def test_a_recorded_checksum_without_a_size_still_gates() raises:
    var d = _dir("sha_only")
    var data = _pattern(64)
    _put(d, "a.parquet", data)
    _put(d, "b.parquet", data)
    var files = List[DatasetFile]()
    files.append(_file("a.parquet", UNRECORDED_BYTES, _hex(data)))
    files.append(_file("b.parquet", UNRECORDED_BYTES, _ABC))
    var report = verify_dataset(_manifest(files^), d)
    assert_equal(report.checks[0].status, FILE_UNRECORDED)
    assert_equal(report.checks[1].status, FILE_SHA_MISMATCH)
    assert_false(report.is_usable())


def test_the_summary_counts_and_the_text() raises:
    var d = _dir("summary")
    var data = _pattern(10)
    _put(d, "ok.parquet", data)
    _put(d, "new.parquet", data)
    var files = List[DatasetFile]()
    files.append(_file("ok.parquet", 10, _hex(data)))
    files.append(DatasetFile.unrecorded(String("new.parquet"), UNRECORDED_ROWS))
    files.append(_file("gone.parquet", 10, _hex(data)))
    var report = verify_dataset(_manifest(files^), d)
    assert_equal(report.count(FILE_VERIFIED), 1)
    assert_equal(report.count(FILE_UNRECORDED), 1)
    assert_equal(report.count(FILE_MISSING), 1)
    var text = report.render()
    assert_true(text.find("VERIFIED 10 ok.parquet\n") >= 0, text)
    assert_true(text.find("UNRECORDED 10 new.parquet\n") >= 0, text)
    assert_true(text.find("MISSING -1 gone.parquet\n") >= 0, text)
    assert_true(text.find("3 files: 1 verified, 1 unrecorded, 1 failed\n") >= 0, text)


def test_arguments_are_checked() raises:
    var d = _dir("args")
    var data = _pattern(10)
    _put(d, "a.parquet", data)
    var files = List[DatasetFile]()
    files.append(_file("a.parquet", 10, _hex(data)))
    var m = _manifest(files^)
    with assert_raises(contains="cache directory is empty"):
        _ = verify_dataset(m, String(""))
    var slash = verify_dataset(m, d + "/")
    assert_true(slash.is_verified())

    var escape = List[DatasetFile]()
    escape.append(_file("../a.parquet", 10, _hex(data)))
    with assert_raises(contains="dataset path"):
        _ = verify_dataset(_manifest(escape^), d)


def main() raises:
    test_sha256_of_file_matches_known_digests()
    test_sha256_of_file_streams_across_chunk_boundaries()
    test_a_file_with_matching_size_and_checksum_is_verified()
    test_a_missing_file_and_a_directory_are_missing()
    test_a_truncated_file_fails_on_size_and_is_not_hashed()
    test_a_changed_byte_fails_on_checksum()
    test_unrecorded_values_are_reported_not_failed()
    test_a_recorded_checksum_without_a_size_still_gates()
    test_the_summary_counts_and_the_text()
    test_arguments_are_checked()
    print("OK")
