# The generated files in a cache directory, and the path from generator to lock.
#
#   * test_generated_groupby_files_verify_and_lock: the group-by file lands at
#     its manifest's path with the bytes `h2o_groupby_parquet` gives; the
#     verifier finds it VERIFIED against the size and SHA-256 the returned
#     manifest records for those bytes; a lock built from the report holds them and decodes back.
#   * test_a_file_cut_short_after_generation_is_refused: the manifest the
#     generator returns records each written file's size and sha256, so a
#     truncated or altered file no longer verifies.
#   * test_generated_join_files_land_in_the_manifest_order: four files at the
#     manifest's four paths, each equal to its table's bytes.
#   * test_an_existing_dataset_is_never_regenerated: a second run raises and
#     leaves the first file's bytes as they were.
#   * test_the_same_seed_gives_the_same_fingerprint_and_another_seed_another:
#     the same seed twice (in two cache directories) gives the same lock
#     fingerprint, another seed another one.
#   * test_write_new_file_refuses_unsafe_paths: parent-directory segments,
#     absolute paths and an empty cache directory write nothing.
from std.os import makedirs
from std.os.path import exists
from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_crypto import sha256, hex_lower_array_32
from komira_runtime_paths import test_tmpdir

from komira_bench_data import (
    FILE_SHA_MISMATCH,
    FILE_SIZE_MISMATCH,
    FILE_VERIFIED,
    verify_against_lock,
    H2O_DEFAULT_SEED,
    decode_lock,
    encode_lock,
    generate_h2o_groupby_files,
    generate_h2o_join_files,
    h2o_groupby_parquet,
    h2o_join_parquet,
    h2o_join_table_names,
    lock_from_report,
    sha256_of_file,
    verify_dataset,
    write_new_file,
)

comptime _SEED: UInt64 = H2O_DEFAULT_SEED


def _dir(name: String) raises -> String:
    var d = test_tmpdir() + "/h2o_files_" + name
    makedirs(d, exist_ok=True)
    return d^


def _hex(data: List[UInt8]) -> String:
    return hex_lower_array_32(sha256(Span(data)))


def test_generated_groupby_files_verify_and_lock() raises:
    var d = _dir("groupby")
    var m = generate_h2o_groupby_files(d, 800, 8, _SEED)
    var bytes = h2o_groupby_parquet(800, 8, _SEED)
    assert_equal(sha256_of_file(d + "/" + m.files[0].path), _hex(bytes))
    var report = verify_dataset(m, d)
    assert_equal(len(report.checks), 1)
    assert_equal(report.checks[0].status, FILE_VERIFIED)
    assert_equal(report.checks[0].observed_bytes, len(bytes))
    assert_equal(report.checks[0].observed_sha256, _hex(bytes))
    var lock = lock_from_report(m, report)
    assert_equal(lock.generator, "komira-h2o-1")
    assert_equal(lock.entries[0].rows, 800)
    var back = decode_lock(encode_lock(lock))
    assert_equal(back.fingerprint(), lock.fingerprint())
    assert_equal(back.entries[0].sha256, _hex(bytes))


def test_generated_join_files_land_in_the_manifest_order() raises:
    var d = _dir("join")
    var m = generate_h2o_join_files(d, 2000, _SEED)
    var tables = h2o_join_table_names()
    assert_equal(len(m.files), 4)
    for i in range(4):
        var want = h2o_join_parquet(tables[i], 2000, _SEED)
        assert_equal(sha256_of_file(d + "/" + m.files[i].path), _hex(want), tables[i])
    var report = verify_dataset(m, d)
    assert_equal(report.count(FILE_VERIFIED), 4)
    assert_true(report.is_verified())
    for i in range(4):
        assert_equal(m.files[i].expected_sha256, _hex(h2o_join_parquet(tables[i], 2000, _SEED)))


def test_a_file_cut_short_after_generation_is_refused() raises:
    var d = _dir("cut")
    var m = generate_h2o_groupby_files(d, 800, 8, _SEED)
    var path = d + "/" + m.files[0].path
    assert_true(verify_dataset(m, d).is_verified())
    var lock = lock_from_report(m, verify_dataset(m, d))
    var bytes = h2o_groupby_parquet(800, 8, _SEED)
    var cut = List[UInt8]()
    for i in range(len(bytes) - 1):
        cut.append(bytes[i])
    Path(path).write_bytes(Span(cut))
    assert_equal(verify_dataset(m, d).checks[0].status, FILE_SIZE_MISMATCH)
    assert_equal(verify_against_lock(lock, d).checks[0].status, FILE_SIZE_MISMATCH)
    var flipped = bytes.copy()
    flipped[100] = flipped[100] ^ UInt8(1)
    Path(path).write_bytes(Span(flipped))
    assert_equal(verify_dataset(m, d).checks[0].status, FILE_SHA_MISMATCH)
    assert_equal(verify_against_lock(lock, d).checks[0].status, FILE_SHA_MISMATCH)
    Path(path).write_bytes(Span(bytes))
    assert_true(verify_against_lock(lock, d).is_verified())


def test_an_existing_dataset_is_never_regenerated() raises:
    var d = _dir("twice")
    var m = generate_h2o_groupby_files(d, 300, 3, _SEED)
    var before = sha256_of_file(d + "/" + m.files[0].path)
    with assert_raises(contains="never overwritten"):
        _ = generate_h2o_groupby_files(d, 300, 3, _SEED)
    assert_equal(sha256_of_file(d + "/" + m.files[0].path), before)


def test_the_same_seed_gives_the_same_fingerprint_and_another_seed_another() raises:
    var fps = List[String]()
    for run in range(3):
        var d = _dir("fp" + String(run))
        var seed = _SEED if run < 2 else _SEED + 1
        var m = generate_h2o_groupby_files(d, 300, 3, seed)
        fps.append(lock_from_report(m, verify_dataset(m, d)).fingerprint())
    assert_equal(len(fps), 3)
    assert_true(fps[0] == fps[1])
    assert_true(fps[0] != fps[2])


def test_write_new_file_refuses_unsafe_paths() raises:
    var d = _dir("unsafe")
    var bytes = List[UInt8]("data".as_bytes())
    with assert_raises(contains="dataset path"):
        write_new_file(d, "../escape.parquet", bytes)
    with assert_raises(contains="dataset path"):
        write_new_file(d, "/abs.parquet", bytes)
    with assert_raises(contains="dataset path"):
        write_new_file(d, "a/../../b", bytes)
    with assert_raises(contains="cache directory is empty"):
        write_new_file(String(""), "a.parquet", bytes)
    assert_false(exists(d + "/../escape.parquet"))
    write_new_file(d, "nested/dir/ok.parquet", bytes)
    assert_equal(sha256_of_file(d + "/nested/dir/ok.parquet"), _hex(bytes))
    with assert_raises(contains="never overwritten"):
        write_new_file(d, "nested/dir/ok.parquet", bytes)


def main() raises:
    test_generated_groupby_files_verify_and_lock()
    test_generated_join_files_land_in_the_manifest_order()
    test_a_file_cut_short_after_generation_is_refused()
    test_an_existing_dataset_is_never_regenerated()
    test_the_same_seed_gives_the_same_fingerprint_and_another_seed_another()
    test_write_new_file_refuses_unsafe_paths()
    print("OK")
