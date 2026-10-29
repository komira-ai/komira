# The lock file: the fingerprint of the dataset a run used.
#
#   * test_the_lock_text_and_fingerprint_are_fixed: a hand-built lock encodes to
#     exactly the documented lines, and its fingerprint is the SHA-256 of the
#     lines above it (checked against a digest computed outside the package).
#   * test_decode_inverts_encode: every field, the unrecorded row count and the
#     generator token come back.
#   * test_the_fingerprint_follows_every_field: a different size, checksum, row
#     count, path, scale, dataset, generator or file order is a different
#     fingerprint.
#   * test_an_edited_lock_is_refused: one changed digit of a size or a
#     checksum, a swapped fingerprint, a deleted file line.
#   * test_a_malformed_lock_is_refused: no final newline, extra lines, a
#     changed header word, an unknown format, a repeated path, a path that
#     leaves the directory, a short checksum, a size with a sign or a leading
#     zero, no files.
#   * test_a_lock_is_built_only_from_a_usable_report: observed values go in,
#     the manifest's row counts go in, and a missing, truncated or altered file,
#     another dataset's report or a reordered report is refused.
#   * test_the_lock_file_is_written_once_and_read_back: written to
#     `locks/<dataset>_<scale>.lock`, never replaced, read back by dataset and
#     scale.
#   * test_one_cache_directory_holds_the_locks_of_several_datasets: the locks of
#     two scales of one dataset and of another dataset are written side by side
#     and each reads back as its own; a file under another dataset's name is
#     refused.
#   * test_a_cache_directory_is_verified_against_a_lock: the files a lock names
#     verify; a missing, shortened, longer or altered file does not.
from std.os import makedirs
from std.os.path import exists
from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_runtime_paths import test_tmpdir

from komira_bench_data import (
    DatasetFile,
    DatasetLock,
    DatasetManifest,
    FILE_MISSING,
    FILE_SHA_MISMATCH,
    FILE_SIZE_MISMATCH,
    FILE_UNRECORDED,
    FILE_VERIFIED,
    FileCheck,
    LOCK_DIR_NAME,
    LOCK_FILE_SUFFIX,
    LockEntry,
    UNRECORDED_ROWS,
    VerifyReport,
    decode_lock,
    encode_lock,
    lock_file_path,
    lock_from_report,
    read_lock_file,
    verify_against_lock,
    tpch_manifest,
    write_lock_file,
)

comptime _ABC: String = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
comptime _EMPTY: String = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
comptime _FP: String = "0a8a89ba114dedb814b36559d6139b4acc1f80af3a0ee877e91632ca3a02403b"

comptime _BODY: String = (
    "komira-bench-data-lock/1\n"
    "dataset tpch\n"
    "scale sf1\n"
    "generator -\n"
    "file tpch/sf1/region.parquet 1000 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad 5\n"
    "file tpch/sf1/lineitem.parquet 2000 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 -\n"
)


def _lock(generator: String = "") -> DatasetLock:
    var entries = List[LockEntry]()
    entries.append(LockEntry(String("tpch/sf1/region.parquet"), 1000, _ABC, 5))
    entries.append(LockEntry(String("tpch/sf1/lineitem.parquet"), 2000, _EMPTY, UNRECORDED_ROWS))
    return DatasetLock(String("tpch"), String("sf1"), generator.copy(), entries^)


def _refuses(text: String, contains: String) raises:
    var refused = False
    try:
        _ = decode_lock(text)
    except e:
        refused = True
        assert_true(String(e).find(contains) >= 0, "error '" + String(e) + "' lacks '" + contains + "'")
    assert_true(refused, "accepted: " + text)



def test_the_lock_text_and_fingerprint_are_fixed() raises:
    var lock = _lock()
    assert_equal(lock.body(), _BODY)
    assert_equal(lock.fingerprint(), _FP)
    assert_equal(encode_lock(lock), _BODY + "fingerprint " + _FP + "\n")


