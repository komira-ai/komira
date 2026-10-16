# =============================================================================
# FileIdentity: what stat(2) says about a path, the settle clause, and the
# one predicate that decides whether a cached entry may be served.
# =============================================================================
#
# Each test works in its own fresh directory (mkdtemp) and removes it, so no
# two runs share a path. Ages are set with set_file_mtime_ns rather than
# waited for: a backdated mtime is an hour old the moment it is written.
# =============================================================================

from std.os import remove, rmdir
from std.os.path import exists
from std.tempfile import mkdtemp
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.file_identity import (
    DEFAULT_STALENESS_MIN_AGE_NS,
    FileIdentity,
    cached_entry_is_trustworthy,
    set_file_mtime_ns,
)

comptime _HOUR_NS = 3600 * 1_000_000_000


def _write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def _cleanup(dir: String, path: String) raises:
    if exists(path):
        remove(path)
    rmdir(dir)


def test_default_identity_is_invalid() raises:
    """FileIdentity() is the invalid identity, every field 0."""
    var i = FileIdentity()
    assert_false(i.valid)
    assert_equal(i.size, 0)
    assert_equal(i.mtime_ns, 0)
    assert_equal(i.ino, 0)
    assert_equal(i.dev, 0)
    assert_equal(i.age_ns, 0)


def test_stat_existing_file() raises:
    """A stat of a written file is valid, has its byte size and a non-zero
    inode, and matches a second stat of the same unchanged file."""
    var dir = mkdtemp()
    var path = dir + "/f.txt"
    try:
        _write(path, "abcdefg")
        var a = FileIdentity.stat_path(path)
        assert_true(a.valid)
        assert_equal(a.size, 7)
        assert_true(a.ino != 0)
        assert_true(a.mtime_ns > 0)
        var b = FileIdentity.stat_path(path)
        assert_true(a.same_file_as(b))
        assert_true(b.same_file_as(a))
    finally:
        _cleanup(dir, path)


def test_stat_missing_path_is_invalid_and_matches_nothing() raises:
    """A failed stat is the invalid identity; it matches neither a valid
    identity (either way round) nor another invalid one, and is never
    settled."""
    var dir = mkdtemp()
    var path = dir + "/present.txt"
    try:
        _write(path, "x")
        var good = FileIdentity.stat_path(path)
        var gone = FileIdentity.stat_path(dir + "/absent.txt")
        assert_false(gone.valid)
        assert_equal(gone.size, 0)
        assert_equal(gone.ino, 0)
        assert_false(gone.same_file_as(good))
        assert_false(good.same_file_as(gone))
        assert_false(gone.same_file_as(FileIdentity()))
        assert_false(gone.is_settled(0))
        assert_false(gone.is_settled(-1))
    finally:
        _cleanup(dir, path)


def test_same_file_as_compares_every_field() raises:
    """Changing any one of size, mtime, inode or device alone makes two
    otherwise identical valid identities differ; age does not count."""
    var base = FileIdentity()
    base.valid = True
    base.size = 10
    base.mtime_ns = 20
    base.ino = 30
    base.dev = 40
    base.age_ns = 50
    var same = base
    same.age_ns = 51
    assert_true(base.same_file_as(same))

    var c = base
    c.size = 11
    assert_false(base.same_file_as(c))
    c = base
    c.mtime_ns = 21
    assert_false(base.same_file_as(c))
    c = base
    c.ino = 31
    assert_false(base.same_file_as(c))
    c = base
    c.dev = 41
    assert_false(base.same_file_as(c))
    c = base
    c.valid = False
    assert_false(base.same_file_as(c))
    assert_false(c.same_file_as(base))


def test_is_settled_is_strictly_older_than_the_threshold() raises:
    """is_settled(m) is age_ns > m: equal is not settled, one less is."""
    var i = FileIdentity()
    i.valid = True
    i.age_ns = 5
    assert_false(i.is_settled(5))
    assert_true(i.is_settled(4))
    assert_false(i.is_settled(6))
    i.age_ns = -1
    assert_false(i.is_settled(0))


def test_set_file_mtime_ns_backdates_and_settles() raises:
    """A fresh file is not settled under the shipped threshold; backdated by
    an hour it is, its mtime is the value set to the nanosecond, and its age
    is about an hour. A missing path returns False."""
    assert_equal(DEFAULT_STALENESS_MIN_AGE_NS, 10_000_000_000)
    var dir = mkdtemp()
    var path = dir + "/aged.txt"
    try:
        _write(path, "payload")
        var fresh = FileIdentity.stat_path(path)
        assert_false(fresh.is_settled(DEFAULT_STALENESS_MIN_AGE_NS))
        var target = fresh.mtime_ns - _HOUR_NS + 123
        assert_true(set_file_mtime_ns(path, target))
        var aged = FileIdentity.stat_path(path)
        assert_equal(aged.mtime_ns, target)
        assert_true(aged.age_ns >= _HOUR_NS - 123)
        assert_true(aged.age_ns < _HOUR_NS + 600 * 1_000_000_000)
        assert_true(aged.is_settled(DEFAULT_STALENESS_MIN_AGE_NS))
        assert_false(fresh.same_file_as(aged))
        assert_false(set_file_mtime_ns(dir + "/absent.txt", target))
    finally:
        _cleanup(dir, path)


def test_cached_entry_is_trustworthy_needs_both_clauses() raises:
    """Served only when the identities match AND the current file is
    settled; min_age_ns <= 0 drops the settle clause but never the match."""
    var cached = FileIdentity()
    cached.valid = True
    cached.size = 1
    cached.mtime_ns = 2
    cached.ino = 3
    cached.dev = 4
    cached.age_ns = 100

    var current = cached
    assert_true(cached_entry_is_trustworthy(cached, current, 99))
    assert_false(cached_entry_is_trustworthy(cached, current, 100))
    assert_true(cached_entry_is_trustworthy(cached, current, 0))
    assert_true(cached_entry_is_trustworthy(cached, current, -5))

    current.age_ns = 0
    assert_false(cached_entry_is_trustworthy(cached, current, 1))
    assert_true(cached_entry_is_trustworthy(cached, current, 0))

    var other = cached
    other.ino = 9
    assert_false(cached_entry_is_trustworthy(cached, other, 99))
    assert_false(cached_entry_is_trustworthy(cached, other, 0))
    assert_false(cached_entry_is_trustworthy(cached, FileIdentity(), 0))


def main() raises:
    var s = TestSuite()
    s.test[test_default_identity_is_invalid]()
    s.test[test_stat_existing_file]()
    s.test[test_stat_missing_path_is_invalid_and_matches_nothing]()
    s.test[test_same_file_as_compares_every_field]()
    s.test[test_is_settled_is_strictly_older_than_the_threshold]()
    s.test[test_set_file_mtime_ns_backdates_and_settles]()
    s.test[test_cached_entry_is_trustworthy_needs_both_clauses]()
    s^.run()
