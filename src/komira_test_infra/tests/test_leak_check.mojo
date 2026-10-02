# The leak check: this run's residue is LEAK; another run's (including one
# whose id extends this one) is not counted; a list that raises is
# CANNOT_TELL; an empty or invalid id is refused before any call.

from std.testing import assert_equal, assert_true

from komira_test_infra import (
    FakeObjectStore,
    VERDICT_CANNOT_TELL,
    VERDICT_CLEAN,
    VERDICT_LEAK,
    leak_check,
    parse_test_infra_config,
)

comptime _CFG: String = """
object_store {
  endpoint: "http://store.invalid:9000"
  region: "r1"
  bucket: "test-bucket"
  run_prefix: "runs/"
  credentials_file: "/c/credentials"
}
max_lease_seconds: 600
teardown_budget_seconds: 60
"""

comptime _ID: String = "1790000000-00000000000000dd"


def _store_with_neighbours() -> FakeObjectStore:
    var s = FakeObjectStore()
    s.seed("runs/1790000000-00000000000000dd0/x", "id that extends mine")
    s.seed("runs/1790000000-00000000000000ee/_lease.textproto", "another run")
    s.seed("other/1790000000-00000000000000dd/y", "outside the run prefix")
    return s^


def test_own_residue_is_leak_and_foreign_is_not_counted() raises:
    var cfg = parse_test_infra_config(_CFG)
    var s = _store_with_neighbours()
    s.seed("runs/" + _ID + "/_lease.textproto", "mine")
    s.seed("runs/" + _ID + "/seg/1.log", "mine")
    var v = leak_check(_ID, cfg, s)
    assert_equal(v.kind, VERDICT_LEAK)
    assert_equal(len(v.residue), 2)
    assert_equal(v.residue[0], "_lease.textproto")
    assert_equal(v.residue[1], "seg/1.log")
    assert_equal(s.calls[0], "bind")
    assert_equal(s.calls[1], "list_keys runs/" + _ID + "/")


def test_only_foreign_residue_is_clean() raises:
    var cfg = parse_test_infra_config(_CFG)
    var s = _store_with_neighbours()
    var v = leak_check(_ID, cfg, s)
    assert_equal(v.kind, VERDICT_CLEAN, String(v))
    assert_equal(len(v.residue), 0)


def test_raising_list_is_cannot_tell() raises:
    var cfg = parse_test_infra_config(_CFG)
    var s = FakeObjectStore()
    s.fail_list_calls.append(0)
    s.seed("runs/" + _ID + "/x", "mine")
    var v = leak_check(_ID, cfg, s)
    assert_equal(v.kind, VERDICT_CANNOT_TELL)
    assert_equal(v.exit_code(), 3)


def test_empty_or_invalid_id_is_refused() raises:
    var cfg = parse_test_infra_config(_CFG)
    for bad in ["", "Upper-Case", "a/b", "runs/../x"]:
        var s = FakeObjectStore()
        s.seed("runs/x", "something")
        var v = leak_check(bad, cfg, s)
        assert_equal(v.kind, VERDICT_CANNOT_TELL, bad)
        assert_true("refused" in String(v), String(v))
        assert_equal(len(s.calls), 0, "an invalid id reached the store: " + bad)


def main() raises:
    test_own_residue_is_leak_and_foreign_is_not_counted()
    test_only_foreign_residue_is_clean()
    test_raising_list_is_cannot_tell()
    test_empty_or_invalid_id_is_refused()
    print("test_leak_check: OK")