def test_decode_inverts_encode() raises:
    var back = decode_lock(encode_lock(_lock()))
    assert_equal(back.dataset, "tpch")
    assert_equal(back.scale, "sf1")
    assert_equal(back.generator, "")
    assert_equal(len(back.entries), 2)
    assert_equal(back.entries[0].path, "tpch/sf1/region.parquet")
    assert_equal(back.entries[0].bytes, 1000)
    assert_equal(back.entries[0].sha256, _ABC)
    assert_equal(back.entries[0].rows, 5)
    assert_equal(back.entries[1].rows, UNRECORDED_ROWS)
    assert_equal(back.fingerprint(), _FP)
    var gen = decode_lock(encode_lock(_lock("komira-h2o-1")))
    assert_equal(gen.generator, "komira-h2o-1")
    assert_true(gen.fingerprint() != _FP)


def test_the_fingerprint_follows_every_field() raises:
    var base = _lock().fingerprint()
    var a = _lock()
    a.entries[0].bytes = 1001
    assert_true(a.fingerprint() != base)
    var b = _lock()
    b.entries[0].sha256 = _EMPTY
    assert_true(b.fingerprint() != base)
    var c = _lock()
    c.entries[0].rows = 6
    assert_true(c.fingerprint() != base)
    var d = _lock()
    d.entries[0].rows = UNRECORDED_ROWS
    assert_true(d.fingerprint() != base)
    var e = _lock()
    e.entries[0].path = String("tpch/sf1/region2.parquet")
    assert_true(e.fingerprint() != base)
    var f = _lock()
    f.scale = String("sf10")
    assert_true(f.fingerprint() != base)
    var g = _lock()
    g.dataset = String("tpch2")
    assert_true(g.fingerprint() != base)
    var h = _lock()
    h.generator = String("g")
    assert_true(h.fingerprint() != base)
    var i = _lock()
    var first = i.entries[0].copy()
    i.entries[0] = i.entries[1].copy()
    i.entries[1] = first^
    assert_true(i.fingerprint() != base)


def test_an_edited_lock_is_refused() raises:
    var good = encode_lock(_lock())
    _refuses(good.replace(" 1000 ", " 1001 "), "fingerprint does not match")
    _refuses(good.replace("ba7816bf", "ba7816be"), "fingerprint does not match")
    _refuses(good.replace(_FP, String("0") * 64), "fingerprint does not match")
    _refuses(good.replace("scale sf1", "scale sf2"), "fingerprint does not match")
    var no_second = _BODY.replace(
        "file tpch/sf1/lineitem.parquet 2000 " + _EMPTY + " -\n", ""
    )
    _refuses(no_second + "fingerprint " + _FP + "\n", "fingerprint does not match")


def test_a_malformed_lock_is_refused() raises:
    var good = encode_lock(_lock())
    _refuses(String(good[byte=0 : good.byte_length() - 1]), "truncated")
    _refuses("", "truncated")
    _refuses(good + "extra\n", "'file' line")
    _refuses(good.replace("komira-bench-data-lock/1", "komira-bench-data-lock/2"), "unknown format")
    _refuses(good.replace("dataset tpch", "dataset"), "'dataset' line")
    _refuses(good.replace("dataset tpch", "datasets tpch"), "'dataset' line")
    _refuses(good.replace("scale sf1", "scale sf1 sf2"), "'scale' line")
    _refuses(good.replace("generator -", "generator a/b"), "generator must be a token")
    _refuses(good.replace("tpch/sf1/lineitem.parquet", "tpch/sf1/region.parquet"), "listed twice")
    _refuses(good.replace("tpch/sf1/lineitem.parquet", "../lineitem.parquet"), "dataset path")
    _refuses(good.replace("tpch/sf1/lineitem.parquet", "/lineitem.parquet"), "dataset path")
    _refuses(good.replace(_EMPTY, "abcd"), "64 lowercase hex")
    _refuses(good.replace(" 1000 ", " +1000 "), "bad size")
    _refuses(good.replace(" 1000 ", " 01000 "), "bad size")
    _refuses(good.replace(" 1000 ", " -1 "), "bad size")
    _refuses(good.replace(" 1000 ", " 1e3 "), "bad size")
    _refuses(good.replace(" 5\n", " five\n"), "bad row count")
    _refuses(good.replace(" 5\n", " -5\n"), "bad row count")
    _refuses(good.replace("file tpch/sf1/region.parquet 1000 " + _ABC + " 5", "file tpch/sf1/region.parquet 1000"), "'file' line")
    var none = String("komira-bench-data-lock/1\ndataset tpch\nscale sf1\ngenerator -\n")
    _refuses(none + "fingerprint " + _FP + "\n", "no files")


