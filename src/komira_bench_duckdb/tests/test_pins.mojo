# The check of a user-supplied DuckDB file against the pin table, on bytes the
# test makes up (the real binary is not in the tests).
#
# What each test proves:
# - test_the_pin_table_has_well_formed_digests: the pinned release is 1.5.6,
#   the digests are 64 lowercase hex digits, the sizes are positive, the
#   default version is pinned and an unknown version is not.
# - test_a_matching_digest_with_another_recorded_size_is_not_pinned: a pin row
#   whose recorded size is not the file's does not pin a file with the row's
#   digest.
# - test_a_file_is_pinned_when_the_digest_matches: with a table
#   built from known bytes, those bytes are PINNED; the same bytes with one
#   byte changed, with a byte appended, and an empty file are MISMATCH and
#   report the digest and size they have.
# - test_the_release_archive_is_recognised_and_refused: the archive's bytes
#   report PIN_IS_ARCHIVE and the message says to unpack it; they are not
#   pinned.
# - test_an_unpinned_version_is_refused_whatever_the_bytes: a version with no
#   row reports PIN_UNKNOWN_VERSION.
# - test_a_file_is_read_whole_and_hashed: a file written by the test comes
#   back with the SHA-256 and size of its bytes against the real table
#   (MISMATCH), and a path that does not exist raises.

from std.os import getenv, makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_crypto import hex_lower_array_32, sha256
from komira_bench_duckdb import (
    DEFAULT_DUCKDB_VERSION,
    DuckDbPin,
    PIN_IS_ARCHIVE,
    PIN_MISMATCH,
    PIN_PINNED,
    PIN_UNKNOWN_VERSION,
    check_against_pins,
    check_duckdb_file,
    duckdb_pins,
    find_pin,
)


def _digest(text: String) -> String:
    return hex_lower_array_32(sha256(text.as_bytes()))


def _table() -> List[DuckDbPin]:
    var pins = List[DuckDbPin]()
    var binary = String("the binary bytes")
    var archive = String("the archive bytes")
    pins.append(
        DuckDbPin(
            String("9.9.9"),
            String("abcdef0123"),
            _digest(archive),
            archive.byte_length(),
            _digest(binary),
            binary.byte_length(),
        )
    )
    return pins^


def test_the_pin_table_has_well_formed_digests() raises:
    var pins = duckdb_pins()
    assert_true(len(pins) >= 1)
    assert_equal(pins[0].version, String("1.5.6"))
    assert_equal(String(DEFAULT_DUCKDB_VERSION), String("1.5.6"))
    assert_equal(find_pin(String("1.5.6")), 0)
    assert_equal(find_pin(String("0.0.1")), -1)
    for i in range(len(pins)):
        for digest in [pins[i].archive_sha256.copy(), pins[i].binary_sha256.copy()]:
            assert_equal(digest.byte_length(), 64)
            for c in digest.as_bytes():
                assert_true((c >= UInt8(48) and c <= UInt8(57)) or (c >= UInt8(97) and c <= UInt8(102)))
        assert_true(pins[i].archive_size > 0)
        assert_true(pins[i].binary_size > 0)
        assert_true(pins[i].commit.byte_length() >= 10)


def test_a_file_is_pinned_when_the_digest_matches() raises:
    var pins = _table()
    var ok = check_against_pins(String("the binary bytes").as_bytes(), pins, String("9.9.9"))
    assert_equal(ok.status, PIN_PINNED)
    assert_true(ok.is_pinned())
    assert_equal(ok.sha256, _digest(String("the binary bytes")))
    var flipped = check_against_pins(String("the binary byteS").as_bytes(), pins, String("9.9.9"))
    assert_equal(flipped.status, PIN_MISMATCH)
    assert_false(flipped.is_pinned())
    assert_equal(flipped.sha256, _digest(String("the binary byteS")))
    assert_equal(flipped.size, 16)
    assert_true(flipped.describe().find(flipped.sha256) >= 0)
    var longer = check_against_pins(String("the binary bytes!").as_bytes(), pins, String("9.9.9"))
    assert_equal(longer.status, PIN_MISMATCH)
    assert_equal(longer.size, 17)
    var empty = check_against_pins(String("").as_bytes(), pins, String("9.9.9"))
    assert_equal(empty.status, PIN_MISMATCH)
    assert_equal(empty.size, 0)


def test_a_matching_digest_with_another_recorded_size_is_not_pinned() raises:
    var binary = String("the binary bytes")
    var wrong = List[DuckDbPin]()
    wrong.append(
        DuckDbPin(
            String("9.9.9"),
            String("abcdef0123"),
            _digest(String("the archive bytes")),
            17,
            _digest(binary),
            binary.byte_length() + 1,
        )
    )
    var got = check_against_pins(binary.as_bytes(), wrong, String("9.9.9"))
    assert_equal(got.status, PIN_MISMATCH)
    assert_equal(got.sha256, _digest(binary))


def test_the_release_archive_is_recognised_and_refused() raises:
    var got = check_against_pins(String("the archive bytes").as_bytes(), _table(), String("9.9.9"))
    assert_equal(got.status, PIN_IS_ARCHIVE)
    assert_false(got.is_pinned())
    assert_true(got.describe().find(String("unpack")) >= 0)


def test_an_unpinned_version_is_refused_whatever_the_bytes() raises:
    var got = check_against_pins(String("the binary bytes").as_bytes(), _table(), String("8.8.8"))
    assert_equal(got.status, PIN_UNKNOWN_VERSION)
    assert_false(got.is_pinned())


def test_a_file_is_read_whole_and_hashed() raises:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var dir = base + String("/bench_pins")
    makedirs(dir, exist_ok=True)
    var path = dir + String("/not_duckdb.bin")
    var body = String("not a duckdb binary\n")
    Path(path).write_text(body)
    var got = check_duckdb_file(path, String("1.5.6"))
    assert_equal(got.status, PIN_MISMATCH)
    assert_equal(got.sha256, _digest(body))
    assert_equal(got.size, body.byte_length())
    var raised = False
    try:
        _ = check_duckdb_file(dir + String("/missing.bin"), String("1.5.6"))
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
