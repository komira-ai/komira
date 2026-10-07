# The leak check: this run's residue is LEAK; another run's (including one
# whose id extends this one) is not counted; a list that raises is
# CANNOT_TELL; an empty or invalid id is refused before any call.

from std.testing import assert_equal, assert_true

from komira_test_bucket import FakeObjectStore, StoreTarget, leak_check
from komira_test_verdict import VERDICT_CANNOT_TELL, VERDICT_CLEAN, VERDICT_LEAK


def _target() -> StoreTarget:
    return StoreTarget("http://store.invalid:9000", "r1", "test-bucket", "/c/credentials")


comptime _ID: String = "1790000000-00000000000000dd"


def _store_with_neighbours() -> FakeObjectStore:
    var s = FakeObjectStore()
    s.seed("runs/1790000000-00000000000000dd0/x", "id that extends mine")
    s.seed("runs/1790000000-00000000000000ee/_lease.textproto", "another run")
    s.seed("other/1790000000-00000000000000dd/y", "outside the run prefix")
    return s^


def test_own_residue_is_leak_and_foreign_is_not_counted() raises:
    var target = _target()
    var s = _store_with_neighbours()
    s.seed("runs/" + _ID + "/_lease.textproto", "mine")
    s.seed("runs/" + _ID + "/seg/1.log", "mine")
    var v = leak_check(_ID, target, s)
    assert_equal(v.kind, VERDICT_LEAK)
    assert_equal(len(v.residue), 2)
    assert_equal(v.residue[0], "_lease.textproto")
    assert_equal(v.residue[1], "seg/1.log")
    assert_equal(s.calls[0], "bind")
    assert_equal(s.calls[1], "list_keys runs/" + _ID + "/")


def test_only_foreign_residue_is_clean() raises:
    var target = _target()
    var s = _store_with_neighbours()
    var v = leak_check(_ID, target, s)
    assert_equal(v.kind, VERDICT_CLEAN, String(v))
    assert_equal(len(v.residue), 0)


def test_out_of_prefix_keys_from_the_client_are_not_charged() raises:
    # The fake filters by prefix itself; this knob makes it return keys from
    # outside the run, so only the library's own guard keeps them out.
    var target = _target()
    var s = FakeObjectStore()
    s.extra_listed_keys.append("runs/" + _ID + "-x/obj.bin")
    s.extra_listed_keys.append("runs/" + _ID + "/../other/obj.bin")
    s.extra_listed_keys.append("other/" + _ID + "/y")
    var v = leak_check(_ID, target, s)
    assert_equal(v.kind, VERDICT_CLEAN, String(v))
    assert_equal(len(v.residue), 0)

    s = FakeObjectStore()
    s.seed("runs/" + _ID + "/mine.bin", "mine")
    s.extra_listed_keys.append("runs/" + _ID + "/../other/obj.bin")
    v = leak_check(_ID, target, s)
    assert_equal(v.kind, VERDICT_LEAK, String(v))
    assert_equal(len(v.residue), 1)
    assert_equal(v.residue[0], "mine.bin")


def test_raising_list_is_cannot_tell() raises:
    var target = _target()
    var s = FakeObjectStore()
    s.fail_list_calls.append(0)
    s.seed("runs/" + _ID + "/x", "mine")
    var v = leak_check(_ID, target, s)
    assert_equal(v.kind, VERDICT_CANNOT_TELL)
    assert_equal(v.exit_code(), 3)


def test_empty_or_invalid_id_is_refused() raises:
    var target = _target()
    for bad in ["", "Upper-Case", "a/b", "runs/../x"]:
        var s = FakeObjectStore()
        s.seed("runs/x", "something")
        var v = leak_check(bad, target, s)
        assert_equal(v.kind, VERDICT_CANNOT_TELL, bad)
        assert_true("refused" in String(v), String(v))
        assert_equal(len(s.calls), 0, "an invalid id reached the store: " + bad)


def main() raises:
    test_own_residue_is_leak_and_foreign_is_not_counted()
    test_only_foreign_residue_is_clean()
    test_out_of_prefix_keys_from_the_client_are_not_charged()
    test_raising_list_is_cannot_tell()
    test_empty_or_invalid_id_is_refused()
    print("test_leak_check: OK")