def _report(var checks: List[FileCheck]) -> VerifyReport:
    return VerifyReport(String("tpch"), String("sf1"), checks^)


def _small_manifest() -> DatasetManifest:
    var files = List[DatasetFile]()
    files.append(DatasetFile.unrecorded(String("tpch/sf1/region.parquet"), 5))
    files.append(DatasetFile.unrecorded(String("tpch/sf1/lineitem.parquet"), UNRECORDED_ROWS))
    return DatasetManifest(String("tpch"), String("sf1"), String(), files^)


def _checks(first: Int, second: Int) -> List[FileCheck]:
    var checks = List[FileCheck]()
    checks.append(FileCheck(String("tpch/sf1/region.parquet"), first, 1000, _ABC))
    checks.append(FileCheck(String("tpch/sf1/lineitem.parquet"), second, 2000, _EMPTY))
    return checks^


def test_a_lock_is_built_only_from_a_usable_report() raises:
    var m = _small_manifest()
    var lock = lock_from_report(m, _report(_checks(FILE_VERIFIED, FILE_UNRECORDED)))
    assert_equal(lock.body(), _BODY)
    assert_equal(lock.fingerprint(), _FP)

    var bad = List[Int]()
    bad.append(FILE_MISSING)
    bad.append(FILE_SIZE_MISMATCH)
    bad.append(FILE_SHA_MISMATCH)
    for i in range(len(bad)):
        with assert_raises(contains="tpch/sf1/lineitem.parquet is "):
            _ = lock_from_report(m, _report(_checks(FILE_VERIFIED, bad[i])))
        with assert_raises(contains="tpch/sf1/region.parquet is "):
            _ = lock_from_report(m, _report(_checks(bad[i], FILE_VERIFIED)))

    with assert_raises(contains="not tpch/sf10"):
        _ = lock_from_report(tpch_manifest(10), _report(_checks(FILE_VERIFIED, FILE_VERIFIED)))
    var short = _checks(FILE_VERIFIED, FILE_VERIFIED)
    _ = short.pop()
    with assert_raises(contains="1 files, the manifest 2"):
        _ = lock_from_report(m, _report(short^))
    var swapped = List[FileCheck]()
    var two = _checks(FILE_VERIFIED, FILE_VERIFIED)
    swapped.append(two[1].copy())
    swapped.append(two[0].copy())
    with assert_raises(contains="where the manifest lists"):
        _ = lock_from_report(m, _report(swapped^))


def test_the_lock_file_is_written_once_and_read_back() raises:
    var d = test_tmpdir() + "/lock_file"
    makedirs(d, exist_ok=True)
    assert_equal(lock_file_path(d, "tpch", "sf1"), d + "/locks/tpch_sf1.lock")
    assert_equal(lock_file_path(d + "/", "tpch", "sf1"), d + "/locks/tpch_sf1.lock")
    with assert_raises():
        _ = read_lock_file(d, "tpch", "sf1")
    write_lock_file(d, _lock())
    assert_true(exists(d + "/" + LOCK_DIR_NAME + "/tpch_sf1" + LOCK_FILE_SUFFIX))
    var back = read_lock_file(d, "tpch", "sf1")
    assert_equal(back.fingerprint(), _FP)
    var other = _lock()
    other.entries[0].bytes = 1
    with assert_raises(contains="never overwritten"):
        write_lock_file(d, other)
    assert_equal(read_lock_file(d, "tpch", "sf1").fingerprint(), _FP)
    with assert_raises(contains="cache directory is empty"):
        write_lock_file(String(""), _lock())
    with assert_raises(contains="must be tokens"):
        _ = lock_file_path(d, "../tpch", "sf1")
    with assert_raises(contains="must be tokens"):
        _ = lock_file_path(d, "tpch", "")


