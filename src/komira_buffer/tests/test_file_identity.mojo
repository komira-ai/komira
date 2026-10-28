# =============================================================================
# test_file_identity.mojo — FileIdentity: stat, same-file comparison, the settle
# clause and the trust predicate.
# =============================================================================
#
# Each test writes its own file under $TEST_TMPDIR and ages it with
# `set_file_mtime_ns`, so the real predicate runs with the real default
# threshold:
#   - a missing path gives the invalid identity, which matches nothing;
#   - a stat of a file reports its size and a valid identity;
#   - a rewrite that changes the size is not the same file;
#   - a file backdated past the default threshold is settled, a fresh one is
#     not;
#   - the trust predicate needs both the field match and the settle clause;
#     `min_age_ns <= 0` turns the settle clause off.
# =============================================================================

from std.io import FileHandle
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.file_identity import (
    DEFAULT_STALENESS_MIN_AGE_NS,
    FileIdentity,
    cached_entry_is_trustworthy,
    set_file_mtime_ns,
)
from komira_libc.posix import _read_env


def _scratch_dir() -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        return String("/tmp")
    return d


def _path(name: String) -> String:
    return (_scratch_dir() + String("/komira_test_file_identity_")) + name


def _write(path: String, text: String) raises:
    var h = FileHandle(path, "w")
    h.write(text)
    h.close()


# One hour in nanoseconds, well past the 10 second default.
comptime _HOUR_NS: Int = 3_600_000_000_000


def test_invalid_identity_matches_nothing() raises:
    var missing = FileIdentity.stat_path(_path("does_not_exist"))
    assert_false(missing.valid, "a missing path must give the invalid identity")
    var blank = FileIdentity()
    assert_false(blank.valid)
    assert_false(missing.same_file_as(missing))
    assert_false(blank.same_file_as(blank))
    assert_false(missing.is_settled(1))
    assert_false(cached_entry_is_trustworthy(missing, missing, 0))


def test_stat_path_reports_the_file() raises:
    var p = _path("stat")
    _write(p, String("hello"))
    var a = FileIdentity.stat_path(p)
    assert_true(a.valid)
    assert_equal(a.size, 5)
    assert_true(a.ino != 0)
    assert_true(a.same_file_as(FileIdentity.stat_path(p)))


def test_size_change_is_a_different_file() raises:
    var p = _path("resize")
    _write(p, String("abc"))
    var before = FileIdentity.stat_path(p)
    _write(p, String("abcdef"))
    var after = FileIdentity.stat_path(p)
    assert_true(before.valid and after.valid)
    assert_false(before.same_file_as(after), "a size change must not match")


def test_mtime_change_is_a_different_file() raises:
    var p = _path("mtime")
    _write(p, String("abc"))
    assert_true(set_file_mtime_ns(p, 1_000_000_000_000_000_000))
    var before = FileIdentity.stat_path(p)
    assert_equal(before.mtime_ns, 1_000_000_000_000_000_000)
    assert_true(set_file_mtime_ns(p, 1_000_000_001_000_000_000))
    var after = FileIdentity.stat_path(p)
    assert_equal(after.mtime_ns, 1_000_000_001_000_000_000)
    assert_false(before.same_file_as(after), "an mtime change must not match")


def test_set_file_mtime_on_missing_path_fails() raises:
    assert_false(set_file_mtime_ns(_path("no_such_file"), 5))


def test_settle_clause_needs_an_old_mtime() raises:
    var p = _path("settle")
    _write(p, String("x"))
    var fresh = FileIdentity.stat_path(p)
    assert_false(
        fresh.is_settled(DEFAULT_STALENESS_MIN_AGE_NS),
        "a file written just now is inside the threshold",
    )
    # Back-date by an hour: the identity is now older than the default.
    var now_ns = fresh.mtime_ns + fresh.age_ns
    assert_true(set_file_mtime_ns(p, now_ns - _HOUR_NS))
    var old = FileIdentity.stat_path(p)
    assert_true(old.age_ns > DEFAULT_STALENESS_MIN_AGE_NS)
    assert_true(old.is_settled(DEFAULT_STALENESS_MIN_AGE_NS))


def test_trust_needs_match_and_settle() raises:
    var p = _path("trust")
    _write(p, String("payload"))
    var now_ns = FileIdentity.stat_path(p).mtime_ns + FileIdentity.stat_path(p).age_ns
    # Fresh file: fields match, settle clause fails.
    var cached = FileIdentity.stat_path(p)
    var current = FileIdentity.stat_path(p)
    assert_false(
        cached_entry_is_trustworthy(cached, current, DEFAULT_STALENESS_MIN_AGE_NS)
    )
    # Settle clause off (test configuration): the field match alone passes.
    assert_true(cached_entry_is_trustworthy(cached, current, 0))
    # Aged file: both clauses hold.
    assert_true(set_file_mtime_ns(p, now_ns - _HOUR_NS))
    var aged_cached = FileIdentity.stat_path(p)
    var aged_current = FileIdentity.stat_path(p)
    assert_true(
        cached_entry_is_trustworthy(
            aged_cached, aged_current, DEFAULT_STALENESS_MIN_AGE_NS
        )
    )
    # Aged but changed since the entry was built: the match clause refuses,
    # settled or not.
    assert_true(set_file_mtime_ns(p, now_ns - _HOUR_NS + 1_000_000_000))
    var moved = FileIdentity.stat_path(p)
    assert_false(
        cached_entry_is_trustworthy(
            aged_cached, moved, DEFAULT_STALENESS_MIN_AGE_NS
        )
    )
    assert_false(cached_entry_is_trustworthy(aged_cached, moved, 0))


def main() raises:
    var suite = TestSuite()
    suite.test[test_invalid_identity_matches_nothing]()
    suite.test[test_stat_path_reports_the_file]()
    suite.test[test_size_change_is_a_different_file]()
    suite.test[test_mtime_change_is_a_different_file]()
    suite.test[test_set_file_mtime_on_missing_path_fails]()
    suite.test[test_settle_clause_needs_an_old_mtime]()
    suite.test[test_trust_needs_match_and_settle]()
    suite^.run()