def test_one_cache_directory_holds_the_locks_of_several_datasets() raises:
    var d = test_tmpdir() + "/lock_several"
    makedirs(d, exist_ok=True)
    var sf1 = _lock()
    var sf10 = _lock()
    sf10.scale = String("sf10")
    var other = _lock()
    other.dataset = String("clickbench")
    other.scale = String("full")
    write_lock_file(d, sf1)
    write_lock_file(d, sf10)
    write_lock_file(d, other)
    assert_equal(read_lock_file(d, "tpch", "sf1").fingerprint(), sf1.fingerprint())
    assert_equal(read_lock_file(d, "tpch", "sf10").fingerprint(), sf10.fingerprint())
    assert_equal(read_lock_file(d, "clickbench", "full").fingerprint(), other.fingerprint())
    assert_true(sf1.fingerprint() != sf10.fingerprint())
    # A lock copied under another dataset's name is not that dataset's lock.
    Path(d + "/locks/tpch_sf100.lock").write_text(encode_lock(sf1))
    with assert_raises(contains="holds the lock of tpch/sf1"):
        _ = read_lock_file(d, "tpch", "sf100")


def _put(dir: String, name: String, data: String) raises:
    Path(dir + "/" + name).write_text(data)


def test_a_cache_directory_is_verified_against_a_lock() raises:
    var d = test_tmpdir() + "/lock_verify"
    makedirs(d + "/tpch/sf1", exist_ok=True)
    _put(d, "tpch/sf1/region.parquet", "abc")
    _put(d, "tpch/sf1/lineitem.parquet", "")
    var entries = List[LockEntry]()
    entries.append(LockEntry(String("tpch/sf1/region.parquet"), 3, _ABC, 5))
    entries.append(LockEntry(String("tpch/sf1/lineitem.parquet"), 0, _EMPTY, UNRECORDED_ROWS))
    var lock = DatasetLock(String("tpch"), String("sf1"), String(), entries^)
    var ok = verify_against_lock(lock, d)
    assert_true(ok.is_verified())
    assert_equal(len(ok.checks), 2)
    # A lock read back from its file verifies the same bytes.
    write_lock_file(d, lock)
    assert_true(verify_against_lock(read_lock_file(d, "tpch", "sf1"), d).is_verified())

    _put(d, "tpch/sf1/region.parquet", "abd")
    var altered = verify_against_lock(lock, d)
    assert_equal(altered.checks[0].status, FILE_SHA_MISMATCH)
    assert_equal(altered.checks[1].status, FILE_VERIFIED)
    _put(d, "tpch/sf1/region.parquet", "ab")
    assert_equal(verify_against_lock(lock, d).checks[0].status, FILE_SIZE_MISMATCH)
    _put(d, "tpch/sf1/region.parquet", "abcd")
    assert_equal(verify_against_lock(lock, d).checks[0].status, FILE_SIZE_MISMATCH)
    _put(d, "tpch/sf1/region.parquet", "abc")
    _put(d, "tpch/sf1/lineitem.parquet", "x")
    var longer = verify_against_lock(lock, d)
    assert_equal(longer.checks[1].status, FILE_SIZE_MISMATCH)
    assert_false(longer.is_usable())
    var elsewhere = test_tmpdir() + "/lock_verify_empty"
    makedirs(elsewhere, exist_ok=True)
    var missing = verify_against_lock(lock, elsewhere)
    assert_equal(missing.count(FILE_MISSING), 2)


def main() raises:
    test_the_lock_text_and_fingerprint_are_fixed()
    test_decode_inverts_encode()
    test_the_fingerprint_follows_every_field()
    test_an_edited_lock_is_refused()
    test_a_malformed_lock_is_refused()
    test_a_lock_is_built_only_from_a_usable_report()
    test_the_lock_file_is_written_once_and_read_back()
    test_one_cache_directory_holds_the_locks_of_several_datasets()
    test_a_cache_directory_is_verified_against_a_lock()
    print("OK")
